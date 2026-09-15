// ignore_for_file: avoid_print
//
// 「模型 ↔ 显存适配」判定验证（含 GPU 探测的 CSV 解析）。
//
// 为什么值得单独验：判定写错的后果很实在 ——
//   太松 → 用户下载 13.4GB 然后启动 OOM（一次 10 分钟白等）
//   排错 → 按**文件体积**挑，会挑到「0.1B 却占 3.4GB」的架构变体，白降智
// 纯 Dart 模块 ⇒ 能在这里真跑，用**真实 12 个模型体积 + 本机真实显存**当夹具。
//
// 运行：dart run tool/verify_model_fit.dart
import 'dart:io';

import 'package:novelcraft/ai/rwkv/rwkv_gpu_probe.dart';
import 'package:novelcraft/ai/rwkv/rwkv_gpu_probe_native.dart';
import 'package:novelcraft/ai/rwkv/rwkv_model_fit.dart';

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

const int gib = 1024 * 1024 * 1024;
int mb(int n) => n * 1024 * 1024;

/// 真实清单（2026-09-15 从 HF `BlinkDL/rwkv7-g1` 拉的 12 个 .pth）
final Map<String, int> realModels = <String, int>{
  'rwkv7-g1d-0.1b-20260129-ctx8192': mb(365),
  'rwkv7-g1d-0.4b-20260210-ctx8192': mb(860),
  'rwkv7a-g1d-0.1b-20260212-ctx8192': mb(1921),
  'rwkv7-g1i-1.5b-20260805-ctx16384': mb(2914),
  'rwkv7-g1j-1.5b-20260831-ctx16384': mb(2914),
  'rwkv7b-g1b-0.1b-20250822-ctx4096': mb(3482),
  'rwkv7-g1i-2.9b-20260805-ctx16384': mb(5623),
  'rwkv7-g1j-2.9b-20260831-ctx16384': mb(5623),
  'rwkv7-g1i-7.2b-20260805-ctx16384': mb(13733),
  'rwkv7-g1j-7.2b-20260831-ctx16384': mb(13733),
  'rwkv7-g1i-13.3b-20260805-ctx16384': mb(25311),
  'rwkv7-g1j-13.3b-20260831-ctx16384': mb(25311),
};

