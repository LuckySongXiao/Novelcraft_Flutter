// ignore_for_file: avoid_print
//
// `RwkvLightningLaunchArgs` 的参数组装 + 启动前硬校验（P4-25）。
// 纯 Dart，可 `dart run` 直接跑（不需要 Flutter）。
//
// 运行：dart run tool/verify_launch_args.dart
import 'dart:io';

import 'package:novelcraft/ai/rwkv/rwkv_lightning_launch_args.dart';

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

void main() {
  print('=' * 78);
  print('[1] 参数组装：必须与 llama.cpp 的 CLI 完全不重叠');
  print('=' * 78);
  const a = RwkvLightningLaunchArgs(
    modelPath: '/m/rwkv7-g1j-7.2b.pth',
    vocabPath: '/m/_assets/rwkv_vocab_v20230424.txt',
    port: 8000,
    stateDbPath: '/m/_tools/_states/rwkv_lightning_sessions.db',
  );
  final args = a.toArgs();
  final joined = args.join(' ');
  print('     $joined');
  check('用 --model-path（不是 llama.cpp 的 --model）',
      args.contains('--model-path') && !args.contains('--model'),
      args.contains('--model-path') ? 'ok' : '缺失');
  check('带 --vocab-path（外置词表，缺它必 crash）',
      args.contains('--vocab-path'), 'ok');
  check('默认带 --chunk-load（避免整份 .pth 进内存）',
      args.contains('--chunk-load'), 'ok');
  check('默认 --chunk-size 128', joined.contains('--chunk-size 128'), 'ok');
  check('显式 --state-db-path（不污染 CWD）',
      args.contains('--state-db-path'), 'ok');
  check('不带 llama.cpp 专属参数',
      !joined.contains('--ctx-size') && !joined.contains('--n-gpu-layers'),
      'ok');
  check('密码为空时不输出 --password', !args.contains('--password'), 'ok');

  print('');
  print('=' * 78);
  print('[2] 动态加载：目录 + 开关');
  print('=' * 78);
  const dyn = RwkvLightningLaunchArgs(
    modelPath: '/m/lightning',
    vocabPath: '/m/_assets/rwkv_vocab_v20230424.txt',
    enableDynamicModelLoading: true,
  );
  check('目录模式带 --enable-dynamic-loading',
      dyn.toArgs().contains('--enable-dynamic-loading'), 'ok');

  print('');
  print('=' * 78);
  print('[3] 启动前硬校验（两条秒退原因）');
  print('=' * 78);

  // ① GGUF 混入
  final gguf = preflightLightningArgs(
    const RwkvLightningLaunchArgs(
        modelPath: '/m/rwkv7-g1j-Q6_K.gguf', vocabPath: '/m/v.txt'),
    isDirectory: false,
    vocabSizeBytes: 1100000,
    modelSizeBytes: 5000000000,
  );
  check('拦 GGUF 混入', !gguf.ok && (gguf.message ?? '').contains('GGUF'),
      (gguf.message ?? '').split('\n').first);

  // ② 词表缺失
  final noVocab = preflightLightningArgs(
    const RwkvLightningLaunchArgs(modelPath: '/m/a.pth', vocabPath: '/m/v.txt'),
    isDirectory: false,
    vocabSizeBytes: null,
    modelSizeBytes: 100,
  );
  check('拦词表缺失', !noVocab.ok && (noVocab.message ?? '').contains('不存在'),
      (noVocab.message ?? '').split('\n').first);

  // ③ 词表过小（损坏）
  final smallVocab = preflightLightningArgs(
    const RwkvLightningLaunchArgs(modelPath: '/m/a.pth', vocabPath: '/m/v.txt'),
    isDirectory: false,
    vocabSizeBytes: 1024,
    modelSizeBytes: 100,
  );
  check('拦词表损坏（<500KB）', !smallVocab.ok, 
      (smallVocab.message ?? '').split('\n').first);

  // ④ 目录但没开动态加载
  final dirNoFlag = preflightLightningArgs(
    const RwkvLightningLaunchArgs(modelPath: '/m/lightning', vocabPath: '/m/v.txt'),
    isDirectory: true,
    vocabSizeBytes: 1100000,
    modelSizeBytes: null,
  );
  check('拦「目录 + 未开动态加载」', !dirNoFlag.ok,
      (dirNoFlag.message ?? '').split('\n').first);

  // ⑤ 正常通过
  final okCase = preflightLightningArgs(
    const RwkvLightningLaunchArgs(
        modelPath: '/m/rwkv7-g1j-7.2b.pth', vocabPath: '/m/v.txt'),
    isDirectory: false,
    vocabSizeBytes: 1093733,
    modelSizeBytes: 14400864256,
  );
  check('正常配置放行', okCase.ok, 'ok');

  // ⑥ .rwkvq 量化权重也放行
  final rwkvq = preflightLightningArgs(
    const RwkvLightningLaunchArgs(
        modelPath: '/m/a.w8a16.rwkvq', vocabPath: '/m/v.txt'),
    isDirectory: false,
    vocabSizeBytes: 1093733,
    modelSizeBytes: 8000000000,
  );
  check('放行 .rwkvq（W8A16 量化）', rwkvq.ok, 'ok');

  print('');
  print('=' * 78);
  print('[4] 词表真实体积核对（PITFALLS §30.8：文档写 2.5MB，实测 1.07MB）');
  print('=' * 78);
  final f = File('rwkv_models/_assets/rwkv_vocab_v20230424.txt');
  if (f.existsSync()) {
    final int n = f.lengthSync();
    check('本地词表 ≥ 500KB 守卫阈值', n >= 500 * 1024,
        '${(n / 1024).toStringAsFixed(0)} KB');
  } else {
    print('     （本地尚无词表，跳过 —— 可在 AI 配置页点「安装内置引擎 + 词表」）');
  }

  print('');
  print('=' * 78);
  print('VERDICT: $pass passed, $fail failed');
  print('=' * 78);
  if (fail > 0) exitCode = 1;
}
