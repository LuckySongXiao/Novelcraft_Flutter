# NovelCraft 写作链路 · 真机实测与修复报告（v1.0.0+46 → +47）

> 日期：2026-10-11 ｜ 工程：`F:\30_Novelcraft_Flutter\Flutter版代码\novelcraft`
> 方法：**真实 RWKV Cloud 模型调用 + 真实用户库取证 + 桌面端启动验证 + 离线自检回归**
> 前置报告：`docs/写作BUG测试与修复报告-v1.0.0+46.md`（静态审计那轮，4 个 BUG）

---

## 0. 本轮测试环境（全部真实，非模拟）

| 项 | 实测值 |
|---|---|
| 桌面端 | `novelcraft_1.0.0+46_windows_release\novelcraft.exe` → **启动存活**（PID 29520，窗口 `novelcraft`，22s 后仍在） |
| 模型 | `rwkv7-g1k-7.2b-20260930-ctx25600` @ `https://api-7b.rwkvos.com/v1`（HTTP 可达，无需 apiKey） |
| 用户预设 | `samplingPreset=strong`（topK40 / topP0.5 / alphaPresence3.0 / alphaFrequency0.4 / dryPenaltyLastN16000）、`thinkingEnabled=true`、`maxReferenceLength=25600`、`ctx=25600` |
| 用户库 | `C:\Users\Administrator\Documents\novelcraft.sqlite`（8.5 MB，**725 章 / 9 个项目**） |
| 离线工具链 | `dart 3.10.4`（`--disable-dart-dev`）+ `tools/analyze_inprocess.dart` |

> ⚠ 本机 **Dart VM 无法 spawn 子进程**（`CreateFile failed 231`，沙箱内外均失败）→ `flutter build windows` 不可用。
> 因此**未产出 +47 二进制包**；修复以源码 + 离线/真机验证交付（出包需走云构建或开发机，见 `docs/打包指南.md`）。

---

## 1. 真实模型侧实测：采样参数对复读的影响（4 组对照）

固定同一提示词（章大纲 + 前文末尾 + 硬字数要求），只改采样参数：

| 组 | 参数 | 耗时 | 字数 | ngram | 段落复读 | 判定 |
|---|---|---:|---:|---:|---:|---|
| **A** | App 现状（strong 夹区间）+ think 默认 `fast` | 25s | 2039 | **0.005** | 0.000 | ✅ 干净 |
| **B** | App 现状 + `think_type: none` | 22s | 1938 | **0.017** | 0.000 | ✅ 干净 |
| **C** | **官方创作档** `top_k5 / top_p0.3 / alpha_presence0.2 / alpha_frequency0.2` + think none | 27s | 2260 | **0.385** | **0.500** | ❌ **判退化复读** |
| **D** | App 现状但**不发 `stop_tokens`** | 27s | 2279 | **0.001** | 0.000 | ✅ 干净 |

**三条结论（都推翻/修正了此前的推测）**：

1. **App 现行的「夹区间」抗复读档是对的，官方创作档反而会退化。**
   此前报告曾把 `alpha_frequency` 被夹到 `[0.6,1.0]`（官方 0.2）列为「待复核的过激项」——
   实测 C 组正是用官方档跑出了 ngram 0.385 / 段落复读 0.500 的**整段复读**。
   ⇒ **不要**把 `longFormSamplingParams` 的夹区间往官方 0.2/0.3 回调。
2. **`stop_tokens` 不伤输出**（D 组 2279 字 > A 组 2039 字），+46 给无状态路由补发它是安全的。
3. **`think_type` 有可观测差异**：`fast`（A/D）输出首字符是 Markdown 引用符 `>`；
   `none`（B/C）无 `>` 但**更容易复述提示词里的前文末尾**（B 组首句即回抄 `前文末尾`）。
   两条链路各有对应清理器（`_stripLeadingQuoteBlock` / `trimSliceEcho`），故只在
   **用户主动关闭思维链**时下发 `none`（见上轮 BUG-4 修法），默认行为不变。

---

## 2. 真实用户库取证：写作质量问题的规模

扫描 725 章（只读，未改动任何数据）：

| 项目 | 章数 | 空正文 | <3200字 | ≥3200字 | 标题带生产元信息 | 梗概带生产元信息 | **疑似复读章** |
|---|---:|---:|---:|---:|---:|---:|---:|
| `421e4a69`（430 章） | 430 | 278 | 41 | 111 | 0 | 115 | **118** |
| `cf949155` | 121 | 32 | 44 | 45 | 0 | 101 | 22 |
| `41a7139d` | 41 | 9 | 17 | 15 | 0 | 36 | 1 |
| `30e1cd8d` | 31 | 1 | 19 | 11 | 0 | 28 | 0 |
| `dbc60d1e` | 30 | 0 | 19 | 11 | 0 | 28 | 7 |
| `081f8357` | 30 | 6 | 3 | 21 | **9** | 21 | 2 |
| `73bd1eec` | 30 | 0 | 0 | 30 | 0 | 27 | 6 |

**实锤样本**（这些值已作为回归用例写进 `tools/chapter_title_selftest.dart` T 组）：

```
标题：第一卷·第三章·《青铜面具的秘密（约600字》        ← 半截括号 + 字数提示
标题：第一卷·第六章·《第7/10章》                      ← 纯章号当章名
标题：第二卷·第六章·《净化仪式（约700字）开局状态：》   ← 元信息拼接
梗概：# 第1章：祭祀夜的异常\n## 本章目标\n- **推进核心事件**…   ← 原始 Markdown 大纲落库
梗概：…| 角色 | 身份/状态 |                            ← Markdown 表格行混入
梗概：…在绝境中完全觉醒，看到整个宇宙网络。…（同句循环十余遍）  ← 复读梗概落库
正文：ngram 0.83 / 0.916 / 0.784（118 章）               ← 复读正文落库
```

