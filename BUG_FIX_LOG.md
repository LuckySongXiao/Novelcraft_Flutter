# BUG 修复记录

更新时间：2026-10-07

## 2026-10-07 修复

用户实测反馈三项 BUG（G1K 串行写书 / 云端 RWKV state / 审核后未同步设定）。

### BUG 3（最重要）：章节正文审核通过后，人物管理与世界观子项**完全不更新**

| 编号 | 现象 | 根因 | 修复与验证 |
|---|---|---|---|
| NC-20261007-01 | 审核通过后 `人物管理`/`世界观` 的角色信息与状态履历没有任何变化 | 多智能体服务的「验收后更新分派」被 `post == null && …` 门控**永久关死** —— 生产环境 `chapterPostProcessServiceProvider` 恒被注入（`core/di.dart`），该条件恒为假 | 去掉 `post == null` 门控，改为只要求 `acceptance.updateItems` 非空 + `dispatcher` 非空 |
| NC-20261007-02 | G1K **串行**写书（`WritingCraft.duo/solo/beam`）从不更新设定 | 三种工艺的返回体 `acceptance` 恒为 `null` → 天然没有 `updateItems` | 新增 `_extractAcceptanceFromProse()`：正文定稿后用**独立** `_AgentChannel(keepHistory:false)` 调组长，渲染新增的 `Book/stateUpdates` 节点（zh/en 双语）产出与组长验收同接口的 `{"updates":[…]}`；三处 `return` 改为定稿后抽取，失败返回空 `TeamAcceptance` 不阻断落库 |
| NC-20261007-03 | 7B 全书审查通过并回写正文后仍是零同步 | `BookContentReviewService.reviewChapter` 的 `applyComments` 之后**没有**任何后处理钩子 | 构造参新增 `ChapterPostProcessService? postProcess`（`di.dart` 注入）；新增 `_syncAfterReview()`：重读章节 → `seniorApproved` 且状态非 `Completed` 则推进为 `Completed`（`ModuleStateService.extractAndApply` 以此为前提）→ `post.runForChapter(...)` |
| NC-20261007-04 | 章内任一分段抽取失败 → 整章静默零更新 | `module_state_service.dart` 里 `if (valid == null) return null;` 直接放弃整章 | 改为跳过错块 `failedChunks++ / continue`，全部失败才放弃；返回文案追加「（N 个分段未产出，其余照常写入）」 |

### BUG 1：写书输出需要正则提纯（真机样本 = **正文前的元话语 / 元信息抬头**）

用户重发 3 张真机截图后，实际形态与初判不同：泄漏在**正文之前**（元话语 / 元信息抬头），
不是尾部状态块。三种真实形态（均已抄进 `tools/sanitizer_selftest.dart` 当回归用例）：

| 编号 | 现象 | 根因 | 修复与验证 |
|---|---|---|---|
| NC-20261007-05 | 正文末尾混入「线性状态更新参考素材履历」类的状态登记文本 | 模型按隐含约定在正文后补一段供上游登记用的文本（`{"updates":[…]}` / `【设定更新】` / `设定更新：…`），无清洗 | 新增 `AIOutputSanitizer.stripStateUpdateBlocks()`：围栏代码块 → 含 `updates` 键的裸 JSON（括号配平 + `jsonDecode` 校验）→ **尾部整块**剥离（`_stripTrailingStateBlock`：取最后一个锚点行，要求其后每行均为状态块形态，否则整块放弃；全篇皆状态块则返回空串）→ 逐行兜底 → 清 `---` 与多余空行。已接入 `_cleanFinalChapter`（四种书稿工艺都经过）。**⚠ 绝不并入 `extractCleanOutput`** —— 设定抽取链路正是要拿那个 `updates` JSON |
| NC-20261007-07 | 章节正文被 AI 元话语污染（三种形态，截图实测）| ①`你好，我是NovelCraft的主编智能体。我将严格保留原文中的人物对话……---润色后版本：“你们到底是谁？”……`（**自我介绍 + 处理说明，正文紧随同一段**）②`【主编修订稿】---第一章北极圈基地（正式）*目标：…*1991年，……`（修订稿抬头 + 星号字段，**正文紧跟同一行**）③`---【本章正式章名】《…》【出场人物】…【场景与时间线】…【关键冲突与转折】…【章末钩子】…`（**整行章节元信息区块**，字段后还跟着元信息散文）| 新增 `AIOutputSanitizer.stripMetaPreambles()`：①**整行元信息**丢弃（整行是元信息小标题，或一行内塞了 ≥2 个元信息字段）；②**整行元话语**丢弃（句子级判定：`我是…智能体` / `我将…原文/措辞` / `字数统计：…`）；③**行内标记切前缀**（`---润色后版本：`、`*目标：…*` —— 取行内最后一个标记的收尾，保留其后的正文）；④开头残留的名单条目 / 分隔线 / 小标题清理。已**并入 `extractCleanOutput`**（它只吃元信息、绝不碰 JSON 载荷，故设定抽取链路安全）+ `_cleanFinalChapter`，覆盖全部正文出口。新增 `tools/sanitizer_selftest.dart` **22 用例全过**（含三张截图的原文、以及「我会保留这份记忆」等防误删回归） |

### BUG 2：云端 RWKV 的 state 没有落在客户端

