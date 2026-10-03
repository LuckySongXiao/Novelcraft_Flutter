// AiRuntimeSettings（采样预设 + 思维链开关/强度）单元验证。
//
// 运行：flutter test test/runtime_settings_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:novelcraft/ai/runtime_settings.dart';
import 'package:novelcraft/ai/rwkv/rwkv_sampling.dart';

void main() {
  group('AiRuntimeSettings 采样参数', () {
    test('官方推荐默认值 == kRwkvAntiRepeatSampling 全集', () {
      final Map<String, Object?> params =
          AiRuntimeSettings.defaults().samplingParams();
      expect(params.length, kRwkvAntiRepeatSampling.length);
      for (final MapEntry<String, Object?> e in kRwkvAntiRepeatSampling.entries) {
        expect(params[e.key], e.value, reason: '${e.key} 应与官方推荐一致');
      }
    });

    test('强抗复读档惩罚整体重于官方档', () {
      final Map<String, Object?> strong =
          AiRuntimeSettings(samplingPreset: RwkvSamplingPresetId.strong)
              .samplingParams();
      final Map<String, Object?> official =
          AiRuntimeSettings(samplingPreset: RwkvSamplingPresetId.official)
              .samplingParams();
      expect((strong['alpha_presence'] as num) > (official['alpha_presence'] as num), isTrue);
      expect((strong['alpha_frequency'] as num) > (official['alpha_frequency'] as num), isTrue);
      expect((strong['dry_multiplier'] as num) > (official['dry_multiplier'] as num), isTrue);
      expect((strong['top_p'] as num) < (official['top_p'] as num), isTrue);
    });

    test('手动微调覆盖预设值；空字段回落预设', () {
      final AiRuntimeSettings s = AiRuntimeSettings(
        samplingPreset: RwkvSamplingPresetId.official,
        topP: 0.42,
        alphaPresence: 2.7,
        // dryMultiplier 留空 → 回落官方 0.8
      );
      final Map<String, Object?> params = s.samplingParams();
      expect(params['top_p'], 0.42);
      expect(params['alpha_presence'], 2.7);
      expect(params['dry_multiplier'], 0.8);
    });

    test('custom 档的空字段回落官方推荐', () {
      final Map<String, Object?> params =
          AiRuntimeSettings(samplingPreset: RwkvSamplingPresetId.custom)
              .samplingParams();
      expect(params['top_k'], kRwkvAntiRepeatSampling['top_k']);
    });

    test('toJson/fromJson 往返一致', () {
      final AiRuntimeSettings s = AiRuntimeSettings(
        samplingPreset: RwkvSamplingPresetId.strong,
        topP: 0.42,
        alphaPresence: 2.7,
        thinkingEnabled: false,
        thinkingIntensity: ThinkingIntensity.high,
      );
      final AiRuntimeSettings back =
          AiRuntimeSettings.fromJson(s.toJson());
      expect(back.samplingPreset, RwkvSamplingPresetId.strong);
      expect(back.topP, 0.42);
      expect(back.alphaPresence, 2.7);
      expect(back.thinkingEnabled, isFalse);
      expect(back.thinkingIntensity, ThinkingIntensity.high);
      // 覆盖值经序列化后仍参与合并
      expect(back.samplingParams()['top_p'], 0.42);
    });

    test('损坏 JSON 字段回落安全默认', () {
      final AiRuntimeSettings s = AiRuntimeSettings.fromJson(
          <String, Object?>{'samplingPreset': 'bogus', 'thinkingIntensity': 'x'});
      expect(s.samplingPreset, RwkvSamplingPresetId.official);
      expect(s.thinkingEnabled, isTrue);
      expect(s.thinkingIntensity, ThinkingIntensity.medium);
    });
  });
}