---

## 3. 本轮修复的 BUG（真机/真库实锤）

### BUG-5 ｜章名解析器把「污染名」判成可靠，污染标题直接落库 ★高

- **位置**：`lib/ai/utils/chapter_title.dart`
- **复现（真库值，修复前 12/21 断言失败）**：
  `extractName('# 第3章：青铜面具的秘密（约600字）\n## 本章目标\n…')`
  → 产出 **`青铜面具的秘密（约600字`** 且 `reliable=true` → 标题写成 `《青铜面具的秘密（约600字》`。
  `第7/10章`、`裂痕（700字` 同样被判可靠。
- **根因**：`cleanFragment` 只剥了**右**括号（留半截左括号），且 `isReliableName`
  不认「字数提示 / 纯章号 / 分数章号 / 半截括号」。
- **修法**：
  1. `cleanFragment` 先删 `（约600字）` 类字数提示，再删**落单括号**（与 `OutlineRepairText` 同策）；
  2. `isReliableName` 新增 4 条判据：残留字数提示、纯章号（`第7章`/`第7/10章`）、
     名字混入 `第N/M章`、括号不配对或含 `/`。
- **修复后**：`青铜面具的秘密` / `暗流涌动` / `裂痕` / `净化仪式开始`（全部干净且可靠）。

### BUG-6 ｜解析不可靠时仍把污染名写进标题 ★高

- **位置**：`lib/application/services/multi_agent_book_generation_service.dart`（章节大纲落库循环）
- **根因**：`final String resolved = resolvedNames[i].name ?? '';` ——
  `reliable` 只用来决定「要不要请模型批量重命名」，**取名字时完全不看它**。
  批量重命名失败/未配模型时，污染名照样落库。
- **修法**：`resolvedName.reliable ? (name ?? '') : ''`，不可靠即回落 `第N章`。

### BUG-7 ｜退化复读的梗概可落库 ★高

- **位置**：`_chapterBrief`（同上文件）
- **根因**：梗概链路无复读闸。真库 100+ 条 summary 是「同一句循环十余遍」的复读文本；
  且它们是**短文本**，`RepetitionGuard` 通用阈值 0.30 抓不住（实测真实退化梗概 ngram=0.271）。
- **修法**：`_chapterBrief` 内以 **0.20** 阈值过 `RepetitionGuard.isDegenerate`，
  命中即回落章名（宁可信息少，不可投毒 —— 坏梗概会污染后续每次「按梗概重写」）。

### BUG-8 ｜Markdown 表格行混进章节梗概 ★中

- **位置**：`ChapterTitleParser.extractBrief`
- **根因**：只跳「纯元信息行」，不认 Markdown 表格行 → 梗概尾部出现 `| 角色 | 身份/状态 |`。
- **修法**：整行丢弃表格行/分隔行（`_isTableRow`），并兜底剥掉行内管道符。

### 上一轮（静态审计）已修的 4 个，本轮复验仍在位

| # | BUG | 文件 |
|---|---|---|
| 1 | 作者「额外要求」在续写/补片时被丢弃 | `chapter_rewrite_service.dart` |
| 2 | 长选区「续写」被截断判据误判必失败 | `selection_edit_service.dart` + `selection_apply_text.dart` |
| 3 | 复读正文可穿闸落库（落库前闸只覆盖大纲） | `chapter_rewrite_service.dart` |
| 4 | 「关闭思维链」在 RWKV 云路由无效 | `openai_compatible_provider.dart` + 两个调用方 |

---

## 4. 验证结果（修复后）

| 项 | 结果 |
|---|---|
| 解析器真机探针（真库污染值） | **21 / 21 通过**（修复前 12 失败） |
| 离线自检 | **13 / 13 全绿**（`chapter_title` 新增 T 组 17 条真实库回归锁） |
| 类型检查 | `analyze_inprocess lib` → **235 文件 error:0 warning:0** |
| i18n | **1164 调用点 / 0 缺失** |
| 插值 lint | 279 文件 / **0 命中** |
| 桌面端 | v1.0.0+46 二进制**启动存活**验证通过 |

**改动文件**

```
lib/ai/utils/chapter_title.dart                          BUG-5 / BUG-8
lib/application/services/multi_agent_book_generation_service.dart  BUG-6 / BUG-7
tools/chapter_title_selftest.dart                        新增 T 组（真实库回归锁）
pubspec.yaml / version.txt / lib/core/app_version.dart   版本号 → 1.0.0+47
tools/sync_release_snapshot.py / tools/package_release.py  DEFAULT_VERSION → 1.0.0+47
```

---

## 5. 遗留与后续

1. **出包**：本机无法构建（Dart VM 不能 spawn 子进程）。需走 GitHub Actions 云构建，
   或换一台具备 VS2022 的 Windows 开发机执行 `flutter build windows --release`。
2. **存量数据清洗**（用户库 725 章）：
   - 9 条污染标题、260+ 条污染梗概、150+ 章复读正文 —— 建议加一个「项目体检 → 一键清洗」动作，
     用本轮的解析器 + `RepetitionGuard` 批量修 `title`/`summary`（正文复读需人工确认或重写）。
3. **复读的服务端根因**仍在（`dry_*` 被云服务端忽略、`alpha_*` 生效性未验证）——
   见 `docs/交接-复读问题-外援接入指南.md §5`。
4. **采样档位建议**：实测数据支持**维持**现有 `strong` 夹区间，勿回调官方 0.2/0.3。
