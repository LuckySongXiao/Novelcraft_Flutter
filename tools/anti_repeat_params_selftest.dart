// 离线自检：`AiRuntimeSettings.maxAntiRepeatSamplingParams`（+48 最严防重复）。
//
// 运行：dart --disable-dart-dev tools/anti_repeat_params_selftest.dart
//
// 锁住三件事：
//   1. 结果**恒等于**实测最严点（kRwkvStrictestWritingSampling），
//      不受用户预设（宽松 / 激进）影响 —— 这就是「默认最严」的语义；
//   2. 唯一例外是 `alpha_decay`：只抬不压（用户配得更严时保留用户值）；
//   3. 类型正确（top_k / dry_penalty_last_n 为 int）且带 stop_tokens。
//
// ⚠ 为什么是「恒等于最严点」而不是「往严的方向夹」：+48 三轮真机对照证明
// 「把 frequency / DRY 一并拉满」会既掉字数（481/644 vs 1957）又抬复读
// （ngram 最差 0.236 vs 0.001）。见 kRwkvStrictestWritingSampling 头注。
library;

import 'package:novelcraft/ai/runtime_settings.dart';
import 'package:novelcraft/ai/rwkv/rwkv_sampling.dart';

int _passed = 0;
int _failed = 0;

void _check(String name, bool cond) {
  if (cond) {
    _passed++;
  } else {
    _failed++;
    print('FAIL  $name');
  }
}

void main() {
  final Map<String, Object?> strictest = kRwkvStrictestWritingSampling;

  // -------------------------------------------------------------------------
  // A 组：不论用户预设如何，结果都落到「实测最严点」
  // -------------------------------------------------------------------------
  for (final RwkvSamplingPresetId preset in <RwkvSamplingPresetId>[
    RwkvSamplingPresetId.official,
    RwkvSamplingPresetId.strong,
    RwkvSamplingPresetId.relaxed,
  ]) {
    final AiRuntimeSettings s = AiRuntimeSettings(samplingPreset: preset);
    final Map<String, Object?> p = s.maxAntiRepeatSamplingParams();
    for (final String key in <String>[
      'top_k', 'top_p', 'alpha_presence', 'alpha_frequency', 'alpha_decay',
      'dry_multiplier', 'dry_base', 'dry_allowed_length', 'dry_penalty_last_n',
    ]) {
      _check('A-${preset.name}-$key == 最严点', p[key] == strictest[key]);
    }
    _check('A-${preset.name}-stop_tokens 带上', p['stop_tokens'] != null);
  }

  // -------------------------------------------------------------------------
  // B 组：alpha_decay 只抬不压
  // -------------------------------------------------------------------------
  {
    // 用户配得更严（0.9995）→ 保留。
    final AiRuntimeSettings stricter =
        AiRuntimeSettings.defaults().copyWith(alphaDecay: 0.9995);
    _check(
        'B1 用户 decay 0.9995 被保留',
        (stricter.maxAntiRepeatSamplingParams()['alpha_decay'] as num)
                .toDouble() ==
            0.9995);

    // 用户配得更松（0.99，官方创意档）→ 抬到 0.999。
    final AiRuntimeSettings looser =
        AiRuntimeSettings.defaults().copyWith(alphaDecay: 0.99);
    _check(
        'B2 用户 decay 0.99 被抬到 0.999',
        (looser.maxAntiRepeatSamplingParams()['alpha_decay'] as num)
                .toDouble() ==
            0.999);

    // 脏值 >1 → 收口到 1.0。
    final AiRuntimeSettings dirty =
        AiRuntimeSettings.defaults().copyWith(alphaDecay: 1.5);
    _check(
        'B3 脏值 decay 1.5 收口到 1.0',
        (dirty.maxAntiRepeatSamplingParams()['alpha_decay'] as num).toDouble() ==
            1.0);
  }

  // -------------------------------------------------------------------------
  // C 组：类型 / 关键取值（防回归：这些值是实测结论，改动即回归）
  // -------------------------------------------------------------------------
  {
    final Map<String, Object?> p =
        AiRuntimeSettings.defaults().maxAntiRepeatSamplingParams();
    _check('C1 top_k 是 int', p['top_k'] is int);
    _check('C2 dry_penalty_last_n 是 int', p['dry_penalty_last_n'] is int);
    _check('C3 dry_penalty_last_n == 2048（不是 4096）',
        (p['dry_penalty_last_n'] as num).toInt() == 2048);
    _check('C4 alpha_frequency == 0.2（抬高反而更复读）',
        (p['alpha_frequency'] as num).toDouble() == 0.2);
    _check('C5 dry_multiplier == 0.8',
        (p['dry_multiplier'] as num).toDouble() == 0.8);
    _check('C6 alpha_presence == 2.0',
        (p['alpha_presence'] as num).toDouble() == 2.0);
    _check('C7 top_p == 0.6', (p['top_p'] as num).toDouble() == 0.6);
    _check('C8 alpha_decay == 0.999',
        (p['alpha_decay'] as num).toDouble() == 0.999);
    _check('C9 返回的是新表（不污染预设常量）', () {
      final q = AiRuntimeSettings.defaults().maxAntiRepeatSamplingParams();
      q['top_p'] = 0.99;
      return (kRwkvStrictestWritingSampling['top_p'] as num).toDouble() == 0.6;
    }());
    _check('C10 官方档原值仍带 stop_tokens',
        kRwkvAntiRepeatSampling['stop_tokens'] != null);
  }

  print('anti_repeat_params_selftest: $_passed passed, $_failed failed');
  if (_failed > 0) {
    throw StateError('anti_repeat_params_selftest FAILED: $_failed assertion(s)');
  }
}
