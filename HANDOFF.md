# NovelCraft Flutter 版 — 交接文档（HANDOFF）

## 最新交接：1.0.0+46（2026-10-11）—— 复读问题修复 + 外援交接

**用户报「遇到个大问题」：严格惩罚重复输出的参数设定下，大纲修订仍整段复读并持久化
进 notes（截图铁证：「本章目标：本章目标：」双层前缀）；要求先修复读，再整理测试记录、
编写交接文档给外援。**

### 1. 取证结论（用户假设「停止符被正则过滤掉」的验证）

停止符不是被剥掉，而是**根本没发给无状态路由**：`kRwkvDefaultStopTokens=[0,261,24281]`
之前只在有状态路由（`/state/*`、`/v1/batch/*`）下发；无状态 `/v1/chat/completions`
（大纲修订走的就是它）从不携带。另有两个既有事实：`alpha_presence` 被
`longFormSamplingParams` 夹到 [0,0.5]（用户设的 strong 3.0 从未真正生效，实测更激进会
「被罚得不敢写」）；`dry_*` 在 RWKV Cloud 服务端被静默忽略。完整取证表见
`docs/交接-复读问题-外援接入指南.md` §3。

### 2. 实现

- **`lib/ai/rwkv/rwkv_sampling.dart`**：`kRwkvAntiRepeatSampling` 补
  `'stop_tokens': kRwkvDefaultStopTokens`（import batch_chat，纯 Dart 链不破），
  经 `_buildExtraFields` 白名单展平顶层 → 无状态路由与有状态路由行为对齐。
- **新增 `lib/ai/utils/repetition_guard.dart`（纯 Dart）**：三层退化复读检测 ——
  字符级 12-gram 重复率（阈值 0.30）/ 紧邻重复行 / 段落级重复率；
  `isDegenerate()` 综合判定 + `diagnose()` 诊断串。
- **`lib/ai/utils/outline_repair_text.dart`**：`parse()` 循环剥净复读标签
  （修「本章目标：本章目标：」双层前缀 —— 此前只剥一层，`render` 又包一层）；
  新增 `stripFieldLabels()` 供兜底路径使用。
- **`chapter_rewrite_service.repairOutlineAndRewrite` 复读闸**：落库前对
  `notesOutline` / `cleanedRaw` 跑 `isDegenerate`，命中 → **如实失败、绝不写库**
  （新 i18n 键 `CRW.OutlineRepeatBlocked`）—— 复读大纲一旦落 notes 会传染后续每次重写。
- **文档进源码树**：`docs/交接-复读问题-外援接入指南.md`（难点/开放问题/文件索引）、
  `docs/测试记录-v1.0.0+42-+46.md`（五轮测试记录与验证结果）。

### 3. 验证

- `lib/` **235 文件** `error: 0 warning: 0`。
- **新增第 13 个离线自检 `tools/repetition_guard_selftest.dart`（16 例）**；
  `outline_repair_selftest` 扩到 **52 例**（F 组锁双层前缀）；**13 个自检全绿**。
- i18n：**1163 调用点 / 0 缺失**（+1 条）。
- 复读样本（模拟截图形态）ngram=0.655 命中拦截；正常散文/结构化大纲 0.00 不误杀。

### 4. 遗留（给外援，见交接文档 §5）

复读根因大概率在服务端采样层（客户端参数空间「压复读 vs 写够长」互斥）；alpha_* 服务端
生效性待验证；复读触发条件未知；stop_tokens 解码确认。

### 5. 交付件（`F:\30_Novelcraft_Flutter\`）

| 文件 | 字节数 | SHA256 |
| --- | ---: | --- |
| novelcraft_1.0.0+46_windows_release.zip | 见 `发布清单-v1.0.0+46.md` | 见清单 |
| novelcraft_1.0.0+46_release.apk | 见 `发布清单-v1.0.0+46.md` | 见清单 |
| novelcraft_1.0.0+46_source.zip | 见 `发布清单-v1.0.0+46.md` | 见清单 |

## 上一版交接：1.0.0+45（2026-10-10）

**用户报两件事：① 「续写的字数依然未达标」；② 「章节预览中对选中文本进行续写或者
润色、扩写等操作后，没有让用户确认是否应用。通常来说用户采纳之后，续写的文本需要
被插入到所选文本的下一段，润色和扩写的文本被采纳后需要替换所选文本段。」**

### 1. 根因

- **续写不达标**：`SelectionEditService` 的续写提示词**没有任何字数要求**
  （「仅输出紧接选区的新增正文」），`maxTokens` 也没传（默认 1800）——
  模型随手给一两百字就交差。
- **无采纳环节**：AI 结果卡只有「复制结果」；预览页注释明说「只读快照，
  不写回正文」—— 用户只能手工复制回编辑表单。

### 2. 实现

- **新增 `lib/ai/utils/selection_apply_text.dart`（纯 Dart 零 import）+
  `tools/selection_apply_selftest.dart`（15 条断言）**：`applySelectionResult` —
  替换语义（润色/去重润色/扩写/重写）原地覆盖选区；续写语义插到**所选文本所在
  段落的末尾之后**作为独立一段（选区停在段中时，先把该段剩余部分留在前面，
  绝不把续写硬插进句子中间）；结果 trim、连续空行归一、选区不在正文/空结果如实抛错。
- **`SelectionEditService` 补字数纪律**：`wordTarget()` —— 续写目标约 1200 字
  （下限 600，validate 里 `continuation_too_short` 让 `FictionQuality.generate`
  带反馈重试一次）；扩写目标 ≈ 选区×2（400~2000）；`maxTokens()` 按动作给足
  （续写 2400、扩写按目标×2），不再用默认 1800。作者要求里写了字数时优先
  （提示词顺序保证）。
- **采纳应用链路**（面板确认 → 预览写库 → 表单回填，三段闭环）：
  - `ChapterAiPanel`：结果卡增「**采纳应用**」按钮 + 确认对话框
    （语义说明因动作而异：插入下一段 vs 替换选区 + 版本号 +1；展示两侧字数）；
    新增 `onApply(result, action)` 回调，null 时退回「仅复制」旧行为；
    记录 `_resultAction`（采纳时要区分插入/替换）。
  - `ChapterPreviewPage._applyResult()`：`applySelectionResult` 做文本手术 →
    `chapterService.updateById` 写库（content/wordCount/lastEditedAt/**versionNumber+1**）
    → 页面即时刷新（应用结果立刻可见）→ 选区清空 + 面板重建（`_applyTick` 作 key，
    防重复应用）。**面板 `fullContent` 改传展示态正文 `_displayContent`** ——
    选区文本来自阅读视图，对同一份串做 indexOf 才永远命中（原传库原文，
    多段选区会因 \r\n/\n 差异 indexOf 失败）。
  - **防覆盖闭环**：预览页 `PopScope(canPop:false)` —— 应用过后离页时把最新
    `_values` 作为路由结果带回；`entity_page` 预览按钮改 `await` 接结果，
    非 null 时回填表单控制器 —— 否则表单还持有应用前的旧正文，
    用户一保存就把 AI 结果冲掉。

### 3. 验证

- `lib/` **234 文件** + `test/` **46 文件** `error: 0 warning: 0`。
- **新增第 12 个离线自检 `tools/selection_apply_selftest.dart`（15 条断言）**，
  合计 **12 个自检 366 条断言全绿**。
- i18n：**1162 调用点 / 0 缺失**（+8 条）；`dart_interp_lint.py` **278 文件 / 0 命中**。
- Windows / APK 构建、启动验证见 `发布清单-v1.0.0+45.md`。

### 4. 交付件（`F:\30_Novelcraft_Flutter\`）

| 文件 | 字节数 | SHA256 |
| --- | ---: | --- |
| novelcraft_1.0.0+45_windows_release.zip | 见 `发布清单-v1.0.0+45.md` | 见清单 |
| novelcraft_1.0.0+45_release.apk | 见 `发布清单-v1.0.0+45.md` | 见清单 |
| novelcraft_1.0.0+45_source.zip | 见 `发布清单-v1.0.0+45.md` | 见清单 |

> ⚠ 哈希以发布根目录的 `发布清单-v1.0.0+45.md` 为准（HANDOFF 自身在源码包里）。

### 5. 遗留

- 应用链路（写库 / 回填 / PopScope 返回值）需真机实测：选中 → 续写 → 采纳 →
  检查插入位置；替换 → 采纳 → 返回表单确认已回填。
- 续写目标 1200 字是选节级缺省；作者可在「附加要求」里写字数覆盖。
- B / C / D 旧遗留不变；+44 管线的批量效果待跑完整本 NG 书。

## 上一版交接：1.0.0+44（2026-10-10）

**用户报：草稿按要求重写后「正文总篇幅未达预期」且「章节状态未做变更」，并给出新工艺：
调纲之后要规划正文续写切片数与目标字数 → 按规划逐片续写 → 达标后由 7B 模型结合上下文
逐段审查润色 → 审毕变更状态 → 更新素材履历 → 同步刷新项目进度。本轮把 +43 的单发重写
升级为这条完整管线。**

### 1. 根因（代码级）

- **篇幅不足**：`ChapterRewriteService.rewrite()` 是**单发生成**——「约 4200 字」只写在
  提示词里，输出预算一次押完；7B 单发实际只出 1200~3100 字 → 过不了 3200 字质量闸。
- **状态不变**：质量闸不过 → 整稿**不落库**（坏稿绝不覆盖原稿的安全设计）→
  `status` 停在 Draft，履历/时间线因「先过闸才落库」被一起卡住。
- **进度不同步**：重写落库路径从不调 `projects.updateProgress`——只有整书生成收尾会刷。

### 2. 实现（三个口径均经用户确认）

- **达标口径**：规划总目标锚定 4200 字；写完规划片仍 <3200 自动补片（至多 2 片）；
  **≥3200 过闸即达标**进入润色（4200 是尽力目标，3200 是硬底线）。
- **续写起点**：程序判据 —— 原稿非空且过质量检查（`chapterQualityNote(minWords: 0)`，
  只查质量不查字数）→ 从原稿末尾续写；原稿为空 / 复读 / 大纲体 → 第一片从开篇重写。
- **润色通道**：主 Agent（`resolveAgentProvider(main: true)`，即用户配置的 7B 主模型），
  与写作同上下文口径，不新增配置。

### 3. 改动清单

- **新增 `lib/ai/utils/chapter_plan_text.dart`（纯 Dart 零 import）**：
  `ContinuationSlice`；`parseSlicePlan`（宽容解析「片N|1400|要点」等行形态，先全量解析
  → 验总量 ≥ 缺口七成 → 再按 `maxSlices` 截断——**顺序反了会把合法规划误判为不足**）；
  `fallbackSlices`（程序兜底均分，单片 ≤2200，绝不回到「押一次输出」）；
  `chunkForPolish`（句子边界分块，移植 `_polishDraft`）；`trimSliceEcho`（回声去重：
  剥 `【前文末尾】`标记回抄 + 逐字重叠 ≥12 字切掉 + 从句界重启）。
- **新增第 11 个离线自检 `tools/chapter_plan_selftest.dart`（42 条断言）**。
- **`ChapterRewriteService.rewriteWithPlan()`**：底座判据 → `plan`（模型规划 +
  兜底）→ `write`（逐片串行续写，每片带前文末尾 500 字 + 大纲 + 本片要点，末片收
  章末钩子；单片失败且底座为空 → 如实失败）→ 补片循环 → `polish`（900 字块逐段
  润色，temperature 0.5，单块塌缩 <85% 保留原块，整体 <90% 放弃润色）→ `gate`
  （润色后复检）→ 落库（`_persistAndSync` 负责 Draft → Completed + 履历/时间线含
  故事时间）→ `progress`（**新增** `_refreshProjectProgress` 刷新 `projects.progress`）。
- `repairOutlineAndRewrite` 改调 `rewriteWithPlan`（自动触发「智能修复全部草稿章」、
  矩阵批量按钮、单章重写对话框三条入口**自动全部升级**，无需改调用方）。
- 构造器增 `ProjectRepository? projects`（DI 注入 `projectRepositoryProvider`）。
- `chapter_rewrite_dialog._phaseLabel` 增 `plan` / `write` / `polish` / `progress` 四阶段。
- i18n +12 条（`tools/add_l10n_keys_2026_10_10.py` 追加第二批，幂等）。

### 4. 验证

- `lib/` **233 文件** + `test/` **46 文件** `error: 0 warning: 0`。
- **11 个离线自检 351 条断言全绿**（新增 `chapter_plan` 42 条）。
- i18n：**1151 调用点 / 0 缺失**（enStrings 4616 条）；`dart_interp_lint.py`
  **277 文件 / 0 命中**；`dart format --output=none` 无语法错误。
- Windows / APK 构建、启动验证见 `发布清单-v1.0.0+44.md`。

### 5. 交付件（`F:\30_Novelcraft_Flutter\`）

| 文件 | 字节数 | SHA256 |
| --- | ---: | --- |
| novelcraft_1.0.0+44_windows_release.zip | 见 `发布清单-v1.0.0+44.md` | 见清单 |
| novelcraft_1.0.0+44_release.apk | 见 `发布清单-v1.0.0+44.md` | 见清单 |
| novelcraft_1.0.0+44_source.zip | 见 `发布清单-v1.0.0+44.md` | 见清单 |

> ⚠ 哈希以发布根目录的 `发布清单-v1.0.0+44.md` 为准（HANDOFF 自身在源码包里）。

### 6. 遗留

- **管线需真机带模型实测**：规划质量 / 补片次数 / 润色耗时（每章 ≈ N 片 + M 块润色
  次调用）需实际跑一本 NG 书验证；离线只锁了纯文本规则。
- B（章名/梗概解析源头修复）、C（存量 9 章污染清洗）、D（空正文不落库语义）仍未开工。
- 润色与写作共用主 Agent：若模型慢，修复一章的调用次数 ≈ 1 规划 + N 片 + 补片 + M 块
  润色（N≤6+2，M≈4200/900≈5）——用户侧可感知变慢，属工艺换质量的预期代价。

## 上一版交接：1.0.0+43（2026-10-10）

**用户报：一键写书「章节 NG 率变高」；对失败章手动 agent 重写「一直失败，原因是质量或上下文不达标」。要求：先按前后章节调整大纲、再按流程重写本章节，且由 agent 主动完成；完成后自动在角色管理 / 世界观设定中插入该章对应时间节点的素材履历。**

### 1. 取证（只读用户真实数据库，`novelcraft.sqlite`）

- `夜闯寡妇村` 30 章 = 21 Completed / **9 Draft（NG 30%）**：其中 6 章 `content` 为 NULL
  且 `version_number=1`（写作团队失败、`multi_agent_book_generation_service.dart` 失败分支
  **不落库直接返回**），另 3 章字数不足（1176 / 2231 / 3075，闸门 `minFinalWords=3200`）。
- **污染实锤**：失败章的 `summary` 被「章名 + 字数元信息」污染 ——
  `第一章：祭祀之夜（700字）##`、`暗流涌动（约500字）##`、`大纲：夜闯寡妇村（全卷第5章）##`；
  `title` 有半截括号 `《暗流涌动（约600字》`、`《第7/10章》`、`《净化仪式（约700字）开局状态：》`。
- **「一直重写失败」的真凶**：`ChapterRewriteService` 把污染的 `summary` 原样喂回模型 →
  模型照「700 字」写 → 过不了 3200 字闸 → 次次 NG。用户「先调大纲再重写」的判断被证实为正解。
  `ChapterTitleParser` 对上述形态均判 `reliable=true`（漏网：半截括号、`（700字）`、行尾 `##`、
  中文数字章号），重命名兜底永不触发（Dart 探针喂真实库值逐字复现）。
- 口径说明：`示例项目·玄穹剑主` 6 章 102~138 字全部 Draft（100% NG），会拉高全库平均 NG 率。

### 2. 修法（用户拍板：只做 A「调大纲 → 重写 → 回写履历」；触发 = 生成收尾自动 + 手动按钮；履历时间 = 故事内时间）

- **新增 `lib/ai/utils/outline_repair_text.dart`（纯 Dart 零 import）**：
  `RepairedOutline`（目标/承接/冲突/转折/钩子/时间节点/人物 7 字段 + `isUsable`）；
  `stripMeta`（含 `_dropUnpairedBrackets` 清 `（约600字` 半截括号，兼容繁体 `約` 与全角数字）；
  `hasMetaDirt`；`parse`（标签须紧跟冒号/空白/右括号，防「目标人物是X」误判）；
  `render`（可附「不少于 N 字」硬要求；落 notes 用 `targetWords:0` 免得自己成残渣）；`toBrief`。
- **`ChapterRewriteService.repairOutlineAndRewrite()`**：收集前 800 字 / 后 800 字 /
  同卷梗概（过 stripMeta）/ 卷大纲（截 900）→ 编辑人格（temperature 0.6）修订大纲（7 字段
  输出格式 + 「禁止字数提示」「过渡章如实写」纪律）→ `parse`（失败回落 cleanedRaw≥20 字）→
  `render(targetWords:0)` 幂等写回 `notes`（`_composeNotes` 保留原备注）+ `toBrief` 写 `summary`
  → 复用 `rewrite()`，`storyTime` 一路透传。
- **履历回写（诉求④的落点本就存在，此前被「质量闸通过才落库」前置卡死）**：
  `ChapterSyncService` 全链路接受 `storyTime`，履历条目、`CharacterEvents.storyTime`
  （该列语义本就是「书籍世界内的时间」）、时间线 `description`（加 `【故事时间：…】`头）
  均带故事时间；`_cleanStoryTime` 归一化（剥头部标记、「未明确/未知/N/A」归空、限 200）。
- **自动触发**：一键写书收尾 `_rewriteFailedChapters` 改走 `repairOutlineAndRewrite`，
  并向矩阵发 `outlineRepair` 阶段事件（紫色「调纲重写」）；失败章重写仍在章节池之后、
  分卷归纳之前。
- **手动触发**：矩阵悬浮窗新增「智能修复全部草稿章」批量按钮（确认文案注明先调纲再重写）；
  单章重写对话框 / 按钮默认 `repairOutline: true`。
- **悬浮窗保留 + 统计**（用户要求「写完了也要能进悬浮窗」）：`MultiAgentRunState` 增
  `projectId / finishedAt / completedCount / failedCount / ngRate / hasLastRun`
  （NG 率分母 = 已出结果章）；矩阵对话新增统计行（总章/定稿/失败/待写/NG 率，NG>0 红色），
  elapsed 冻结于 `finishedAt`；项目概览页新增「上次写作结果」横幅（匹配 `run.projectId`）
  可重进矩阵；应用壳「写作结果 · NG N 章」长条常驻入口。

### 3. 验证

- `lib/` **232 文件** + `test/` **46 文件** `error: 0 warning: 0`。
- **新增第 10 个离线自检 `tools/outline_repair_selftest.dart`（45 条断言）**
  （A 组 12 用库里真实污染值锁 `stripMeta`、B 组 4 锁 `hasMetaDirt`、
  C 组 10 锁 `parse`、D 组 8 锁 `render`、E 组 4 锁 `toBrief`），
  合计 **10 个自检 309 条断言全绿**。
- i18n：**1138 调用点 / 0 缺失**（+18 条）；`dart_interp_lint.py` **276 文件 / 0 命中**。
- Windows / APK 构建、启动验证见 `发布清单-v1.0.0+43.md`。

### 4. 交付件（`F:\30_Novelcraft_Flutter\`）

| 文件 | 字节数 | SHA256 |
| --- | ---: | --- |
| novelcraft_1.0.0+43_windows_release.zip | 见 `发布清单-v1.0.0+43.md` | 见清单 |
| novelcraft_1.0.0+43_release.apk | 见 `发布清单-v1.0.0+43.md` | 见清单 |
| novelcraft_1.0.0+43_source.zip | 见 `发布清单-v1.0.0+43.md` | 见清单 |

> ⚠ 哈希以发布根目录的 `发布清单-v1.0.0+43.md` 为准（HANDOFF 自身在源码包里）。

### 5. 遗留（用户未要求本轮做）

- **B**：章名 / 梗概解析源头修复（给 `isReliableName` 补半截括号、`（N字）`、行尾 `##`、
  中文数字章号判据）——本轮只做兜底清洗，不动解析器。
- **C**：存量 9 章污染数据清洗（`夜闯寡妇村` 6 章 NULL + 3 章字数不足；示例项目 6 章）。
- **D**：空正文不落库语义（失败分支直接 return，用户看不到「第 N 次尝试失败」痕迹）。
- 本轮链路（调纲重写 / 履历回写 / 矩阵统计）**需真机带模型实测**。

## 上一版交接：1.0.0+42（2026-10-10）

**用户报：「本次模型上下文支持 25K，但是我没办法设定 25K 上下文」。**
排查后确认是**两个 bug 叠加 + 一处未同步**，模型侧完全正常。

### 1. 现象与真实数据

用户的模型是 `rwkv7-g1k-7.2b-20260930-ctx25600` —— 模型名里**明确写着 25K**，
`parseContextWindow()` 也能正确解析出 `25600`（自检 A1 锁死）。但现场
`%APPDATA%\NovelManagement\ai_config\runtime_settings.json` 落的是
`contextWindowTokens: 16384` / `maxReferenceLength: 4000`，**与模型名对不上**。
于是生成链路的 `outputBudgetTokens` 被 `16384 × 55% ≈ 9011` 钳死 —— 滑块怎么拖都上不去。

### 2. 三个根因

| # | 根因 | 后果 |
| --- | --- | --- |
| A | 「最大令牌数」档位表 `kMaxTokensSteps` 只有 512/1K/…/16K/**32K**/…，**没有 24K/25K** | 想选 25K 只能吸附到 32K，选不出模型真实支持的档位 |
| B | 窗口**只在点「保存」provider 时**刷新一次，页面加载读的是 KVStore 旧值 | 模型名 `ctx25600`，窗口却停在默认 16384 |
| C | `_SamplingThinkingCardState._collectAndPersist` 保存采样参数时**新建 `AiRuntimeSettings` 却漏传 `maxReferenceLength` / `contextWindowTokens`** | 每保存一次采样参数，就把用户设的令牌数与已同步的窗口**静默重置**回 4000 / 16384 |

**C 最隐蔽**：新建实例漏字段 → 回落构造默认值，**类型检查完全看不出来**
（这也解释了落盘文件里那对可疑的 `4000 / 16384`）。

### 3. 修法（遵守用户「只补档位、不动窗口交互」的要求：不新增任何可编辑控件）

- **A** 档位表插入 `24576`（24K）/ `25600`（25K）两档，标签表同步 → 共 14 档。
- **B** 新增 `_syncContextWindowFromModel()`，在页面加载（`initState` post-frame，
  特意排在 provider 配置与默认 provider 都恢复**之后**）按**默认 provider 的模型名**
  刷新窗口并落盘。窗口仍是**只读派生值**，没有新 UI 控件。配套新增
  `_kindByRegisteredName()`（注册名 → kind，兼容 `RWKV Cloud` 与 `RWKV Cloud::official-7b`）。
- **B'** `_persistProviderConfig` 里窗口改为**优先取默认 provider 的模型名**，
  避免在非默认 tab 上点保存时把窗口改写成别家模型的值（OpenRouter 模型无 ctx → 会被写成 16384）。
- **C** `_collectAndPersist` 显式继承 `maxReferenceLength` / `contextWindowTokens`。
- 顺带把「保存 provider」里的 KV 写入抽成 `_persistRuntimeSettings()`，与新增的窗口同步共用。

### 4. 验证

- `lib/` **231 文件** + `test/` **46 文件** `error: 0 warning: 0`。
- **新增第 9 个离线自检 `tools/context_window_selftest.dart`（27 条断言）**，
  合计 **9 个自检 264 条断言全绿**：
  - A 组 10 条锁 `parseContextWindow`（用户实际模型 `ctx25600` → 25600；无标记 / `<512` / 非数字 → 回落 16384）；
  - B 组 10 条锁预算切分：窗口 25K → 参考 10240 / 输出 14080；旧窗口 16K → 参考 6553 / 输出 9011，
    **B5 直接断言「窗口 25K 的输出预算 > 旧窗口 16K」**（实测差 5069）；
  - D 组锁死「漏传字段会回落 4000 / 16384」这一坑，提醒后来者必须显式继承。
- i18n：1120 调用点 / **0 缺失**；`dart_interp_lint.py` 275 文件 / **0 命中**。
- Windows / APK 构建、真机启动验证见 `发布清单-v1.0.0+42.md`。

### 5. 交付件（`F:\30_Novelcraft_Flutter\`）

| 文件 | 字节数 | SHA256 |
| --- | ---: | --- |
| novelcraft_1.0.0+42_windows_release.zip | 见 `发布清单-v1.0.0+42.md` | 见清单 |
| novelcraft_1.0.0+42_release.apk | 见 `发布清单-v1.0.0+42.md` | 见清单 |
| novelcraft_1.0.0+42_source.zip | 见 `发布清单-v1.0.0+42.md` | 见清单 |

> ⚠ 哈希以发布根目录的 `发布清单-v1.0.0+42.md` 为准（HANDOFF 自身在源码包里）。

## 上一版交接：1.0.0+41（2026-10-09）

**这是 1.0.0+40 的紧急返修（P0）：+40 在 Windows 上「启动即崩」。** 用户实测截图报：

```
PathNotFoundException: Cannot open file, path =
'C:\Users\Administrator\AppData\Roaming\NovelManagement\internal\
 Closure: (String) => String from Function '_fileOf@872141309': static (key)'
(OS Error: 文件名、目录名或卷标语法不正确。, errno = 123)
```

### 1. 根因：字符串插值漏写花括号

F1（存储键净化）把路径拼接写成了：

```dart
final f = File('${_scopeDir(scope).path}${Platform.pathSeparator}$_fileOf(key)');
```

Dart 的 `$identifier` **只能插值简单标识符** —— `$_fileOf` 插进去的是**函数对象本身**，
后面的 `(key)` 退化成**字面文本**。于是路径成了
`...\internal\Closure: (String) => String from Function '_fileOf@...': static (key)`，
`File.existsSync()` 直接抛 `errno 123`。

**为什么之前四道门禁一道都没拦住**：

| 门禁 | 为什么没用 |
| --- | --- |
| `dart analyze` | **插值一个函数是合法 Dart**，0 error 0 warning |
| 8 个离线自检 | 没有一个覆盖「文件路径拼接」（它需要 `dart:io` + `path_provider`） |
| 构建 | 编译期同样无从察觉 |
| 产物版本串核验 | 只证明「新版本进了包」，与能否启动无关 |
| **真机跑一次** | ← **唯一能拦住的，而 +40 恰恰漏了这一步** |

