// 写作质量闸回归测试（RWKV7-G1J 长文实测问题的定点复现）：
//   ① 整章段落复读 → 二次删重定稿必须被采纳，复读稿不得落库；
//   ② 收尾语「（全文完）」必须从正文剥离（模型把「一章」误当「全书」写完）；
//   ③ 写手通道不得累积历史（同一写手被派到多段时，回灌自己上一段是
//      整章自我复读的主要结构性来源）；
//   ④ 新增质量阈值 maxRepeatRatio 的归一化钳制。
//
// 运行：flutter test test/writing_quality_gate_test.dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novelcraft/ai/models/chat.dart';
import 'package:novelcraft/ai/workflow/agent_state_manager.dart';
import 'package:novelcraft/application/services/multi_agent_book_generation_service.dart';
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/chapter_repository.dart';
import 'package:novelcraft/data/repositories/plot_repository.dart';
import 'package:novelcraft/data/repositories/project_repository.dart';
import 'package:novelcraft/data/repositories/volume_repository.dart';

/// 复读稿：A/B 两句交替 300 段（相邻不相等，故不会被「相邻去重」抹平，
/// 但去重后只剩 2 种 → 段落级复读率 ≈ 99%）。
String _alternatingText() {
  const String a = '主角拔剑斩向傀儡，剑光如练，气浪翻涌。';
  const String b = '师姐立于石阶之上，衣袂翻飞，目光沉静。';
  final StringBuffer sb = StringBuffer();
  for (int i = 0; i < 150; i++) {
    sb
      ..writeln(a)
      ..writeln()
      ..writeln(b)
      ..writeln();
  }
  return sb.toString();
}

/// 单段回复（约 900 字）：分段串行按字数驱动，需要多轮才会收敛。
String _segText(int start) => _distinctText(start: start).substring(0, 900);

/// 合格稿：300 个互不相同的段落（复读率 0，字数 ≈ 1.1 万）。
String _distinctText({int start = 1}) {
  final StringBuffer sb = StringBuffer();
  for (int i = start; i < start + 300; i++) {
    sb
      ..writeln('第 $i 段：主角沿山道前行，遇见第 $i 位试炼者，剑意与心境各不相同。')
      ..writeln();
  }
  return sb.toString();
}

/// 脚本化假执行器：按 system/user 关键词路由；记录每次调用的消息条数
/// （用于断言「写手通道不累积历史」）。
class _ScriptedChat {
  _ScriptedChat({
    required this.assemblyFirst,
    required this.assemblyRetry,
    this.segmentFirst = '',
    this.segmentNext = '',
  });

  /// 首次「拼接定稿」返回的整章正文。
  final String assemblyFirst;

  /// 质量闸触发后「二次定稿」返回的整章正文。
  final String assemblyRetry;

  /// 分段串行工艺：第 1 段（开篇）的回复；后续段按轮次返回**不同**内容
  ///（若每轮返回同一段文本，会被质量闸判为复读 —— 这正是闸生效的证据）。
  final String segmentFirst;
  final String segmentNext;

  /// 续写轮次计数（决定第 2、3… 轮返回哪一段文本）。
  int _segRound = 0;

  final List<String> userCalls = <String>[];
  final List<int> messageCounts = <int>[];

