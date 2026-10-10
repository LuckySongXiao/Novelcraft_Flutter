// 上下文窗口 / 令牌预算自检（不需要 flutter test，直接跑）：
//
//   cd <pkg> && "d:/flutter_windows_3.38.5-stable/flutter/bin/cache/dart-sdk/bin/dart.exe" \
//       --disable-dart-dev tools/context_window_selftest.dart
//
// 覆盖 `AiRuntimeSettings` 里**纯 Dart** 的两块逻辑：模型名 → 上下文窗口的解析，
// 以及「参考预算 / 输出预算」在窗口内的切分。UI 侧的档位表（`kMaxTokensSteps`）
// 在 `ai_configuration_page.dart` 里、依赖 Flutter，不在本脚本范围内。
//
// 为什么值得单独锁：
//   * 用户报「模型支持 25K，却设不了 25K 上下文」。链路是
//     ① 滑块档位表要能选到 25K；② 窗口要真的解析成 25600；③ 输出预算不能被
//     旧窗口 16384 钳死。①在 UI 层，②③在这里。
//   * 若 ② 失败（模型名解析不出 / 落盘旧值），B 组会直接红灯，而不是等到
//     真机上「拖到 25K 但生成还是短」才发现。
//   * D 组锁的是一个**极易再踩的坑**：UI 侧新建 `AiRuntimeSettings` 时若漏传
//     `maxReferenceLength` / `contextWindowTokens`，会静默回落 4000 / 16384。
import '../lib/ai/runtime_settings.dart';

int pass = 0;
int fail = 0;

void check(String name, bool ok, {String detail = ''}) {
  if (ok) {
    pass++;
    print('PASS  $name');
  } else {
    fail++;
    print('FAIL  $name${detail.isEmpty ? '' : '\n  $detail'}');
  }
}

void eqInt(String name, int got, int want) {
  check(name, got == want, detail: 'want=$want got=$got');
}

AiRuntimeSettings _s({required int window, required int maxRef}) =>
    AiRuntimeSettings(
      maxReferenceLength: maxRef,
      contextWindowTokens: window,
    );