### 2. 修法：路径拼接下沉成纯函数 + 一道永久防线

- `lib/data/storage/store_key.dart`（纯 Dart 零 import）新增三个纯函数：
  - `storeFileName(key)` → `'${sanitizeStoreKey(key)}.json'`
  - `storeFilePath(scopeDir, key, separator)` → **唯一**允许拼路径的地方
  - `storeKeyFromFileName(fileName)` → `storeFileName` 的逆
- `key_value_store_native.dart` 收敛为单一私有方法 `_file(scope, key)`，
  读 / 写 / 删三个入口都走它，内联拼接彻底消失。
- 顺带修掉 `listKeys` 的 `replaceAll('.json', '')` —— 那会削掉键名**中间**的 `.json`
  （`a.json.b` → 文件 `a.json.b.json` → 被削成 `a.b`），
  破坏了「`listKeys` 的返回值能被 `readJson` 原样命中」这条契约。改为只剥结尾一个后缀。
- **新增 `tools/dart_interp_lint.py`**：扫描「字符串字面量内出现 `$标识符(`」这一模式，
  自带 `--selftest`。**上线即抓到一个既有 bug**：`ai_configuration_page.dart:1893` 的
  `$totalMb.toStringAsFixed(1)` —— 界面上会显示成「12.3/45.6.toStringAsFixed(1) MB」，
  是模型下载进度文案的显示错误，与本轮改动无关但一并修了。

### 3. 验证（这次跑了真机）

- `lib/` **231 文件** + `test/` **46 文件** `error: 0 warning: 0`。
- 8 个离线自检 **237 条断言全绿**；其中 `kv_key_selftest.dart` 增至 **29 条**，
  新增 D 组锁死路径拼接，含「结果不得含 `Closure` / `Function(` / `static`」的
  **errno 123 回归断言**。
- `dart_interp_lint.py --selftest` → OK；全库扫描 **275 个 .dart / 0 命中**。
- Windows `flutter build windows --release` → **EXIT=0 / 65.3s**；
  `data/app.so` 含 `1.0.0+41`，旧串 `1.0.0+40` 已消失。
- **真机启动验证**：脱离 Job Object 拉起 `novelcraft.exe`，18 秒后进程存活
  （101 MB / 105 MB），截图为「项目管理」正常界面、右下角 `v1.0.0+41`、
  项目列表只剩示例项目 —— **不再出现错误页**。
- APK `versionCode='41'`、`Verifies`（v2）、证书 SHA256 与 +34~+40 一致。

### 4. 教训

> **构建成功 + 类型检查 0 error + 自检全绿 ≠ 能启动。**
> 纯逻辑自检覆盖不到「平台 API 的调用形态」；这类代码只能在真机跑出来。
> 往后的硬规矩：**凡改动启动路径（存储层 / DI / 打开数据库），出包前必须实际拉起一次
> 可执行文件并截图确认**，不能只看构建日志与版本串。

### 5. 交付件（`F:\30_Novelcraft_Flutter\`）

| 文件 | 字节数 | SHA256 |
| --- | ---: | --- |
| novelcraft_1.0.0+41_windows_release.zip | 见 `发布清单-v1.0.0+41.md` | 见清单 |
| novelcraft_1.0.0+41_release.apk | 见 `发布清单-v1.0.0+41.md` | 见清单 |
| novelcraft_1.0.0+41_source.zip | 见 `发布清单-v1.0.0+41.md` | 见清单 |

> ⚠ 哈希以发布根目录的 `发布清单-v1.0.0+41.md` 为准（HANDOFF 自身在源码包里）。
> **1.0.0+40 的交付件请勿使用**（Windows 端启动即崩）。

## 上一版交接：1.0.0+40（2026-10-09）

承接 1.0.0+39 的 C1 拆书。用户实测报了 **4 个缺陷**（附 5 张截图），本轮逐条定位根因并修复。

| # | 用户报障 | 根因 |
| --- | --- | --- |
| ① | 项目概览的「7B 全书审查」不生效 | 存储键含 `:` → Windows 非法文件名 → 写盘异常被 `catch` 静默吞掉；解析任一条坏就整章丢弃；无任何进度反馈 |
| ② | 项目进度不随完成度更新 | 全工程 `projects.progress` **只读不写** |
| ③ | 章节写完不更新人物卡 / 世界观卡 | evidence 判据要求「连续子串」而 7B 给的是拼接引用 → 条条必败；行式兜底又被 Markdown 表格外壳打垮 |
| ④ | 质量校验失败的章不自动重写 | 只有「章节管理 → 单章重写」这个手动入口 |

### 1. F1 —— KV 键含冒号导致静默写盘失败【①与③的共同病灶】

`KeyValueStore` 的文件名直接取 key。审查留言用 `'{pid}:{cid}'`、防重签名用
`'last_success_v2:{cid}'` —— **冒号在 Windows 文件名里非法**，`File.writeAsString` 抛
`FileSystemException`，被调用方的 `try/catch` 吞掉。现场取证：
`%APPDATA%\NovelManagement\book_review\` 是**空目录**；`chapter_sync\` 下只有
`ai.enabled.json` 和一个 C# 时代遗留的 0 字节 `last_version` —— 说明**防重签名从未写进去过**，
所以同一版本的章节永远在重复抽取。

修法：新增 `lib/data/storage/store_key.dart`（**纯 Dart、零 import**），
`sanitizeStoreKey` 把 `<>:"/\|?*` 与控制字符换成 `_`，并去掉结尾的 `.` / 空格；
native 与 web 两个实现都改为经它取键。**必须幂等** —— `listKeys` 返回的已是净化键，
再走 `readJson` 必须命中同一条（自检 A12 锁死）。

### 2. F2 —— 完成进度 = 已完成章 / 总章数

新增纯函数 `progressFromChapterCounts(completed, total)`（`lib/application/models/stats.dart`）。
`ProjectStatisticsService.getStats` 读取时**顺带自愈回写** `projects.progress` ——
「只要打开一次概览页」，项目卡片上的进度就跟着修正，不必重跑生成。
新增 `ProjectRepository.updateProgress()` **只写 progress 一列、不动 `updated_at`**，
否则「最近编辑」会被刷成刚刚。生成链路收尾也补刷一次（见 F4）。

### 3. F3 —— 抽取证据校验放宽 + 行式兜底修好

**用真实数据复现过**：拿项目里的第一章正文直连
`https://api-7b.rwkvos.com/v1/chat/completions`（32.1s 返回 2693 字符）：

- 7B **确实**吐出合法 `updates` JSON，`name` 也是正文原名（林晚、维克拉姆）；
- 但 `evidence` 写成**一整段拼接引用**且带 `正文：` 前缀 → 旧判据要求「连续子串」
  → 条条必败 → 3 次重试全废 → **整章 0 条**；
- 行式兜底同样废：7B 输出的是 **Markdown 表格**（行首 `>` 与 `|`，还有 `|---|---|`
  分隔线）→ 裸 `split('|')` 切出空首段 → `类别 = ''` → **整行被丢弃**。

数据库侧旁证：`重生之红色警戒…` 30 章只有 **1 个**角色、`重生之我在印度…` 30 章
**0 个**角色，两本书都只有 0 个世界观设定，却各有 **27 条**时间线事件 ——
正是「只跑零模型的规则同步、AI 抽取全线失败」的指纹。

修法：新增 `lib/ai/utils/entity_update_text.dart`（纯 Dart）：
`stripEvidencePrefix` / `evidenceSharesText`（脱前缀 → 整段命中最好，否则按句读切段，
**任意段 ≥8 字且命中正文**即算有据）/ `pipeRowCells`（剥列表符号与序号、表头、分隔线，
按 `|` / `｜` 切分后**去掉首尾空段、保留中间空段**）。
`ModuleStateService` 校验前先做 `_normalizeItem`：`content` 超列宽**截断**而不是拒绝
（status 列宽 50，7B 几乎必给整句，旧「超长即拒绝」等于 status 永远落不下来），
evidence 脱前缀。**防幻觉的真闸门保留不动**：`source.contains(name)`。

### 4. F4 —— 全书跑完后自动重写质量失败章

位置在 `MultiAgentBookGenerationService.generate` 里，**章节池之后、分卷档案归纳之前**：
池子之后（质量失败是「跑完才知道」的，且重写要靠邻居定稿）、归纳之前（补出来的正文
同样要参与设定抽取与归档）。复用 `ChapterRewriteService` —— 与「章节管理 → 单章重写」
**同一条链路**，清洗与质量闸只有一套口径。逐章独立 `try/catch`，不过闸**不覆盖原稿**，
结果如实写进 `warnings`。按用户口径：**全部失败章，各试 1 次**。
补写成功会 `written += fixed`（`_needsRewrite` 与 `_qualityNote` 同参同源，
故失败集与已计入 `written` 的集合互斥，不会重复计数）。

### 5. F5 —— 审查链路后端修好 + 进度对话框

- **解析容错**：`_parseComments` 改为**逐条**容错 —— 接受 `List` 或 `Map['comments']`；
  单条缺 `problem`/`suggestion` 只跳过该条；`quote` 不在正文只清空 quote、**保留该条**；
  只有拿不到列表才判「未产出」。
- **`json_scan.dart` 重写**：新增 `parseJsonPayload`，**由文本里最先出现的结构字符**决定顶层。
  这条是必须的 —— `parseJsonObject(raw) ?? parseJsonArray(raw)` 有陷阱：裸数组 `[{…}]`
  会被 `parseJsonObject` 命中**内层对象**，于是 `decoded['comments']` 取不到
  → 整章留言被误判为「审查未产出」。
- **进度对话框**：`ValueNotifier` + `LinearProgressIndicator`，显示「正在审查第 i/N 章」
  与章节名，可取消，收工自动关窗并弹汇总 SnackBar。
  ⚠ 取消时对话框立刻关闭，而「当前那一章」还在飞 —— 必须把后台任务句柄留住、
  关窗后 `await` 它，否则读到的 `finished.value` 还是 null，取消文案永远出不来。

### 6. 交付件（`F:\30_Novelcraft_Flutter\`）

| 文件 | 字节数 | SHA256 |
| --- | ---: | --- |
| novelcraft_1.0.0+40_windows_release.zip | 见 `发布清单-v1.0.0+40.md` | 见清单 |
| novelcraft_1.0.0+40_release.apk | 见 `发布清单-v1.0.0+40.md` | 见清单 |
| novelcraft_1.0.0+40_source.zip | 见 `发布清单-v1.0.0+40.md` | 见清单 |

> ⚠ 三个交付件的字节数与 SHA256 **以发布根目录的 `发布清单-v1.0.0+40.md` 为准**：
> HANDOFF.md 本身就在源码包里，在包里写死「包含它自己的这个包的哈希」必然自相矛盾。

### 7. 本轮验证

- `lib/` **231 文件** + `test/` **46 文件** `error: 0 warning: 0`。
- 新增 `tools/entity_update_selftest.dart` 32 / 0、`tools/kv_key_selftest.dart` 19 / 0、
  `tools/json_scan_selftest.dart` 40 / 0；回归 `chapter_title` 17 / 0、
  `entity_profile` 24 / 0、`sanitizer` 28 / 0、`style_digest` 27 / 0、`style_rule` 40 / 0
  —— **共 227 条断言全绿**。
- i18n：zh / en 各 **4585 条**、严格对称；缺失 key 扫描 **1120 调用点 / 0 缺失**。

### 8. 仍未做 / 需注意

- **修复效果要先清洗旧数据才看得到**：F3 只保证**此后**的抽取能落库；那两本实测书里
  的 27 条时间线 / 0~1 个角色是**旧数据**，不重跑不会自己变好。批量清洗是破坏性操作
  （会改写实体档案），须用户确认后再做。
- B3 抽取结果审核面板、C2–C6、D3 端到端复测仍未开工。
- C1 拆书链路的真机实测缺口（7 次调用耗时 / 规则注入效果 / 中文 txt 编码边界）与上版一致。

## 上一版交接：1.0.0+39（2026-10-09）

承接 1.0.0+38 的 B4 分卷档案归纳。用户指令为
**「按原计划执行，`E:\书籍拆分` 目录下有样本书籍」**，
即按既定顺序进入 **C1 拆书：Agent 拆书 → 写作模板**，本轮完成 C1 全部子项并出包。

### 1. C1 解决什么问题

写作提示词此前全是手工写死的通用指令（「严禁重复」「不要写章节名」「不要输出（全文完）」），
模型只能凭自己的默认文风落笔。用户手上有一批拆解样本，但那些结论是**人读出来的**，
进不了生成链路。

C1 把它做成产品内的流水线：**10~18 MB 的小说 → 可塞进上下文的样本 → 两阶段归纳 →
一套可注入的写作规则**。

### 2. 实现（C1a–C1f）

| 子项 | 文件 | 作用 |
| --- | --- | --- |
| C1a | `lib/ai/utils/style_digest_text.dart`（新增，纯 Dart） | 段落切分 / 样本清洗 / 均匀采样 / 多块观察合并 / 分类归一 |
| C1b | `lib/application/services/style_rule.dart`（新增，纯 Dart） | 规则模型 + `toPromptBlock` 渲染 |
| C1b | `lib/application/services/style_rule_store.dart`（新增） | 规则库持久化（`KeyValueStore`，scope `style_digest`） |
| C1b | `lib/application/services/style_digest_service.dart`（新增） | 两阶段拆书服务 |
| C1c | `multi_agent_book_generation_service.dart` | `styleRuleSetId` + 6 个注入点 |
| C1d | `writing_prompt_catalog.dart` | `Style/system`、`Style/observe`、`Style/synthesize` |
| C1e | `lib/ui/pages/style_study_page.dart`（新增） | 文风研读页；设置页新增入口 |
| C1f | 本文件 + 三交付件 | 验证与打包 |

**两阶段为什么必须两步**：阶段一逐块观察得到的是**并列的描述句**（「多用短句」
「段落偏短」），直接拼起来是一堆同义反复；阶段二把它们压成**指令式规则**
（「以短句为主，单句成段，叙述密度高」），并有机会丢掉互相矛盾的观察。
阶段二失败时**降级**用阶段一的合并结果 —— 可读性差些，但用户拿到的是能用的东西。

### 3. 规则注入点（C1c）

`MultiAgentBookConfig` 新增 `styleRuleSetId`。注入形态**分两档**：

| 工艺 | 节点 | 形态 |
| --- | --- | --- |
| 续写优选（默认） | `Book/beamCandidate` | **精简版** ≤700 字（禁忌词 / 句长 / 对白配比 / 视角） |
| 单笔直书 | `Book/soloChapter` | 完整版 ≤1600 字 |
| 主笔分段串行 | `Book/serialSegment` | 完整版 |
| 组长 + 9 写手 | `Book/plan` + `Book/writer` | 完整版 |
| 全部工艺 | `Book/chapterOutline` | 完整版（大纲阶段就按同一套节奏/结构） |

> ⚠ **`beam` 是默认工艺，而它的正文由 `Book/beamCandidate` 产出**（不是
> `Book/serialSegment`）。一开始只注入了 serialSegment / soloChapter 等，等于默认工艺下文风
> 规则**完全没生效**。补 `beamCandidate` 时才发现它不能吃完整版：
> 那段提示词的注释明确写着「刻意极简 —— 提示词越像一段被截断的小说，产出越像小说」。
> 所以给它单开了一条 **brief** 路径，并把「禁忌表达」提到维度列表第一位
> （原本它排最后，一截断就没了）。

规则块为空时注入**空串**而不是空标题。理由：注入一个「【文风要求】」却没有内容，
模型会把空标题当成约束去猜 —— 比不注入更糟。

### 4. 三个坑（值得记）

- **`_dedupeJoin` 的注释与实现不一致**。注释写「只留信息量大的那条」，实现却是
  `k.contains(v) || v.contains(k)` 一起 `continue` —— **先到的短句会把后到的长句挤掉**。
  观察是按块顺序来的，早的块不一定更完整，结果越靠后的信息越容易丢。
  修法：新值是已有超集时**替换**，并新增自检 D8/D9 锁死两个方向。
  ⚠ **这条是靠代码审查发现的，不是靠测试失败** —— 「测试全绿」不等于「实现与注释一致」。
- **中文维度名不能用「连续汉字段」的思路处理**（同 B4 的教训）→ 采样/合并全部按
  段落与行处理，不做词法切分。
- **纯函数必须放 `lib/ai/utils/`**。C1b 的模型与渲染一开始想放服务里，
  但服务依赖导出的 `database.dart` 会把 Flutter framework 拖进来，`dart` 直跑自检
  直接编译失败（满屏 `Offset isn't defined for the type 'VelocityTracker'`）。
  与 `profile_synthesis_text.dart` / `output_sanitizer.dart` 同一约定。

### 5. 文件编码的取舍（刻意保守）

网文 txt 相当比例是 GBK。Dart 标准库只自带 UTF-8 / UTF-16，而沙箱环境无法
`pub get` 拉新依赖（本地 pub 缓存里也没有任何 GBK 包）。

实测用户 4 本长篇样本（`众仙俯首.txt` 10.6 MB、`我的妻子是大乘期大佬.txt` 18.7 MB、
`读校版《开局合欢宗…》305万字.txt` 9.4 MB、`活儿该/《从 姑 获 鸟 开 始》.txt` 6.3 MB）
**全部是 UTF-8**，于是决定：**不引入 GBK 解码表**，只做
BOM 嗅探 + 严格 UTF-8，失败时**明确报错要求另存为 UTF-8**。

关键在于**不用 `allowMalformed: true` 兜底**：那会把 GBK 字节解成一串 U+FFFD，
模型看到的是乱码样本，却会吐出「貌似正常」的规则 —— **静默错误比报错难查得多**。

### 6. 交付件（`F:\30_Novelcraft_Flutter\`）

| 文件 | 字节数 | SHA256 |
| --- | ---: | --- |
| novelcraft_1.0.0+39_windows_release.zip | 见 `发布清单-v1.0.0+39.md` | 见清单 |
| novelcraft_1.0.0+39_release.apk | 见 `发布清单-v1.0.0+39.md` | 见清单 |
| novelcraft_1.0.0+39_source.zip | 见 `发布清单-v1.0.0+39.md` | 见清单 |

> ⚠ 三个交付件的字节数与 SHA256 **以发布根目录的 `发布清单-v1.0.0+39.md` 为准**：
> HANDOFF.md 本身就在源码包里，在包里写死「包含它自己的这个包的哈希」必然自相矛盾
> （改一次 HANDOFF → 哈希变 → 再改 → 再变）。+38 时 Windows / APK 两个包的哈希
> 不在包内所以可以照写，本版统一改为指向清单，少一处需要二次同步的地方。

### 7. 本轮验证

- `lib/` **229 文件** + `test/` **46 文件** `error: 0 warning: 0`。
- 新增 `tools/style_digest_selftest.dart` → **27 pass / 0 fail**；
  新增 `tools/style_rule_selftest.dart` → **40 pass / 0 fail**；
  回归 `entity_profile_selftest.dart` 24 / 0、`sanitizer_selftest.dart` 28 / 0。
- 提示词节点变量契约：脚本扫描全部 **39 个节点**，`{{变量}}` 与 `variables` 键集合
  **0 处不一致**。
- i18n：zh / en 各 **4583 条**、严格对称无重复；缺失 key 扫描 **1115 调用点 / 0 缺失**。
- Windows `flutter build windows --release` → **EXIT=0 / 73.9s**；
  Android `flutter build apk --release`（经 `subst S:`）→ **EXIT=0 / 111.9s / 70.7 MB**。
- `aapt2 dump badging` → `versionCode='39'`；Windows `data/app.so` 含 `1.0.0+39`、
  旧串 `1.0.0+38` 已消失；APK 验签 `Verifies`（v2），证书
  `4fc478771c4fc823cbe24b6bd4bd93052660d5a48a3d1382a8c40189b466289d`（与 +34~+38 一致）。

### 8. 仍未做 / 需注意

- 未做：B3 抽取审核面板、C2–C6、D3 端到端复测。
- **拆书链路只做了类型检查与离线自检，尚未真机跑过一次完整拆书**。
  需要实测的三点：① 6 块样本 + 汇总的 7 次调用的实际耗时；
  ② 规则注入后正文是否真的更像样本（还是模型直接忽视）；
  ③ 中文 txt 里偶尔出现的坏字节（实测三本长篇均为合法 UTF-8，但边界情况未穷举）。
- GBK 编码 txt 不支持（见上文「文件编码的取舍」）。
- 已落库的脏章节（章名碎片、正文污染）**仍未清洗** —— 只保证「之后写出来的干净」。
  批量清洗需直读 `C:\Users\Administrator\Documents\novelcraft.sqlite` 原地重写，
  **破坏性操作，须先确认**（可先只读扫描出清单）。
- 英文界面「项目概览」统计卡标签折行被轻微裁切（纯外观，未修）。
- ⚠ `flutter test` 在本机沙箱不可用（Dart VM 无法 spawn 子进程）。C1 的纯逻辑
  已由两个离线自检覆盖；需要数据库 + 模型打桩的链路**只做了类型检查，未实际运行**。

---

## 上一版交接：1.0.0+38（2026-10-09）

承接 1.0.0+37 的 A 阶段 + B1/B2/B5。用户在「下一步方向」中选了
**「先继续开发 B4 档案归纳」**，归纳粒度选**「每卷结束自动 + 手动触发」**，
本轮即按此实现并出包。

### 1. B4 解决什么问题

设定抽取（`ModuleStateService`）每章把变更**追加**成一行
`[<chapterId>:<版本> <章节标题>] <变化内容>` 写进实体的 `history` 列。
这让变更可追溯，但代价是：写到第 30 章时点开「人物管理」，看到的是 30 行
变更日志，而不是「这个角色是谁」—— **档案消失了**。

B4 把「按章的流水」收敛为「按卷的档案」，与抽取形成互补：
抽取负责「这一章发生了什么变化」（增量、证据链），归纳负责
「到这一卷为止，这个角色/势力/设定是什么样」（收敛、可读）。

### 2. 实现

| 文件 | 作用 |
| --- | --- |
| `lib/application/services/entity_profile_synthesizer.dart`（新增） | 归纳服务：按卷扫描有流水的实体 → 调主 Agent → 写结构化档案 |
| `lib/ai/utils/profile_synthesis_text.dart`（新增） | 纯文本规则：流水筛选 / 关键事件合并 / 防幻觉判据 / JSON 平衡扫描 / 字段规格 |
| `lib/ui/pages/volume_profile_dialog.dart`（新增） | 归纳进度弹窗 + 卷宗列表行按钮 |
| `tools/entity_profile_selftest.dart`（新增） | **24 用例**离线自检（可 `dart` 直跑） |

归纳目标字段（**都是 SQL 列名**，见下文「坑 1」）：

- 人物：`personality` / `background` / `appearance` / `abilities`，外加
  `key_events` 按卷累积成 `【第N卷】事件A；事件B`；
- 势力：`description` / `resources` / `special_abilities` / `headquarters` / `territory`；
- 世界观：`description` / `content` / `rules` / `related_settings`。

**触发方式**：

- **自动** —— `MultiAgentBookGenerationService` 在**章节并发池结束之后**按卷各跑一次。
  必须放在池子之后：章节是并行写的，池子没结束就无从判断「哪一卷写完了」。
  该卷正文全空则跳过；归纳失败只记 warning，**不影响**已写好的正文与已落库的设定。
- **手动** —— 卷宗管理列表每行「归纳本卷档案」，用于补跑
  （首次失败 / 模型不可用 / 事后又改了章节内容）。

### 3. 五条安全边界（改之前先读）

1. 稳定属性**默认只在字段为空时写入**，绝不覆盖作者手写或前卷已有内容。
   归纳是「模型意见」，不该抹掉人工成果。（要覆盖式重写时传 `overwriteExisting: true`。）
2. `history` 列**一字不动** —— 它是可追溯的证据链，也是下次归纳的输入。
   把归纳结果写回去会让下一卷「归纳的归纳」，信息两三卷内衰减成空话。
3. `status` 列**不动** —— 由设定抽取按**章**维护，粒度比卷更细，用卷级归纳覆盖是降级。
4. 文本一律过长度上限（200 字）+ `FictionQuality` 闸 + **n-gram 重叠**依据判据（防编造）。
5. 归纳**幂等**：属性只填空、关键事件同卷段替换，重复触发不会让字段无限膨胀。

### 4. 踩到的三个坑（值得记）

- **`specialAbilities` 会静默取不到值**。drift 的 `QueryRow.data` 键与
  `GeneratedColumn.$name` 用的都是 **SQL 列名（snake_case）** —— drift 源码里
  该字段的注释就是 "The sql name of this column"。字段规格若写成 Dart 属性名
  （`specialAbilities` / `relatedSettings` / `keyEvents`），读会得到 null、
  写回会报列不存在。已由自检 E1 锁死。
- **中文不能用「连续汉字段」当词组**。`isGrounded` 最初用
  `[\u4e00-\u9fa5A-Za-z]{2,}` 抓 token —— 中文整句话就是一个连续汉字段，
  于是每次都拿**整句**去 `contains`，**永远不命中**，结果所有字段都被判为幻觉、
  档案一个字都填不上。已改为 4→2 字 n-gram 重叠。自检 C1/C5 就是这个回归。
- **纯函数不能留在服务类里**。`entity_profile_synthesizer.dart` 依赖 drift →
  `database.dart` 会把 Flutter framework 拉进来，`dart` 直跑脚本直接编译失败
  （报 `Offset isn't defined` 之类满屏 flutter 内部错误）。把这些规则抽到
  `lib/ai/utils/profile_synthesis_text.dart` 后
  `dart --disable-dart-dev tools/entity_profile_selftest.dart` 离线跑通，
  也与 `output_sanitizer.dart` / `chapter_title.dart` 的既有约定一致。

### 5. 顺带改动

- `ModuleContract` 契约表抽为静态 `ModuleStateService.contractsOf(db)` 供归纳复用 ——
  归纳扫描的表/列必须与抽取落库目标完全一致，否则会出现「抽取写进 A 列、
  归纳却去 B 列找流水」的**静默错位**。
- 归纳的 `maxEntities` 默认 **15**（候选按本卷流水条数降序）：归纳挂在整书收尾，
  40 个实体 × 3 卷 = 120 次模型调用会把主流程拖长十分钟以上；按流水量排序后
  前 15 个必然是主角与核心势力。

### 6. 交付件（`F:\30_Novelcraft_Flutter\`）

