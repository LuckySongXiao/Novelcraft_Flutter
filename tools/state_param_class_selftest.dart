// State 参数当量分类自检（纯 Dart，无需 Flutter）。
//
// 运行：
//   dart --disable-dart-dev tools/state_param_class_selftest.dart

import '../lib/ai/rwkv/state_tuning_registry.dart';

int _passed = 0;

void check(bool condition, String label) {
  if (!condition) throw StateError('FAIL: $label');
  _passed++;
  print('PASS $label');
}

RwkvStateArtifact artifact({
  required String id,
  required String baseModelId,
  String statePath = 'rwkv_models/states/x.pth',
}) => RwkvStateArtifact(
  id: id,
  target: RwkvStateTarget.stateUpdates,
  statePath: statePath,
  baseModelId: baseModelId,
);

void main() {
  // A. 底座参数类：必须从模型 id 的带边界参数段解析。
  check(
    parseRwkvBaseParamClass('rwkv-g1m-1b-temp-6629-ctx65536') ==
        RwkvBaseParamClass.b1,
    'A1 1B 底座',
  );
  check(
    parseRwkvBaseParamClass('rwkv7-g1l-1.5b-20261031-ctx34304') ==
        RwkvBaseParamClass.b1p5,
    'A2 1.5B 底座',
  );
  check(
    parseRwkvBaseParamClass('rwkv-g1m-3b-temp-6056-ctx65536') ==
        RwkvBaseParamClass.b3,
    'A3 3B 底座',
  );
  check(
    parseRwkvBaseParamClass('rwkv7-g1k-7.2b-20260930') == RwkvBaseParamClass.b7,
    'A4 7B 底座',
  );
  check(
    parseRwkvBaseParamClass('rwkv7b-g1b-0.1b') == RwkvBaseParamClass.b1,
    'A5 家族前缀 rwkv7b 不得抢先命中',
  );
  check(
    parseRwkvBaseParamClass('rwkv-custom') == RwkvBaseParamClass.unknown,
    'A6 无参数段 → unknown',
  );
  check(
    parseRwkvBaseParamClass('rwkv_models/states/1b/st1_prose-1b-v1.pth') ==
        RwkvBaseParamClass.b1,
    'A7 路径回退也能识别 1B（不误判成 1.5B）',
  );

  // B. 当量映射：只看已实测形状，7B 不套用 3B 字节数。
  check(
    rwkvStateTierFor(RwkvBaseParamClass.b1) == RwkvStateParamTier.s6m,
    'B1 1B → S6M',
  );
  check(
    rwkvStateTierFor(RwkvBaseParamClass.b1p5) == RwkvStateParamTier.s6m,
    'B2 1.5B → S6M（与 1B 同形）',
  );
  check(
    rwkvStateTierFor(RwkvBaseParamClass.b3) == RwkvStateParamTier.s10m,
    'B3 3B → S10M',
  );
  check(
    rwkvStateTierFor(RwkvBaseParamClass.b7) == RwkvStateParamTier.unknown,
    'B4 7B 未实测 → unknown',
  );
  check(
    RwkvStateParamTier.s6m.expectedStateBytes == 6 * 1024 * 1024,
    'B5 S6M 理论体积 6 MiB',
  );
  check(
    RwkvStateParamTier.s10m.expectedStateBytes == 10 * 1024 * 1024,
    'B6 S10M 理论体积 10 MiB',
  );
  check(RwkvStateParamTier.unknown.sizeLabel == '-', 'B7 未知当量不编造体积');

  // C. 综合分类：训练底座优先，缺底座才回退路径。
  check(
    classifyRwkvStateTier(
          'rwkv-g1m-1b-temp-6629-ctx65536',
          statePath: 'rwkv_models/states/3b/x.pth',
        ) ==
        RwkvStateParamTier.s6m,
    'C1 底座优先于路径',
  );
  check(
    classifyRwkvStateTier(
          '',
          statePath: 'rwkv_models/states/3b/st8_state_updates-3b-v6.pth',
        ) ==
        RwkvStateParamTier.s10m,
    'C2 缺底座时按路径回退到 3B',
  );

  // D. 产物扩展：给 UI 的一行标签必须同时含当量、底座与体积。
  final RwkvStateArtifact oneB = artifact(
    id: 'a',
    baseModelId: 'rwkv-g1m-1b-temp-6629-ctx65536',
  );
  check(oneB.baseParamClass == RwkvBaseParamClass.b1, 'D1 1B 产物底座类');
  check(oneB.paramTier == RwkvStateParamTier.s6m, 'D2 1B 产物当量');
  check(
    oneB.paramClassLabel(false).contains('S6M') &&
        oneB.paramClassLabel(false).contains('1B 底座') &&
        oneB.paramClassLabel(false).contains('6.0 MiB'),
    'D3 1B 标签内容完整',
  );

  final RwkvStateArtifact threeB = artifact(
    id: 'b',
    baseModelId: 'rwkv-g1m-3b-temp-6056-ctx65536',
    statePath: 'rwkv_models/states/3b/st8_state_updates-3b-v6.pth',
  );
  check(threeB.paramTier == RwkvStateParamTier.s10m, 'D4 3B 产物当量');
  check(
    threeB.paramClassLabel(false).contains('S10M') &&
        threeB.paramClassLabel(false).contains('10.0 MiB'),
    'D5 3B 标签内容完整',
  );

  print('OK: $_passed assertions passed');
}
