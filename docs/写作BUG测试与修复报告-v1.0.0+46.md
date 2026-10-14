# NovelCraft 桌面版「写作链路」BUG 测试与修复报告

> 被测版本：**v1.0.0+46（2026-10-11）** ｜ 工程：`F:\30_Novelcraft_Flutter\Flutter版代码\novelcraft`
> 测试日期：2026-10-11 ｜ 方法：源码级静态审计 + 离线自检回归 + RWKV 官方/社区文档比对
> 结论：**定位并修复 4 个写作链路 BUG**（2 个「写得不对/写不够」、1 个「能落库但永远失败」、1 个「开关失效」）；13 个离线自检全绿，`lib/` 235 文件 `error:0 warning:0`。

---

## 0. 测试范围与方法

| 维度 | 做法 |
|---|---|
| 链路覆盖 | 大纲修订 → 切片规划 → 逐片续写 → 补片 → 逐段润色 → 质量闸 → 落库/同步；以及「选节 AI（润色/扩写/续写/重写）→ 采纳应用」 |
| 静态审计 | 逐行读 `chapter_rewrite_service` / `selection_edit_service` / `multi_agent_book_generation_service` / `openai_compatible_provider` / `runtime_settings` / 4 个纯 Dart 工具 |
| 动态验证 | 13 个离线自检（`tools/*_selftest.dart`）+ `tools/analyze_inprocess.dart` 同进程类型检查 + i18n/interp 审计 |
| 外部基准 | `docs/rwkv_lightning_api/http-api.zh-CN.md`（RWKV 云官方）、`rwkv_lightning_api_doc.md`（rwkv_lightning 官方）、RWKV 中文网/社区长文写作经验 |

**基线（修复前）**：13 个自检全绿 —— 说明既有自检**覆盖不到**本次发现的 4 个 BUG，这正是「能构建、能自检，但真机写作仍出错」的原因。

---

## 1. BUG 清单

### BUG-1 ｜作者「额外要求」在**真正写正文**时被丢弃 ★高

- **位置**：`lib/application/services/chapter_rewrite_service.dart`（`rewriteWithPlan` 的两个 `_buildSlicePrompt` 调用点）
- **证据**：`_buildSlicePrompt({… String instruction = '' …})` 有该参数，但规划调用（`_buildSlicePlanPrompt`）传了 `instruction`，**逐片续写与补片调用都没传** → 恒为 `''`。
- **影响**：用户在「额外要求」里写的「本章要推进 XX 剧情」只影响**规划**，不进写手提示词。UI 上像是「AI 无视了我的要求」，正文照旧跑偏 —— 直接对应历史反馈「按我的要求重写后仍不对」。
- **修法**：两个调用点补 `instruction: instruction.trim()`。
- **回归锁**：提示词构造是私有方法，暂无纯 Dart 断言；已在代码注释标注，避免再次漏传。

### BUG-2 ｜长选区「续写」**必然失败**（截断判据用错基线）★高

- **位置**：`lib/application/services/selection_edit_service.dart`（`edit` 的 `validate`）
- **证据**：`if (… text.length < selected.length * .6) return 'truncated_selection';`
  续写是**新增**文本（`applySelectionResult` 里 `insertAfter=true` 插到所选段落之后，原选区保留），其长度与选区长度**没有可比性**。
- **影响（可复现）**：选中一段 3000 字 → 点「续写」→ 模型产出 1200 字合格续写（≥ 续写下限 600 字）→ 被判 `truncated_selection` → `FictionQuality.generate` 重试一次仍失败 → 抛 `Fiction quality check failed` → **整个续写动作如实报错**。选区越长越必失败。
- **修法**：把判据抽成纯函数 `isTruncatedSelection(additive:)`（`lib/ai/utils/selection_apply_text.dart`），`additive`（续写）时恒不判；`SelectionEditService` 调用之。
- **回归锁**：`tools/selection_apply_selftest.dart` 新增 **D 组 7 条**（D1/D2 续写不误判；D3–D5 替换语义仍按 0.6 倍判；D6 空选区；D7 自定义比例）。

### BUG-3 ｜复读正文仍可穿闸落库（+46 的「铁律」只落实在大纲路径）★高

- **位置**：`lib/application/services/chapter_rewrite_service.dart`（`rewriteWithPlan` 的定稿闸 / `_persistAndSync`）
- **证据**：`RepetitionGuard.isDegenerate` 全工程**只有 1 处调用**（`repairOutlineAndRewrite` 的大纲闸，`:489`）。正文路径的闸是 `chapterQualityNote` → `FictionQuality.issue` + `_repeatRatio > 0.5`，而：
  - `FictionQuality.issue` 的句子级判据要求**单句 ≥16 字且出现 ≥3 次** → **短句循环**（如「他笑了。」×40）直接漏网；
  - 段落级 `_repeatRatio` 只看**整段全同** → **段内换词复读**漏网；
  - 12-gram 重复率落在 **0.30–0.50** 区间的整段复读，两条都抓不住。
  这与 `docs/交接-复读问题-外援接入指南.md §5.5` 自定的铁律相悖：*「凡是模型输出 → 直接落库的路径，落库前必须过 `RepetitionGuard.isDegenerate`」*。
- **影响**：复读正文落库 → 污染后续每次重写（与大纲污染同一条传染链），也是「NG 率下不来」的隐性来源。
- **修法**：在**唯一落库点** `_persistAndSync` 加落库前闸 —— 退化复读则**如实失败、绝不写库**，复用既有 `CRW.QualityFailed` 文案（不新增 i18n 键）。`rewrite()` 与 `rewriteWithPlan()` 两条路径一并覆盖。
- **回归锁**：`tools/repetition_guard_selftest.dart` 新增 **E 组 3 条**（E1 短句循环 ngram=0.973 命中；E2 换词复读 ngram=0.550 命中；E3 正常长篇散文不误杀）。

