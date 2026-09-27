# NovelCraft Flutter 版 — 交接文档（HANDOFF）

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