| 编号 | 现象 | 根因 | 修复与验证 |
|---|---|---|---|
| NC-20261007-06 | 云端模型只能靠调提示词提升上下文一致性，服务端不知道哪个 state 对应哪个并发 | ①`RwkvCloudProvider` 未覆写 `chat()`/`chatStream()` → 走 `/v1/chat/completions` **每轮重发全量 messages**；②`statefulChat()` 零调用方；③客户端没有会话台账。且 `rwkv_lightning` **没有 state 导出端点**（`POST/GET /state` 实测 404，`RwkvState.bytes` 恒为空）→「存 state 字节」物理不可行 | 落地「**端点重放 + 本地台账**」：新增 `lib/ai/rwkv/rwkv_cloud_state.dart`（`RwkvCloudSessionRecord` + `RwkvCloudSessionLedger`，session_id **客户端生成**、转写本本地持久化、断线重放重建 state）；`RwkvCloudProvider` 覆写 `chat()` 按 `parameters['rwkvSessionKey']` 分流到 `/state/chat/completions` 增量续跑，任何失败都回落无状态链路；`MultiAgentBookGenerationService` 的 `_AgentChannel` 新增 `sessionKeyPrefix`（规划组 `<书名>::plan` / 章节组 `<projectId>::chapter`，最终 key = `'$prefix::${agentId}'`）。**两条铁律**：`storageKey()` 必须把 `:` 转 `_`（native KVStore 拿 key 当文件名）；同 session 用 `ledger.runExclusive()` 在客户端排队（多章并行 + 同角色跨章共会话）|

## 2026-10-02 修复（历史）

| 编号 | 现象 | 根因 | 修复与验证 |
|---|---|---|---|
| NC-20261002-01 | 章节结构化导出文件没有定稿正文 | `ChapterExportInput` 没有把正文传入 Markdown/JSON 渲染器 | 增加 `content` 字段，所有续写/多智能体调用方传入落库正文；`chapter_export_service_test.dart` 验证正文与过程数据均可回读 |
| NC-20261002-02 | 用户选择的导出文件名可能穿越到导出根目录之外 | 项目 ID、标题只做非法字符替换，未处理点段和相对路径 | 统一净化控制字符、首尾点、长度；文件树拒绝绝对路径和 `..`；`chapter_export_service_test.dart`、`project_folder_export_test.dart` 覆盖恶意输入 |
| NC-20261002-03 | 取消中的任务提前释放并发槽，依赖任务过早启动 | `cancel()` 从运行表移除任务并立即完成 Future，但实际 runner 仍在执行 | 改为只标记取消，在 runner 的 `finally` 中释放槽、完成依赖和记录结果；`task_queue_test.dart` 覆盖运行中取消与槽位复用 |
| NC-20261002-04 | RWKV SSE 流响应头到达后就释放并发额度 | `chatStream` 在 `send()` 返回后调用 `leaveInFlight`，正文尚未消费 | 将释放移动到完整流消费的 `finally`；`rwkv_batch_test.dart` 验证流未结束时额度仍占用 |
| NC-20261002-05 | SSE 合法的 `data:`（无空格）分块被丢弃 | 解析器只接受 `data: ` 前缀 | 接受规范允许的两种前缀，并保留 `[DONE]` 处理；对应 Provider 回归测试通过 |
| NC-20261002-06 | 模型在说明文字后返回 JSON 时解析失败 | 清洗器只识别整段 JSON，未从前导说明中提取配平的对象/数组 | 增加引号、转义和括号配平扫描；`output_sanitizer_test.dart` 覆盖说明文字、嵌套 JSON 和原文保护 |
| NC-20261002-07 | Semaphore 配置为 0 时所有请求永久等待 | 并发上限未做下限保护 | 将上限钳制为至少 1，并增加边界测试 |
| NC-20261002-08 | JSON 导入布尔/日期字段失真；章节恢复后丢失卷归属 | 导入只比较字符串 `true`，日期只接受一种类型，章节备份遗漏 `volumeId`；部分实体跨项目反查未过滤 | `_vBool`/日期解析兼容 JSON 原生类型；章节导出/恢复保留 `volumeId`；修炼等级与政治职位按所属体系过滤；全量测试通过 |
| NC-20261002-09 | 项目只能导出 Markdown/文本，无法直接生成电子书 | 没有 EPUB 打包链路 | 新增纯 Dart EPUB 3 服务（mimetype、OPF、导航、章节 XHTML、样式表），导入导出页增加 EPUB 按钮；`epub_export_service_test.dart` 解包验证结构、转义和正文 |
| NC-20261002-10 | 备份导入到另一个项目后主键冲突或父子关系悬空 | 导入器总是重新生成主键，却没有同步改写外键 | 新增两阶段 `ImportIdRemap`：先建立全量旧→新映射，再改写章节、人物关系、体系子实体等外键；`import_id_remapper_test.dart` 验证跨项目导入关系完整 |
| NC-20261002-11 | 并发探测的两个请求同时通过单许可闸门 | `waitForPermit` 和 `enterInFlight` 分离，多个异步调用可在入场前看到同一空槽 | `RwkvConcurrencyController` 增加 reservation 计数，将等待与许可预留原子化；回归测试验证 cap=1 不会越限 |

## 验证结果

- `flutter analyze --no-pub`：No issues found。
- `flutter test --no-pub`：355 项通过。
- `dart run tool/verify_model_fit.dart`：31/31 通过。
- `dart run tool/verify_output_sanitizer.dart`：19/19 通过。
- `dart run tool/verify_segment_rewrite.dart`：59/59 通过。
- `dart run tool/verify_session_archive.dart`：18/18 通过。