### BUG-4 ｜「关闭思维链」在 RWKV 云路由上从未生效 ★中

- **位置**：`lib/ai/providers/openai_compatible_provider.dart`（`_buildExtraFields` 白名单）
- **证据**：RWKV 云**无状态路由** `/v1/chat/completions` 的思考控制键是 `think_type` / `enable_think`（官方 `http-api.zh-CN.md`：`none|fast|free|preferChinese|…`；**省略时服务端默认 `fast`**）。白名单里**没有这两个键** → 即便 App 把思维链开关关掉，服务端仍加 `fast` 思考前缀。
- **影响**：思考 token 挤占本就紧张的正文预算 → 成稿变短 → 更容易过不了 3200 字闸（与「字数不达标」反馈同源）；且 `agent.dart:484` 的开关只管**本地**思维链构造，对云路由无效。
- **修法**：
  1. 白名单补 `think_type` / `enable_think`（纯能力放行，零行为变化）；
  2. 写作链路（`ChapterRewriteService._generateOnce`）与选节编辑（`SelectionEditService.edit`）在 **`thinkingEnabled == false`** 时显式下发 `think_type: 'none'`；开启时不传，沿用服务端默认。
- **回归锁**：需真机带模型验证（离线无法断言服务端行为）。

---

## 2. 与 RWKV 官方/社区最佳实践的对照

| 议题 | 官方/社区口径 | 本项目现状 | 判定 |
|---|---|---|---|
| 停止符下发 | 云路由 `/v1/chat/completions` 接受 `stop_tokens:[0,261,24281]`（整数 ID，`http-api.zh-CN.md`） | +46 已把 `stop_tokens` 经白名单展平到无状态路由 | ✅ 与官方一致 |
| 本地 lightning 的停止符 | `rwkv_lightning_api_doc.md` 用**字符串**序列（`["\nUser:"]`），与 CUDA 整数约定不同 | 本项目只对接云路由，整数 ID 正确 | ✅ 无冲突（勿混用） |
| 创作类推荐采样 | 云官方范例：`temperature 1.0 / top_k 5 / top_p 0.3 / alpha_presence 0.2 / alpha_frequency 0.2 / alpha_decay 0.99` | `longFormSamplingParams` 夹 `alpha_presence≤0.5`（方向一致）、`alpha_frequency∈[0.6,1.0]`（**比官方 0.2 激进 3–5×**）、`top_p∈[0.45,0.55]`（官方 0.3 实测过早停笔，已记录） | ⚠ 见 §3 遗留 |
| DRY 采样器 | 社区公认对长文最有效（llama.cpp 参考实现） | 云服务端**静默忽略 `dry_*`**（PITFALLS §31） | ⚠ 服务端能力缺口，客户端无解 |
| 复读治理 | 「事中止损」（stop token）+「事后清洗」+「落库前拦截」三层 | +46 补齐前两层，**第三层只覆盖大纲** | ❌ → 已由 BUG-3 修复 |
| 思考前缀 | 长文正文建议 `think_type: none`（避免思考吃 token） | 无状态路由无法下发 | ❌ → 已由 BUG-4 修复 |

---

## 3. 验证结果（修复后）

| 项 | 结果 |
|---|---|
| 离线自检 | **13 / 13 全绿**（新增断言：repetition_guard 16→**19**、selection_apply 15→**22**） |
| 类型检查 | `tools/analyze_inprocess.dart lib` → **235 文件 error:0 warning:0** |
| i18n | **1164 调用点 / 0 缺失**（复用既有键，未新增） |
| 插值 lint | `dart_interp_lint.py` → 279 文件 / **0 命中** |
| 关键样本 | 短句循环 ngram=0.973 命中；换词复读 ngram=0.550 命中；正常长篇散文 0.000 不误杀 |

**改动文件（4 处源码 + 2 处自检）**

```
lib/application/services/chapter_rewrite_service.dart   BUG-1 / BUG-3 / BUG-4
lib/application/services/selection_edit_service.dart    BUG-2 / BUG-4
lib/ai/utils/selection_apply_text.dart                  BUG-2（新增纯函数）
lib/ai/providers/openai_compatible_provider.dart        BUG-4（白名单）
tools/selection_apply_selftest.dart                     D 组 7 条
tools/repetition_guard_selftest.dart                    E 组 3 条
```

---

## 4. 遗留与后续建议

1. **真机回归（必须）**：BUG-3 的落库闸会**提高**「复读章」的 NG 可见度（原本静默落库的复读稿现在会如实失败）。需真机跑一本 NG 书，确认 ① 正常章照常通过 ② 复读章被拦且提示 `CRW.QualityFailed（疑似整段复读…）`。
2. **`alpha_frequency` 夹区间待复核**：官方创作范例为 `0.2`，本项目夹到 `[0.6,1.0]`。若真机出现「文笔被罚得发干 / 用词重复」可下调下限至 0.2–0.4 做对照。
3. **服务端采样层仍是根因**：`dry_*` 被云服务端忽略、`alpha_*` 服务端生效性未验证、复读触发条件未知 —— 见 `docs/交接-复读问题-外援接入指南.md §5`。
4. **版本号**：本轮未升版本、未重新出包（未做 Windows/APK 构建）。若要交付，按工程约定同步 `pubspec.yaml` / `version.txt` / `lib/core/app_version.dart` / `tools/*.py` 四处为 `1.0.0+47`。