void main() {
  print('--- A. 模型名 → 上下文窗口（parseContextWindow）---');
  eqInt(
    'A1 用户实际模型 ctx25600 → 25600',
    AiRuntimeSettings.parseContextWindow('rwkv7-g1k-7.2b-20260930-ctx25600'),
    25600,
  );
  eqInt(
    'A2 带日期段的老模型 ctx16384 → 16384',
    AiRuntimeSettings.parseContextWindow('rwkv7-g1j-7.2b-20260831-ctx16384'),
    16384,
  );
  eqInt(
    'A3 无 ctx 标记 → 回落 16384',
    AiRuntimeSettings.parseContextWindow('gpt-4o-mini'),
    16384,
  );
  eqInt(
    'A4 分隔符 ctx-25000 → 25000',
    AiRuntimeSettings.parseContextWindow('some-model-ctx-25000'),
    25000,
  );
  eqInt(
    'A5 分隔符 ctx_2048 → 2048',
    AiRuntimeSettings.parseContextWindow('some_model_ctx_2048'),
    2048,
  );
  eqInt(
    'A6 大小写不敏感 CTX32768 → 32768',
    AiRuntimeSettings.parseContextWindow('CTX32768-upper'),
    32768,
  );
  eqInt(
    'A7 边界 ctx512（恰好达标）→ 512',
    AiRuntimeSettings.parseContextWindow('ctx512'),
    512,
  );
  eqInt(
    'A8 ctx100（< 512）→ 回落 16384',
    AiRuntimeSettings.parseContextWindow('ctx100'),
    16384,
  );
  eqInt(
    'A9 ctxabc（无数字）→ 回落 16384',
    AiRuntimeSettings.parseContextWindow('ctxabc'),
    16384,
  );
  eqInt('A10 空串 → 回落 16384', AiRuntimeSettings.parseContextWindow(''), 16384);

  print('--- B. 参考/输出预算在窗口内切分 ---');
  // 窗口 25600 + 令牌数 25600：参考 = min(25600, 25600*40%=10240) = 10240；
  // 输出 = min(25600*55%=14080, 25600-10240-512=14848, 25600) = 14080。
  final AiRuntimeSettings big = _s(window: 25600, maxRef: 25600);
  eqInt('B1 窗口 25K：参考预算 = 10240', big.referenceBudgetTokens, 10240);
  eqInt('B2 窗口 25K：输出预算 = 14080', big.outputBudgetTokens, 14080);

  // 窗口仍是旧的 16384：参考 = min(25600, 6553) = 6553；
  // 输出 = min(9011, 16384-6553-512=9319, 25600) = 9011。
  final AiRuntimeSettings stale = _s(window: 16384, maxRef: 25600);
  eqInt('B3 旧窗口 16K：参考预算被钳到 6553', stale.referenceBudgetTokens, 6553);
  eqInt('B4 旧窗口 16K：输出预算被钳到 9011', stale.outputBudgetTokens, 9011);

  // ⭐ 核心回归锁：同一个「最大令牌数」，窗口对了差 5K 输出。
  check(
    'B5 窗口 25K 的输出预算 > 旧窗口 16K（差 ' '${big.outputBudgetTokens - stale.outputBudgetTokens}）',
    big.outputBudgetTokens > stale.outputBudgetTokens,
    detail: 'big=${big.outputBudgetTokens} stale=${stale.outputBudgetTokens}',
  );

  // 令牌数小于窗口 55% 时，以令牌数为准。
  final AiRuntimeSettings modest = _s(window: 25600, maxRef: 4000);
  eqInt('B6 令牌数 4000 < 配额 → 输出 = 4000', modest.outputBudgetTokens, 4000);
  eqInt('B7 令牌数 4000 → 参考 = 4000', modest.referenceBudgetTokens, 4000);

  // 小窗口的下限夹取：参考不低于 1024、输出不低于 512。
  final AiRuntimeSettings tiny = _s(window: 2048, maxRef: 100);
  eqInt('B8 小窗口：参考下限 1024', tiny.referenceBudgetTokens, 1024);
  eqInt('B9 小窗口：输出下限 512', tiny.outputBudgetTokens, 512);

  // 生成链路只会用到 ≤12000 的预算，窗口 25K 时不再受窗口钳制。
  final AiRuntimeSettings user = _s(window: 25600, maxRef: 16384);
  check(
    'B10 25K 窗口 + 16K 令牌数 → 输出配额 14080 ≥ 生成侧上限 12000',
    user.outputBudgetTokens >= 12000,
    detail: 'conf=${user.outputBudgetTokens}',
  );

  print('--- C. copyWith / 序列化 保留窗口 ---');
  final AiRuntimeSettings base = AiRuntimeSettings.defaults();
  final AiRuntimeSettings bumped = base.copyWith(contextWindowTokens: 25600);
  eqInt('C1 copyWith 只改窗口 → 窗口 = 25600', bumped.contextWindowTokens, 25600);
  eqInt('C2 copyWith 不碰令牌数 → 保留 4000', bumped.maxReferenceLength, 4000);

  final AiRuntimeSettings roundTrip = AiRuntimeSettings.fromJson(
    <String, Object?>{
      ...user.toJson(),
    },
  );
  eqInt('C3 toJson→fromJson 往返：窗口 = 25600', roundTrip.contextWindowTokens, 25600);
  eqInt(
    'C4 toJson→fromJson 往返：令牌数 = 16384',
    roundTrip.maxReferenceLength,
    16384,
  );

  final AiRuntimeSettings fromEmpty = AiRuntimeSettings.fromJson(
    <String, Object?>{},
  );
  check(
    'C5 fromJson 空表 → 回落 4000 / 16384',
    fromEmpty.maxReferenceLength == 4000 &&
        fromEmpty.contextWindowTokens == 16384,
    detail:
        'ref=${fromEmpty.maxReferenceLength} win=${fromEmpty.contextWindowTokens}',
  );

  print('--- D. 漏传字段的回落陷阱（UI 侧必须显式继承）---');
  // 采样参数卡片若这样新建实例，就会把用户设好的 25K 静默抹掉 —— 这是本轮
  // 修掉的第二个 bug，此断言把「回落行为」钉死，提醒后来者必须显式传参。
  final AiRuntimeSettings bare = AiRuntimeSettings(
    samplingPreset: RwkvSamplingPresetId.strong,
    topK: 40,
    topP: 0.5,
  );
  check(
    'D1 未显式传 → 回落 4000 / 16384（故 UI 必须继承！）',
    bare.maxReferenceLength == 4000 && bare.contextWindowTokens == 16384,
    detail: 'ref=${bare.maxReferenceLength} win=${bare.contextWindowTokens}',
  );
  check(
    'D2 显式继承后不再回落',
    bare
                .copyWith(
                  maxReferenceLength: user.maxReferenceLength,
                  contextWindowTokens: user.contextWindowTokens,
                )
                .contextWindowTokens ==
            25600,
  );

  print('===============================');
  print('pass=$pass  fail=$fail');
  if (fail > 0) {
    print('SELFTEST FAILED');
    throw StateError('$fail case(s) failed');
  }
  print('SELFTEST OK');
}