Future<void> main() async {
  print('=' * 78);
  print('[1] nvidia-smi CSV 解析（纯函数）');
  print('=' * 78);
  final List<RwkvGpuInfo> gpus = parseNvidiaSmiOutput(
      'NVIDIA GeForce RTX 3070 Ti Laptop GPU, 8192, 7150\n');
  check('解析单卡', gpus.length == 1, '${gpus.length}');
  if (gpus.isNotEmpty) {
    final RwkvGpuInfo g = gpus.first;
    check('显卡名正确', g.name == 'NVIDIA GeForce RTX 3070 Ti Laptop GPU', g.name);
    check('总显存 8.0GB', (g.totalGb - 8.0).abs() < 0.01,
        g.totalGb.toStringAsFixed(2));
    check('空闲 7.0GB', (g.freeGb - 6.98).abs() < 0.05,
        g.freeGb.toStringAsFixed(2));
  }
  check('多卡', parseNvidiaSmiOutput('A, 1024, 512\nB, 2048, 1024\n').length == 2,
      'ok');
  check('空输出 → 空列表', parseNvidiaSmiOutput('').isEmpty, 'ok');
  check('脏行被跳过',
      parseNvidiaSmiOutput('garbage\nA, 1024, 512\n,,\n').length == 1, 'ok');
  check('非数字被跳过', parseNvidiaSmiOutput('A, abc, 512\n').isEmpty, 'ok');
  check('总显存 0 被跳过（防空值误判）',
      parseNvidiaSmiOutput('A, 0, 0\n').isEmpty, 'ok');

  print('');
  print('=' * 78);
  print('[2] 参数量解析（排序依据 —— 绝不能用文件体积排）');
  print('=' * 78);
  check('0.1b → 1', parseParamRankFromName('rwkv7-g1d-0.1b-20260129') == 1,
      '${parseParamRankFromName('rwkv7-g1d-0.1b-20260129')}');
  check('1.5b → 15', parseParamRankFromName('x-1.5b-y') == 15,
      '${parseParamRankFromName('x-1.5b-y')}');
  check('2.9b → 29', parseParamRankFromName('rwkv7-g1j-2.9b-20260831') == 29,
      '${parseParamRankFromName('rwkv7-g1j-2.9b-20260831')}');
  check('13.3b → 133', parseParamRankFromName('x-13.3b') == 133,
      '${parseParamRankFromName('x-13.3b')}');
  check('解析不到 → -1', parseParamRankFromName('no-params-here') == -1,
      '${parseParamRankFromName('no-params-here')}');
  check('0.1B 变体 rank < 2.9B（体积却是反的：3.4GB > 5.5GB 不存在，但变体确实更大）',
      parseParamRankFromName('rwkv7b-g1b-0.1b-20250822-ctx4096') <
          parseParamRankFromName('rwkv7-g1j-2.9b-20260831-ctx16384'),
      'rank 1 < 29');

  print('');
  print('=' * 78);
  print('[3] 本机真实显存（实测）');
  print('=' * 78);
  final List<RwkvGpuInfo> local = await rwkvProbeGpusImpl();
  int? localFree;
  int? localTotal;
  if (local.isEmpty) {
    print('  ⚠ 未探测到 NVIDIA GPU → 按设计不做任何拦截');
  } else {
    for (final RwkvGpuInfo g in local) {
      print('  $g');
    }
    localFree = local.first.freeBytes;
    localTotal = local.first.totalBytes;
  }

  print('');
  print('=' * 78);
  print('[4] 真实清单在「空闲 6.6GB」上的适配（模拟 3070 Ti 开着桌面）');
  print('=' * 78);
  final int vram66 = (6.6 * gib).round();
  final List<String> fitsList = <String>[];
  final List<String> tightList = <String>[];
  final List<String> tooLargeList = <String>[];
  for (final MapEntry<String, int> e in realModels.entries) {
    final RwkvModelFit f =
        judgeModelFit(modelSizeBytes: e.value, vramAvailableBytes: vram66);
    if (f == RwkvModelFit.fits) fitsList.add(e.key);
    if (f == RwkvModelFit.tight) tightList.add(e.key);
    if (f == RwkvModelFit.tooLarge) tooLargeList.add(e.key);
    if (e.key.contains('1.5b') ||
        e.key.contains('2.9b') ||
        e.key.contains('7.2b')) {
      print('  ${e.key.padRight(42)} '
          '${(e.value / gib).toStringAsFixed(1)}GB  ${f.name}');
    }
  }
  print('  —— fits=${fitsList.length}, tight=${tightList.length}, '
      'tooLarge=${tooLargeList.length}');

  check('1.5B → fits（约 4.2GB 需求 ≤ 5.6GB 阈值）',
      judgeModelFit(
              modelSizeBytes: realModels['rwkv7-g1j-1.5b-20260831-ctx16384']!,
              vramAvailableBytes: vram66) ==
          RwkvModelFit.fits,
      '1.5B');
  check('2.9B → 不再误判为 fits（7.3GB > 6.6GB 空闲）',
      judgeModelFit(
              modelSizeBytes: realModels['rwkv7-g1j-2.9b-20260831-ctx16384']!,
              vramAvailableBytes: vram66) ==
          RwkvModelFit.tooLarge,
      '2.9B');
  check('**7.2B 必须放不下**（13.4GB，最关键的一条）',
      judgeModelFit(
              modelSizeBytes: realModels['rwkv7-g1j-7.2b-20260831-ctx16384']!,
              vramAvailableBytes: vram66) ==
          RwkvModelFit.tooLarge,
      '7.2B');
  check('13.3B 必须放不下',
      judgeModelFit(
              modelSizeBytes: realModels['rwkv7-g1j-13.3b-20260831-ctx16384']!,
              vramAvailableBytes: vram66) ==
          RwkvModelFit.tooLarge,
      '13.3B');
  check('tooLarge → shouldBlock=true（UI 据此拦截）',
      judgeModelFit(
              modelSizeBytes: realModels['rwkv7-g1j-7.2b-20260831-ctx16384']!,
              vramAvailableBytes: vram66)
          .shouldBlock,
      'ok');

  print('');
  print('=' * 78);
  print('[5] 探不到显存时必须「不拦截」（unknown ≠ 放不下）');
  print('=' * 78);
  check('vramAvailableBytes=null → unknown',
      judgeModelFit(modelSizeBytes: mb(13733), vramAvailableBytes: null) ==
          RwkvModelFit.unknown,
      'ok');
  check('unknown → shouldBlock=false（不能全标成放不下）',
      !judgeModelFit(modelSizeBytes: mb(13733), vramAvailableBytes: null)
          .shouldBlock,
      'ok');
  final String d =
      describeModelFit(modelSizeBytes: mb(13733), vramAvailableBytes: null);
  check('unknown 时提示用户自行确认', d.contains('未探测'), d);

  print('');
  print('=' * 78);
  print('[6] 24GB 显卡（云端同款）');
  print('=' * 78);
  final int vram24 = 24 * gib;
  check('7.2B → fits',
      judgeModelFit(
              modelSizeBytes: realModels['rwkv7-g1j-7.2b-20260831-ctx16384']!,
              vramAvailableBytes: vram24) ==
          RwkvModelFit.fits,
      describeModelFit(
          modelSizeBytes: realModels['rwkv7-g1j-7.2b-20260831-ctx16384']!,
          vramAvailableBytes: vram24));
  check('13.3B → tooLarge',
      judgeModelFit(
              modelSizeBytes: realModels['rwkv7-g1j-13.3b-20260831-ctx16384']!,
              vramAvailableBytes: vram24) ==
          RwkvModelFit.tooLarge,
      '13.3B');

  print('');
  print('=' * 78);
  print('[7] pickBestFittingModel：必须按**参数量**挑，不能按体积');
  print('=' * 78);
  final List<String> names = realModels.keys.toList();
  int rankOf(String k) => parseParamRankFromName(k);
  int sizeOf(String k) => realModels[k]!;

  final String? pick66 = pickBestFittingModel<String>(names,
      sizeOf: sizeOf, rankOf: rankOf, vramAvailableBytes: vram66);
  print('  空闲 6.6GB → 推荐：$pick66');
  check('挑出 1.5B（fits 里参数量最大的）',
      pick66 != null && pick66.contains('1.5b'), '$pick66');
  check('没有挑到 0.1B 的体积变体',
      pick66 == null || !pick66.contains('0.1b'), '$pick66');

  final int vram12 = (12 * gib).round();
  final String? pick12 = pickBestFittingModel<String>(names,
      sizeOf: sizeOf, rankOf: rankOf, vramAvailableBytes: vram12);
  print('  空闲 12GB → 推荐：$pick12');
  check('12GB 上挑 2.9B（不是 0.1B/1.5B）',
      pick12 != null && pick12.contains('2.9b'), '$pick12');

  final String? pick24 = pickBestFittingModel<String>(names,
      sizeOf: sizeOf, rankOf: rankOf, vramAvailableBytes: vram24);
  print('  空闲 24GB → 推荐：$pick24');
  check('24GB 上挑 7.2B（不是 13.3B）',
      pick24 != null && pick24.contains('7.2b'), '$pick24');

  check('候选为空 → null',
      pickBestFittingModel<String>(<String>[],
              sizeOf: (String _) => 0, vramAvailableBytes: vram66) ==
          null,
      'ok');

  print('');
  print('=' * 78);
  print('[8] 本机实际推荐');
  print('=' * 78);
  if (localFree == null) {
    print('  探不到显卡 → 不做推荐（用户自行判断）');
  } else {
    final String? best = pickBestFittingModel<String>(names,
        sizeOf: sizeOf, rankOf: rankOf, vramAvailableBytes: localFree);
    print('  显卡：${local.first.name}');
    print('  显存：总 ${(localTotal! / gib).toStringAsFixed(1)}GB / '
        '空闲 ${(localFree / gib).toStringAsFixed(1)}GB');
    print('  → ** 推荐模型：$best **');
    print('  → 7.2B 判定：'
        '${describeModelFit(modelSizeBytes: realModels['rwkv7-g1j-7.2b-20260831-ctx16384']!, vramAvailableBytes: localFree)}');
    check('本机推荐不为空且不是 7.2B',
        best != null && !best.contains('7.2b'), '$best');
  }

  print('');
  print('=' * 78);
  print('VERDICT: $pass passed, $fail failed');
  print('=' * 78);
  if (fail > 0) exitCode = 1;
}