| 文件 | 字节数 | SHA256 |
| --- | ---: | --- |
| novelcraft_1.0.0+38_windows_release.zip | 15432927 | `B140F96F4B2DA52A541DF687C845026E71F9C10D8A9FAC364A2EEA6095E3A35C` |
| novelcraft_1.0.0+38_release.apk | 73702825 | `65CB12F1FAC31FDD0F27DDED30682F55ACDEE4553AF034D4216D4667DC1DBCCC` |
| novelcraft_1.0.0+38_source.zip | 4082487 | 见 `发布清单-v1.0.0+38.md` |

> ⚠ 源码 ZIP 的 SHA256 **以发布根目录的 `发布清单-v1.0.0+38.md` 为准**：
> HANDOFF.md 本身就在源码包里，在包里写死「包含它自己的这个包的哈希」必然自相矛盾
> （改一次 HANDOFF → 哈希变 → 再改 → 再变）。Windows / APK 两个包的哈希不在包内，可照写。

### 7. 本轮验证

- `lib/` **223 文件** + `test/` **46 文件** `error: 0 warning: 0`
  （`dart --disable-dart-dev tools/analyze_inprocess.dart`）。
- 新增 `tools/entity_profile_selftest.dart` → **24 pass / 0 fail**。
- i18n 缺失扫描 → **1070 调用点 / 0 缺失**。
- Windows `flutter build windows --release` → **EXIT=0 / 65.6s**。
- Android `flutter build apk --release`（经 `subst S:`）→ **EXIT=0 / 87.4s**，70.3 MB。
- `aapt2 dump badging` → `versionCode='38'`；Windows `data/app.so` 含 `1.0.0+38`、旧串已消失。
- APK 验签 `Verifies`（v2），证书 `4fc478771c4fc823cbe24b6bd4bd93052660d5a48a3d1382a8c40189b466289d`
  （与 +34 ~ +37 一致）。
- 源码包 **510 条目**（+37 为 506），含 4 个新增源码/工具文件与 `备份说明-v1.0.0+38.md`；
  包内 `pubspec.yaml` / `version.txt` 均为 `1.0.0+38`；零密钥零缓存。

### 8. 仍未做 / 需注意

- 未做：B3 抽取审核面板、C 阶段（C1 `StyleDigestService` Agent 拆书 → 写作模板、C2–C6）、
  D3 端到端复测。
- 已落库的脏章节（章名碎片、正文污染）**仍未清洗** —— 只保证「之后写出来的干净」。
  批量清洗需直读 `C:\Users\Administrator\Documents\novelcraft.sqlite` 原地重写，
  **破坏性操作，须先确认**（可先只读扫描出清单）。
- 英文界面「项目概览」统计卡标签折行被轻微裁切（纯外观，未修）。
- ⚠ `flutter test` 在本机沙箱不可用（Dart VM 无法 spawn 子进程）。B4 的纯逻辑
  已由离线自检覆盖；需要数据库 + 模型打桩的链路**只做了类型检查，未实际运行**。

---

## 上一版交接：1.0.0+37（2026-10-09）

用户真机实测 1.0.0+36 后报了 5 个问题。先出了一份定位+计划文档
（`F:\30_Novelcraft_Flutter\完善计划-v1.0.0+36-实测问题定位.md`，三层取证：
导出产物 + `novelcraft.sqlite` + 源码互相印证），用户确认「按你认可的最佳顺序进行」后，
本轮完成 **阶段 A（止血）全部 + 阶段 B 的 B1/B2/B5**，并重建三个交付件。

### 1. 阶段 A —— 五个问题的止血（A1–A7）

| 编号 | 问题 | 修法 |
| --- | --- | --- |
| A1 | 正文混入 `【上文结尾】` 与被回灌的上文复述、段落重复 | 提示词去掉可被回抄的标记 →「前文末尾（仅供衔接，**不要输出这一段**）」；新增跨段重叠修剪 `_mergeSegment`（残句重起 / 前缀重叠两种形态）；清洗器新增该标记的整行与行内剥离规则 |
| A2 | 全书 30 章标题全是大纲碎片、梗概是大纲原文截断 | 新增纯函数 `lib/ai/utils/chapter_title.dart`（`ChapterTitleParser.extractName/extractBrief`，含未闭合引号、元信息标签、跨行粘连、中文序号等判据）；不可靠时由 7.2B 走 `Book/chapterNames` 批量命名兜底 |
| A3 | 单段落解析失败导致**整章**零抽取（且静默） | 抽取链路不再整章放弃：`validate` 的 source 放宽为全章、重试 2→3 次、`okChunks==0` 时走**行式兜底抽取**（`类别\|名称\|字段\|一句话`，名称必须在正文原样出现）、同实体同字段合并后再落库 |
| A4 | 草稿章（生成坏掉被降级）完全不抽取 | 前置条件从「`status == 'Completed'`」放宽为「正文非空且过质量闸」 |
| A5 | 导出目录泄漏示例项目的人物事件（林月/妖皇） | `character_events` **表无 `project_id` 列**（C# 原实现疏漏，刻意 1:1 复刻）→ 不改表结构，改用 `customSelect` + `INNER JOIN characters` 隔离 |
| A6 | 时间线 location 章号 off-by-one | `marker` 由 `第${orderIndex+1}章` 改为 `第${orderIndex}章` |
| A7 | 全书字数统计显示「0 字」 | 归档前 `chapters.getByProjectId()` 重读数据库聚合 |

### 2. 阶段 B —— 单章重写能力（B1/B2/B5）

- **B1** 新增 `lib/application/services/chapter_rewrite_service.dart`：按上下文
  （**前章结尾 400 字 + 本章大纲/梗概 + 下章开头 400 字 + 项目设定摘要**）整章重写。
  清洗与质量闸**直接复用** `MultiAgentBookGenerationService.cleanFinalChapter` /
  `chapterQualityNote`（本轮把二者开了公开入口）—— 单章重写与整书生成对「什么算合格正文」
  只能有一套口径，否则又是一处修好另一处照旧。质量闸不过**不覆盖原稿**并如实回报原因。
- **B2** 三处入口，共用 `lib/ui/pages/chapter_rewrite_dialog.dart`（不可点掉的进度窗 + 结果 SnackBar）：
  ① 写作动态矩阵：失败格「重写」小徽章 + 底部「重写全部草稿章」（批量串行）；
  ② 章节列表：`Draft` 行尾「重写」；③ 章节编辑页表单顶部「按上下文整章重写」。
  为支持①②，`EntityPageConfig` 新增 `rowActionBuilder` / `formActionBuilder` 两个可选钩子。
- **B5** `ChapterAiStateService` 标注「未被装配的遗留实现」+ `@Deprecated`，并在文件头列出与
  在用实现（`ModuleStateService`）的**行为级差异**。不删除：其配套的
  `ai/utils/state_extraction_parser.dart` 与 `tool/verify_state_extraction_parser.dart` 仍在维护。

### 3. 交付件（`F:\30_Novelcraft_Flutter\`）

| 文件 | 字节数 | SHA256 |
| --- | ---: | --- |
| novelcraft_1.0.0+37_windows_release.zip | 15408116 | `7E05C7ED49898764385F04527B0617B3708F6B2A68FBE619D9506F2DC74C9EC2` |
| novelcraft_1.0.0+37_release.apk | 73588137 | `1722DC7A8282B43E46E212513CD5AE4B30C7C7CC22A2EE5CE3BA06E0867C4ADB` |
| novelcraft_1.0.0+37_source.zip | 4060553 | 见 `发布清单-v1.0.0+37.md` |

> ⚠ 源码 ZIP 的 SHA256 **以发布根目录的 `发布清单-v1.0.0+37.md` 为准**：
> HANDOFF.md 本身就在源码包里，在包里写死「包含它自己的这个包的哈希」必然自相矛盾
> （改一次 HANDOFF → 哈希变 → 再改 → 再变）。Windows / APK 两个包的哈希不在包内，可照写。

### 4. 本轮验证

- `lib/` **220 文件** + `test/` **45 文件** `error: 0 warning: 0`
  （`dart --disable-dart-dev tools/analyze_inprocess.dart`）。
- `tools/sanitizer_selftest.dart` → **28 pass / 0 fail**（新增 B14–B16 三条续写标记用例）。
- 新增 `tools/chapter_title_selftest.dart` → **17 pass / 0 fail**（样本取自实测碎片）。
- i18n 缺失扫描 → **1066 调用点 / 0 缺失**。
- Windows `flutter build windows --release` → **EXIT=0 / 69.1s**；Android
  `flutter build apk --release`（经 `subst S:`）→ **EXIT=0 / 192.1s**，70.2 MB。
- `aapt2 dump badging` → `versionCode='37'`；Windows `data/app.so` 含 `1.0.0+37`、旧串已消失。
- APK 验签 `Verifies`（v2），证书 `4fc478771c4fc823cbe24b6bd4bd93052660d5a48a3d1382a8c40189b466289d`。
- 源码包 **506 条目**（+36 为 497），含 5 个新增源码/测试/工具文件与 `备份说明-v1.0.0+37.md`；
  包内 `pubspec.yaml` / `version.txt` 均为 `1.0.0+37`；零密钥零缓存。

### 5. 仍未做 / 需注意

- ⚠ **`flutter test` 在本机沙箱不可用**（Dart VM 无法 spawn 子进程）。本轮新增/修改的
  `test/module_state_service_test.dart`、`test/chapter_rewrite_service_test.dart`、
  `test/writing_quality_gate_test.dart` **只做了类型检查，未实际运行** ——
  请在能跑的环境执行确认。
- 未做：B3 抽取审核面板、B4 `EntityProfileSynthesizer` 档案归纳、
  C1 `StyleDigestService`（Agent 拆书 → 写作模板）、C2–C6、D3 端到端复测。
- 已落库的脏章节（章名碎片、正文污染）**仍未清洗** —— 只保证「之后写出来的干净」。
  批量清洗需直读 `C:\Users\Administrator\Documents\novelcraft.sqlite` 原地重写，
  **破坏性操作，须先确认**（可先只读扫描出清单）。
- 英文界面「项目概览」统计卡标签折行被轻微裁切（纯外观，未修）。

---

## 上一版交接：1.0.0+36（2026-10-07）

在 1.0.0+35 那轮（三个 BUG 修复 + 编排改造）通过全量验证后，按用户要求**升级版本号并重新出包**。
代码改动与 1.0.0+35 那轮一致（见下一节），本版额外做的是版本号收口与交付件重建。

### 1. 版本号提升到 1.0.0+36

- `pubspec.yaml`、工程根 `version.txt`、`tools/sync_release_snapshot.py` 的
  `DEFAULT_VERSION`、`tools/package_release.py` 的 `--version` 默认值 → 全部 `1.0.0+36`。
  `pubspec.yaml` 里已加注释，列出升版本时必须同步的三处。
- 新增 `lib/core/app_version.dart`（`kAppVersion` / `kAppVersionLabel`），
  修掉底部状态栏**硬编码 `v1.0.0+23`** 的历史问题（`app_shell.dart` 改引用常量）。
  用常量而非 `package_info_plus`：本工程还要跑 Web，为一行版本号引入插件不划算。
- 新增 `docs/功能使用说明-v1.0.0+36.md`、`docs/项目交接-v1.0.0+36.md`；
  README / README.en.md 的徽章、正文版本号、文档链接、验证记录表全部更新。

### 2. 交付件（`F:\30_Novelcraft_Flutter\`）

| 文件 | 字节数 | SHA256 |
| --- | ---: | --- |
| novelcraft_1.0.0+36_windows_release.zip | 15374348 | `DE6B24D577029A490D53444286443C448627ECEFDA883A6E2D7289C2D09D432D` |
| novelcraft_1.0.0+36_release.apk | 73244073 | `B3795E2975337C9CC7E1049A13EFD1C761447877294E26405BEBA9C49A3C098A` |
| novelcraft_1.0.0+36_source.zip | 4002044 | `AFD86B306DEF0569A45A371C5970B5350478FEEBBBDF43B8DA3CDB07472FCC25` |

1.0.0+35 的三个交付件保留未删除。

### 3. 本轮验证

- Windows `flutter build windows --release` → **EXIT=0 / 60.1s**。
  ⚠ `novelcraft.exe` 本轮**确实重新链接**了（时间戳 23:28:47）——
  版本资源变化会触发重链接，这与「只改 Dart 代码时 exe 不重链接」的旧经验不同；
  判断是否真的重构建，仍以 `data/app.so` 时间戳为准。
- Android `flutter build apk --release`（经 `subst S:` ）→ **EXIT=0 / 82.8s**，69.9 MiB。
- **版本号落地验证**（不只看构建日志）：
  - `aapt2 dump badging` → `versionCode='36'`（旧件 `'35'`），`versionName='1.0.0'`。
  - APK 三个 ABI 的 `libapp.so` 与 Windows `data/app.so` 中均检索到 `1.0.0+36`，
    旧串 `1.0.0+35` 与 `v1.0.0+23` 均已消失。
- APK 验签：`Verifies`、v2 方案、证书 `4fc478771c4fc823cbe24b6bd4bd93052660d5a48a3d1382a8c40189b466289d`。
- 源码包 **497 条目**（+35 为 494），含 `lib/core/app_version.dart` 与两份 +36 文档；
  包内 `pubspec.yaml` / `version.txt` 均为 `1.0.0+36`；零密钥零缓存。

### 4. 经验

- **版本号是四处独立记录**：`pubspec.yaml`、`version.txt`、`lib/core/app_version.dart`、
  两个 tools 脚本的默认版本。少改一处就会出现「包名是 36、状态栏还是 23」这类错位。
- 升版本后**必须重新构建两个产物**（版本号写进可执行文件，不是运行时读的配置）。

---

## 上一版交接：1.0.0+35 迭代（2026-10-07，第二轮）

本轮承接用户真机（**手机端**）实测反馈，做三件事：**打补丁 → 架构编排改造 → 本地全量验证**。

### 1. BUG 1 补丁：串行写书输出提纯（正则清洗器）

用户截图暴露的泄漏**全部在正文之前**，三种真实形态（原文抄录见
`lib/ai/utils/output_sanitizer.dart` 顶部注释与 `tools/sanitizer_selftest.dart` B1/B2/B3）：

1. 自我介绍 + 处理说明前缀，**与正文同段**：
   `你好，我是NovelCraft的主编智能体。我将严格保留原文……---润色后版本：“你们到底是谁？”她问道……`
2. 修订稿抬头 + 星号字段，**正文紧跟同一行**：
   `【主编修订稿】---第一章北极圈基地（正式）*目标：……*1991年，莫斯科……`
3. 整行章节元信息区块（4~5 个字段挤一行，字段后还有元信息散文）→ **必须整行丢弃**。

实现：`AIOutputSanitizer.stripMetaPreambles()`（与管尾部的 `stripStateUpdateBlocks`
分工，**前者可并进 `extractCleanOutput`，后者绝不能**）。接入点两处：
`extractCleanOutput` 与 `MultiAgentBookGenerationService._cleanFinalChapter`。

**本轮新增长度安全阀** `_kMaxMetaLineChars = 800`：旧判据「一行塞 ≥2 个元信息小标题
就整行丢」会被**单行长文**满足 —— 章节正文里恰好出现两个 `【人物】`/`【本章】`
之类小标题时整章被吞。800 字覆盖真实抬头（实测 200~600），又远小于任何一章正文。

### 2. BUG 2 补口：客户端 state 台账

- **G1K 双模型模式下章节写作链路根本没用上客户端 state** —— 章节正文走的是
  `temporaryWriter`（2.9B 端点），而它是**裸构造**（`sessionLedger = null`、
  `clientStateEnabled = false`）。现在继承 DI 里 `cloud` 的台账与开关。
- **`newSessionId()` 会撞 ID** —— 旧实现只用 `microsecond * 7919 % 1000003`，
  Windows 上紧密循环 200 次**只得到 6 个不同值**；撞 ID 后服务端会把两条独立
  state 链当成同一条，正是用户报的「服务器不知道哪个 state 对应哪个并发」。
  现在 = `nc-<毫秒>-<进程内单调序号 base36>-<随机 4 位>`。
- 台账键加**端点身份前缀**（`<baseUrl host>::<sessionKey>`）。
- 新增 `test/rwkv_cloud_state_test.dart`（23 例，此前该模块**零覆盖**）。

### 3. 架构编排改造（用户定的拓扑，已落代码）

| 层次 | 编排 | 实现 |
|---|---|---|
| 主线大纲 | **串行** | 规划组 `leader` 单链，一次调用产出全书骨架 |
| 支线大纲（分卷/章节） | **并行** | 9 条规划写手链；`_runPoolIndexed` 让**每个并发道固定绑一条通道** |
| 单章内容 | **串行** | 每章各自一条 state 链，段与段严格串行 |
| 全书章节 | **并行** | `lanes = cfg.concurrency`，章间零依赖，同时开工 |

关键决策（**与上一轮会话粒度不同，已改**）：

- 章节会话前缀从「项目级」改为 **`<projectId>::chapter::<章 id>`**。
  原因：`duo`（默认工艺）只有 `leader` 一个角色，项目级共享链会让台账把所有章节
  排成一条队 ——「N 章并行」直接退化成**整书严格串行**，`concurrency` 彻底失效。
  改成章级后跨章一致性改由**提示词 + 章节验收通过后的设定回写**承担（不靠 state）。
- **支线大纲不能按「任务序号 % 通道数」轮转**：章节大纲的序号是**卷内序号**
  （每卷从 1 重新数），池宽 9 时第 10 个任务会退回通道 0，与在飞的第 1 个任务
  **撞同一条会话**。现在改为 lane → 通道一一绑定。
- **beam 的 N 份候选一律走无状态链路**（`_AgentChannel.send(isolated: true)`）：
  候选是 `Future.wait` 并发的，共用 lead 的 state 会①候选互相污染
  ②被台账 `runExclusive` 排成串行白给并发。候选数 == 1（G1K 双模型快写）
  时是严格串行，**保留** state。
- `team` 工艺是唯一的「章内并行」（9 写手各独享链），保留兼容但已非默认。

### 4. 本轮验证（全绿）

- `dart --disable-dart-dev tools/analyze_inprocess.dart lib test tools`
  → **263 文件 / 0 error / 0 warning**
- `dart --disable-dart-dev tools/sanitizer_selftest.dart` → **25 pass / 0 fail**
- `flutter test` → **+416 ~1: All tests passed!**
- `flutter build windows --release` → **EXIT=0 / 53.3s**
- `flutter build apk --release` → 见发布清单

### 5. 仍未做（需用户确认）

- **已落库的脏章节批量清洗**：本轮只保证「之后写出来的章节干净」，真机截图里
  那些**已写进数据库**的脏章节还在。可加 `tools/clean_polluted_chapters.dart`
  直读 `Documents/novelcraft.sqlite` 原地重写 —— **破坏性操作，必须先确认**。

### 6. 调试经验（本轮新增，值得复用）

- **PS 5.1 `*>>` 混合编码陷阱**：`& $flutter test ... *>> $log` 写的是
  **UTF-16LE**，而首行 `Out-File -Encoding utf8` 是单字节；且 native stdout 先被按
  **GBK(936)** 解码成 mojibake 再转 UTF-16LE（`[Console]::OutputEncoding` 在无控制台时
  **静默失效**）。还原配方：
  `tail -c +95 <log> | iconv -f UTF-16LE -t UTF-8 | iconv -c -f UTF-8 -t GBK`
- **测试失败原因直接在测试里写 UTF-8 诊断文件**（临时 `import 'dart:io'` +
  `writeAsStringSync`，跑完 Read，再撤掉）比折腾控制台编码快得多。
- `.ps1` **必须纯 ASCII**（无 BOM 时 PS 5.1 按 ANSI 解码，中文路径变乱码 →
  `Set-Location` 失败 → `No pubspec.yaml file found`）。

### 7. 第三轮收尾：交付件重建（2026-10-07）

用户要求「全部完善之后，在本地跑一圈测试」。收尾时发现**打包链路本身已断**，
属真实缺陷，已一并修掉：

1. **脚本目录名断链**：发布清单第 20 行记的源码快照目录是
   `Novelcraft_Flutter_source_v1.0.0+35`，但该目录**早已被改名**为
   `novelcraft_1.0.0+35_source`，而 `package_release.py` 与
   `sync_release_snapshot.py` 里都还硬编码旧名 →
   `sync` 只打印「跳过（目录不存在）」（它不创建目录！）、`package_release.py`
   在第 2 步直接 return 1 中断。
   现两个脚本统一改为 `find_clean_snapshot()` **自动探测**
   （`novelcraft_<版本>_source` → `Novelcraft_Flutter_source_v<版本>`），
   并新增 `--source-snapshot` / 保持 `--release-root` 可显式覆盖。
2. **快照不纳入新增文件**：`sync()` 原先只遍历**快照已有条目**，工程新建的文件
   永远进不了对外源码包。实测漏掉 3 个：
   `lib/ai/rwkv/rwkv_cloud_state.dart`（**BUG 2 的核心模块**）、
   `test/rwkv_cloud_state_test.dart`、`tools/sanitizer_selftest.dart`。
   现新增 `NEW_SOURCE_DIRS` 白名单（`lib/ test/ tools/ assets/ docs/ scripts/
   integration_test/`）自动补入新增手写文件；平台目录（`android/ ios/ windows/`
   等）**只更新不新增**，签名密钥 `upload-keystore.jks`、`key.properties`、
   `local.properties`、`GeneratedPluginRegistrant` 等仍严格排除（已逐条验证：
   源码包 494 条目，零密钥/零 `__pycache__`）。