  Future<String> call(
    String systemPrompt,
    List<ChatMessage> messages, {
    required int maxTokens,
    double temperature = 0.85,
    // 客户端 state 会话标识（[AgentChatExecutor] 契约的一部分）：
    // 打桩不关心，但签名必须对齐。
    String? sessionKey,
  }) async {
    final String user = messages.isEmpty ? '' : messages.last.content;
    userCalls.add(user);
    messageCounts.add(messages.length);

    if (systemPrompt.contains('MainAgent')) {
      return '核心冲突：玄穹宗面临魔渊复苏。';
    }
    // 主笔工艺（单笔直书 / 分段串行 / 续写优选）
    if (systemPrompt.contains('主笔')) {
      if (user.contains('本章要点')) {
        _segRound++;
        return _segText(1 + _segRound * 20);
      }
      if (user.contains('接着上文继续写')) {
        _segRound++;
        // 每轮返回不同的 900 字文本（复读检测会因此判定为健康）
        return _segRound <= 1 ? segmentNext : _segText(11 + _segRound * 20);
      }
      if (user.contains('请从本章开篇写起')) return segmentFirst;
      if (user.contains('请一次写出本章完整正文')) return segmentFirst;
      return segmentFirst;
    }
    if (systemPrompt.contains('大纲规划智能体')) {
      if (user.contains('制定本卷大纲')) return '本卷：入门 → 历练。';
      if (user.contains('制定章节大纲')) return '本章：主角初入宗门。';
      return '大纲内容。';
    }
    if (systemPrompt.contains('Team Lead')) {
      if (user.contains('输出 JSON 数组')) {
        // 两段都派给 combat 写手 → 同一个写手通道被调用两次
        return '[{"agent":1,"persona":"combat","title":"试炼之战",'
            '"brief":"主角与傀儡交手","boundary":"止于傀儡倒下","wordTarget":1200},'
            '{"agent":2,"persona":"combat","title":"再战傀儡",'
            '"brief":"主角继续深入","boundary":"止于洞窟入口","wordTarget":1200}]';
      }
      if (user.contains('逐段验收')) {
        return '{"paragraphs":[{"agent":1,"accepted":true,"problems":""},'
            '{"agent":2,"accepted":true,"problems":""}],'
            '"report":{"timeRange":"入门第一天","themeTask":"主角拜入玄穹宗",'
            '"gains":"完成拜师","safeguards":"注意师姐线"},"updates":[]}';
      }
      // 二次定稿提示词带「⚠ 上一稿不合格」，必须优先于首次定稿判断
      if (user.contains('⚠ 上一稿不合格')) return assemblyRetry;
      if (user.contains('拼接为整章正文')) return assemblyFirst;
      return '组长回复。';
    }
    if (systemPrompt.contains('SubAgent Writer')) {
      return '主角在试炼中与傀儡交手，剑光交错，气浪翻涌。' * 60;
    }
    if (systemPrompt.contains('writer-')) return '人物履历：拜入玄穹宗。';
    return '';
  }
}

