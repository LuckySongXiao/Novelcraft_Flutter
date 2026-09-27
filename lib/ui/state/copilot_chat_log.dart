// 「边聊边写」的聊天记录 —— 落 KVStore（`copilot/chat_log`），重启后接着上一段对话。
//
// 与 `ChapterReferral`（关联到哪一章）**分开成两个模块**：两者是正交的关注点，
// 各自一个 KV 键、各自恢复，互不牵连。
//
// 限长策略（防止记录文件无限膨胀）：
//   * 最多 [maxEntries] 条；
//   * 且累计正文字符数不超过 [maxTotalChars]；
//   * 从最新往回取，**至少保留最新 1 条**（它再长也留）。
// 刻意**不在单条内容中间截断**：截断会让恢复出来的对话与当时看到的不一致
// （长文改写结果本来就以章节正文为准，聊天里那条只是回显）。
//
// 开场白（`AC.Welcome`）也在这里补：只有"恢复不到任何记录"时才生成一条。
// 放在页面 initState 里补会与异步恢复抢时序（先写后读会把上次的记录冲掉）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ai/models/chat.dart';
import '../../core/di.dart';
import '../../data/storage/key_value_store.dart';
import '../../l10n/l10n.dart';

/// 聊天记录（页面渲染 + 重启恢复的唯一数据源）。
class CopilotChatLog {
  const CopilotChatLog({this.messages = const <ChatMessage>[]});

  /// 按时间正序排列的消息流。
  final List<ChatMessage> messages;
}

/// 聊天记录控制器。
class CopilotChatLogController extends Notifier<CopilotChatLog> {
  /// KVStore 作用域 / 键（与关联状态同 scope，便于一起清理）。
  static const String _scope = 'copilot';
  static const String _key = 'chat_log';

  /// 最多保留的条数。
  static const int maxEntries = 60;

  /// 累计正文字符数上限。
  static const int maxTotalChars = 60000;

  @override
  CopilotChatLog build() {
    // 先给空记录保证首帧可渲染，再异步恢复（与关联状态同一套写法）
    unawaited(_restore());
    return const CopilotChatLog();
  }

  /// 追加一条消息（用户输入 / AI 回复 / 系统汇报）并落盘。
  Future<void> append(ChatMessage message) async {
    state = CopilotChatLog(
      messages: _trim(<ChatMessage>[...state.messages, message]),
    );
    await _save();
  }

  /// 清空会话（用户显式操作）：清掉 KVStore 记录并重置为一条全新开场白。
  ///
  /// 没有此入口时，用户想"重新开一段对话"只能卸载重装（记录落在
  /// KVStore，重启不丢）。落盘失败仅记日志 —— 内存态已清，刷新后
  /// 由 _restore 的空记录分支自然补开场白。
  Future<void> clear() async {
    state = CopilotChatLog(messages: <ChatMessage>[_welcome()]);
    try {
      final KeyValueStore kv = await ref.read(keyValueStoreProvider.future);
      await kv.writeJson(_scope, _key, jsonEncode(
        state.messages.map((ChatMessage m) => m.toJson()).toList(growable: false),
      ));
    } on Object catch (e) {
      ref.read(aiLoggerProvider).warning('清空聊天记录落盘失败：$e');
    }
  }

  // ---------------------------------------------------------------------------
  // 持久化 + 限长
  // ---------------------------------------------------------------------------

  Future<void> _save() async {
    try {
      final KeyValueStore kv = await ref.read(keyValueStoreProvider.future);
      final String payload = jsonEncode(
        state.messages.map((ChatMessage m) => m.toJson()).toList(growable: false),
      );
      await kv.writeJson(_scope, _key, payload);
    } on Object catch (e) {
      ref.read(aiLoggerProvider).warning('保存聊天记录失败：$e');
    }
  }

  Future<void> _restore() async {
    try {
      final KeyValueStore kv = await ref.read(keyValueStoreProvider.future);
      final String? raw = await kv.readJson(_scope, _key);
      final List<ChatMessage> restored = <ChatMessage>[];
      if (raw != null && raw.isNotEmpty) {
        final Object? decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final Object? item in decoded) {
            if (item is Map) {
              restored.add(ChatMessage.fromJson(item.cast<String, dynamic>()));
            }
          }
        }
      }
      // ⚠ 恢复不覆盖"已经在聊"的现场：恢复是异步的，用户完全可能在它落地前
      // 就发出了第一条消息（API 层没有"加载中"闸门）。此时宁可少恢复几条历史，
      // 也不能把刚说的话吞掉。
      final bool idle = state.messages.isEmpty;

      if (restored.isEmpty) {
        // 首次运行（或记录被清空）：补一条开场白并落盘
        if (!idle) return;
        state = CopilotChatLog(messages: <ChatMessage>[_welcome()]);
        await _save();
        return;
      }
      if (!idle) return;
      state = CopilotChatLog(messages: _trim(restored));
    } on Object catch (e) {
      ref.read(aiLoggerProvider).warning('恢复聊天记录失败：$e');
      if (state.messages.isEmpty) {
        state = CopilotChatLog(messages: <ChatMessage>[_welcome()]);
      }
    }
  }

  /// 从最新往回取，按条数与总字数双重限长。
  static List<ChatMessage> _trim(List<ChatMessage> all) {
    final List<ChatMessage> kept = <ChatMessage>[];
    int chars = 0;
    for (int i = all.length - 1; i >= 0; i--) {
      if (kept.length >= maxEntries) break;
      final int len = all[i].content.length;
      // 至少保留最新一条：单条超上限也认
      if (kept.isNotEmpty && chars + len > maxTotalChars) break;
      kept.add(all[i]);
      chars += len;
    }
    return kept.reversed.toList(growable: false);
  }

  /// 会话开场白（与页面原先在 initState 里补的那条完全一致）。
  ChatMessage _welcome() => ChatMessage.system(ref.read(l10nProvider).t(
        'AC.Welcome',
        '这里是 NovelCraft AI 协作工作台。\n• 在「自由聊天」可以与默认提供商的大模型自由问答；\n• 在「一键工作流」可以执行主编 / 写作 / 审稿 / 一致性检查 等完整 Agent 流水线。\n先到「AI 配置」注册并设置默认模型后开始使用更稳定。',
      ));
}

/// 聊天记录 —— 全局单例，页面销毁与 App 重启都不丢。
final copilotChatLogProvider =
    NotifierProvider<CopilotChatLogController, CopilotChatLog>(
        CopilotChatLogController.new);