**交付件（已重建，位于 `F:\30_Novelcraft_Flutter\`）**：

| 文件 | 字节数 | SHA256 |
| --- | ---: | --- |
| novelcraft_1.0.0+35_windows_release.zip | 15374326 | `D5FDE85001FFEC084090AD8C04A59193AF1FD925E58F81808B5DA7554CE18445` |
| novelcraft_1.0.0+35_source.zip | 3989385 | `D098B3CEB7E5EC388DE85C19A60F57A70744525F1C56B7CD6C216648E7DFFDAE` |
| novelcraft_1.0.0+35_release.apk | 73244073 | `07A11B0E67F0DF38044EFB2B4F2312668B7457430A4538BD0B7837878A5779FB` |

APK 为 arm64-v8a + armeabi-v7a + x86_64 三 ABI（69.9 MiB），
包名 `com.novelcraft.novelcraft`，versionName `1.0.0` / versionCode `35`。
**手机端复测直接装这个 APK。**

---

## 上一版交接：1.0.0+35（2026-10-04）

新增写作工艺节点 Prompt 配置，支持多模板、编辑保存、选择生效与重启恢复。
详细接入点、测试结果、发布流程及继承的未完成问题见 [本版交接](docs/项目交接-v1.0.0+35.md)；操作见 [功能使用说明](docs/功能使用说明-v1.0.0+35.md)。
本版静态分析通过；全量测试 392 通过 / 1 跳过 / 1 既有重复正文样例失败。旧章节的完成状态不应覆盖本版明确列出的限制。

> 生成于 2026-09-12。本文件记录 C# WPF 版 NovelCraft 向 Flutter/Dart 移植的当前进度、架构、验证方式与已知阻塞，供接手者快速上手。

---

## 1. 项目背景

- **源项目**：`F:\30_Novelcraft_Flutter\C#版源代码\`（497 个文件，315 个 .cs，NovelCraft —— AI 小说创作管理系统）。
- **目标**：把桌面端 WPF 应用整体移植为 Flutter（Windows 优先，兼顾 Web），复用同一套业务模型。
- **当前位置**：`F:\30_Novelcraft_Flutter\Flutter版代码\novelcraft\`（101 个 .dart 文件，约 82,467 行）。

## 2. 当前进度（截至 2026-09-14，TRAE-NovelCraft-Bot 第九次更新）

| 层 | 状态 | 说明 |
|---|---|---|
| 数据库 schema（drift） | ✅ 完成 | 27 张表，`build_runner` 生成 `lib/data/database.g.dart` |
| Repository 层（23 个） | ✅ 完成 | 每个实体一个文件，统一基类 |
| 服务层（Application，21+1 个） | ✅ 完成 | 强类型统计模型（替代 C# 的 `Dictionary<string,object>`）；**DatabaseSeeder 已启用（首启动 27 表玄穹剑主修仙模板事务批量插入 + KeyValueStore(internal,seed_version)=seeded-v1 幂等，flutter analyze 0 verified）** |
| AI 层（lib/ai，32 文件） | ✅ 完成 + **RWKV 推理引擎 + State 复用增强 + 官方资源一键安装（新增 10 文件） | 6 提供商 + 智能体 + 记忆 + 工作流 + 平台条件导出；**8 Agent 修仙题材 prompt 精修 + 结构化解析 + 本地 fallback；新增 RWKV 引擎（RwkvState + RwkvSession + RwkvStateCache LRU + RwkvEngine + RwkvModelScanner 三平台条件导出 + RwkvProvider 扩展 API + Agent/Workflow 跨层 State 复用；官方 llama.cpp 预编译安装 + BlinkDL HuggingFace 原生模型下载 + 进度取消+互斥锁+断点续传** |
| 领域层（枚举/异常） | ✅ 完成 | 含 C# 的「字符串伪枚举」规范化 |
| 主题 / 本地化 | ✅ 完成（本轮 L10n 全量回填） | 3 套皮肤 + 3996 条中英文词条（CSV→Dart 自动生成 + 第二轮 UI 改造补齐约 300 key）；**L10n 双层架构严格切换无 fallback 中文兜底陷阱**；ThemeSkin 新增 nameEn 字段 + displayName(isEnglish) helper；AppShell 二级导航 + 14 页面 UI 文案 100% L10n 化 + Flexible 防巨量像素溢出 |
| 导航 / 应用外壳 | ✅ 完成 | NavigationRail + 世界观二级导航 **+ AI 助手二级导航（4 子项）** |
| 入口 main.dart | ✅ 完成 | ProviderScope + **启动屏 appBootstrapProvider（KVStore init → seeding → AppShell）** + **Flutter 本地化三件套（GlobalMaterialLocalizations / CupertinoLocalizations / WidgetsLocalizations + intl 0.20.2 SDK pinning + localeListResolutionCallback）**（修复首启动三条级联异常：locale 不支持 / MaterialLocalizations missing / RenderFlex overflowed 98736px） |
| 真实功能页面 | ✅ 完成 | 项目管理、10 个 JSON 体系页、20 个数据库实体页（含 14 个新增）、4 个聚合/工具页（概览/时间线/导入导出/设置）** + 4 个 AI 功能页（AI 协作 / AI 配置 / 对话生成 / 项目健康检查）= 14 页 **；**AI 配置页 RWKV 本地面板：硬件版本下拉 + 扫描 + 启动 + 官方一键安装+下载+取消按钮（KVStore 持久化不丢）** |
| 数据库首启动 seeding | ✅ 已启用 | 标准修仙模板「玄穹剑主」27 表 Companion.insert 严格按签名 required-only 最小数据量写入（1 项目 + 1 卷 2 章 + 2 种族 1 关系 + 2 势力 1 敌对 + 2 资源 1 秘境 + 1 修炼体系 3 境界 + 1 政治体系 2 官职 + 1 货币 + 2 情节 + 3 人物 2 事件 2 关系 + 1 关系网 + 人物×情节 3 联结 + 章×情节 2 联结 + 8 世界观设定 + 2 时间线事件 2 参与者），事务+batch 回调式 API，KeyValueStore(scope=internal, key=seed_version)='seeded-v1' 幂等；首次启动未种过才会写入。**flutter analyze 0 issues 已验证**；用户首启动会自动出现「示例项目 · 玄穹剑主」和各实体示例数据。**RWKV 本地 GGUF 模型（rwkv7-g1j-7.2b-Q6_K）放在 rwkv_models/，支持 llama.cpp 兼容 HTTP API 启动（RwkvEngine.ensureLocalServer）或官方一键下载** |
| 其余页面 | ✅ 完成 | **占位页全部归零**。 |

**静态质量**：`flutter analyze --no-pub` → **No issues found!**（141→0 基线 + 26→0 第二轮 + P1/P2 第三轮 + Seeder 启用第四轮 + **L10n 第五轮 58→0（含 strings.g.dart 双份 key 去重、tf() 签名扩展 List+Map 双模式、ThemeSkin nameEn 字段必填化、_projectTypeLabel 提升为顶层函数、SnackBar backgroundColor 错位修复、7 处 unused 警告清理）**，共五轮全量 0 基线）

**真机首启动零级联异常基线**：`F:\30_Novelcraft_Flutter\novelcraft_en` (junction 纯英文路径) 下 `flutter run -d windows` → √ Built novelcraft.exe → Syncing 112ms → Dart VM Service 监听 http://127.0.0.1:49291，**首启动无 Warning / 无 MaterialLocalizations missing / 无 98736px overflow / 无 Lost connection**。

**RWKV 本地启动链路 Bug 清零（P1 阶段三链路大修复）**：
- 「RWKV 模型下载 HTTP 404」→ 修复：GGUF 真实源仓切换至社区 `shoumenchougou/RWKV7-G1j-7.2B-GGUF`（5 量化版本 FP16/Q4_K_M/Q5_K_M/Q6_K/Q8_0，HF API 实时验证可下载），BlinkDL 官方私仓 `RWKV-7-G1J/RWKV-v7` 返回 401、`rwkv-7-world` 0 GGUF 文件，仅作第二 fallback。
- 「llama.cpp Server 一键安装失败」→ 修复：`ggml-org/llama.cpp` `/releases/latest`（tag=0.4.0）仅附源码 2 资产，无 Windows 二进制；二进制资产移至 nightly tag（当前 b10941，27 资产/13 Windows zip）；资产命名模式 `llama-<tag>-bin-win-<backend[-小版本]>-<arch>.zip`（cuda-12→cuda-12.4、cuda-13→cuda-13.x、hip→rocm、cudart-前缀纯 DLL 包跳过）；`fetchLatestServerBuild` 改为 latest + releases?per_page=10 双候选 + 四段匹配；匹配失败在错误信息中枚举最近 2 release 的 Windows zip 名供用户调试。
- 「下载的驱动无法运行下载的模型 / SocketException errno=1225 拒绝连接」→ 修复：llama.cpp nightly Windows 版**`--mlock` 参数已废除**（传参直接 exitCode=1、stderr=`error: invalid argument: --mlock`，进程秒退无提示，用户仅见「拒绝连接」泛化错误）；三步根治：① `ensureLocalServer args` 删除 `--mlock`；② 新增 45s `/health` + `/v1/models` 双路由探活循环（600ms/轮），`_launcherStarted` 仅探活成功后 true，失败则超时 kill 进程；③ 建立 stderr→engine→provider→UI 诊断链：`InferenceProcessLauncher` 新增 200 行 stdout/stderr 环形缓冲 + `lastExitCode` + broadcast Stream；`RwkvEngine` 四处失败点把 `launcher.recentStderr / exit / stdout` 全量拼接写入 `_lastLaunchDiagnostics`；`ai_configuration_page` 启动失败时优先展示该真实诊断（如 cudart DLL 缺失/CUDA 版本不匹配/显存 OOM），不再泛化「检查路径」；真机命令行验证：llama-b10941-cuda13 + rwkv7-g1j-7.2b Q6_K → `/health HTTP 200 {"status":"ok"}` 3.6s 就绪，进程稳定存活。

**RWKV 新生态调研（对班落地目标）**：
- 新增参考仓 `Alic-Li/rwkv_lightning_cuda`（v1.5.0，发布于 2026-09-13，CI 持续更新）：纯 C++/CUDA 原生 RWKV-7 推理服务，支持 PTH 模型 + W8A16/W4A16 量化 `.rwkvq`、L1/L2/SQLite 三级 State Cache、X-RWKV-Session-Id / X-RWKV-State-Id 请求头、Go Router 多后端负载均衡 + 会话亲和、Go Launcher Web UI；核心并行 API 四件套：① `POST /v1/chat/completions`（原生 batch `contents: string[]`，N 条 prompt 一次并行返回，SSE 中 `choices[].index` 交错输出）；② `POST /big_batch/completions`（超大 batch 仅 temperature 采样，专啃角色/世界观批量生成）；③ `POST /v2/chat/completions`（V2 sampler top_k=500/top_p=0.5）；④ `POST /state/chat/completions` + `/multi_state/chat/completions`（可分叉多分支 dialogue_idx Stateful 推理，用于 NovelCraft 世界观分支剧情的「多条故事线并行推演」）；OpenAI 兼容路由 `/openai/v1/chat/completions` 供已有客户端无缝接入；启动参数需额外 `--vocab-path`（RWKV v20230424 词表 txt，和模型分文件存放）。
- 新增线上 RWKV API 测试环境：`https://api-7b.rwkvos.com`，三张 4090 部署 rwkv_lightning_cuda 集群；Cloudflare Access 双向 mTLS 认证：请求头必传 `CF-Access-Client-Id` + `CF-Access-Client-Secret`（凭据已脱敏，运行时经 `--dart-define` / 环境变量传入，勿硬编码进仓库）；`GET /v1/models` 已真机验证返回 `rwkv7-g1j-7.2b-20260831-ctx16384`（owned_by=rwkv_lighting_cuda，注意拼写 t/cuofa，代码里别写死 owned_by 匹配）；支持同步并发多发（4090×3 可同时承载 12-24 并行 batch 请求，当前 `RwkvProvider` 全局 `Semaphore(4)` + `TaskQueue(5)` 限流过于保守，需按 Provider 模式动态解锁上限）。

**LOGO 全平台分发**：源文件 `F:\30_Novelcraft_Flutter\novelcraft_en\icon.ico` → 覆盖写入 Windows / Web / Android / iOS / macOS 全部尺寸位图表 + favicon.ico（详见 §7 Logo 分发清单）。

**编译质量**：
- 代码级 dart2js 全量通过（Compiling lib/main.dart for the Web 均完成）
- 中文路径 build：Flutter 3.38.5 impellerc.exe ANSI fopen 打开 UTF-8 中文路径报 `Could not write file .../ink_sparkle.frag`（PITFALLS §24.3）— **非代码缺陷**
- 纯英文 junction 路径 build：`F:\30_Novelcraft_Flutter\novelcraft_en` → 目标项目，`flutter build web --no-pub --release --no-wasm-dry-run` **exit 0**，ink_sparkle.frag / main.dart.js / canvaskit skwasm ×5 变体 全部产物齐全

### 2026-09-17 第十轮：边聊「关联章节」改稿闭环 + 会话持久化 + 分段改写 + 真机验收

**交付**（四块，均 `flutter analyze` 0 issue）：

| 能力 | 实现 | 验证 |
|---|---|---|
| 关联章节改稿（边聊页选定 书→卷→章 → 提意见 → Agent 改写 → 回写 `Chapter.Content`，同步 wordCount/version/lastEditedAt，**不动 status**） | `lib/ai/utils/chapter_intent.dart`（提问/处理/解除三态判定）+ `lib/application/services/chapter_revision_service.dart` + `lib/ui/pages/ai_collaboration_page.dart` 关联面板 + `lib/ui/state/chapter_referral.dart` | 打桩 23/23 + **真模型 3/3** |
| 长文分段滚动改写（C# `RewriteChapterCoreAsync` 工艺：1800 字切片 → 逐片携带上一片结尾 → 复读换更强提示词重试 → 拼接 → **原子落库**；另加**段数闸门**：超 12 段 ≈ 2.16 万字，在**任何模型调用之前**拒绝） | `lib/ai/utils/segment_rewrite.dart`（纯函数，含 `SegmentRewrite.plan` / `SegmentPlan`）+ `ChapterRevisionService._rewriteSegmented` | `verify_segment_rewrite` 59/0 + 打桩用例 7 条 |
| 会话状态落 KVStore（跨页面 + **跨 App 重启**） | `copilot/chapter_referral`（关联 + 处理模式）、`copilot/chat_log`（聊天记录；限长 60 条 / 6 万字，**不截断单条**；恢复**不覆盖**"已经在聊"的现场；悬空关联自愈） | 打桩用例：跨页面 / 跨重启 / 悬空自愈 / 限长 4 条 |
| 产出清洗：剥**行首** Markdown 引用符 `>` | `AIOutputSanitizer._stripLeadingQuoteBlock`（只剥开头连续引用行，正文中间的 `>` 保留） | `verify_output_sanitizer` 19/0 |

**本轮修掉的三个真 BUG**（都在「关联章节」链路上，属数据事故，别回退）：
1. **提问被当成改稿** → 作者问一句「这章节奏有什么问题？」会把正文重写掉。C# 有 `LooksLikeChapterQuestion` 闸门，Flutter 侧此前漏了。现按 `ChapterIntent` 分派（先看处理关键词，再看 `?`/`？`/「吗」结尾），提问走 `askAboutChapter` 只作答、`persisted=false`。
2. **占位文本覆盖正文** → `BaseAgent.executeTaskWithAI` 在模型调用失败时**静默回退** `executeTask`，返回内置示例文本（`【本地回退章节示例】叶知秋…`）且 `isSuccess=true`；`AiWritingService._singleAgent` 又把 `Fallback` 标记吞了。现透传该标记，改稿服务见到即**拒绝落库**并如实报错。
3. **关联后模式切换器消失** → `_linkChapter` 原会收起面板，而「按意见改写 / 按意见续写」切换器在展开区里（关联后想换模式必须重新展开）。现关联后保持展开；另把"切分卷导致关联失效"的提示与手动解除的文案区分开。

**真机验收（真模型，非打桩）**：`integration_test/chapter_revision_live_test.dart`（凭证约定同 `rwkv_cloud_live_test.dart`，可 `--dart-define` 覆盖；**只写内存库，不碰真实书稿**）
- 入口：`flutter test -d windows integration_test/chapter_revision_live_test.dart`
- 2026-09-17 结果：连通性 200；改写用例 **8 秒**完成、`workflowMode=DualAgent`（两个角色都真接管）、`persisted=true`、207 字 → 185 字、`versionNumber+1`、`status` 未变；问答用例 `ChapterQa`、**正文与版本号一字未动**。
- 验收中当场发现并已修：该模型（`rwkv7-g1j-7.2b`）在「原文 + 处理要求」结构下**产出首行总带 `>`**（改写与问答两条用例全部复现，属系统性行为），已在 `extractCleanOutput` 里剥掉。

**已知边界（下一轮候选）**：
- ~~分段改写对超长章无段数上限~~ → **已加闸门（2026-09-18）**：`SegmentRewrite.maxSegments = 12`（≈2.16 万字）。超限时**在发起任何模型调用之前**就返回失败，提示里带「本章 N 字 / 按每段 1800 字需 M 段 / 上限 12 段」，正文一字不动；**刻意不做「只改前 N 段」**（那会把正文切成"改过的前半 + 原样的后半"，风格断层且作者看不出原因）。闸门是纯函数 `SegmentRewrite.plan()`，段长与上限都可传参覆盖，将来要做成配置项直接接参数即可；
- 聊天记录只做限长、还没有"清空会话"入口；
- `AppShell._buildPage` 每次只挂一个页面 → 其它页面的会话态（如对话生成器已生成的结果）仍会随导航丢失，未统一处理。

### 2026-09-19 第十一轮：安卓 APK 打包链路

**产物**：`F:\30_Novelcraft_Flutter\novelcraft_1.0.0+1_release.apk`（65.1MB，`com.novelcraft.novelcraft`，minSdk 24 / targetSdk 36，含 arm64-v8a + armeabi-v7a + x86_64，apksigner 验签通过）

**配置改动**（都在工程内，clone 后即可复现）：
- `android/local.properties` → SDK 指向 `D:\Android\Sdk`（C 盘那个 sdk 目录是空壳 + 曾有一个损坏的 NDK 28.2.13676358，已删）。⚠ **flutter build 会按 Flutter 全局配置重写此文件**，所以真正要固化的是 `flutter config --android-sdk D:\Android\Sdk`（已执行，落 Flutter 全局配置）。
- `android/app/src/main/AndroidManifest.xml` → 补 `INTERNET` 权限（Flutter 模板只在 debug/profile 带，release 缺它云端 AI 全挂）。
- `android/app/build.gradle.kts` → release 正式签名：读 `android/key.properties`（口令+别名，gitignored），缺失时自动回退 debug 签名。密钥 `android/app/upload-keystore.jks` 别名 **song**（CN=song，RSA2048/10000 天，gitignored）—— **发布前务必备份这两个文件，丢了无法发更新包**。
- `android/gradle.properties` → `android.overridePathCheck=true`（见下）。