void main() {
  late AppDatabase db;
  late AgentStateManager states;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    states = AgentStateManager();
  });

  tearDown(() async => db.close());

  MultiAgentBookGenerationService buildService(_ScriptedChat chat) =>
      MultiAgentBookGenerationService(
        projects: ProjectRepository(db),
        plots: PlotRepository(db),
        volumes: VolumeRepository(db),
        chapters: ChapterRepository(db),
        writingProvider: () => null,
        stateManager: states,
        chatExecutor: chat.call,
      );

  Future<ChapterRow> runOneChapter(
    _ScriptedChat chat, {
    WritingCraft craft = WritingCraft.team,
  }) async {
    final MultiAgentBookResult r = await buildService(chat).generate(
      config: MultiAgentBookConfig(
        bookTitle: '质量闸测试书',
        authorName: '作者',
        targetVolumes: 1,
        chaptersPerVolume: 1,
        craft: craft,
      ),
    );
    expect(r.isSuccess, isTrue,
        reason: '${r.message} | ${r.warnings.join(' || ')}');
    final ProjectRepository projects = ProjectRepository(db);
    final List<ProjectRow> p = await projects.getAll();
    final List<ChapterRow> chapters =
        await ChapterRepository(db).getByProjectId(p.first.id);
    expect(chapters, hasLength(1));
    return chapters.single;
  }

  test('段落复读 → 二次删重定稿被采纳，复读稿不落库', () async {
    final _ScriptedChat chat = _ScriptedChat(
      assemblyFirst: _alternatingText(),
      assemblyRetry: _distinctText(),
    );

    final ChapterRow ch = await runOneChapter(chat);

    // 二次定稿触发过一次
    final int retries = chat.userCalls
        .where((String u) => u.contains('⚠ 上一稿不合格'))
        .length;
    expect(retries, 1, reason: '复读超阈值必须触发一次删重定稿');

    expect(ch.content, contains('第 1 段'), reason: '采纳二次定稿');
    expect(ch.content, isNot(contains('师姐立于石阶之上')),
        reason: '复读稿不得落库');
    expect(ch.status, 'Completed', reason: '删重后达标 → 视为已完成');
  });

  test('收尾语「（全文完）」从正文剥离', () async {
    final _ScriptedChat chat = _ScriptedChat(
      assemblyFirst: '${_distinctText()}\n（全文完）',
      assemblyRetry: _distinctText(),
    );

    final ChapterRow ch = await runOneChapter(chat);

    expect(ch.content, isNot(contains('全文完')),
        reason: '收尾语是元信息，必须剥离');
    expect(ch.content, isNot(contains('（完）')));
    expect(ch.status, 'Completed');
    // 未因复读触发重试（合格稿只定稿一次）
    final int retries = chat.userCalls
        .where((String u) => u.contains('⚠ 上一稿不合格'))
        .length;
    expect(retries, 0);
  });

  test('同写手被派到多段时，第二次调用只带本轮消息（不回灌自己上一段）', () async {
    final _ScriptedChat chat = _ScriptedChat(
      assemblyFirst: _distinctText(),
      assemblyRetry: _distinctText(),
    );

    await runOneChapter(chat);

    final int i1 = chat.userCalls.indexWhere((String u) => u.contains('段落 1/'));
    final int i2 = chat.userCalls.indexWhere((String u) => u.contains('段落 2/'));
    expect(i1, isNonNegative);
    expect(i2, isNonNegative);
    expect(chat.messageCounts[i1], 1,
        reason: '写手是「每段独立生成」，不得带历史');
    expect(chat.messageCounts[i2], 1,
        reason: '旧实现会把上一段自己的产出回灌 → 整段自我复读');
  });

  test('分段串行（duo）：按剩余字数驱动续写、只带上一段尾部', () async {
    final _ScriptedChat chat = _ScriptedChat(
      assemblyFirst: '',
      assemblyRetry: '',
      // 每轮只回 900 字 → 4500 字章必须多轮补齐（验证「按字数驱动」而非固定段数）
      segmentFirst: _segText(1),
      segmentNext: _segText(11),
    );

    final ChapterRow ch = await runOneChapter(chat, craft: WritingCraft.duo);

    final int seg1 =
        chat.userCalls.indexWhere((String u) => u.contains('请从本章开篇写起'));
    final int seg2 =
        chat.userCalls.indexWhere((String u) => u.contains('紧接上文继续写'));
    expect(seg1, isNonNegative);
    expect(seg2, isNonNegative, reason: '每轮 900 字，4500 字章必须续写多轮');
    // 主笔通道 keepHistory=false：每次都只带本轮消息（上文尾部在提示词里）
    expect(chat.messageCounts[seg1], 1);
    expect(chat.messageCounts[seg2], 1);
    // A1：上下文标记由 `【上文结尾】` 改为明确「禁止回抄」的
    // `【前文末尾（仅供衔接上下文，**不要输出这一段**）】`。
    expect(chat.userCalls[seg2], contains('前文末尾'),
        reason: '续写段必须携带上一段尾部以保证衔接');
    expect(chat.userCalls[seg2], contains('不要输出这一段'),
        reason: 'A1：必须显式禁止模型把回灌的尾部抄进正文');
    expect(chat.userCalls[seg2], contains('上一段写得太短'),
        reason: '上一段 900 < 目标 2200×0.6 → 必须明确要求补足字数');
    // 不走组长派活 / 验收（team 工艺独有）
    expect(chat.userCalls.any((String u) => u.contains('输出 JSON 数组')), isFalse);
    expect(ch.status, 'Completed', reason: '多轮补齐后必须过 4000 字质量闸');
    expect(ch.content, contains('第 1 段'));
    expect(ch.content, contains('第 11 段'), reason: '多轮产出都要被拼接');
  });

  test('续写优选（beam）：每轮并发 N 份候选、择优续写直至达标', () async {
    final _ScriptedChat chat = _ScriptedChat(
      assemblyFirst: '',
      assemblyRetry: '',
    );

    final ChapterRow ch = await runOneChapter(chat, craft: WritingCraft.beam);

    // 目标 = max(4200, 3200×1.2=3840) = 4200 字，每轮 5 候选 × ~900 字 → 5 轮
    final int beamCalls =
        chat.userCalls.where((String u) => u.contains('本章要点')).length;
    expect(beamCalls, 25, reason: '5 轮 × 每轮 5 份候选');
    expect(
      chat.userCalls.firstWhere((String u) => u.contains('本章要点')),
      contains('【本卷背景】'),
      reason: 'beam 候选提示词 = 本章要点 + 本卷背景 + 前文尾部（极简续写式）',
    );
    expect(chat.userCalls.any((String u) => u.contains('输出 JSON 数组')), isFalse,
        reason: 'beam 工艺不走组长 JSON 派活');
    expect(ch.status, 'Completed', reason: '多轮择优补齐后必须过字数闸');
    expect(ch.content, contains('第 21 段'),
        reason: '第 1 轮 5 份候选同分时取第一份');
    expect(ch.content!.length, greaterThanOrEqualTo(4200),
        reason: '5 轮择优结果都要被拼接（每轮 ~900 字 × 5 ≈ 4500）');
  });

  test('单笔直书（solo）：1 次调用，目标字数被钳到 2600（实测超 3000 即退化）', () async {
    final _ScriptedChat chat = _ScriptedChat(
      assemblyFirst: '',
      assemblyRetry: '',
      segmentFirst: _distinctText(),
    );

    final ChapterRow ch = await runOneChapter(chat, craft: WritingCraft.solo);

    final int call = chat.userCalls
        .indexWhere((String u) => u.contains('请一次写出本章完整正文'));
    expect(call, isNonNegative);
    expect(chat.userCalls[call], contains('目标 2600 字'),
        reason: '章目标 4500 也要钳到 2600 —— solo 只适合短章');
    expect(chat.messageCounts[call], 1);
    expect(ch.status, 'Completed');
  });

  test('退化截断只砍退化尾巴，不误伤正文主体（回归：整篇退化会被砍成几十字）', () async {
    // 真正 4-gram 多样的正文（用伪随机词表拼句，避免「只换数字」造成的假退化）
    const List<String> words = <String>[
      '剑冢', '寒潭', '傀儡', '长老', '星图', '断刃', '阵法', '符箓', '灵脉', '铜镜',
      '山道', '雨幕', '灯火', '账本', '枯井', '石阶', '铁链', '铜鼎', '沙暴', '孤舟',
    ];
    final StringBuffer healthy = StringBuffer();
    int seed = 7;
    int next(int m) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed % m;
    }

    for (int i = 0; i < 200; i++) {
      final StringBuffer line = StringBuffer();
      for (int k = 0; k < 16; k++) {
        line.write(words[next(words.length)]);
      }
      healthy.writeln('$line，这是第 $i 次推演。');
      healthy.writeln();
    }
    final String body = healthy.toString();
    // 相邻互不相同的复读尾巴（绕开「相邻去重」，必须靠退化截断处理）
    final String degenerate = <String>[
      for (int i = 0; i < 200; i++)
        i.isEven ? '他抬起头，看着天空，什么也没说。' : '风从窗缝里灌进来，吹动了桌上的纸页。',
    ].join('\n\n');

    final _ScriptedChat chat = _ScriptedChat(
      assemblyFirst: '$body\n\n$degenerate',
      assemblyRetry: '$body\n\n$degenerate',
    );
    final ChapterRow ch = await runOneChapter(chat);

    expect(ch.content!.length, greaterThan((body.length * 0.8).floor()),
        reason: '正文主体必须完整保留 —— 旧实现会在这里砍到只剩几十字');
    expect(ch.content!.length, lessThan(body.length + degenerate.length),
        reason: '退化尾巴必须被截断');
    expect(ch.content, isNot(contains('什么也没说')));
  });

  test('maxRepeatRatio 归一化钳制到 [0.1, 0.95]', () {
    const MultiAgentBookConfig tooLoose =
        MultiAgentBookConfig(bookTitle: 'a', authorName: 'b', maxRepeatRatio: 5);
    expect(tooLoose.normalize().normalized.maxRepeatRatio, 0.95);

    const MultiAgentBookConfig tooTight = MultiAgentBookConfig(
        bookTitle: 'a', authorName: 'b', maxRepeatRatio: 0.01);
    expect(tooTight.normalize().normalized.maxRepeatRatio, 0.1);

    const MultiAgentBookConfig ok = MultiAgentBookConfig(
        bookTitle: 'a', authorName: 'b', maxRepeatRatio: 0.4);
    expect(ok.normalize().normalized.maxRepeatRatio, 0.4);
  });
}
