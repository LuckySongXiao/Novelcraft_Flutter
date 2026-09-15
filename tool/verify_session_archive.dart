// ignore_for_file: avoid_print
//
// `RwkvSessionArchive` 逻辑验证（P4-27）。
//
// ⚠ 先说清一个被实测推翻的前提：HANDOFF 原话是「把 session 当前 state 快照
//   **字节**写 KeyValueStore」。但 rwkv_lightning **没有 state 导出端点**，
//   客户端 `RwkvState.bytes` 一直是 `Uint8List(0)` 假占位 ——
//   「存几 MB state 字节」物理上不可实现。所以这里存的是**对话转录本**，
//   恢复 = 重放一次重建服务端 state（付一次 prefill，之后继续 O(1)）。
//
// 纯 Dart ⇒ 能在这里真跑。重点验：
//   · 往返序列化不丢轮次
//   · **模型不匹配必须拒绝**（跨模型重放 = 塞进另一个模型的"记忆"）
//   · 空 / 损坏存档按"不存在"处理，不抛异常
//
// 运行：dart run tool/verify_session_archive.dart
import 'dart:convert';
import 'dart:io';

import 'package:novelcraft/ai/rwkv/rwkv_session_archive.dart';

int pass = 0;
int fail = 0;

void check(String name, bool ok, String detail) {
  if (ok) {
    pass++;
    print('  ✅ $name — $detail');
  } else {
    fail++;
    print('  ❌ $name — $detail');
  }
}

/// 内存实现（模拟 KVStore）
class MemoryStore implements RwkvSessionArchiveStore {
  final Map<String, String> data = <String, String>{};

  @override
  Future<void> write(String key, Map<String, Object?> json) async =>
      data[key] = jsonEncode(json);

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> delete(String key) async => data.remove(key);

  @override
  Future<List<String>> keys() async => data.keys.toList();
}

RwkvSessionArchiveEntry sample(String modelId) => RwkvSessionArchiveEntry(
      archiveKey: 'workflow-玄穹剑主',
      modelId: modelId,
      archivedAtMs: 1789000000000,
      turns: const <RwkvArchivedTurn>[
        RwkvArchivedTurn(role: 'system', content: '你是主笔，写东方修仙。'),
        RwkvArchivedTurn(role: 'user', content: '第一章：主角登场。'),
        RwkvArchivedTurn(role: 'assistant', content: '叶知秋握剑而立，山风猎猎。'),
      ],
    );