**关键教训：中文路径是 Android 构建的硬阻塞**。工程真实路径含 `Flutter版代码`，AGP 先拒绝（加 overridePathCheck 放行），随后 Kotlin 增量缓存写不进、Dart AOT snapshotter 读文件路径乱码（`Flutter?????`），flutter clean 也救不了 —— **junction 没用（工具会解析回真实路径），必须 `subst`**：
```
subst S: "F:\30_Novelcraft_Flutter\Flutter版代码\novelcraft"
Set-Location S:\
flutter build apk --release
```
subst 映射重启后失效，重打 APK 前先重跑第一条。产物在 `S:\build\app\outputs\flutter-apk\`（物理上就是工程 `build\` 目录）。想要更小的包用 `--split-per-abi`（每 ABI 约 1/3），上架商店用 `flutter build appbundle`。

**2026-09-20 真机首启修复**：安卓首启报 `FileSystemException: Creation failed, path='//NovelManagement' (errno 30)` —— `key_value_store_native.dart` 用 `Platform.environment['APPDATA']` 取数据目录，安卓上 APPDATA/HOME 均 null，退到只读根目录。已改为：**Windows 保持 `%APPDATA%\NovelManagement`（老数据不动），其它平台走 `path_provider.getApplicationSupportDirectory()`**（应用私有可写目录，无需权限）。新 APK 已重签打包（仍 CN=song，65.1MB）。这是**全库唯一**一处环境变量路径依赖（已 grep 确认）；`Directory.systemTemp`（推理 pid 文件）在安卓落到应用缓存目录，安全。

**2026-09-20 安卓横屏 + 布局缩放优化**：真机反馈 AI 配置页导航标签换行、右侧卡片溢出。四处改动：① `AndroidManifest.xml` MainActivity 加 `android:screenOrientation="sensorLandscape"`（默认横屏、随传感器双向旋转）；② `main.dart` MaterialApp.builder 对安卓把系统字体缩放钳到 1.2（`MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.2)`，⚠ Flutter 3.38 **没有** `TextScaler.clamping` 静态方法，只有实例 `clamp`；用 foundation 的 `defaultTargetPlatform` 判断，不引 dart:io 保 Web 可编译）；③ `app_shell.dart` 主侧栏窄屏（<1000 逻辑宽）自动收起为图标栏，`_extendedOverride ?? width >= 1000`，手动切换后以手动值为准；④ `ai_configuration_page.dart` 内容区 <560px 时供应商列表与配置卡片上下堆叠（`_ProviderList` 加可变 width），宽屏保持左右分栏。验证：analyze 0 issue、chapter_revision_test 25/25；APK 已重签打包并覆盖 `F:\30_Novelcraft_Flutter\novelcraft_1.0.0+1_release.apk`（65.1MB，apksigner 验签通过）。

**2026-09-20 主侧栏滚动 + 字体钳制收紧 + 协作页短屏适配**：真机后续两轮反馈的收尾。① `app_shell.dart` 主侧栏 NavigationRail 包纵向滚动——手机横屏高度装不下 6 个目的地，第 6 项「AI 助手」整块被裁导致进不去 AI 配置。⚠ **NavigationRail 不能直接塞进滚动视图**：其外层 Column 是 `MainAxisSize.max` 且含 `Flexible`（groupAlignment 布局），无界高度触发 unbounded 断言；需 `LayoutBuilder + SingleChildScrollView + ConstrainedBox(minHeight: 视口高) + IntrinsicHeight`——IntrinsicHeight 先算固有高度再给 tight 约束绕开断言，minHeight 保证内容不满一屏时背景仍撑满整列。二级导航（世界观/AI 功能）本就是 ListView，无需处理。② `main.dart` 安卓字体钳制 1.2 → **1.0**（真机反馈 1.2 仍偏大；App 按桌面密度设计，安卓端不再跟随系统字体缩放）。③ `ai_collaboration_page.dart` 矮视口（逻辑高 <520）紧凑布局：隐藏页内重复大标题（AppBar 已有标题）、内边距 20→12、输入框 maxLines 5→2；关联章节面板展开态用 `ConstrainedBox(45% 视口高) + SingleChildScrollView` 限高内部滚动，避免把输入框挤出屏幕。验证：analyze 0 issue、chapter_revision_test 25/25；APK 重签打包覆盖发布产物。

**2026-09-27 桌面端 RWKV 超级并发压测 + 两端封装 v1.0.0+2**：版本号 1.0.0+1 → **1.0.0+2**（pubspec 与状态栏同步显示；此前用户拿到的 APK 全是旧构建——**交付纪律：构建完成后立刻拷贝覆盖发布产物并汇报路径**）。新增压测 `integration_test/rwkv_concurrency_stress_test.dart`（真端点，运行 `flutter test integration_test/rwkv_concurrency_stress_test.dart -d windows -r expanded`，5/5 通过）：①容量 hard=169 / available=167 / bytesPerBsz≈52.4MB；②串行 8 条 0.74 req/s（基线）；③8 槽单 POST **6.06 req/s**（8.2×）；④6 路批量 × 8 槽 = 48 路并行 **16.42 req/s**、48/48 内容无混串、压测后服务端队列归零 available 回落 167；⑤16 路有状态会话并发 3.76 req/s、抽查暗号无串号无丢失、测试后清理全部会话。⚠ 用例设计坑：**别给小模型下「只回复：好的」这类复读指令**——第二轮问暗号它会复读自己上一句，看起来像并发串号，实为提示词污染。封装产物：`F:\30_Novelcraft_Flutter\novelcraft_1.0.0+2_release.apk`（65.1MB，song 签名，旧 +1 已删）、`F:\30_Novelcraft_Flutter\novelcraft_1.0.0+2_windows_release.zip`（14.6MB，解压运行 `novelcraft.exe`）。⚠ 桌面**运行中的 GUI 实例会锁 `build\windows\...\Debug\novelcraft.exe`**，集成测试构建时报 MSB3073/INSTALL 退出码 1——跑测试前先 `Get-Process novelcraft | Stop-Process -Force`。

**2026-09-27 RWKV 并发放开 + 安卓操控性优化 + 主 Agent 分派决策（v1.0.0+4）**：用户明确「单卡 4090 可扛 900+ 并发，尽可能开放利用能力上限」「跑之前先测本地最大并发数并保存到配置，由主 Agent 自主决定分派多少个子 Agent」。① **并发**：`RwkvConcurrencyController.clientHardCap` 16 → **64**（服务端 FIFO admission + dynamic_max_bsz 自保护，客户端上限只防本地在途失控）；`rwkvMaxConcurrentSessions` 默认 8 → 16（引擎级会话限流，对齐实测峰值；存量用户配置不受影响）。⚠ **关键修复：`effectivePermits` 此前没有任何消费方**——批量客户端只做观测不做门控，实际并发不设防；现已在 `rwkv_batch_client.dart` 两条 POST 路径（非流式 `_chatWithRetry` / 流式 SSE）加 `waitForPermit()` 动态门控（许可=min(64, 服务端 available, 排队折半, 惩罚档)，每 200ms 复查），使「吃满服务端容量 + 本地不失控」真正生效。② **主 Agent 分派决策**：新增 `lib/ai/workflow/dispatch_planner.dart`（纯 Dart，存储走回调注入对齐 session_archive 先例）——`WorkflowEngine.executeWorkflow` 跑之前自动 `probeAndPersist()`（探测云端 `capacity().effectiveAvailable`，失败回退本地配置 16，持久化 KVStore `ai_config/rwkv.probed_concurrency`，60s TTL）→ 让**双代理 Main provider** 对「分派多少个子 Agent 并行」表态（只回整数，16 token 预算）→ `decide()` clamp 到 [1, 探测值] → `TaskQueue.setMaxConcurrentTasks()` 运行时生效（**TaskQueue 已从固定 Semaphore 改为动态门控**，快照读 `maxConcurrentTasks`），决策写进 `workflow.configuration['dispatchConcurrency'/'dispatchProbedMax']`；规划任何一步失败按原并发执行不阻塞。⚠ TaskQueue 的 Semaphore 已移除，别再按旧签名用它。③ **安卓操控性**：输入框触控平台放宽（`isDense:false` + 内边距 14，桌面保持紧凑）、AppBar <720 逻辑宽时「一键生成书籍」收成纯图标、二级导航 ListTile 密度触控平台放宽（`kSubNavTileDensity`）。验证：analyze 0 issue、`test/dispatch_planner_test.dart` 7/7（未装配用满探测值/表态 clamp/超报钳制/非整数未表态/探测回退/持久化往返）、`test/chapter_sync_test.dart` 4/4、压测 5/5 + 回归 25/25 串跑全绿；产物 v1.0.0+4（旧 +3 删除）。

**2026-09-27 并发/生成质量实测审查 + 立即修 5 处（并入 v1.0.0+4）**：真端点压测复跑 5/5（容量 hard=169/available=167/queued=0；串行 0.77 req/s；8 槽批量 3.41 req/s = 4.4×；48 路并行 **15.0 req/s** ≈ 19.5× 串行、去重 48/48 无混串、压后队列归零；16 路有状态暗号各自命中无串号）+ 一次性生成质量探针（跑完即删，不进仓库）：长文 420 字 12 字滑窗去重比 1.000 零复读、有状态续写跨轮记住主角名并在首句出现；⚠ **g1j 推理模型的 `<think>` 块会白吃 max_tokens**——严格 JSON / 格式类短输出任务在预算紧张时「剥 think 后正文为空」（应用层 AIOutputSanitizer + Fallback 闸保护不落库，长期需 think 预算自适应：格式类任务 maxTokens ≥2× 预期正文 + 空正文放大预算重试一次）。立即修：① `rwkv_concurrency.dart` effectivePermits 注释与实现对齐（探测失败沿用 clientHardCap，服务端 FIFO + bsz overflow 惩罚档已构成兜底，无需减半）；② `RwkvBatchFailureKind` 新增 `network`（网络异常不再误标 truncated，面板可区分链路断/响应截断）；③ 流式批量 `chatStream` 收尾加完整性校验——`finished.length < n` 时告警并把指标记为失败（failureKind=truncated），不再无条件 done=true 静默当成功（不重试：调用方已拿部分快照，补拉语义归上层）；④ `dispatch_planner.dart decide()` 持久化**完整** DispatchPlan（此前只写 probedMax/source/probedAtMs 三元组，fromMap 读 effective/mainAgentDecision 永远为 0，lastPlan 形同虚设）；⑤ `di.dart` planner 探测值与 `concurrency.clientHardCap`(64) 取小——非批量路由（chat/state/postJson）不过 waitForPermit，TaskQueue 是它们唯一的并发闸，防止探测值 167 直压移动端内存/套接字。另修 `test/widget_test.dart` 外壳用例：窄屏适配（<1000 收图标栏）使默认 800x600 测试面不渲染品牌字，改 `tester.view.physicalSize = 1280x800`（⚠ `binding.setSurfaceSize` 已失效静默不改尺寸，必须用 `tester.view`）。已知遗留（下版/长期）：门控下沉 postJson/chat 全路径、waitForPermit/TaskQueue 忙等改唤醒、主 Agent 表态缓存、planner 回退值读配置页 rwkvMaxConcurrentSessions（当前硬编码 16）、工作流结束恢复 TaskQueue 原并发、think 预算自适应。验证：analyze 0 issue、test/ 95/95。⚠ **APK 构建两条硬教训（本次 +4 实录）**：① `novelcraft_en` 是指向真实目录 `Flutter版代码\novelcraft`（中文路径）的 **junction**，Gradle 会把路径解析回真实位置；从 junction 发起构建时 gen_snapshot/impellerc 等原生工具在中文路径上挂掉（`Unable to read app.dill` / `Could not write ...shaders/*.frag`，日志里路径乱码成 `Flutter?????`）——**必须按 §2 的 subst 方案 `subst S: "F:\30_Novelcraft_Flutter\Flutter版代码\novelcraft"` 后从 `S:\` 构建**（subst 盘符路径不会被 canonicalize 回中文）；Windows 构建不受影响（走 novelcraft_en 纯 ASCII 路径）。② 构建中途失败/`flutter clean` 后若报 `e: Daemon compilation failed` + `Storage ... is already registered`，是 **Kotlin daemon 僵死**（长驻 JVM 持有已被删除的增量缓存注册）——`gradlew --stop` + `taskkill /F /IM java.exe`（Gradle/Kotlin daemon 同源）后重建即好；`flutter clean` 不清 daemon。产物 v1.0.0+4：`F:\30_Novelcraft_Flutter\novelcraft_1.0.0+4_release.apk`（65.8MB，song 签名 apksigner 验签通过）+ `novelcraft_1.0.0+4_windows_release.zip`（14.1MB，**含全部立即修**；zip 在 flutter clean 之前打出、clean 只删 build 不影响已交付 zip），旧 +2/+3 已删。

**2026-09-27 三大功能：章节结构化预览 + 写作过程档案 + 写后世界观自动同步（v1.0.0+3）**：用户反馈三连的收口。① **功能 A 章节预览**：`chapter_stats_service.dart`（C# 口径：段落=非空换行块、阅读时长=400 字/分、目标进度）+ `chapter_preview_page.dart`（统计面板 / 元信息 Chip / 梗概备注卡 / 段落阅读视图 / 字号切换）+ `entity_page.dart` 新增 `previewBuilder` 挂口（表单快照 + 行元信息一起带走，未保存改动也能预览）。② **功能 B 过程档案**：`readonly_prose_view.dart` 共享阅读组件 + `generation_archive_page.dart` 双 Tab（生成档案=**首次接线只写不读的 `project_archive`**，详情含 RequirementBrief/MainDraft 过程数据；大纲 Tab 读 `Plots(type='主线')`）+ `NavigationTarget.generationArchive`（AI 分组）+ 协作页工作流 SnackBar「查看结果」+ 一键生成结果行「查看」（结果类新增 outlineText/chapterText 内存直通）。③ **功能 C 写后同步**：`chapter_sync_service.dart`（C# `ChapterContentSyncService` 1:1：人物 History/KeyEvents/首末出场/履历事件 upsert、势力 memberCount/Notes、人物关系两两配对、剧情涉及章节+进度+状态推进、世界设定 History、势力关系、时间线「剧情事件」按 chapterId upsert+参与者重建；**单字名不参与 contains 匹配**防误伤；追加去重幂等）+ `chapter_post_process_service.dart`（防重 `last_version:{chapterId}`、开关 KVStore scope=chapter_sync、**规则同步默认开 / AI 抽取默认关**、异常全部折叠绝不阻塞章节保存）+ `chapter_ai_state_service.dart` + `state_extraction_parser.dart`（配平截取/回显过滤含模板占位名/单引号修复/长度钳制）+ AI 配置页 `_ChapterSyncCard` 两级开关 + 改稿与一键生成两个落库出口挂钩子、`linkageApplied` 接真值（一键结果对话框按真值显示「已同步/未执行」）。**状态栏书名**：`currentProjectNameProvider`（此前显示 projectId UUID，用户无法辨认；autoDispose 反查项目名，失败回退 id）。验证：`tool/verify_chapter_stats.dart` 17/0、`tool/verify_state_extraction_parser.dart` 19/0、`test/chapter_sync_test.dart` 4/4、`chapter_revision_test` 25/25。⚠ **规则同步的验证必须放 `test/` 而非 `tool/`**——`database.dart` 经 drift_flutter 依赖 dart:ui，纯 `dart run` 编不过；lib/ai 的纯解析器仍可走 tool/。产物：v1.0.0+3（后被 +4 取代，+3 已删）。

## 3. 架构分层

```
lib/
  core/        enums, exceptions, di.dart(全量 Riverpod 装配)
  data/
    tables/    27 张 drift 表定义
    database.dart / database.g.dart
    repositories/  23 个仓储
    storage/   KeyValueStore 平台抽象(Native/Web/Stub)
  application/ services/(21) + models/stats.dart(强类型统计)
  ai/          模型/提供商/智能体/记忆/工作流/推理启动器
  theme/       3 套皮肤 + 主题状态机
  l10n/       3664 条词条 + 运行时切换
  ui/
    layout/    navigation(导航枚举+二级导航) + app_shell
    pages/     entity_page(通用CRUD模板) / world_system_page(10 JSON体系模板)
               / entity_configs / system_configs / placeholder_page / project_management_page
```

**关键设计取舍**
- C# 的 21 个服务统一 `try/catch{rethrow}` 模板被**有意丢弃** —— Dart 侧异常直接上抛，UI 统一处理。
- C# 的 10 个世界观体系页数据**没有数据库表**，存 JSON 文件（`%AppData%\NovelManagement\{scope}\{projectId}.json`），Flutter 侧抽象为 `KeyValueStore`（Web 走 localStorage）。
- C# 大量重复页面（12 个体系 View ≈ 11,400 行、各实体 CRUD 页）统一收敛为 **模板 + 配置**。
- 统计返回强类型（如 `ProjectStats`），不用 `Map<String,Object?>`。

## 4. 构建与验证

```bash
# 依赖
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # 仅改了表定义后需要

# 静态检查（必过）
flutter analyze          # 期望: No issues found!

# 纯函数 / 工艺验证（16 个脚本，**不进 GUI、不联网**；改完 ai/utils 或 RWKV 参数后必跑）
Get-ChildItem tool\verify_*.dart | ForEach-Object { dart run $_.FullName }

# 真机（当前环境已可跑；会编译并启动桌面 App，跑完自动关闭）
flutter test -d windows integration_test/seeder_test.dart                 # 数据库 seeding 幂等
flutter test -d windows integration_test/chapter_revision_test.dart       # 边聊改稿全链路（AI 打桩，23 条）
flutter test -d windows integration_test/chapter_revision_live_test.dart  # 真模型验收（需外网 + 那台 GPU 在线）
flutter test integration_test/rwkv_cloud_live_test.dart                   # 云端端点 / 批量路由

# Web 编译（可验证 dart2js 全量编译）
flutter build web        # 产物 build/web/main.dart.js（约 3MB）
```

> ⚠ 第 5 节的**环境阻塞**是早期沙箱的限制；截至 2026-09-17，`flutter build windows` 与 `flutter test -d windows` 在**当前环境均已验证可跑**（真机验收 + 打桩用例都跑过）。`flutter build web` 仍受中文路径 impellerc 限制（PITFALLS §24.3），需在纯英文 junction 路径下构建。
>
> 跑真机用例的注意：`flutter test -d windows` 会占用 `build\windows\...\novelcraft.exe`，**同时开着 `flutter run` 会因文件锁导致 CMake INSTALL 失败** —— 先停掉 App 再跑测试。

## 5. 环境阻塞（非代码缺陷）

| 现象 | 根因 | 状态 |
|---|---|---|
| `flutter build windows` 崩溃 | `reg.EXE` 在沙箱程序黑名单；CMake 在沙箱注入下崩溃（exit `0xC0000409`） | 需 **未受沙箱限制** 的环境 |
| `flutter test` 无法运行 | `flutter_tester` 的本地 WebSocket 被沙箱拦截（Invalid WebSocket upgrade） | 已写好 `test/widget_test.dart`，环境具备即可跑 |
| 每次 Windows 构建前 | `windows/linux/flutter/ephemeral/.plugin_symlinks` 残留链接导致 errno 183 | 需在普通环境 `rm -rf` 各平台该目录后重试 |
| `flutter build web --release` shader 编译报 **Could not write file .../ink_sparkle.frag** | 路径含中文（如 `Flutter版代码`）时，Flutter 3.38.5 的 `impellerc.exe`（C++）用 ANSI ACP `fopen` 打开输出文件失败（见 PITFALLS §24.3） | 在纯英文路径 build / 开 UTF-8 BCP47 locale 即可通过 |

已验证可用的编译：`flutter build web` exit code 0，**dart2js + Impeller shader 全链路通过**，产物 `build/web/` 可直接部署（本地验证 HTTP 访问）。

## 6. 待办清单（建议优先级）

> 更新：2026-09-14 · 签署：TRAE-NovelCraft-Bot（第九次签署，本节新增 18-30 项 = rwkv_lightning_cuda 离线引擎 + 线上 RWKV API 配置区 + 三 Provider 分级高并发方案；原 1-17 保留未变）

> ⚠ **执行顺序硬约束**：P1（12/13）真机验收完成 → **然后才允许推进 18-30 的 RWKV 增强**；严禁跳过 12/13 直接进入 RWKV 主线。理由：P1 是「App 能稳定跑、UI 真生效、seeder 真不重复」的底线，不先验证就加 RWKV 新特性，会导致 bug 归因混乱（是 L10n 没生效还是 rwkv_lightning 参数错了分不清）。

> 18-30 的优先级：P2（18/19 是最小可用闭环，先做）→ P3（20-24 是高并发能力落地）→ P4（25-30 是体验/可维护性增强）。

---

### P1（真机验收，先做完这三项才能进入 P2/P3/P4）

1. **数据库实体页** ✅ 已完成：原 6 个 + 新 14 个 = 20 个，全部经 `entity_configs.dart` 模板 + `app_shell.dart` 路由接入；`flutter analyze` 通过。
2. **L10n 中英文切换 14 页面全量回填** ✅ 已完成（本轮）：
   - `tf(String key, String fallback, Object args)` 签名多态化：`List<Object>` 位置占位 + `Map<Object,Object>` 命名占位（`{label}` / `{path}` / `{ms}`），同时支持 C# 移植风格代码和新语义化代码，一次修改消除 24 项同类型编译错误。
   - 14 页面（AppShell + 世界观/实体/4AI 大页/6 小页/System Configs）硬中文三分法落地：① UI 展示型 → t()/tf() 包装；② 枚举/过滤键值型（where 字面量「错误 / 玄幻 / 朋友」）→ const 中文值保留，新增 display 映射；③ Prompt / 存储内容（AI 对话草稿 / 卷宗标题）不翻译。
   - 配置驱动三层双字段：SystemFieldDef/EntityPageConfig/WorldSystemConfig → labelZh/labelEn + optionsZh/optionsEn → 纯函数访问器 labelFor(isEnglish)/optionsFor(isEnglish)，UI 零 if/else 硬编码。
   - Riverpod ref 作用域修复：私有 `_buildBody` 显式传 `WidgetRef ref`，消除 project_overview_page.dart undefined_identifier。
   - SnackBar 参数语法修正：`backgroundColor` 归位 SnackBar 命名参数（不是 Text() 构造的命名参数），同时修正括号层级错位。
   - 双表 key 3996→3996 去重：首轮「CSV 3664 key」+ 第二轮 UI 改造「352 调用」因重复追加导致 `equal_keys_in_const_map` 52 处，按首次出现保留去重 + 修复 en 表末尾悬空 value 多行字符串。
   - 首启动三条级联异常根因代码级修复：pubspec 补 `flutter_localizations` SDK 依赖（intl ^0.20.2 服从 SDK pinning）+ main.dart 注入 Material/Cupertino/Widgets 三 delegate + `localeListResolutionCallback` 三语回退；AppShell Row 二级导航包 `Flexible` 防 98736px RenderFlex overflow。
   - **14 缺失通用 key 补齐**：zh/en 双表追加 Common.Clear/.Deleted/.DeleteFailed/.EmptyItem/.NewItem/.Refresh/.Saved/.SaveFailed/.SearchItem/.SelectOrNewItem/.UnsavedChanges/.PleaseSelectProjectFirst/.StoreInitFailed 与 Dlg.Save/.Delete/.Settings，修复 entity_page 通用 CRUD 操作永远 fallback 中文的问题。
3. **LOGO 多平台分发** ✅ 已完成（本轮）：
   - 源：`F:\30_Novelcraft_Flutter\novelcraft_en\icon.ico`
   - 脚本：`F:\30_Novelcraft_Flutter\deploy_icon.ps1`（System.Drawing HighQualityBicubic 缩放，重复运行幂等）。
4. **真实页面替换占位** ✅ 已完成：时间线 / 项目概览 / 导入导出 / 设置 → 真实页；**AI 协作创作、AI 配置、对话生成、项目健康检查 → 真实页（全部接 `lib/ai` + `ModelManager` / `NovelWorkflowEngine` / `Repository` 23 类）**，占位页归零。
5. **数据库初始化/种子数据** ⏳ 第一阶段完成（空壳 + TODO）：新增 `DatabaseSeeder` 服务（标准修仙模板「玄穹剑主」完整示例项目架构 + 事务 + 幂等）+ `appBootstrapProvider` 首启动触发；**Companion.insert 双类型签名（裸 String 必填 vs d.Value 可空）需逐表对照 database.g.dart 重写**（27 张表，约 600 行插入代码）。
6. **AI 层接线** ✅ 已完成：`lib/ai` 6 个 provider + 8 个 agent + memory + workflow + task_queue + thinking processor 全部注册到 `di.dart` 并带 onDispose；AI 协作（自由聊天流式 + 工作流执行）/ AI 配置（连接测试 + 注册）/ 对话生成（真流式生成 + 质量评分 + 保存章节草稿 + md/txt/json 导出 + 模板存读）/ 项目健康检查（本地 11 条规则 + AI ConsistencyCheck 工作流复检 + 跳转定位）全部真实调用。
7. **8 个 Agent 提示词精修** ✅ 已完成：Director / Writer / Character / Plot / World / Reader / Summarizer / Editor 全部覆写 `supportedCapabilities / buildSystemPrompt / buildUserPrompt / processAIResponse / executeTask`（本地 fallback）；system prompt 贴合修仙题材（玄穹剑主风格）并强制结构化 `## 分节` 输出；公共 `parseMarkdownSections` 按标题切分 sections Map；所有 4 个预定义工作流（项目初始化 / 章节创作 / 内容审查 / 一致性检查）输出可直接消费。
8. **三页 AI UI 接口契约全量修复（141→0 analyze）** ✅ 已完成：AI 配置页 5 种 Configuration 子类构造参数签名对齐；对话生成页 ChatRequest/ChatMessage + chatStream 回调式 + Companion.insert 双类型 + Icons 替代 + deprecations；AI 协作页 Material 3.33 Container.child 移除 → DecoratedBox/ColoredBox 组合 + StateProvider 移除 + 括号层级修复。
9. **RWKV 推理引擎 + State 复用强化 Agent** ✅ 已完成（新增 32→25 AI 文件，+7 个新文件）：
   - `lib/ai/rwkv/rwkv_state.dart`：RwkvState opaque 封装 + RwkvStateCache LRU（64 条 / 30min TTL）
   - `lib/ai/rwkv/rwkv_session.dart`：RwkvSession 单会话 Semaphore(1) 串行化 + RwkvSessionManager
   - `lib/ai/rwkv/rwkv_models.dart` + 3 scanner（stub/native/web）：条件导出扫描本地 GGUF 模型（parseRwkvFileName 解析架构/参数量/量化等级）
   - `lib/ai/rwkv/rwkv_engine.dart`：RwkvEngine 中枢（ensureLocalServer 进程拉起 + chat/chatStreamWithSession + takeSnapshot/restoreSnapshot）
   - `lib/ai/providers/rwkv_provider.dart`：RwkvConfiguration 保持 3 参数签名 + RwkvProvider IModelProvider + 扩展 API openSession/closeSession/chatInSession/listLocalModels/launchLocalServer
   - `lib/ai/agents/agent.dart`：BaseAgent 三级 sessionId 解析（workflow parameters → Agent 级 → 新建）+ chatInSession 调用 + stop/reset/dispose 自动 closeRwkvSession
   - `lib/ai/workflow/workflow_engine.dart`：executeWorkflow 开头绑定全 workflow 共享 session（sessionId 注入全部 task.parameters）+ 完成/失败/取消/dispose 四分支 _cleanupSession 回收
8. **AI 配置页 RWKV 本地面板** ✅ 已完成（硬件版本下拉 + 本地模型扫描下拉 + 启动 Server 按钮）：`listLocalModels()` 扫描 `rwkv_models/` 填下拉，`launchLocalServer()` 拉进程并回填 baseUrl=http://127.0.0.1:8080。
9. **NovelWorkflowEngine 全局 DI 共享 RwkvProvider 单例** ✅ 已完成：`lib/core/di.dart` workflowEngineProvider 构造时注入同一个 `rwkvProvider` 单例；Agent 从 ModelManager 拿、Workflow 从构造参拿，二者为同一对象，跨层共享 session。
10. **RWKV 官方资源一键安装 + 取消 + 断点续传** ✅ 已完成（Bridge 条件导出 + Provider 透传 + UI 进度块）：
    - Bridge：`rwkv_official_resources.dart` 抽象 + stub/native/web 三条件导出签名严格一致；native 调 GitHub Releases API + HuggingFace Models API；PowerShell Expand-Archive 解压不引 archive 包。
    - 下载：Range header 断点续传 + 500ms 节流刷新进度 + 滑动 20 采样点速度/ETA；取消后保留 .part，下次继续。
    - 并发互斥：`_installInProgress / _downloadInProgress` 布尔锁，并发直抛 StateError → UI SnackBar 提示。
    - 取消：抽象 `RwkvCancelHandle { isCancelled + cancel([reason]) }` + `onHandleReady` 回调句柄透传；UI 进度块 phase 非 terminal 时右上角 `Icons.highlight_off_outlined` 取消按钮（Semantics + Tooltip「取消当前任务」）。
11. **RWKV 配置持久化（KVStore 双 scope）** ✅ 已完成：
    - 序列化：`RwkvEngineConfig.toMap/fromJson` 6 字段（Duration 转秒）+ `RwkvConfiguration.toMap/fromJson` 3 主参 + localExecutable/localModelPath/engineConfig 子 map。
    - scope 隔离：`(ai_config, rwkv.configuration)` 存核心配置、`(ui_prefs, rwkv.server_variant)` 存用户选的硬件版本（防止其他 provider 写 ai_config 撞 key）。
    - 四个写入挂点：saveAndRegister 成功 / install 成功 / download 成功 / serverVariant 下拉切换；写入 try/catch 全吞，失败不阻塞 UI。
    - 启动加载：initState.addPostFrameCallback 最先 `_loadPersistedRwkvPrefs()`，优先于 _refreshFromManager/_ensureRwkvScanned；4 步容错（KVStore 读失败 → decoded 非 map → 字段缺省 → variant name 不匹配回 vulkan）。

剩余建议项（完成度 100%，非阻塞但会提升用户体验）：
12. **真实 Windows 环境运行验证（P1 真机 L10n 验收）**：在普通命令行执行 `flutter pub get ; flutter run -d windows` → ① 首启动三条级联异常全消 ② 切 EN 后 5 大截图页（AC/DG/HC/PM/AICfg）所有 UI 标签 100% 英文无中文残留 ③ 切回中文 100% 还原 ④ 无 overflow / 裸枚举名。验收标准：PITFALLS §26.3 的 reverse key diff 差集为空 + 真机双路径肉眼验收均通过。
13. **Seeder 幂等 & 集成测试（P1 数据库验收）**：玄穹剑主 3 次重启无重复；`flutter test -d windows integration_test/seeder_test.dart -v` → 2/2 PASS。验收标准：三次 `flutter run` 启动后「玄穹剑主」项目仍仅 1 条，seeder_test 两个 test case（空库 seeding + 二次幂等跳过）都 PASS。
14. **RWKV 本地点按钮端到端验证（P1 推理链路验收）**：AI 配置页 → RWKV（本地）→「启动本地 RWKV Server」按钮 → 观察红色错误面板不再是「拒绝连接 errno=1225」→ 若失败显示真实 llama-server 崩溃行（如 `cudart64_130.dll not found` / `CUDA OOM` / `invalid argument` 等），若成功「运行统计」可用性由离线→在线、testConnection HTTP 200。验收标准：UI 诊断链路真的能展示真实 stderr，不再泛化。

---

### P2（RWKV 最小可用闭环，先做 18/19 = 让用户立刻能调用 api-7b.rwkvos.com 线上模型）

18. **AI 配置页新增「RWKV 云端（rwkvos）」独立 Provider 注册入口 + Cloudflare Access 认证配置区**
   - 目标：把用户提供的 `api-7b.rwkvos.com`（三张 4090）做成**可切换的独立 Provider**，不要塞到现有的「RWKV (本地)」里面（二者路由完全不同：本地 llama-server 是 GGUF；云端 rwkv_lightning_cuda 是 PTH；认证方式、并发策略、State API 语义全部不同，硬塞会导致互相覆盖、配置持久化混乱、启动时本地拉进程、云端根本跑不起来）。
   - 具体改动清单：
     a. `_ProviderKind` 枚举（ai_configuration_page.dart:L28）新增 `rwkvCloud` 项，label 中文=「RWKV 云端 (rwkvos)」、英文=「RWKV Cloud (rwkvos)」，icon=Icons.cloud_outlined；左侧 Provider 列表由原来 5 项变 6 项，RWKV 云端放 RWKV 本地正下方。
     b. `IModelConfiguration` 体系新增 `RwkvCloudConfiguration implements IModelConfiguration`（单独文件 `lib/ai/providers/rwkv_cloud_configuration.dart`，别乱塞到 rwkv_provider.dart 里会导致 analyze 爆炸），字段：`baseUrl`（默认 `https://api-7b.rwkvos.com`，去尾 `/`）、`defaultModel`（默认从 `/v1/models` 取第一条，推荐值=用户给的 `rwkv7-g1j-7.2b-20260831-ctx16384`）、`defaultMaxTokens=16000`（匹配 ctx16384 标签）、`defaultTemperature=1.0`、`timeoutSeconds=180`、`enableStreaming=true`、`cfAccessClientId`（Cloudflare Access 明文 Client ID，默认值已脱敏，经 --dart-define / 用户输入提供，用户可自定义）、`cfAccessClientSecret`（Cloudflare Access 明文 Secret，默认值已脱敏，用户可自定义）、`customHeaders=<String,String>{}`（兜底扩展）。**切勿把这两个 CF 字段塞到 OpenAICompatibleConfiguration.customHeaders**——原因：customHeaders 是用户手动填的键值对，和 `CF-Access-Client-Id/Secret` 的语义不一样；后者是「服务端零信任安全认证，必带两个成对 header」，应该在 `_defaultHeaders()` 内按命名字段组装，防止用户误删/拼错大小写（Access 头必须是精确 camelcase 这两个拼写，否则 CF 直接返回 403 / 302 重定向到身份页 HTML 导致 JSON 解析炸）。
     c. `RwkvCloudProvider implements IModelProvider`（单独文件 `lib/ai/providers/rwkv_cloud_provider.dart`，策略：**不 extends RwkvProvider**，因为 RwkvProvider 内部持有 `_engine` + `_globalSemaphore(4)` + `launchLocalServer()` 等纯本地逻辑，继承会导致 20+ 字段废用和初始化混乱；正确做法：**组合一个内部的 `http.Client` + `OpenAICompatibleProvider` 实例做实际 HTTP 调用**，把 Cloudflare Access 头 + `X-RWKV-*` 扩展头在 `_effectiveHeaders()` 中注入后传给内部 OpenAICompatibleProvider 的 customHeaders；对外的 `testConnection/getAvailableModels/chat/chatStream/statistics/dispose` 全部转调内部实例，仅扩展 `get nativeBatchApiEnabled` + `batchChatContents(List<String> prompts, ...)` + `multiStateChat(...)` 等 rwkv_lightning 独有接口）。
     d. `lib/core/di.dart` 新增 `rwkvCloudProviderInstanceProvider = Provider<RwkvCloudProvider>` 单例（和 rwkvProviderInstanceProvider 平级，**同一个 RwkvCloudProvider 必须被 workflowEngineProvider + allAgentsProvider 两边注入到同一个实例引用里**——重复 P2 第八签的教训：Agent 拿一个、Workflow 拿另一个会导致 session/state 全部对不上，直接炸 State 复用链）。
     e. AI 配置页 UI（ai_configuration_page.dart）`_buildProviderConfigCard(_ProviderKind.rwkvCloud)` 新增独立的参数卡片（别复用 RWKV 本地那张「本地 RWKV 管理 / 官方资源一键安装」面板，云端不需要那一堆），参数区结构：① API 基础地址（`TextFormField` 默认 https://api-7b.rwkvos.com，onChange 实时写 `_cfg`）；② 默认模型（`TextFormField` + 按钮「从云端拉取模型列表」，点了之后内部调 `getAvailableModels()` 填下拉，和 Ollama 拉本地模型同理）；③ 超时秒/温度/最大 token（沿用现有 RWKV 本地同款 4 行 Row 布局）；④ **Cloudflare Access 认证区（两行 TextFormField + 行尾 EyeIcon 切换明文/密文）**：第一行 label=CF-Access-Client-Id，hintText=<REDACTED>（凭据经 --dart-define / 用户输入提供，勿写进仓库）；第二行 label=CF-Access-Client-Secret，obscureText=true，hintText=<REDACTED>；两行下面放小字 warning（黄色）：「Cloudflare Access 密钥绑定 rwkvos 测试集群，请勿外传；如部署自有集群，请替换为自己的 Service Token 对」。
     f. **配置持久化**（KVStore 新 scope，不要污染 ai_config/rwkv.configuration）：`(scope=ai_config, key=rwkv_cloud.configuration)` 存 RwkvCloudConfiguration.toJson()（含 baseUrl/model/cfAccessClientId/cfAccessClientSecret 明文）；启动 initState 里先读 KV → 填 `_cfg` → 然后 `_testing=true` 时按用户填的头发请求。持久化风险：明文存 Client Secret 会被本地用户读到；这是用户允许的 tradeoff（桌面端本地存储，不存在跨租户泄露风险），如果后续要加密就套个 `String XOR mask`（不要引 cryptography 包，Flutter Web 编译会炸，用简单 XOR 即可）。
     g. **测试连接时的 HTTP 403/302 拦截**：Cloudflare Access 不合法时不会返回 JSON，会返回 302 跳转到 `.cloudflareaccess.com` 登录页 HTML，`jsonDecode` 直接报 `FormatException: Unexpected character <`；`RwkvCloudProvider.testConnection()` 必须特判 statusCode=403 / 302：如果 body 以 `<` 开头或包含 `cloudflareaccess`，就直接返回人类可读的错误：「Cloudflare Access 认证失败：请检查 CF-Access-Client-Id / CF-Access-Client-Secret 是否匹配当前集群（返回为 Cloudflare 登录 HTML 而非 JSON）」，不要把整段 HTML 抛给用户会炸 RedErrorScreen。
     h. L10n：所有新增 UI 文字都要进 strings.g.dart，key 前缀=AIC.RwkvCloud*（例如 AIC.RwkvCloudLabel=RWKV 云端(rwkvos)、AIC.RwkvCloudCfId=CF Access Client Id、AIC.RwkvCloudCfSecret=CF Access Client Secret、AIC.RwkvCloudCfWarn=Cloudflare Access 密钥绑定测试集群，请勿外传…），禁止硬中文，严格走 PITFALLS §26.3 的 reverse key diff。
   - 验收标准：点「测试连接」→ 返回 ConnectionTestResult.isSuccess=true，serverInfo={'modelCount':1, 'modelId':'rwkv7-g1j-7.2b-20260831-ctx16384'} → 点「保存并注册」后 ModelManager 中 getProvider('RWKV Cloud') != null → 退出 App 再进，配置自动加载（CF Id/Secret 不丢）。

19. **AI 协作/对话生成页新增 Provider 下拉切换（本地 RWKV / 云端 RWKV / DeepSeek 等都能切）**
   - 背景：当前 `ai_collaboration_page.dart` 和 `dialog_generation_page.dart` 写死用 `rwkvProviderInstanceProvider` 或某个默认 Provider，用户根本切不到云端。
   - 改动：AI 协作页左上角 + 对话生成页顶部，各加一个 `DropdownButton<ProviderKind>`（或复用 ModelManager 的 getRegisteredProviders 列表动态生成 Chip 选择器），选中 Provider 后把当前页的后续 chat/chatStream/workflow 调用全部指向用户选中的 provider；若选的是 RwkvCloudProvider，底层 `BaseAgent.executeTask` 里的 `chatInSession` 判断：如果 provider 是 RwkvCloudProvider 就走 RwkvCloudProvider 扩展 API（后面 24 项实现），否则走原来 RwkvProvider 的本地引擎 State。
   - 验收标准：切到「RWKV 云端」→ 发一条测试聊天 → 控制台 http 日志能看到请求头带 CF-Access-Client-Id/Secret 两个键 → `/openai/v1/chat/completions` 返回正常，TokenUsage 非空。

---

### P3（高并发方案，最大化 3×4090 的吞吐 = 核心价值项）

20. **Provider 层并发限流按「本地 llama / 云端 rwkvos / 第三方云 API」三档动态分级**
   - 背景：当前两处并发锁都写死保守值：
     - `RwkvProvider(globalConcurrency: 4)` → Semaphore(4)，防止本地 GPU 显存过载（单张消费级卡跑 7B 同时并发 4 已经是极限）
     - `TaskQueue(maxConcurrentTasks: 5)`（di.dart:L391）→ 工作流并行最多 5 条
     - 但对三张 4090 的 api-7b.rwkvos.com 来说，**并发 4/5 简直浪费（至少 16-24 并行才打满）**，当前并发上限会导致工作流（批量生成 8 Agent + 10+ 章节草稿）时 80% GPU 资源空转。
   - 改动：
     a. `RwkvCloudProvider` 构造函数不要加 `_globalSemaphore(4)`，直接改成 **Semaphore(24)**（24=3卡×8并发/卡；保守也给 16），理由：api-7b.rwkvos.com 是服务端限流，客户端并发越高吞吐越高（只要不是 1000 并发把 CF 打 429 就行）。先写死 24 到构造，后面 P4 阶段改成用户可配置。
     b. `lib/ai/workflow/task_queue.dart` 的 `maxConcurrentTasks` 改成**按 Workflow 的「主 Provider 类型」动态分配**：本地 RWKV→保留 5，云端 RWKV→升到 12，云 API(DeepSeek/Zhipu)→保留 5，Ollama→保持 3。实现方式：在 `NovelWorkflowEngine.executeWorkflow(..., {IModelProvider? primaryProvider})` 开头先拿 primaryProvider 的类型 → new 一个对应并发数的子 TaskQueue（不是全局的那个 di.dart 实例，是局部临时对象），整个 workflow 的任务全部走这个子 queue；全局 TaskQueue（di.dart）只保留给「用户不知道选啥 Provider 的兜底老 workflow」。
     c. `RwkvEngine` 的引擎级 `Semaphore(config.maxConcurrentSessions)` 也要分开：本地 llama server → 默认 4（写死），走云端 RwkvCloudProvider 的会话 → 引擎级默认开到 **12 并发 session**（不是推理并发，是 session 隔离数，12 个 Agent 并行互不阻塞地跑同一 workflow 的不同分支）。
     d. 所有 Semaphore 构造处加 Logger.info 打印：`RwkvCloudProvider init: globalConcurrency=24` 之类，方便用户 flutter logs 里能看到当前上限到底用了哪档，避免"调了半天根本没生效"的老坑。
   - 验收标准：跑「章节批量创作」工作流（10 章并发）→ 抓包/Wireshark 看同一秒内能发出 12 个并发 HTTP POST（而不是当前的 4/5 个就卡着排队）。

21. **RwkvCloudProvider 新增原生 batch API（`/v1/chat/completions` contents[]）封装 —— 把「8 个 Agent 各发 1 条」变「Server 端 1 次 batch 并行处理」**
   - 背景：rwkv_lightning_cuda 最大的性能特性就是原生 batch（同一条 HTTP 请求里 contents 传 8 条 prompt，Server 侧一次性 CUDA prefill 8 条，比 8 次独立 POST 的 8 次连接+8 次 prefill 快 2-4 倍）。当前 `IModelProvider.chat()` 是一条 Request 一条 Response 的单路接口，根本用不上这个特性；8 个 Character Agent 分别生成 8 个角色 profile，现在的做法是 TaskQueue 并行发 8 次 chat()，浪费了 api-7b.rwkvos.com 的 batch 能力。
   - 改动：
     a. 先在 `lib/ai/models/`（现有 chat.dart 旁边）新增 `batch_chat.dart`：
        - `RwkvBatchRequest`：`List<String> contents`、`int maxTokens`、`List<String> stopTokens`、`double temperature`、`int topK`、`double topP`、`double alphaPresence/alphaFrequency/alphaDecay`、`bool stream`、`int chunkSize`、`String? password`（留空，云端 rwkvos 用 CF Access 认证不用 JSON 密码）；默认值和 rwkv_lightning_api_doc.md §1.4 原生生成参数完全一致（temperature=1.0、top_k=50、top_p=0.6、alpha_presence=2.0、alpha_frequency=0.2、alpha_decay=0.996）。
        - `RwkvBatchChoice`：`int index`（和 contents 的输入位置一一对应，**千万别假定 Server 按输入顺序返回，SSE 是交错 index 的**，本地组装 Map<int,StringBuffer> 按 index 拼，最后转 List 时按 index 排序）、`String content`、`String finishReason`。
        - `RwkvBatchResponse`：`String id`、`String model`、`List<RwkvBatchChoice> choices`；流式 SSE 时每个事件是增量 delta。
     b. `RwkvCloudProvider` 里新增两个方法（**不要改 IModelProvider 契约，保持 IModelProvider 对老 6 Provider 兼容**）：
        - `Future<RwkvBatchResponse> batchChat(RwkvBatchRequest request)`：非流式一次性 POST 到 `$baseUrl/v1/chat/completions`（**不是 `/openai/v1/chat/completions`**，原生 batch 路由是 `/v1/chat/completions`，用 contents 不是 messages），body `jsonEncode(request.toJson())`，header 带 CF Access + `Content-Type: application/json`；返回解析成 RwkvBatchResponse。
        - `Future<RwkvBatchResponse> batchChatStream(RwkvBatchRequest request, void Function(int index, String delta) onDeltaChunk)`：SSE 流式，每条 `data: {...}` 解析取 `choices[].index` + `choices[].delta.content` → 调 `onDeltaChunk(index, delta)` 给上层 UI 逐 token 刷新对应 index 的结果框；内部 `ListQueue<Map<int,StringBuffer>>` 按 index 缓存，遇到 `[DONE]` 或全部 index 都 finishReason=stop 就返回聚合的 RwkvBatchResponse。
     c. 特别注意的两个坑：① **路由名两个 `/v1/chat/completions` 和 `/openai/v1/chat/completions` 很像但语义完全不同**，代码里要写常量 `const kRouteNativeBatchChat = '/v1/chat/completions'` 和 `const kRouteOpenAiChat = '/openai/v1/chat/completions'`，禁止写字符串字面量（写错 1 次就会把 contents 发给 OpenAI 路由，Server 返回 422 字段不合法，查一天查不出来）；② 原生 batch 的输入是 `contents`（String 数组纯 prompt）不是 OpenAI 的 messages（role/content 结构），调用前必须先把 `List<ChatMessage>` 按 NovelCraft 的「User: ... \n\nAssistant:」模板格式拼接成单条 String prompt，再塞 contents 数组——别想当然把 messages 直接塞进去，Server 会当 gibberish 生成毫无意义的内容。
   - 验收标准：构造一个 8 prompt 的 batch（每条 prompt=「生成修仙角色档案：门派=玄穹剑主第N代掌门」）→ batchChat() 一次调用返回 8 条完整 choice（index=0..7）→ 总耗时比 8 次独立 chat() 至少快 1.5 倍（8 次独立≈24s，batch≈16s 就算达标，实际应该能跑到 10s 以内）。

22. **8 Agent 工作流适配 batch API：把 8 个 Agent 的 system prompt 预拼后走一次 batchChat，把原有的串行/并行单请求替换成 batch 聚合执行器**
   - 背景：NovelWorkflowEngine 跑「项目初始化」工作流时，Director → 分 8 个小 task 给 8 个 Agent（Character/Plot/World 等），每个 task 执行 BaseAgent.executeTask → 内部各自发 1 次 chat()；现在有了 batch API，就能攒到 8 条一起发，Server 端并行处理。
   - 改动：
     a. 新增 `BatchAgentExecutor`（`lib/ai/workflow/batch_agent_executor.dart`），职责：收一批 `(BaseAgent agent, TaskContext ctx)` 对 → 对每个 Agent 先调 agent.buildPromptForBatch(ctx)（**需要给 BaseAgent 新增这个方法**，返回的是单条 String prompt = systemPrompt + userPrompt 按 rwkv_lightning 原生模板拼好的纯文本，不要用 OpenAI 的 messages 结构）→ 攒够 N 条（或等 100ms 超时窗口没新增就立即发，防止单条卡很久）→ 调 RwkvCloudProvider.batchChatStream() → 把收到的 delta index 反向映射回对应 agent 的 agentResultBuffer → 全部 index 完成后，调 agent.processAIResponse(choice.content) 做结构化解析 → 返回 `List<AgentTaskResult>`。
     b. BaseAgent 新增三个方法（注意是可选实现，默认非 batch 走老逻辑不破坏现有兼容）：
        - `bool get supportsBatch → true/false`：RWKV 家族 Agent 全部返回 true，其他（DeepSeek/Zhipu）返回 false。
        - `Future<String> buildPromptForBatch(TaskContext ctx)`：把 system prompt 和 user prompt（含当前项目上下文）拼成 rwkv_lightning 原生 batch 需要的单条纯文本 prompt，格式统一用 `System: {systemPrompt}\n\nUser: {userPrompt}\n\nAssistant:`；不要带 role JSON。
        - `Future<AgentTaskResult> processBatchResponse(String rawContent, TaskContext ctx)`：原来的 processAIResponse 是拿 ChatResponse.content，现在换成 batch 返回的 rawContent，逻辑不变，只是入口参数名改一下而已。
     c. `NovelWorkflowEngine.scheduleAgentTasks` 中加分支判断：如果 primaryProvider 是 RwkvCloudProvider **且** 当前所有 waitingTask 中的 agent 都 supportsBatch=true，就走 BatchAgentExecutor；否则走老的 TaskQueue 并发单请求（确保 Cloudflare 没配好 / Provider 没切对的老路径 100% 兼容）。
   - 验收标准：跑「项目初始化」工作流，从 Director 拆分任务到 8 Agent 全部生成结束，日志里能看到一条 `POST /v1/chat/completions contents.length=8`（不是 8 条 `/openai/v1/chat/completions`），总耗时从 ≈40s 降到 ≈20s 以内。

23. **RwkvCloudProvider 对接 Stateful 路由 + multi_state dialogue 分叉（= 利用 rwkv_lightning 的 L1/L2/L3 State Cache 做世界观分支并行推演）**
   - 背景：当前 NovelCraft 工作流的 State 复用是「单 session 线性推进」（一条 workflow 共享一个 sessionId，state 只能一路往后演化）；但用户明确要求「最大化并行」+ 参考 `agent.objects.rwkvos.com` 的多 Agent 能力——rwkv_lightning 有 `/state/chat/completions`（单 session 有状态复用）+ `/multi_state/chat/completions`（同 session 内分叉 dialogue_idx，用于「如果主角走正道路线 vs 走邪道路线」这种世界观分支），这是 Transformer 架构根本做不到的（Transformer 没有 O(1) state 延续，分叉只能重新 prefill 整段历史，RWKV 只要保存 state 字节就能随时续跑，分叉成本接近于 0）。
   - 改动：
     a. `RwkvCloudProvider` 新增 Stateful 路由方法（4 个）：
        - `Future<ChatResponse> statefulChat({required String sessionId, required List<ChatMessage> messages, ...})`：POST 到 `$baseUrl/state/chat/completions`，body 里塞 `session_id` + 单条 `contents[0]=拼接的prompt`；HTTP 头里同时传 `X-RWKV-Session-Id: $sessionId`（双保险，符合 rwkv_lightning_api_doc.md §8 中「session_id 既可以在 body 也可以在 header，冲突返回 400」的约定，但传两处不会冲突，只要两处值相同就行）。注意：一个 sessionId **绝不能并发 POST**，否则 Server 返回「会话状态锁冲突」类的错误（文档写了不要并发写同一个 session_id），因此单 session 内部仍套 Semaphore(1)（和本地 RwkvSession 的单会话串行锁语义完全对齐，复用现有 RwkvSession 抽象即可，不要重写一套）。
        - `Future<RwkvMultiStateResult> multiStateChat({required String sessionId, required int parentDialogueIdx, required List<ChatMessage> messages, ...})`：POST 到 `$baseUrl/multi_state/chat/completions`，body 塞 `session_id:$sessionId` + `dialogue_idx:$parentDialogueIdx` + `contents[0]=prompt`；返回解析成 `RwkvMultiStateResult(content:String, newDialogueIdx:int)`（非流式响应顶层直接带 new_dialogue_idx，流式要在 `[DONE]` 之前抓那个 type=multi_state.dialogue_idx 的 SSE 事件，千万别丢了，丢了下次分叉找不到 parent 节点）。
        - `Future<RwkvStateCacheStatus> stateCacheStatus()`：POST `$baseUrl/state/status` 拿 `total_sessions/l1_cache_count/l2_cache_count/database_count`，AI 配置页新增一个「云端 State Cache 概览」小面板展示给用户看（体现产品差异化）。
        - `Future<bool> stateDelete({required String sessionId, bool deletePrefix=false})`：POST `$baseUrl/state/delete`，用于用户主动关会话、切换 Provider、或 workflow 失败清理残留。
     b. 新增 `RwkvStateCacheStatus` / `RwkvMultiStateResult` 数据类（和 batch_chat.dart 放一起，别散），字段和 API 文档完全一致，不要自造。
     c. Workflow Engine 层适配：在 `WorkflowTask` 中新增字段 `List<WorkflowBranch>? branches`（每个 branch = `{String label, String promptOverride, Task onResult}`），当 Task.branches 不为空时，调 multiStateChat 传 parent_dialogue_idx=当前节点 → 每个 branch 拿一条分叉的新 dialogue_idx → 并行跑后续子 Task（例如世界观分叉「正道路线/邪道路线」，两条路的后续人物/情节 Agent 同时并行生成，真正吃到 RWKV O(1) state 分叉的低成本红利——这是 Transformer 路线的产品永远做不到的能力，要写注释标出来「这是 RWKV 架构独有能力，切换到其他 Provider 时 branches 自动降级为串行重新编码历史」）。
   - 验收标准：手动写一个小测试用例（在 AI 协作页加个 Debug 按钮也行，正式版不要暴露给用户），创建 sessionId=test-branch，dialogue_idx=0 发 prompt=「玄穹剑主第 10 代掌门继位」→ branches=[「走正道收徒」,「走邪道夺权」] → 能拿到两个 new_dialogue_idx（如 1/2）→ 用各自的 dialogue_idx 1 和 2 分别继续发后续 prompt → 两条路的后续生成内容世界观一致但剧情走向明显分叉，且两条并行生成延迟差 <500ms。

24. **RwkvCloudProvider 请求失败重试 + 批量失败重试（指数退避 + CF 429 限流处理）**
   - 背景：当前 `OpenAICompatibleProvider` 有 maxRetries 字段但实际上 chat()/chatStream() 里**根本没写 retry 逻辑**（只在构造里存了字段）；Cloudflare Access 前面还套了一层 CF 全球 CDN，突发流量会触发 HTTP 429（Too Many Requests）+ Retry-After header；并发 24 时一张 4090 短时爆显存也会 500/503；batch 请求只要其中 1 条 index 炸了就整个请求 fail 也太浪费。
   - 改动：
     a. 抽 `_withRetry<T>(Future<T> Function() request, {int maxRetries, String debugLabel})` 内部私有方法，重试触发条件：HTTP 429（读 Retry-After 秒数作为 sleep 下限，没传默认用指数退避 2^attempt 秒，首等待 1s）、502/503/504（网关层错误，必重试）、SocketException/TimeoutException（网络抖动重试）；不重试条件：400/401/403/404/413/422（业务参数错，重试毫无意义）。
     b. batch 请求部分失败的降级策略：如果返回 HTTP 200 但只有部分 index 有内容、其他 index 的 choice.content 为空（或 SSE 中某些 index 一直没 delta），就把「失败的 index 子集」再单独拼一个小 batch 做一次重试，重试成功后把缺失的 choice 填回原响应，向上层透明屏蔽部分失败（上层永远拿到完整 choices 列表），只有重试 2 次之后仍有失败 index 才抛 RwkvBatchPartialFailureException（带上失败的 indices 列表，供 UI 展示哪些 Agent 哪条没成功）。
     c. 失败日志必须结构化：`_logger.warning('RwkvCloud retry attempt=$attempt/$maxRetries after ${sleep}s for $debugLabel: statusCode=$code, retryAfter=$retryAfter')`，不要只扔一句「请求失败」。用户以后调 CF 限流策略需要看日志。
   - 验收标准：手动在网络层代理注入 throttle（抓包工具模拟 1 次 429 Retry-After=2），请求总耗时应比正常慢 2s 左右但最后成功，日志里刚好出现 1 条 retry attempt=1 的 warning，没有 RedErrorScreen。

---

### P4（体验增强与可维护性，P2/P3 通了之后再做）

25. **新增离线 rwkv_lightning_cuda 引擎支持（替代 llama.cpp，支持 PTH 模型 + W8A16 量化 + 原生 batch）**
   - 目标：让用户不想用云端、但本地有 NVIDIA 卡时，能在 NovelCraft 内一键安装并启动 `Alic-Li/rwkv_lightning_cuda` 的官方 release Windows 预编译包（不要再要求用户本地装 CMake + CUDA Toolkit 去 build，99% 用户不会）。
   - 参考 llama.cpp 的一键安装链路完全复用，新增一个 OfficialResources 的子模块（不要混到 llama.cpp 的老代码里）：
     a. `OfficialServerVariant` 枚举（rwkv_official_resources.dart:L5）新增 `rwkvLightningCuda12 / rwkvLightningCuda13 / rwkvLightningRocm6 / rwkvLightningCpu` 4 项，assetToken 分别取 `rwkv-lightning-cuda-12 / rwkv-lightning-cuda-13 / rwkv-lightning-rocm / rwkv-lightning-cpu`（具体命名等 v1.5.0 Windows 正式 release 出来后查 GitHub Releases 实际资产名，先写占位常量，拿到真名称立刻替换，写法和 llama.cpp 的 latest+10releases 候选+四段匹配完全一致，复用 fetchLatestServerBuild 内部的匹配逻辑即可）。
     b. 安装目录放 `rwkv_models/_tools/rwkv-lightning-<tag>-<variant>/`（和 llama.cpp 目录并列，不要互相覆盖）。
     c. **rwkv_lightning 启动参数和 llama.cpp 完全不同**（文档已附），不能共用一套 args。新增 `RwkvLightningLaunchArgs` 数据类，字段：`modelPath`（注意是 **PTH 格式 .pth/.rwkvq，不是 llama.cpp 的 GGUF**——GGUF 和 PTH 是两个完全不同的权重格式，不互通！这是最大陷阱，见 PITFALLS §27.1）、`vocabPath`（必须单独指定 `rwkv_vocab_v20230424.txt`，llama.cpp 的 GGUF 内嵌词表，rwkv_lightning 是外置单独文件，没传直接 startup crash，下载模型时要把词表也一并下到 `rwkv_models/_assets/rwkv_vocab_v20230424.txt`，若官方 Release asset 没有词表文件，就从仓库 raw.githubusercontent.com 直接下 txt 单独存）、`host`、`port`、`chunkSize`（128）、`chunkLoad=true`（强烈建议开，省显存，详见 run.md）、`stateDbPath`（会话 state SQLite，放 `rwkv_models/_tools/_states/rwkv_lightning_sessions.db`，避免卸载重装丢 state）、`password`（空）、`wkv32=false`。
     d. ensureLocalServer 内部按可执行文件的路径名判定是哪种（路径包含 `rwkv-lightning` → 走 LightningLaunchArgs，否则走 llama.cpp 的老 args），不要硬切换破坏兼容。
   - 验收标准：AI 配置页「官方资源一键安装」硬件版本下拉新增 rwkv-lightning 系列 → 点安装下载 release zip + 词表 → 启动 Server → testConnection HTTP 200 + ServerInfo 中 serverBackend=rwkv_lightning_cuda。

26. **新增 AI 健康检查页：当前 Provider 类型、并发上限、请求 QPS、失败率、State Cache 命中/L1/L2/L3 分布实时面板**
   - 目标：用户能一眼看到「我现在跑的是本地 llama 还是 云端 rwkvos？并发 4 还是 24？最近成功率多少？State 有多少命中了 VRAM L1？」——现在这些数据全在 logger 里，普通用户根本看不到。
   - 改动：AI 配置页底部新增「运行统计」旁边的 Tab，或独立子页面，面板分三块：
     a. Provider 概览：当前选中 Provider 名、类型（本地/云端/Ollama/云 API）、基础域名、模型名、并发上限（Semaphore 的 _max 值，得暴露 getter 别一直写死）。
     b. 请求吞吐：最近 60s 的滚动 QPS 折线（采样 1s 1 次，Dart 画折线不用引 charts 包，用 CustomPainter 手写 100 行够用了，引第三方包会炸 Web 编译大小）、成功数/失败数饼、平均响应时间 p50/p95（算 percentiles，别只给平均，p95 长尾对 batch 工作流影响极大）。
     c. State 诊断（仅 RWKV 系列 Provider 显示）：当前活跃 session 数、cache 条目数、L1/L2/L3 各自命中次数百分比（给 RwkvStateCache 加命中计数器，每次 get 命中就 inc hitCountL1，RAM 降级再 inc L2，DB 读再 inc L3）。
   - 价值：用户以后说「生成好慢」，先让他看这页，一眼就能知道是「并发上限设低了排队」还是「State 没命中 L1 每次都重 prefill」还是「云端 CF 429 重试」，不用来回发日志来回问。

27. **Agent 对话草稿自动 State 存档 + 恢复**（用于用户手滑关 App 再进来继续写同一章节）
   - 对接 `RwkvEngine.takeSnapshot/restoreSnapshot` 和 RwkvCloudProvider 的 `state/status`、`state/delete`，在 Workflow 每完成一个节点就把 session 当前 state 快照字节写 KeyValueStore(scope=internal, key=snapshot_${sessionId}_${task.nodeId})，下次重开自动 restore 不用重编码几 MB 的历史 prompt 文本。

28. **8 Agent 配置页：用户手动指定哪些 Agent 要 batch 聚合、哪些要独立请求**
   - 现在 P3 第 22 项是全支持 batch 的 Agent 一起 batch，但用户可能说「Director 的 prompt 特别长不适合和其他短 prompt 一起 batch（会被长 prompt 拖慢整个 batch 的首 token 时间）」，所以给每个 Agent 一个开关 `batchGroupId`，相同 groupId 的 Agent 才放一批，不同 groupId 分开。

29. **把 P3 的 batch API 做成通用接口**（`IBatchChatModel` mixin），后续如果引入其他原生 batch 能力的推理服务（比如本地 rwkv_lightning_cuda v1.5.0 也支持 batch），只要 with 一下这个 mixin 就能自动拿到 BatchAgentExecutor 的工作流聚合，不用重写一遍。

30. **单元测试 & 集成测试**：
   - 单测：RwkvCloudProvider 的 header 组装正确（发请求前用 mock HttpClient 验证 CF Access 两个头拼对了、大小写正确）、_withRetry 指数退避行为正确、batch SSE 按 index 聚合不会乱序。
   - 集成测试：连真实 api-7b.rwkvos.com 发最小 batch 2 条 ping prompt（contents=['ping1','ping2']），返回 2 条 choice，HTTP 200 不超时。
   - 注意：测试文件全部放 `integration_test/` 下，不要放 test/（test/ 是纯 Dart 单测无网络）。

## 7. 文件地图（核心入口）

> 更新：2026-09-14 · 签署：TRAE-NovelCraft-Bot（第九次签署）

### LOGO 分发清单（源：`F:\30_Novelcraft_Flutter\novelcraft_en\icon.ico` / 脚本：`F:\30_Novelcraft_Flutter\deploy_icon.ps1`）

| 平台 | 尺寸 / 数量 | 目标路径 |
|---|---|---|
| Windows | ICO（含多档内置尺寸）| `windows/runner/resources/app_icon.ico` |
| Web PWA | 192 / 512 ×2 (maskable) = 4 PNG | `web/icons/Icon-192.png` `web/icons/Icon-512.png` `web/icons/Icon-maskable-192.png` `web/icons/Icon-maskable-512.png` |
| Web Fav | 32×32 PNG + ICO | `web/favicon.png` `web/favicon.ico` |
| Android launcher | mdpi 48 / hdpi 72 / xhdpi 96 / xxhdpi 144 / xxxhdpi 192 = 5 PNG | `android/app/src/main/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png` |
| iOS AppIcon | 20/29/40/60 × @1x@2x@3x + 76@1x@2x + 83.5@2x + 1024@1x = 15 PNG | `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-{size}@{scale}.png` |
| macOS AppIcon | 16/32/64/128/256/512/1024 × 基础档 + @2x Retina = 14 PNG | `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}(@2x).png` |

- 依赖装配：`lib/core/di.dart`（Repository + Service + Store + Database + AI 层 + **appBootstrapProvider（KVStore + seeding）** 全部 provider；`NovelWorkflowEngine(rwkvProvider: ref.read(rwkvProvider))` 同一单例跨 Agent/Workflow 共享）
- 表定义：`lib/data/tables/*.dart`，生成代码 `lib/data/database.g.dart`
- 页面模板：`lib/ui/pages/entity_page.dart`、`lib/ui/pages/world_system_page.dart`
- 页面配置：`lib/ui/pages/entity_configs.dart`、`lib/ui/pages/system_configs.dart`
- 外壳/导航：`lib/ui/layout/app_shell.dart`（世界观二级导航 + **AI 助手二级导航 4 项**）、`lib/ui/layout/navigation.dart`（新增 `aiGroupTargets`）
- 入口：`lib/main.dart`（新增启动屏 `_BootLoadingPage` + 错误页 `_BootErrorPage`）
- Seeding：`lib/application/services/database_seeder.dart`（DatabaseSeeder，玄穹剑主修仙模板 27 表事务批量插入约 110 行，KeyValueStore(internal,seed_version)=seeded-v1 幂等，回调式 db.batch API，flutter analyze 0 已验证；首次启动未种过时自动写入，后续不重复插）
- AI Agent 实现：`lib/ai/agents/agents.dart`（8 Agent 完整实现：Director / Writer / Character / Plot / World / Reader / Summarizer / Editor，含 `parseMarkdownSections` 公共辅助 + 修仙题材 system prompt + 本地 fallback）
- **RWKV 推理引擎（新增 10 文件：引擎 6 + 官方资源 Bridge 4）**：
  - State 抽象：`lib/ai/rwkv/rwkv_state.dart`（RwkvState opaque + RwkvStateCache LRU + rwkvGenerateId）
  - Session 抽象：`lib/ai/rwkv/rwkv_session.dart`（RwkvSession + RwkvSessionManager + Semaphore(1)）
  - 模型扫描（条件导出 3 份）：`lib/ai/rwkv/rwkv_models.dart`（数据结构 + 导出入口）、`lib/ai/rwkv/rwkv_model_scanner_stub.dart`、`lib/ai/rwkv/rwkv_model_scanner_native.dart`、`lib/ai/rwkv/rwkv_model_scanner_web.dart`
  - 核心引擎：`lib/ai/rwkv/rwkv_engine.dart`（RwkvEngine 中枢：Session/State/InferenceLauncher/ModelScanner 组合 + **toMap/fromJson 序列化**（Duration 转秒 int））
  - Provider 层：`lib/ai/providers/rwkv_provider.dart`（RwkvConfiguration 3 参数契约 + RwkvProvider IModelProvider + 扩展 API openSession/closeSession/chatInSession/listLocalModels/launchLocalServer + **toMap/fromJson 6 字段序列化** + 官方资源 installLlamaServer/downloadOfficialModel 透传 onHandleReady）
  - 官方资源 Bridge（条件导出 4 份）：`lib/ai/rwkv/rwkv_official_resources.dart`（公共类型：RwkvDownloadProgress/RwkvServerBuildInfo/RwkvOfficialModel/ OfficialServerVariant 枚举 + RwkvCancelHandle 抽象 + Bridge 方法签名）+ **stub/native/web 三条件导出**（native GitHub Releases + HuggingFace API 真实调用 + Range 断点续传 + 500ms 节流速度/ETA + PowerShell Expand-Archive 解压；stub/web 抛 UnsupportedError）
  - 取消 / 互斥锁（native）：`lib/ai/rwkv/rwkv_official_resources_native.dart`（`_NativeCancelHandle`：isCancelled + cancel([reason]) + onCancelled 回调链 + throwIfCancelled；`_installInProgress/_downloadInProgress` 布尔互斥；`_downloadFileWithProgress` onCancelled 同步关 StreamSubscription/IOSink/http.Client，**取消后保留 .part 文件**，下次走 Range 断点续传）
  - Agent 接入：`lib/ai/agents/agent.dart`（BaseAgent 三级 sessionId 解析 + tryExecute/tryExecuteWithRwkv 两入口 chatInSession + stop/reset/dispose 自动关 session）
  - Workflow 接入：`lib/ai/workflow/workflow_engine.dart`（workflow 级 session 共享：id 塞 workflow.configuration + 每个 task.parameters.putIfAbsent + 四分支 _cleanupSession（成功/失败/取消/dispose）；dispose 兜底清全部残留）
- AI 助手页（4 个）：
  - 协作创作：`lib/ui/pages/ai_collaboration_page.dart`（自由聊天流式 + 4 工作流执行 + 可视化进度）
  - AI 配置：`lib/ui/pages/ai_configuration_page.dart`（5 Provider 注册 + 默认模型切换 + 统计 + 连接测试；**RWKV 本地面板**：硬件版本下拉（CPU/Vulkan/CUDA12/13/HIP/SYCL/ARM64）+ 本地模型扫描下拉 + 启动 Server 按钮 + 官方一键安装/下载进度块（右上角取消按钮）+ **KVStore 双 scope 持久化（启动加载 / 4 写入挂点）**）
  - 对话生成：`lib/ui/pages/dialog_generation_page.dart`（真流式生成 + 质量评分 + 保存章节草稿 + md/txt/json 导出 + 模板存读）
  - 项目健康检查：`lib/ui/pages/project_health_check_page.dart`（本地 11 条规则 + AI ConsistencyCheck 工作流 + 严重性排序 + 跳转定位）
- **本地 RWKV GGUF 模型目录**：`rwkv_models/rwkv7-g1j-7.2b-Q6_K.gguf`（用户手动下载，7.2B Q6_K，llama.cpp/rwkv.cpp 服务端可直接 --model 参数挂载；`.gitignore` 已排除 `rwkv_models/_tools/*.exe/dll/zip/part/tmp`，二进制不进 git）
- **build web 纯英文 junction**：`F:\30_Novelcraft_Flutter\novelcraft_en` [Junction → `F:\30_Novelcraft_Flutter\Flutter版代码\novelcraft`]，在此路径执行 `flutter build web --no-pub --release` 绕开 PITFALLS §24.3 impellerc 中文路径 bug，exit 0
- **技术参考**：`RWKV_核心技术项目参考列表.md`（9 条官方 RWKV v7 参考：RWKV-LM v7 numpy/qwen 推理 / Albatross / DPLR 数学 / rwkv-mobile / RWKV.com JS / 搜索排榜 / SearchReader）

---

### RWKV 云端 + 高并发新增文件坐标（P2/P3/P4 待开发，路径预约定 + 职责边界，避免乱建）

| 优先级 | 文件路径 | 职责 · 设计约束 · 依赖关系 |
|---|---|---|
| P2 18c | `lib/ai/providers/rwkv_cloud_configuration.dart` | RwkvCloudConfiguration 数据类：7 字段 `baseUrl / defaultModel / defaultMaxTokens / cfAccessClientId / cfAccessClientSecret / customHeaders(Map) / connectTimeout`；**toMap/fromJson 必须包含**（KVStore 持久化序列化用）；`cfAccessClientSecret` 存 KV 时若平台支持 flutter_secure_storage 优先用，否则存普通 KV + 标注日志 `WARNING: storing CF secret in plain KV` |
| P2 18c | `lib/ai/providers/rwkv_cloud_provider.dart` | **独立实现 IModelProvider，组合内部 `OpenAICompatibleProvider _oai` 做单路 `/openai/v1/chat/completions` 调用；绝不 extends RwkvProvider（会继承 20+ 本地进程启动废字段）**；构造参数 `globalConcurrency=24`（三张 4090 集群）；自定义 `_headersForRequest()` 注入两个 CF Access 头（const 常量名禁拼错）+ X-RWKV-Session-Id / X-RWKV-State-Id（若有）；扩展 `batchChat / batchChatStream / statefulChat / multiStateChat / stateCacheStatus / stateDelete` 6 个 rwkv_lightning 独有方法（§P3 21/23 用）；`dispose()` 关内部 http.Client |
| P2 18d | `lib/core/di.dart` 追加 2 行 | ① `rwkvCloudConfigurationProvider = Provider<RwkvCloudConfiguration>`（从 KVStore(ai.rwkvCloud.cfg) 反序列化，缺省值 baseUrl=`https://api-7b.rwkvos.com` + model=`rwkv7-g1j-7.2b-20260831-ctx16384`）；② `rwkvCloudProviderInstanceProvider = Provider<RwkvCloudProvider>`（构造时传上面的 config）；**workflowEngineProvider 与 allAgentsProvider 必须注入同一个实例**（ref.read 同一份，防止 workflow 拿一份 agent 拿另一份造成 state_id 错位——第八签老坑复现） |
| P3 21 | `lib/ai/models/batch_chat.dart` | 3 个公共数据类 + 2 个路由常量：`RwkvBatchRequest(model, contents<String[]>, temperature, top_p, stream, ...sampler)` / `RwkvBatchChoice(index, message, finish_reason)` / `RwkvBatchResponse(id, model, choices<RwkvBatchChoice[]>, usage)`；**const 路由名**：`kRouteRwkvNativeBatch = '/v1/chat/completions'`（contents[] 原生 batch）、`kRouteRwkvOpenAiChat = '/openai/v1/chat/completions'`（messages[] OAI 兼容）；禁在别处写字面量字符串，防止写串路由炸 422 |
| P3 22 | `lib/ai/workflow/batch_agent_executor.dart` | BatchAgentExecutor：构造参 `int maxBatchSize=8 / Duration batchWaitWindow=const Duration(milliseconds: 100) / RwkvCloudProvider provider`；对外 `Future<Map<BaseAgent,AgentTaskResult>> submit(BaseAgent agent, WorkflowTask task)` → 内部攒批（等 maxBatchSize 到齐或 100ms 窗口到期谁先触发）→ 各 agent 调 `buildPromptForBatch(task)` 拼成 pure text → 单次 POST `provider.batchChat(contents: prompts[])` → SSE delta 按 `choices[].index` 反向映射（Map<int,StringBuffer> 缓存，因为 SSE 到达顺序无序，不能假定 0→1→2）→ 全部完后按 index 排序调 `agent.processBatchResponse(task, rawText)` 结构化；构造时 Logger.info 打 `BatchAgentExecutor init: maxBatchSize=$maxBatchSize window=$batchWaitWindow` 方便档位自查 |
| P3 23 | `lib/ai/workflow/workflow_branch.dart` | WorkflowBranch 数据类：`String branchId / String parentStateId / Map<String,dynamic> parameters / int dialogueIdx` + WorkflowTask 追加 `List<WorkflowBranch>? branches` 字段；世界观分支用：同一 workflow.sessionId 下 dialogue_idx 分叉多条剧情线并行发 `multiStateChat()`；RWKV 独有 O(1) state 分叉（DeepSeek/Zhipu 等 Transformer Provider 自动降级为串行重编码 + 空 branches），降级时 Logger.warning 打 `Provider ${provider.runtimeType} does not support O(1) state branching, falling back to serial re-encode` |
| P4 25 | `lib/ai/rwkv/rwkv_lightning_launch_args.dart` | RwkvLightningLaunchArgs：与 llama.cpp 的 LlamaLaunchArgs 平级，不混用；字段 `String modelPath(.rwkvq/.pth 禁 .gguf) / String vocabPath(rwkv_vocab_v20230424.txt 外置必传) / String host / int port / int ctxSize / int nGpuLayers / int l1VramCacheSessions(16) / int l2RamCacheSessions(64) / String? l3SqlitePath`；**ensureLocalServer() 构造前必须硬校验**：modelPath 后缀是 .gguf → 直接 return false 写诊断 `rwkv_lightning only consumes .rwkvq/.pth + external vocab, got GGUF which is llama.cpp format (see PITFALLS §27.1)`；vocabPath 文件不存在或大小 < 500KB → 诊断 `vocab missing, download from GitHub raw (see HANDOFF §9)` |
| P4 25 | `lib/ai/rwkv/rwkv_official_resources_native.dart` 追加 OfficialServerVariant.rwkvLightning 枚举分支 | 官方资源下载新增：① `_rwkvLightningRepos = ['Alic-Li/rwkv_lightning_cuda']`；② fetchLatestServerBuild 匹配资产名含 `win-cuda` / `windows` 且后缀 `.zip`（CI 持续构建，稳定 tag 优先 v1.5.0+，缺则 fallback nightly）；③ 新增下载器 `downloadRwkvVocab()` → 目标路径 `rwkv_models/_assets/rwkv_vocab_v20230424.txt`，URL const `kRwkvVocabUrl`（§9 给的 raw 地址），单独 Range 续传；④ `rwkvOfficialModels` 列表新增 5 条 PTH/.rwkvq 版本（7.2B W8A16 / W4A16 / FP16 等，从 Alic-Li Releases 或 HF 镜像拉真实 URL，别写死 BlinkDL 仓） |
| P4 26 | `lib/ui/pages/ai_health_dashboard_page.dart`（新页面，挂 app_shell.dart 二级 AI 导航第 5 项） | AI 健康检查实时面板：① 顶部 Provider 概览 6 卡（本地 RWKV / 云端 RWKV / DeepSeek / Zhipu / Ollama / Custom）各显 当前 concurrency / 60s QPS / p50/p95 latency / 状态灯绿黄红；② RWKV 云端专卡：State Cache L1/L2/L3 命中率（拉 `stateCacheStatus()` JSON）/ batch 成功数 / 部分失败降级数；③ 折线图用 `fl_chart`（先查 pubspec.yaml 有无，没有就加 `fl_chart: ^0.69.0`），禁自己手动画 Canvas |
| P4 28 | `lib/ai/agents/batch_agent_mixin.dart`（IBatchChatModel mixin 抽象） | `mixin IBatchChatModel on BaseAgent`：强制子类实现 `bool get supportsBatch`（默认 false，Director / Writer / Character / Plot / World 5 个写作 Agent override 成 true，其他 Reader/Summarizer/Editor 因为要上下文依赖就 false）、`String buildPromptForBatch(WorkflowTask task)`（把 system+user 拼成 pure text，纯文本不含 role，因为 native batch 走 contents[] 不是 messages[]）、`AgentTaskResult processBatchResponse(WorkflowTask task, String rawText)`（把服务端返回的裸文本套成 structured result，和老 executeTask() 输出格式一致）；**mixin 方式不继承**，以后加新 Agent 只需 with + override 3 方法就能接 BatchAgentExecutor |
| P4 30 | `integration_test/rwkv_cloud_integration_test.dart` | 集成测试三必过用例：① `testConnection()` GET /v1/models 带 CF 头 → HTTP 200 / JSON 有 data[0].id；② `batchChat_2items()` contents=['ping1','ping2'] → 2 条 choice index 0/1 全有、finish_reason='stop'；③ `withRetry_429backoff()` mock HttpClient 第一次返回 429 + Retry-After:1 → 第二次 200 → 验证总耗时 ≥ 1s；放在 `integration_test/` 目录，**别放 test/**（test/ 无网络、无浏览器、Windows 下 `flutter test integration_test/rwkv_cloud_integration_test.dart -d windows` 才能跑） |
| L10n 同步 | `lib/l10n/strings.g.dart` 追加约 18 条新 key | 前缀 `aics.`（AI Configuration Rwkv Cloud）：`aics.rwkvCloudTab` / `aics.baseUrl` / `aics.defaultModel` / `aics.cfAccessClientId` / `aics.cfAccessClientSecret` / `aics.showSecret` / `aics.hideSecret` / `aics.testConnection` / `aics.connecting` / `aics.connectionOk` / `aics.connectionFailedHtml`（CF 302/403 HTML 拦截时的人类可读提示）/ `aics.concurrencyLevel` / `aics.batchSize`；zh/en 双表同步写（遵守 PITFALLS §26.3 无中文 fallback 陷阱），写完用 §26.3 的 reverse diff PS 脚本验差集为空 |

### 第十轮新增文件坐标（2026-09-17，路径已落盘，别再另建同名概念）

| 文件 | 职责 |
|---|---|
| `lib/ai/utils/chapter_intent.dart` | 关联模式下的输入意图判定（处理要求 / 提问 / 取消关联），对应 C# `LooksLikeChapterQuestion` + `ChapterOpKeywords` |
| `lib/ai/utils/segment_rewrite.dart` | 长文分段改写纯函数集（切片 / 拼接 / 尾部截取 / 复读检测 / 提示词组装 / 切片清洗） |
| `lib/application/services/chapter_revision_service.dart` | 关联章节改稿：改写 / 续写 / 按梗概成文 / 章节问答 → 回写 `Chapter.Content` |
| `lib/ui/state/chapter_referral.dart` | 关联状态（书/卷/章 + 处理模式），全局单例 + KVStore `copilot/chapter_referral` |
| `lib/ui/state/copilot_chat_log.dart` | 聊天记录，全局单例 + KVStore `copilot/chat_log`（限长 60 条 / 6 万字） |
| `tool/verify_chapter_intent.dart` | 意图判定验证 43 条 |
| `tool/verify_segment_rewrite.dart` | 分段工艺验证 49 条 |
| `integration_test/chapter_revision_test.dart` | 边聊改稿全链路（AI 打桩）23 条：改稿/续写/成文/问答/闸门/分段/持久化/UI 接线 |
| `integration_test/chapter_revision_live_test.dart` | 真模型验收 3 条（连通性 + 真改写 + 真问答） |

## 8. 配套工具

- `tools/csv_to_dart.py`：3664 条本地化词条 CSV → `lib/l10n/strings.g.dart`
- `tools/cleanup.py`：批量清理悬空库文档注释告警
- `tools/build_windows.log` / `cmake_*.log`：构建排障临时日志（可删）

---

## 9. RWKV 新生态参考 & 集成要点（2026-09-14 新增，对班不用翻对话历史）

### 9.1 外部仓库坐标（本轮新增 10-12 号参考，别和旧的 1-9 混）

1. **rwkv_lightning_cuda（核心引擎 v1.5.0，2026-09-13 发布，CI 日更）**：
   - 仓库：<https://github.com/Alic-Li/rwkv_lightning_cuda>
   - 中文 API 文档（1121 行，必读，路由名全在这里面）：<https://github.com/Alic-Li/rwkv_lightning_cuda/blob/main/docs/http-api.zh-CN.md>
   - Windows 构建/运行指南：<https://github.com/Alic-Li/rwkv_lightning_cuda/blob/main/docs/windows-build-run.md>
   - 启动运行（中文）：<https://github.com/Alic-Li/rwkv_lightning_cuda/blob/main/docs/run.zh-CN.md>

2. **RWKV Agent 平台参考（多 Agent 并行 + state 分叉最佳实践）**：
   - 中文站：<https://agent.objects.rwkvos.com/zh>
   - 参考点：世界观分支 O(1) state 分叉、Batch 多 Agent 攒批、三级 Cache 命中率面板、Workflow 级 session 共享

3. **线上测试集群（三张 4090，当前开发/测试唯一真实端点）**：
   - 基础 URL：`https://api-7b.rwkvos.com`（结尾**不带斜杠**，代码里 URI.parse 前要 strip 掉用户输入的尾斜杠，否则拼 `/v1/chat/completions` 变双斜杠 `/v1//chat` 部分反向代理会 404）
   - 默认模型名（2026-09-13 实测 `/v1/models` 返回）：`rwkv7-g1j-7.2b-20260831-ctx16384`
   - 注意 `/v1/models` 返回 `owned_by: "rwkv_lighting_cuda"`（**少了一个 t**，lightning → lighting），代码匹配时别写死全等比较，用 `toLowerCase().contains('rwkv')` 宽松判断即可，写死全等会判成未知 Provider

### 9.2 Cloudflare Access 双向认证头语义（精确到每个字符，别改）

> 这两个头名是 Cloudflare Access 约定的**全局固定 camelcase 拼写**，改大小写或换分隔符 CF 直接不认，返回 302 跳 cloudflareaccess.com 登录页 HTML（不是 JSON）

| Header 名（const 常量，禁字面量） | 本项目测试环境值（仅开发/测试，正式生产必须由用户输入，别硬编码进代码） | 语义 |
|---|---|---|
| `const kHeaderCfAccessClientId = 'CF-Access-Client-Id'` | `<REDACTED>` | Cloudflare Access mTLS 客户端 ID（Service Token 颁发，经 --dart-define 传入） |
| `const kHeaderCfAccessClientSecret = 'CF-Access-Client-Secret'` | `<REDACTED>` | Cloudflare Access mTLS 客户端 Secret（Service Token 颁发，经 --dart-define 传入） |

校验拦截代码（写在 RwkvCloudProvider.testConnection() 第一行就加）：
```dart
final resp = await _client.get(...);
if ((resp.statusCode == 302 || resp.statusCode == 403) && resp.body.startsWith('<')) {
  // CF 不认头，返回 HTML 登录页，直接 jsonDecode 会 FormatException 炸 RedErrorScreen
  throw RwkvCloudAuthException(
    'Cloudflare Access 认证失败（返回 HTML 非 JSON）。请检查 CF-Access-Client-Id / CF-Access-Client-Secret 拼写大小写正确、值未过期。原始响应前 200 字符：${resp.body.substring(0, min(200, resp.body.length))}',
  );
}
```

### 9.3 PTH(.rwkvq) vs GGUF 格式选型对照表（离线引擎最容易搞混的核心区别）

| 维度 | llama.cpp / RWKV 本地引擎（现有保留） | rwkv_lightning_cuda 离线引擎（P4 25 新增） |
|---|---|---|
| 权重文件后缀 | `.gguf`（**内嵌词表**，头里有 vocab 区，不需要外置 txt） | `.pth`（FP16 原始）/ `.rwkvq`（W8A16/W4A16 量化，**不含词表**，外置必传） |
| 外置词表文件 | 不需要，加载 GGUF 自动读头 | **强制需要** `rwkv_vocab_v20230424.txt`，启动参数 `--vocab-path <abs>`，缺就报 `vocabulary not loaded` 直接 crash |
| 词表下载地址 | 无（GGUF 自带） | 固定 Raw 地址（版本不变就不动）：<https://raw.githubusercontent.com/Alic-Li/rwkv_lightning_cuda/main/assets/rwkv_vocab_v20230424.txt> |
| 权重文件下载 | shoumenchougou/RWKV7-G1j-7.2B-GGUF（5 量化版本） | Alic-Li/rwkv_lightning_cuda Releases Assets（或其 HF 镜像仓），找 `.rwkvq` 后缀 |
| 传错格式现象 | GGUF 路径传给 rwkv_lightning → 启动报 `invalid model format: not a valid .pth/.rwkvq file` 后 crash；反之 PTH 传给 llama.cpp → `unknown model file type` 无法加载 |
| 本项目存储目录约定 | `rwkv_models/*.gguf`（保留现有） | `rwkv_models/_assets/rwkv_vocab_v20230424.txt`（词表单独目录）+ `rwkv_models/lightning/*.rwkvq`（lightning 权重单独子目录，和 gguf 混放扫描时容易扫错） |

### 9.4 RWKV 四层并行 API 路由速查（只列小说创作有用的，其余 FIM/translate 忽略）

路由名全部定义为 const 常量在 `lib/ai/models/batch_chat.dart`，禁止字面量字符串拼 URL：

| 能力层 | HTTP 方法 · 路由 | 请求体核心字段 | 返回语义 · 典型场景 |
|---|---|---|---|
| L1 原生 Batch（吞吐最高，GPU 利用率从 20%→90%） | **POST** `/v1/chat/completions` | `model: String`, `contents: String[]`（纯文本数组，**不是 messages role/value 对象**）, `temperature`, `top_p`, `top_k`, `stream: bool` | BatchAgentExecutor 攒 8 个 Agent prompt → 一次请求；返回 `choices[]` 每条带 `index` 字段；**SSE 流式时 index 交错无序，必须按 index 分组缓存**（PITFALLS §27.3） |
| L2 OpenAI 兼容单路（已有 Provider 零改动复用） | **POST** `/openai/v1/chat/completions` | `model: String`, `messages: {role,content}[]`, `stream: bool`（和 DeepSeek 完全一致） | 单路对话 / 用户自由聊天；RwkvCloudProvider 内部组合 `OpenAICompatibleProvider` 直接调用，代码无需重写 |
| L3 Stateful 单会话线性（长篇小说单 session 推进） | **POST** `/state/chat/completions` | `X-RWKV-Session-Id` 请求头 + 同 L1 或 L2 body | Session 级 state 存在 L1 VRAM，不用每次重新 prefill 前面 1w+ 字历史；长篇连载章节推进专用 |
| L4 MultiState 分叉（世界观分支并行推演） | **POST** `/multi_state/chat/completions` | `X-RWKV-Session-Id` + `dialogue_indices: int[]` + 同 L1 body | 同 session 内 O(1) 分叉多条剧情线（BE/A线/B线/C线），只需存 state 字节差，不用重跑 prefill；世界观并行推演 P3 23 核心 |
| 辅助：缓存状态 | **GET** `/state/status` | （无 body） | 返回 L1/L2/L3 三层 session 数 + 命中率；健康检查面板 P4 26 拉取 |
| 辅助：删除缓存 | **DELETE** `/state/{session_id}` | （无 body） | 工作流结束清理 L1 state，避免三张 4090 L1 16 槽被占满 |

---

## GLM 增量（2026-09-27 晚，分支 `glm/contribution-v1`，5 个提交）

接手者注意：以下改动已全部通过 `flutter analyze 0 issue` + 测试 **116/116**（基线 95 → 新增 21 个）。

### 已修复（对应本文件「已知遗留」编号）

| 项 | 内容 |
|---|---|
| 遗留#2 | 两处忙等（`waitForPermit` 200ms / `TaskQueue` 门控 100ms）全部改**事件驱动唤醒**：`leaveInFlight`/`noteSuccess`/`invalidate`/`setMaxConcurrentTasks`/任务完成/清空都会主动唤醒等待者；保留周期兜底（1s / 500ms）覆盖「容量探测升档无本地事件」场景。`invalidate()` 此前不清醒等待者已补 |
| 遗留#4 | 分派规划器 `configuredFallback` 读引擎配置 `maxConcurrentSessions`（原硬编码 16，小显存设备配置被无视） |
| 遗留#5 | `WorkflowEngine` 用 try/finally 保证**工作流结束恢复 TaskQueue 原并发**并调用 `clearFinishedState()`（`_completed`/`_completion` 随每次执行无限增长的慢性泄漏） |
| 遗留#7 | 聊天页新增「清空会话」入口：`CopilotChatLogController.clear()` 清 KVStore + 重置开场白；头部按钮带确认对话框；键 `AC.ClearChat`/`AC.ClearChatConfirm` 双语 |
| 遗留「门控下沉」 | `RwkvBatchClient.postJson`（/state/* 等非批量路由）+ `RwkvEngine.rawCompletion`（引擎唯一绕过 `_semaphore` 的入口）全部接入许可闸——**现在没有任何推理路径绕过并发门控** |

### 新发现并修复（审查所得）

- **TaskQueue 僵尸任务**：门控/依赖等待中的任务 `cancel()` 在 `_running`/`_pending` 两处都查不到 → 返回 false 且任务照样执行。新增 `_tracked` 注册表覆盖「已派发未终态」全生命周期。
- **取消态被覆盖**：runner 返回/异常路径无条件写 completed/failed，会覆盖运行中置的 cancelled。现已保留用户取消语义。
- **3 处 `return Future` 未 await**（agent.dart ×2 / rwkv_engine.dart ×1）：异步解析异常成为未处理异步错误，精心设计的 catch/降级链全部失效。
- **AIOutputSanitizer 缺聊天模板 token 清理**：`<|im_start|>`/`<|im_end|>`/`<|endoftext|>` 偶发泄漏（C# 版真机冒烟实证同款），已按 C# 版语义移植（含 `im_end` 紧跟 `im_start` 的模板续写截断）。

### 新增测试（21 个）

`task_queue_test`（6）、`rwkv_concurrency_test`（3）、`output_sanitizer_test`（9）、`copilot_chat_log_test`（2）、`postjson_gate_test`（1）——全部为纯 Dart/假实现，无需真端点。

### 仍待做

- 遗留#8（页面导航状态）：`_buildPage` 每次 new Widget，滚动位置/未保存草稿在切页后丢失——需 IndexedStack/KeepAlive 或 per-scope 状态托管，**涉及 UI 布局重构，建议 Windows 真机配合验证**
- think 预算自适应（g1j `mdlet` 块白吃 max_tokens 的长期解）
- `rwkvMaxConcurrentSessions` 在 AI 配置页的说明文案与实际生效链路的对齐核对

### GLM 第二批（阅读视图 + 选节 AI + 响应式排版，commit 4ee8ec5/94478ef）

**用户需求**：卷宗区域阅读正文 / 正文选节 AI 润色扩写续写 / 屏幕自适应智能排版。

- **GUI 自动化测试落地**：`gui_pages_test.dart` —— 35 页 × 3 视口（800×600/1600×900/420×800）渲染 + RenderFlex 溢出自动检测 + 新建项目交互链路；内存库 + 假 KV 接管真实启动链（突破此前刻意绕开的限制）。**首扫抓出 4 处布局缺陷并修复**：两处二级导航 ListTile 被 ColoredBox 遮挡（3.47 新断言，94 失败的根因）、AI 配置页 4 个 SwitchListTile 同款、参数面板标题行与健康页按钮组窄视口溢出。
- **选节 AI 助手**：`chapter_ai_panel.dart` —— SelectionArea.onSelectionChanged 捕获选区 → 润色/扩写/续写 + 附加要求 → 默认 provider 非流式调用（无服务明确指引）；原文/结果对照 + 复制；空选区引导。预览为只读快照，写回职责留编辑表单。
- **智能排版**：正文列宽视口断点（≥1600→960 / ≥1200→840 / ≥900→760 / 窄屏全宽）+ 居中 + 字号 13-24 钳制；空正文占位时 AI 开关禁用。
- **测试**：新增 chapter_reading_test 6 用例（面板契约/响应式断点/字号钳制/空态禁用）；累计 **123 用例 + 1 skip，analyze 0 issue**。
- **测试基建注记**：3 个网络活跃页（aiCollaboration/aiConfiguration/projectHealthCheck）在渲染测试中 skip——它们加载即自动探测端点，flutter_test 对 pending-timer/HTTP-400 是硬断言；相关逻辑已由 mock 单测覆盖。

---

## 本轮交接（2026-09-27 ~ 09-29，v1.0.0+5 → v1.0.0+11，TRAE 收尾班）

> 承接上文「GLM 增量」与既有基线。本轮把对班成果合入主线并连续交付 7 个版本，
> 每版 `flutter analyze` 0 issue + 全量测试通过（终态 **273 用例 + 1 skip**）。
> 交付产物：`F:\30_Novelcraft_Flutter\novelcraft_1.0.0+11_windows_release.zip`（14.3MB）、
> `novelcraft_1.0.0+11_release.apk`（67.1MB，正式签名 CN=song，apksigner 验签通过）。

### 版本时间线

| 版本 | commit | 内容 |
|---|---|---|
| +5 | bb0a294 | 合入对班 GLM 成果（anti_ai_flavor / chapter_ai_panel / CI workflow / 新测试 / TaskQueue 唤醒式门控 / 章节同步 bugfix）；**顺手修 WorkflowTask.id 时间戳撞车**（见坑位 #2） |
| +6 | 69ae33a | **章节管理接入导航**（此前 chapterEntityConfig 从未接线，「卷宗章节」入口名不副实只渲染卷宗）：新增 NavigationTarget.chapterManagement + 侧栏「章节管理」；原入口更名「卷宗管理」 |
| +7 | 37e8987 | **采样预设 + 手动微调 + 思维链**：AI 配置页新增「生成采样参数与思维链」全局卡片；三档预设（官方推荐/强抗复读/宽松）+ 9 参数微调（RWKV alpha_* + llama.cpp DRY）；思维链开关 + 低/中/高强度；6 处下发点改读全局 `aiRuntimeSettings`；KVStore(ai_config, runtime_settings) 持久化、启动装载、**下一次模型调用即生效** |
| +8 | 94f51ac | **结构化文件夹组导出**：导入导出页选 .md/.txt → 目录树（README/项目信息/逐卷/逐章/18 类实体逐记录），纯函数渲染 + 文件名净化 |
| +9 | cd2d3c1 | **修「项目无法删除」**（坑位 #1）+ AI 面板唤出自动滚动（坑位 #3）+ 选节「去重润色」+ 扩写携带 本章梗概/卷宗大纲/前一章结尾 600 字 |
| +10 | d7d108c | **多智能体协同写书向导**（见下） |
| +11 | 6522fd3 | **项目概览升级**（见下） |

### 三个关键修复（接手必读）

1. **项目删除不生效**：`softDeleteRow/softDeleteByProject` 用裸 SQL（customStatement）更新，
   **drift 的 watch() 流不响应 raw SQL** —— 列表永不刷新（库里已删、重启才消失）。
   已在 repository_base 删除后按表名 `db.notifyUpdates({TableUpdate.onTable(t)})` 补偿。
   **规则：以后任何 raw SQL 写库都必须手动 notifyUpdates**。回归测试 `project_deletion_test.dart`。
2. **WorkflowTask.id 撞车**：`DateTime.now().microsecondsSinceEpoch` 在 Windows 计时器粒度（可达 15ms）下，
   同批创建的任务拿到相同 id → cancel 按 id 误中他人、TaskQueue._completed 按 id 去重丢条目
   （task_queue_test 双红）。id 已改为 `'${微秒}_${_idSeq++}'`（workflow.dart 库级计数器）。
3. **AI 面板"无法唤出"**：选节面板渲染在整章正文后的 ListView 末尾，长章下点魔杖"看起来没反应"。
   已改为唤出后 `Scrollable.ensureVisible` 自动滚动定位（GlobalKey）。

### 新增能力速查（含文件坐标）

- **章节管理页**（+6）：侧栏第 3 项；选中章节 → 表单右上「预览本章」→ 阅读页
  （统计卡/状态 Chip/正文/备注）→ 正文内选中片段 → 右上魔杖唤出选节助手
  （润色/**去重润色**/扩写/续写；扩写自动携带 本章梗概 + 卷宗大纲 + 前一章结尾 600 字，
  进入阅读页即后台装载，失败静默降级）。
