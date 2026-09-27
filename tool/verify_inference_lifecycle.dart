// ignore_for_file: avoid_print
//
// 本地推理进程的生命周期治理（显存残留根治）。
//
// 覆盖三件事：
//   [1] pid 记录文件路径约定（App 退出后靠它精确回收孤儿进程）
//   [2] 无记录 / 记录失效（进程早已退出）时必须安全返回 0，不误杀
//   [3] **安全闸门**：记录里写的是本进程 pid，但镜像名不是推理服务
//       （llama / rwkv）时，必须拒绝终止 —— 否则 pid 被系统回收后会误杀
//       无关程序。这是本机制唯一有破坏性的地方，必须验证。
//
// 纯 Dart，可 `dart run` 直接跑（不需要 Flutter）。
//
// 运行：dart run tool/verify_inference_lifecycle.dart
import 'dart:convert';
import 'dart:io';

import 'package:novelcraft/ai/inference/inference_launcher.dart';

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

Future<void> writeRecord(Object? payload) async {
  await File(InferenceProcessLauncher.pidRecordPath)
      .writeAsString(jsonEncode(payload));
}

Future<void> main() async {
  final File record = File(InferenceProcessLauncher.pidRecordPath);

  print('=' * 78);
  print('[1] pid 记录文件约定');
  print('=' * 78);
  print('     ${InferenceProcessLauncher.pidRecordPath}');
  check('路径非空且带固定文件名',
      InferenceProcessLauncher.pidRecordPath.endsWith('.pid.json'), 'ok');
  check('落在系统临时目录下（跨 App 生命周期可读）',
      InferenceProcessLauncher.pidRecordPath
          .startsWith(Directory.systemTemp.path), 'ok');

  print('');
  print('=' * 78);
  print('[2] 失效记录：不得误杀、必须清理');
  print('=' * 78);

  if (record.existsSync()) await record.delete();
  check('无记录文件时返回 0',
      await InferenceProcessLauncher.reclaimOrphaned() == 0, 'ok（零开销）');

  await writeRecord(<String, Object?>{'pid': 999999, 'exe': 'llama-server.exe'});
  check('pid 已不存在时返回 0',
      await InferenceProcessLauncher.reclaimOrphaned() == 0, 'ok（进程早退出）');
  check('失效记录已被删除', !record.existsSync(), 'ok');

  await writeRecord(<String, Object?>{'pid': -1, 'exe': 'llama-server.exe'});
  check('非法 pid 时返回 0',
      await InferenceProcessLauncher.reclaimOrphaned() == 0, 'ok');

  await writeRecord('not-a-json-object');
  check('脏数据不抛异常且返回 0',
      await InferenceProcessLauncher.reclaimOrphaned() == 0, 'ok');
  if (record.existsSync()) await record.delete();

  print('');
  print('=' * 78);
  print('[3] 安全闸门：镜像名不匹配时绝不终止');
  print('=' * 78);

  // 故意用「当前 dart 进程的 pid + 不匹配的 exe 名」：闸门必须拦住。
  await writeRecord(<String, Object?>{
    'pid': pid,
    'exe': 'llama-server.exe',
  });
  final int killed = await InferenceProcessLauncher.reclaimOrphaned();
  check('镜像名不是推理服务 → 拒绝终止（返回 0）', killed == 0, 'pid=$pid 未被终止');
  check('当前进程未受影响（还能继续跑）', pid > 0, 'ok');
  if (record.existsSync()) await record.delete();

  print('');
  print('=' * 78);
  print('结果：$pass passed / $fail failed');
  print('=' * 78);
  if (fail > 0) exitCode = 1;
}