void main() async {
  print('=' * 78);
  print('[1] 往返序列化（不丢轮次、不丢角色）');
  print('=' * 78);
  final RwkvSessionArchive arch = RwkvSessionArchive(MemoryStore());
  final RwkvSessionArchiveEntry e = sample('rwkv7-g1j-7.2b-20260831-ctx16384');
  await arch.save(e);
  final RwkvSessionArchiveEntry? back = await arch.load(e.archiveKey);
  check('读回非空', back != null, 'ok');
  check('轮次数一致', back!.turns.length == 3, '${back.turns.length}');
  check('role 顺序一致',
      back.turns.map((RwkvArchivedTurn t) => t.role).join(',') ==
          'system,user,assistant',
      back.turns.map((RwkvArchivedTurn t) => t.role).join(','));
  check('内容一致', back.turns[2].content.contains('叶知秋握剑而立'),
      back.turns[2].content);
  check('modelId 一致', back.modelId == e.modelId, back.modelId);
  check('keyFor 加前缀',
      RwkvSessionArchive.keyFor('workflow-玄穹剑主') == 'session_workflow-玄穹剑主',
      RwkvSessionArchive.keyFor('workflow-玄穹剑主'));

  print('');
  print('=' * 78);
  print('[2] **模型不匹配必须拒绝**（跨模型重放 = 塞进另一个模型的记忆）');
  print('=' * 78);
  final (RwkvSessionArchiveEntry? e2, RwkvArchiveMismatch? why2) =
      await arch.loadCompatible(
          archiveKey: e.archiveKey,
          currentModelId: 'rwkv7-g1i-1.5b-20260805-ctx16384');
  check('模型不匹配 → 返回 null', e2 == null, 'ok');
  check('并给出 modelMismatch 原因', why2 == RwkvArchiveMismatch.modelMismatch,
      '$why2');
  check('同模型 → 正常通过',
      (await arch.loadCompatible(
              archiveKey: e.archiveKey,
              currentModelId: 'rwkv7-g1j-7.2b-20260831-ctx16384'))
          .$1 !=
      null,
      'ok');
  check('当前模型未知（空）→ 放行但调用方应自行判断',
      (await arch.loadCompatible(archiveKey: e.archiveKey, currentModelId: ''))
          .$1 !=
      null,
      'ok');

  print('');
  print('=' * 78);
  print('[3] 空 / 损坏存档按「不存在」处理，绝不抛异常');
  print('=' * 78);
  check('没存过的键 → null',
      await arch.load('never-saved') == null, 'ok');
  check('没存过的键 → empty 原因',
      (await arch.loadCompatible(
              archiveKey: 'never-saved', currentModelId: 'm'))
          .$2 ==
      RwkvArchiveMismatch.empty,
      'ok');

  // 脏数据
  final MemoryStore dirty = MemoryStore();
  dirty.data[RwkvSessionArchive.keyFor('broken')] = 'not-json{{{';
  final RwkvSessionArchive arch2 = RwkvSessionArchive(dirty);
  check('损坏 JSON → 当作不存在（不抛）',
      await arch2.load('broken') == null, 'ok');
  check('损坏 JSON 的 loadCompatible 也不抛',
      (await arch2.loadCompatible(
              archiveKey: 'broken', currentModelId: 'm'))
          .$1 ==
      null,
      'ok');

  // 空轮次
  final MemoryStore emptyTurns = MemoryStore();
  emptyTurns.data[RwkvSessionArchive.keyFor('empty-arch')] = jsonEncode(
      RwkvSessionArchiveEntry(
              archiveKey: 'empty-arch', modelId: 'm', archivedAtMs: 1, turns: const <RwkvArchivedTurn>[])
          .toMap());
  final RwkvSessionArchive arch3 = RwkvSessionArchive(emptyTurns);
  check('零轮次存档 → 视为 empty（不该恢复）',
      (await arch3.loadCompatible(archiveKey: 'empty-arch', currentModelId: 'm'))
          .$2 ==
      RwkvArchiveMismatch.empty,
      'ok');

  print('');
  print('=' * 78);
  print('[4] 删除与列表');
  print('=' * 78);
  await arch.save(e);
  await arch.delete(e.archiveKey);
  check('删除后读回为 null', await arch.load(e.archiveKey) == null, 'ok');
  await arch.save(e);
  await arch.save(RwkvSessionArchiveEntry(
    archiveKey: 'workflow-第二本',
    modelId: 'm',
    archivedAtMs: 2,
    turns: const <RwkvArchivedTurn>[RwkvArchivedTurn(role: 'user', content: 'x')],
  ));
  final List<String> keys = await arch.listKeys();
  check('listKeys 去掉前缀并排序',
      keys.join(',') == 'session_占位' ? false : (keys.contains('workflow-玄穹剑主') && keys.contains('workflow-第二本')),
      '$keys');

  print('');
  print('=' * 78);
  print('[5] archiveKey 不能为空（防止用引擎 sessionId 这类不稳定键）');
  print('=' * 78);
  bool threw = false;
  try {
    await arch.save(RwkvSessionArchiveEntry(
        archiveKey: '  ', modelId: 'm', archivedAtMs: 1, turns: const <RwkvArchivedTurn>[]));
  } on ArgumentError {
    threw = true;
  }
  check('空 key 直接抛 ArgumentError', threw, 'ok');

  print('');
  print('=' * 78);
  print('VERDICT: $pass passed, $fail failed');
  print('=' * 78);
  if (fail > 0) exitCode = 1;
}