- **AI 配置页「生成采样参数与思维链」卡片**（+7）：`lib/ai/runtime_settings.dart`
  （`AiRuntimeSettings` + 全局 getter/setter）；预设档位 `RwkvSamplingPresetId`、
  强度 `ThinkingIntensity`；Agent 门控在 `agent.shouldUseThinkingChain`。
- **文件夹组导出**（+8）：`project_folder_export_service.dart`（`buildFileTree` 纯渲染 +
  `writeTree` 落盘，`parseSectionPlan` 同风格可单测）；入口在导入导出页。
- **多智能体协同写书**（+10）：`multi_agent_book_generation_service.dart` +
  `multi_agent_generation_dialog.dart`（入口接管了原一键生成按钮）。向导五字段
  （书名/作者/分卷数/每卷章数/子智能体数 ≥10 = 1 组长 + 9 写手，钳制 10..32）→
  主线大纲 → 子智能体并行分卷大纲（落 Volumes.description，截 950）→ 并行章节大纲
  （落 Chapters.summary，截 900）→ 每章「组长 JSON 分工（内容/边界/字数）+ 9 写手并行 +
  组长拼接润色排版」→ 逐章落库 + 联动。分工解析 `parseSectionPlan` 容错围栏/杂文本，
  失败走 `fallbackPlan` 均匀切分。并发池 `_runPool`（上限 = 子智能体数）。
- **项目概览**（+11）：分类卡 6→15（全实体）+ **双击卡片直达对应管理页**
  （NavigationContext 带项目）；「继续规划剧情并续写」按钮：
  `continue_story_service.dart` —— 主编智能体基于最新 state（主线大纲 + 各卷状态与
  大纲节选 + 最近一章结尾 800 字）输出 JSON 决策 `{needNewVolume, volumeName,
  chapterTitle, chapterOutline}`，**自主判断是否追加新分卷，卷名/章名自主命名** →
  双 Agent 成稿（失败回落单次写手）→ 落库联动；解析失败走保守兜底（不新建卷续写）。

### 新增坑位（PITFALLS 级，别踩）

- **C# language-table.csv 与 strings.g.dart 已分叉（缺约 330 个 Flutter 侧键）**
  → **绝不可再跑 `tools/csv_to_dart.py` 全量重生成**（实测会丢 1340 行词条）。
  新词条手工按生成格式补进 strings.g.dart 的 zh/en 两张 map；CSV 可同步追加键但别重生成。
- **Windows 构建路径**：必须在纯英文路径跑 —— 用 junction `F:\30_Novelcraft_Flutter\novelcraft_en`
  （从中文真实路径跑 `flutter build windows`，CMake 生成阶段 249ms 秒败 "Unable to generate build files"）；
  APK 用 `subst S:` 盘（**映射重启失效**，重跑
  `subst S: "F:\30_Novelcraft_Flutter\Flutter版代码\novelcraft"` 后在 `S:\` 构建）。
- **凭据已脱敏**：CF Access Id/Secret 全部改为 `--dart-define RWKV_CF_ID / RWKV_CF_SECRET`
  或页面输入；集成测试不再有默认值；密钥本体只存本机，未入任何仓库。
- **多智能体写书采样门控**：新增的 `_chat` 通道同样要 `isRwkvFamilyProvider` 门控后再下发
  防复读采样参数（DeepSeek/Zhipu 严格 API 会 400）——新服务已带，抄作业别抄丢。

### 交付与仓库状态（接手起点）

- **本地 git**：main 分支 9 个提交（5f8a240 初始 → 6522fd3 +11），工作区干净。
- **GitHub 远端 `LuckySongXiao/Novelcraft_Flutter` 仍是 2026-09-15 旧快照（含 备份说明.txt）**，
  本地领先 9 个提交；远端旧提交即旧快照，推送需 force（用户已知悉，**未执行**）。
- **`F:\30_Novelcraft_Flutter\Novelcraft_Flutter_source\`**：对班同事的工作副本，
  停留在合并前状态（不含 +5~+11）；同步方式 = 从主仓 `git archive` 重新导出
  （注意 tar 解压中文文件名会乱码，从原项目复制修正）。
- **已知遗留**：GLM 段落所列 遗留#8（导航状态保持）与 think 预算自适应仍未做；
  新增遗留：旧 `one_click_novel_generation_service`（自命名流程）的入口已被多智能体
  向导接管，代码暂留作单章双 Agent 基线，下批可评估移除；
  `Novelcraft_Flutter_source` 与远端仓库的同步由用户决定时机。

---

## 2026-10-04 交接：G1K 预设与双端便携构建（TRAE）

### 本轮交付

- 包版本 `1.0.0+31`。AI 配置页 MainAgent / SubAgent 卡新增「预置 G1K 7.2B 主编 + 2.9B 写手」：先保存并连接官方 7B 端点，再从 7B、3B 各自 `/v1/models` 读取**完整**模型 ID，唯一匹配后才保存；缺失/多版本/失败时不替换旧配置。模型尺寸前缀与 3B 域名内置于 `lib/ai/rwkv/g1k_model_preset.dart`，**密钥未入源码/安装包**。
- 新配置单独落 `ai_config/book.g1k_preset`，启动时加载，可在卡片「停用写书预设」清除。只有 `multiAgentBookGenerationServiceProvider` 使用它；普通 `DualAgentWorkflowService`、其它一键生成/续写保持原双代理设置。多智能体写书：7B 规划及短段润色、2.9B 正文、两端点校验完整 ID；具体参数与边界见 `docs/RWKV-G1K-双模型写作工艺.md`。
- 安卓竖屏（触控 + 逻辑宽 <600）换 4 项底部导航，顶部「更多页面」可进入项目概览/卷宗/人物/时间线/设置；横屏和桌面仍使用侧栏。聊天输入：手机软键盘换行、独立发送按钮；网络失败恢复未发出的输入文本；没有默认 provider 时保留文本并提示配置。写书向导在小屏缩短并发标签、限制内容高度及支持滚动。
- 验证：`flutter analyze --no-pub` 0 问题；`flutter test --no-pub` **363 项通过、1 项既有 skip**，新增 G1K 端点唯一匹配/预设独立持久化及安卓竖屏菜单测试。

### 构建与后续核对

- Windows 从英文 junction `F:\30_Novelcraft_Flutter\novelcraft_en` 构建；APK 从 `subst S:` 构建，避免中文路径导致 CMake/Gradle 失败。**便携包必须包含整个 Windows Release 文件夹**（exe + DLL + data），不能只复制 exe。
- Windows x64 Release 构建成功；便携 ZIP：`build/NovelCraft-Windows-x64-1.0.0+31-portable.zip`（15,184,710 字节，SHA-256 `1986EAB164754694CC4DA1CD71CE73CC45EB4BF7EC2A913B6A2398546BE8B9B0`）。已检查 ZIP 内含 `Release/novelcraft.exe`、`flutter_windows.dll`、`data/app.so`、`data/icudtl.dat` 等完整 40 项。
- Android Release APK：`build/app/outputs/flutter-apk/app-release.apk`（72,112,689 字节，SHA-256 `1CF635F1AF3C652934871F8FFFF890FD5B6AB0AD8440F670D9702D511C898AC3`）；`aapt` 核实包名 `com.novelcraft.novelcraft`、`versionName=1.0.0`、`versionCode=31`、minSdk 24 / targetSdk 36。`apksigner verify` 通过 v2 正式签名，证书 SHA-256 为 `4fc478771c4fc823cbe24b6bd4bd93052660d5a48a3d1382a8c40189b466289d`（CN=song）；未使用 debug 证书。
- 本环境沙箱拒绝写入默认 Android SDK 的 `.knownPackages` 及 Pub 缓存中 `jni/android/.cxx`；实际成功构建时临时复制所需 SDK/依赖到工作区外 `F:\30_Novelcraft_Flutter\android-build-toolchain`，并设置 `PUB_CACHE`、`ANDROID_HOME` / `ANDROID_SDK_ROOT`。另因 `integration_test` 开发依赖在 Release 注册表中被引用但未编译，打包时暂时从 `pubspec.yaml` 排除并重新解析依赖；打包后已恢复该依赖、原 `android/local.properties` SDK 路径，并重跑 `flutter pub get`（锁文件校验和已恢复）。详见 `PITFALLS.md` 第 41 节。
- 密钥只能由使用者在 AI 配置页填写，切勿通过 `--dart-define` 传入将长期分发的公共包；在聊天中暴露过的 Cloudflare Service Token 建议轮换。
- `adb devices` 未发现连接设备；未做 APK 安装、Windows 图形启动或真实 G1K 云端端到端小说验收。若云端同尺寸同时开放多个 G1K 版本，一键预设会拒绝猜测，需后续明确选型。`Novelcraft_Flutter_source` 是独立旧快照，本轮未同步；当前工作区还有大量既存未提交改动，勿整体覆盖。

*交接：TRAE，2026-10-04。*

### 最终交付索引（1.0.0+34）

- 当前功能说明：`docs/功能使用说明-v1.0.0+34.md`。
- Windows：`F:\30_Novelcraft_Flutter\novelcraft_1.0.0+34_windows_release.zip`，SHA-256 `BCC4CC67A77A33C76FFCCC9475034BDC0C9F7F6B314B78455D2EC745C3CD6D43`。
- Android：`F:\30_Novelcraft_Flutter\novelcraft_1.0.0+34_release.apk`，versionCode `34`，SHA-256 `F7A03FD4BC7A7CD13748771865C843A1DF68750EB034CB428638173C670F31D8`。
- 客座读者/13B 审查实现见 `book_review_settings.dart` 与 `book_content_review_service.dart`；源代码备份同步记录见备份目录 `备份说明.txt`。

## 2026-10-04 交接：1.0.0+34 审查团队与双端重新封装

- 新增客座读者配置：最多 3 个第三方平台模型，可分别设置平台、模型、称呼、启用状态和人类品味；评论与 7B 审查意见统一进入留言区。
- 新增 13B 首席审查员：默认目标为 `RWKV Cloud::official-13b`，7B 会把客座读者意见提交给 13B 复核；13B 可 `approve` 认可 7B，或 `revise` 给出改进意见。意见会继续传给 3B 改写器。
- 配置持久化：`ai_config/book_review.settings`；实现见 `lib/application/services/book_review_settings.dart`、`book_content_review_service.dart`、`ui/pages/book_review_settings_card.dart`。
- 使用说明：`docs/功能使用说明-v1.0.0+34.md`。
- Windows x64 便携包：`F:\30_Novelcraft_Flutter\novelcraft_1.0.0+34_windows_release.zip`，15,565,386 字节，SHA-256 `BCC4CC67A77A33C76FFCCC9475034BDC0C9F7F6B314B78455D2EC745C3CD6D43`；包含完整 Release 目录，共 32 个文件。
- Android APK：`F:\30_Novelcraft_Flutter\novelcraft_1.0.0+34_release.apk`，72,604,573 字节，SHA-256 `F7A03FD4BC7A7CD13748771865C843A1DF68750EB034CB428638173C670F31D8`；包名 `com.novelcraft.novelcraft`，versionCode `34`，minSdk `24`，targetSdk `36`，apksigner v2 正式签名通过。
- 构建期间临时移除 `integration_test` 以绕过 Flutter Release 插件注册问题；构建后已恢复依赖、pubspec、锁文件和 `GeneratedPluginRegistrant.java` 中的 `IntegrationTestPlugin`。
- 当前无 Android 设备连接，未做实体安装验收；Windows ZIP 已解压核对入口文件。Cloudflare 凭据未写入源码或安装包。
- 本轮源码已准备无删除增量同步到 `Novelcraft_Flutter_source`，目标目录既有签名材料继续由排除规则保护。

---

## 2026-10-04 交接：T≤1.0 写作参数修订（TRAE）

- 依据 `新一代模型T10修订补丁_20261004.zip（报告v1.1+T≤1/新一代模型四维甜点配置报告.md` 的晨间复测，G1K 写书预设将原 `temperature=1.2` 修订为 **0.88-1.0**（默认请求最低 0.88，短稿重试 1.0），保留 `top_p=0.7` / `presence_penalty=2`；仅影响多智能体写书里的 G1K Cloud 请求，其他 provider 不变。实现见 `lib/ai/rwkv/g1k_writing_profile.dart`、`lib/application/services/multi_agent_book_generation_service.dart`。
- 保留此前用户确定的 7B MainAgent（规划/润色）、2.9B SubAgent（正文）分工；正文改为约 1100 字/段、单发最多 1200 tokens、单段最多 1200 字，提示词明确「至少写满 N 字」并禁字数自报；少于 800 字的常规段重试一次。检测同句出现三次的循环，截去复读尾部避免传递给下一段；7B 润色结果同样检查，缩水/评分回退继续保留原稿。
- **报告与当前分工的差异**：新报告建议 7B 担任分段正文主力、3B 转做幕卡/过渡段。本轮不擅自转换用户既定角色；2.9B 的短停概率、章节成稿质量需要真实云端试产验证。报告的凌晨 N=8 是特定时间窗口数据，不硬编码全天并发或强制夜间调度；13B/1.5B 新工艺未接入本次写书预设。
- 工艺详见 `docs/RWKV-G1K-双模型写作工艺.md`，新陷阱见 `PITFALLS.md` §42。版本 `1.0.0+32`；本轮静态分析 0 问题，完整测试 **367 通过、1 既有 skip**。无连接安卓设备，真实 G1K 请求/章节试产尚未验收；源码有大量此前未提交改动，本轮未重置、未同步独立旧快照。
- Windows x64：`flutter build windows --release --no-pub` 成功；`build/NovelCraft-Windows-x64-1.0.0+32-portable.zip`（15,188,499 字节，SHA-256 `1125839289065BBF2369A4B04A3B379FA9382D5856A141B6121F6EBB07DA28CD`）。ZIP 内 40 项，含 `Release/novelcraft.exe`、`flutter_windows.dll`、`data/app.so`、`data/icudtl.dat`，必须整体解压使用；未做 Windows GUI 手工启动验收。
- Android：`build/app/outputs/flutter-apk/app-release.apk`（72,112,689 字节，SHA-256 `34751319DD4DCE4A34F7C23697FB8017F2840DCEF49245BB75D848D82BA263C4`）；`aapt` 验证包名 `com.novelcraft.novelcraft`、`versionName=1.0.0`、`versionCode=32`、minSdk 24 / targetSdk 36；`apksigner verify` 通过 v2 正式签名，证书 SHA-256 `4fc478771c4fc823cbe24b6bd4bd93052660d5a48a3d1382a8c40189b466289d`（CN=song）。`adb devices` 无设备，尚未安装实测。
- Android 打包沿用 §41 的可写 SDK/Pub 缓存；暂时排除测试依赖 `integration_test` 以绕开 Release 插件注册表错误，产物生成后已恢复依赖、默认 SDK 路径、锁文件校验和并复测。构建命令最后因沙箱拒绝写默认 `D:\Android\Sdk\.knownPackages` 返回非零，**不能称命令整体成功**；但新 APK 的时间戳、版本、哈希与签名均经独立核验。此次没有通过 `--dart-define` 固化 CF 凭据到安装包。

*交接：TRAE，2026-10-04 07:44。*

### 10:17 源码备份补记

- 按用户后续要求，已将本主工程的 `1.0.0+32` 源码增量备份到 `F:\30_Novelcraft_Flutter\Novelcraft_Flutter_source` **目录根部**；此前「独立旧快照未同步」描述仅代表当时状态。无删除同步，保留备份目录独有文件；按既有备份约定排除模型、构建产物、工具缓存与密钥文件，复核 448 个源码文件待复制 0、失败 0。详情见目标目录 `备份说明.txt`。
- 备份目录原本已有 `android/key.properties` 与 `android/app/upload-keystore.jks`，此次没有覆盖或删除；**此目录含旧签名材料，不得直接作为公开源码包分发**。本次未对备份副本单独执行 Flutter 测试，构建和完整测试均在主工程进行。

*补记：TRAE，2026-10-04 10:17。*

### 2026-10-04 RWKV Cloud 多端点配置补记

- AI 配置页增加官方 1.5B / 3B / 7B / 13B 端点模板和自定义端点；模板不预填 API Key、模型名或 Cloudflare Access 凭据。切换到 RWKV Cloud 或切换端点时从当前地址读取 `/models`，服务端模型列表可供选择；网络/鉴权错误不会退回伪造模型。
- 各 profile 独立保留 URL、API Key、CF Access 凭据、模型选择及运行参数；旧版单 RWKV Cloud 配置在首次加载时迁移。自定义配置可删除，官方模板保留。运行时仍是单个 `RWKV Cloud` provider 实例，所选 profile 决定当前活动端点。
- 验证：`flutter analyze --no-pub` 无问题；专项 `rwkv_cloud_provider_test.dart` 13 项全通过；完整 `flutter test --no-pub` 372 项通过、1 项既有 skip。测试期间出现 Drift 多测试数据库复用警告，但无测试失败。未构建新安装包，也未同步源码备份目录。
- 安全：聊天中曾出现 Cloudflare Access Service Token。未将其复制到源码、默认配置或安装包；建议在 Cloudflare 轮换该 token，应用内由用户重新填写。

*补记：TRAE，2026-10-04。*

## 2026-10-04 交接：1.0.0+33 双端重封装与源码备份（TRAE）

- 版本提升至 `1.0.0+33`。Windows x64 Release 从英文路径构建并打包完整 `Release/` 目录；交付包 `F:\30_Novelcraft_Flutter\novelcraft_1.0.0+33_windows_release.zip`，15,206,754 字节，SHA-256 `61B64BBAB9B61E2BA52BDCB25B04973B5EDB4410C9EDB1705D70D3028332C6B7`。包内 40 项，包含 `novelcraft.exe`、Flutter DLL 与 `data/` 运行资源。
- Android Release APK：`F:\30_Novelcraft_Flutter\novelcraft_1.0.0+33_release.apk`，72,227,377 字节，SHA-256 `8061509CBF3FBBAB5A18213C77356CFA7C530276C3031ECAD36C552FE45EA256`。包名 `com.novelcraft.novelcraft`，`versionCode=33`、`versionName=1.0.0`、minSdk 24、targetSdk 36；`apksigner verify` 通过 v2 正式签名，证书为 `CN=song`，SHA-256 `4fc478771c4fc823cbe24b6bd4bd93052660d5a48a3d1382a8c40189b466289d`。
- 两种产物的构建输出与交付副本哈希一致。Windows ZIP 已核实完整性；APK 已独立验包、验签。当前没有 Android 设备连接，未做实体安装验收，也未做 Windows 图形界面手工启动验收。
- Android 构建沿用 §41 的可写工具链与 `subst S:` 路径；为绕过 Flutter 3.38.5 Release 插件注册表问题，构建时短暂移除 `integration_test` 开发依赖。构建后已恢复 `pubspec.yaml`、锁文件、`local.properties`、插件依赖缓存及含 `IntegrationTestPlugin` 的生成注册表；不得把临时注册表覆盖进备份。
- 已将当前源码无删除增量同步至 `F:\30_Novelcraft_Flutter\Novelcraft_Flutter_source`，排除构建产物、缓存、环境配置和签名文件，保留目标独有内容。该目录原有签名材料不作为同步内容覆盖，目录仍不可直接公开分发。详细同步核验见备份目录 `备份说明.txt`。

*交接：TRAE，2026-10-04。*
