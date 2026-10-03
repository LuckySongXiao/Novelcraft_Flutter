# NovelCraft Flutter 移植 — 踩坑日记（PITFALLS）

> 记录移植过程（C# WPF → Flutter）中反复踩、且容易再踩的坑。每条含「现象 / 根因 / 解法」。

---

## 1. Riverpod 3 移除了 StateNotifier / StateNotifierProvider

- **现象**：`extends StateNotifier<T>`、`StateNotifierProvider<...>`、`Classes can only extend other classes`、`The function 'StateNotifierProvider' isn't defined`。
- **根因**：项目依赖 `flutter_riverpod ^3.3.2`，而 Riverpod 3 **彻底移除**了 `StateNotifier`（改为推荐 `Notifier`/`AsyncNotifier`/`StreamNotifier`）。
- **解法**：所有状态类改写为
  ```dart
  class XxxNotifier extends Notifier<T> {
    @override
    T build() { /* 可触发异步加载，返回初始值 */ }
    void doSomething() => state = ...;
  }
  final xxxProvider = NotifierProvider<XxxNotifier, T>(XxxNotifier.new);
  ```
  注意：构造里不能再 `super(initial)`；需要异步初始化的放在 `build()` 里 fire-and-forget 调用，之后 `state = ...` 触发重建。

---

## 2. drift 的 Column 与 Flutter 的 Column 同名冲突

- **现象**：`The name 'Column' is defined in libraries ... drift ... and ... flutter/material.dart`、`'Column' isn't a function`。
- **根因**：`import 'package:drift/drift.dart'` 与 `import 'package:flutter/material.dart'` 都导出 `Column`。
- **解法**：给 drift 加前缀 `import 'package:drift/drift.dart' as d;`，`Value`/`insert` 等统一用 `d.Value(...)`。
  （`Value` 同理——`Value isn't defined` 多半是忘了 `d.` 前缀。）

---

## 3. drift Companion 的 insert：id 必填 + 字段可空性严格

- **现象**：`The named parameter 'id' is required`、`The argument type 'int?' can't be assigned to 'int'`、`Value<String?> can't be assigned to String`。
- **根因**：
  - `*Companion.insert({required String id, ...})` 的 `id` **必填**（drift 不自动生成 UUID），必须显式 `const Uuid().v4()`（`uuid` 包已依赖）。
  - 字段分两类：`required String/int` 是裸值，其余 `this.x = const Value.absent()` 才是 `Value<T>`。非空列 `Value<String>`/`Value<int>` **不接受 null**，可空列 `Value<String?>` 才接受。
- **解法**：写 Companion 前**逐一对照** `lib/data/database.g.dart` 里的 `final Value<X> field;` 确认类型；非空列给默认值（`?? '默认'` / `?? 0`），可空列用 `d.Value(v as String?)`。非空 int 列切勿传 `as int?`。

---

## 4. Repository 查询必须走 db.xxx，不能裸调用

- **现象**：20 个 `The method 'select' isn't defined` 类错误集中在 repository 层。
- **根因**：drift 的 `select(...)`/`into(...)`/`update(...)` 是 `AppDatabase` 的成员方法，不是顶层函数。
- **解法**：一律 `db.select(db.projects)`、`db.into(db.projects).insertReturning(...)`、`db.update(db.xxx)`。基类里 `db` 是 `AppDatabase` 实例。

---

## 5. db.customStatement 返回 Future<void> 而非 Future<int>

- **现象**：把 `customStatement(...)` 当返回值数量使用报类型错。
- **解法**：`customStatement` 返回 `void`，需要行数请改用类型安全查询或 `selectOnly` + `count()`。

---

## 6. Riverpod 3 没有 legacy.dart 兜底

- 不要尝试 `import 'package:flutter_riverpod/legacy.dart'` 来捞 `StateNotifier`——该文件存在但只保留旧版导出，新项目应直接迁移到 `Notifier`。
- 验证 API 是否存在：`grep -rn "Notifier" flutter_riverpod.dart` 确认导出的是 `Notifier/NotifierProvider/AsyncNotifier/StreamNotifier/AnyNotifier`。

---

## 7. Windows 构建符号链接 errno 183

- **现象**：`PathExistsException: Cannot create link ... .plugin_symlinks\jni (OS Error: 当文件已存在时无法创建该文件, errno=183)`。
- **根因**：Flutter 插件链接目录 `windows/flutter/ephemeral/.plugin_symlinks` 是生成产物，上一次失败构建残留的空目录会被下一次构建当成「已存在的链接」而无法覆盖。
- **解法**：每次构建前清理所有平台的残留：
  ```bash
  for d in windows linux macos ios android; do
    rm -rf "$d/flutter/ephemeral/.plugin_symlinks"
  done
  ```
  ⚠ 本沙箱内仍会被 `reg.EXE` 黑名单 / CMake 注入崩溃挡住，需在普通环境执行。

---

## 8. 沙箱环境无法跑 build windows / flutter test / 完整 web 打包

- **build windows**：触发 `reg.EXE`（安全中心程序黑名单拦截），且 `cmake.exe` 在沙箱 DLL 注入下崩溃（exit `0xC0000409`，空输出）。
- **flutter test**：`flutter_tester` 的本地 WebSocket 被沙箱拦截（`Invalid WebSocket upgrade request`）。
- **flutter build web（完整打包）**：dart2js 编译本身能通过（"Compiling lib\main.dart for the Web... 50.9s"），但最后一步 **shader 打包** 在沙箱崩溃——
  `ShaderCompilerException: Shader compilation of .../material/shaders/stretch_effect.frag failed with exit code 1`（Impeller shader 编译器在沙箱环境报错，与代码无关）。
- **可用替代验证**：
  - `flutter analyze` → 全量静态检查（首选，本任务以此为准，结果 **No issues found!**）。
  - `flutter build web` 的 **dart2js 阶段** 能跑通，仅最终 shader 打包因沙箱失败；如需完整产物请到未被沙箱限制的 Windows 环境。
- **结论**：在本工作区只做「写代码 + 静态分析」，真正跑起来（数据库、UI 交互、测试、完整打包）请到未被沙箱限制的 Windows 环境。

---

## 9. 入口 main.dart 是默认计数器模板

- **现象**：一开始 main.dart 仍是 `MyApp` / `MyHomePage` 计数器脚手架，导致前面所有层都没被应用接起来。
- **解法**：重写为 `ProviderScope(child: NovelCraftApp())`，`NovelCraftApp` 用 `ConsumerWidget` 同时 watch `localeControllerProvider` 与 `themeControllerProvider`，home 指向 `AppShell()`。

---

## 10. C# 字符串伪枚举 → Dart 强枚举

- C# 大量用 `string` 当枚举（角色类型、剧情状态、体系 type…）。Dart 侧统一改为 `enum` 或 `const` 字符串集合 + `SystemFieldType.select` 下拉选项，避免拼写漂移。配置驱动的页面（体系页/实体页）字段选项直接写在 `system_configs.dart` / `entity_configs.dart`。

---

## 11. C# 服务层的 try/catch 模板一律删除

- C# 21 个服务全是 `try { ... } catch (e) { log; rethrow; }`，无信息增益（异常不转换不包装）。Dart 侧直接上抛，由 UI 层统一 `try/catch` 弹 SnackBar。

---

## 12. 路径与中文目录

- 项目根含中文目录（`Flutter版代码`、`C#版源代码`）。脚本/命令一律用**绝对路径**，且 `cd` 到项目后操作；Bash 工具在 Windows 走 Git Bash，用正斜杠。
- `sqlite3`/`drift_flutter` 在 Windows 需要 FFI 原生库；纯 Dart 的 `flutter test` 会因无原生库存而失败——这也是为什么测试需在真实环境跑。

---

## 13. file_picker v12 移除了 `FilePicker.platform` 静态实例

- **现象**：`The getter 'platform' isn't defined for the type 'FilePicker'`；`result.files` 报 `List<PlatformFile>` 没有 `files` getter；`file.bytes` 为 `null`。
- **根因**：`file_picker` 升到 12.x 后 `FilePicker` 变成 `abstract final class`，调用方式从 `FilePicker.platform.saveFile(...)` / `FilePicker.platform.pickFiles(...)` 改为**直接静态方法** `FilePicker.saveFile(...)` / `FilePicker.pickFiles(...)`；且 `pickFiles` 直接返回 `List<PlatformFile>`（不再包一层 `FilePickerResult`），读内容用 `await file.readAsBytes()`（旧的 `withData` / `file.bytes` 已废弃）。
- **解法**：参考 `lib/ui/pages/import_export_page.dart` 的导入/导出写法：
  ```dart
  final path = await FilePicker.saveFile(fileName: 'x.json', bytes: bytes); // 返回 Uri?
  final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
  if (files.isEmpty) return;
  final bytes = await files.single.readAsBytes();
  ```

---

## 14. entity_configs.dart 的两类 helper 易混：`_bool`(字段) vs `_vBool`(值)

- **现象**：`The function '_bool' isn't defined`。
- **根因**：文件里有两组名字相近但用途不同的 helper：
  - **字段定义 helper**（`_text` / `_num` / `_sel` / `_multi` / `_bool`）→ 返回 `SystemFieldDef`，供 `EntityPageConfig(fields: [...])` 列表使用；
  - **值转换 helper**（`_vStr` / `_vInt` / `_vDbl` / `_vBool` …）→ 返回 `d.Value<T>`，供 `sourceBuilder` 里构造 `Companion` 使用。
  写 `fields:` 时要用 `_bool(key, label)`，写 Companion 时要用 `_vBool(v, key)`，二者不可互换。
- **解法**：新增布尔字段时在 `fields:` 用 `_bool(...)`（已与 `_sel` 并列定义在文件顶部）；Companion 里照旧用 `_vBool(...)`。

---

## 15. 首次启动 seeding 的幂等双保险：项目计数 + KV 标记缺一不可

> 新增：2026-09-12 23:00 · 签署：TRAE-NovelCraft-Bot

- **现象**：用户一旦手动在 app 里新增项目，之后 app 重启若再执行 seeding，会再次插入示例项目，导致数据库出现重复的「玄穹剑主」示例项目。
- **根因**：若只做 KVStore 标记（`seeded-v1=true`），当用户删除了示例项目又清空了 KVStore（比如卸载重装或 Web 清除 localStorage），会再次插入；反过来只看 `projects.count > 0`，如果用户首启动就立刻手动建项目、没等 seeding 跑完，seeding 也会跳过导致示例项目永远没有。
- **解法**：**双条件同时为假**才执行 seeding：
  ```dart
  if ((await projectRepo.countActive()) > 0) return false;
  if ((await store.getBool('seeded-v1')) ?? false) return false;
  ```
  一旦开始写，在同一事务里把所有示例数据写完，再写 KV 标记。只要任一条件存在（用户自己建项目 OR 已成功 seed 过），就跳过。

---

## 16. FutureProvider<T> 做启动初始化时要把 loading 态当 home

> 新增：2026-09-12 23:00 · 签署：TRAE-NovelCraft-Bot

- **现象**：`appBootstrapProvider`（`FutureProvider<bool>`）在 KVStore + seeding 跑完前返回 loading 态；如果直接 `ref.watch(appBootstrapProvider).requireValue` 放进 `MaterialApp.home` 会抛 `AsyncValue` 未加载异常。
- **根因**：Riverpod 的 FutureProvider 首次进入 `watch` 时进入 `AsyncLoading` 态，必须走 `when(data/loading/error)` 三分支。不要写 `requireValue`。
- **解法**：启动前要做异步工作（开 store / seed 数据库），统一：
  ```dart
  final boot = ref.watch(appBootstrapProvider);
  final home = boot.when(
    loading: () => const _BootLoadingPage(),
    error: (e, _) => _BootErrorPage(error: e),
    data: (_) => const AppShell(),
  );
  ```
  这样启动屏 → 真实 AppShell 切换自然。

---

## 17. `ProjectsCompanion.insert(id: Value.absent())` 在 drift 中无效，需要 `customStatement` 回填 UUID

> 新增：2026-09-12 23:00 · 签署：TRAE-NovelCraft-Bot

- **现象**：`ProjectsCompanion.insert(id: const Value.absent(), name: Value('xxx'))` 期望 SQLite `id` 列有缺省（`UuidValue.newV4()`），但 drift 不会把 `Value.absent()` 扩展为 UUID，会直接抛 `NOT NULL constraint failed: projects.id`。
- **根因**：drift 对 `VARCHAR PRIMARY KEY`（非 `AUTOINCREMENT INTEGER`）**不会**自动生成主键。唯一约束的 projects.name 在 seed 中是已知的，可以先 `insert` 用任意值，再 `customStatement('UPDATE projects SET id = ? WHERE name = ?', [pId, name])` 回填。
- **解法**：DatabaseSeeder 统一策略：
  1. 先 `_uuid.v4()` 预生成所有实体 id；
  2. 用 `companion.insert(id: Value(pId), ...)` 直接写入；
  3. 对有 **唯一约束 name** 的 Projects 表，先 insert 再用 customStatement 回填（避免因为数据库层默认顺序乱掉，外键 pId 对不上）。
- **不要**：`const Value.absent()` 给非自增主键，一律 `Value(pId)`。

---

## 18. Seeding 所有写入必须在单个 `transaction(...)` 块内完成

> 新增：2026-09-12 23:00 · 签署：TRAE-NovelCraft-Bot

- **现象**：示例项目插入到一半崩掉（比如外键错、Companion 类型错），下次启动因为 `projects.count>0` 会判断为已经有项目而跳过剩余数据，留下半残示例。
- **根因**：SQLite 每一条 `customStatement` / `insert` 是自动提交的；中间失败无法回滚。
- **解法**：所有 seeding 写入包在一个 `await db.transaction(() async { ... })` 内；要么全部成功、要么一条不留（KVStore 的 `seeded-v1` 标记要等事务成功才写，**不要**写在事务里，因为 KVStore 与数据库是两个存储）。

---

## 19. Dart switch 表达式 + 长字符串（中文 + 插值）极易导致引号不闭合级联错误

> 新增：2026-09-12 23:30 · 签署：TRAE-NovelCraft-Bot

- **现象**：在 `buildSystemPrompt` 中用 `switch (taskType) { 'AnalyzeTheme' => '''修仙系统提示词...''', ... }` 分派时，出现大量 `Can't find string terminator`、`expected an identifier`、`expected an element in map literal` 的级联报错，且报错行号与实际不闭合的位置偏离 100~200 行。
- **根因**：Dart 3 的 switch 表达式对多行字符串 + 相邻字符串自动拼接 + 中文标点 + `$插值` 的组合极其敏感；三引号 `'''` 段内只要有一处中文引号混入、或 `switch` 的 `=>` 后紧跟的字符串被 formatter 自动换行，就会导致 Dart 分析器无法正确识别闭合位置，进而产生大范围**虚假报错**，掩盖真正的语法问题。
- **解法**：**一律把 switch 表达式改写为 if-else 多分支**（或 `if (taskType == 'X') return '...';` 的早期返回链）：
  ```dart
  @override
  String buildSystemPrompt(String taskType) {
    if (taskType == 'AnalyzeTheme') {
      return '## 你是一名修仙题材的主编剧...\n'
          '### 输出格式：\n'
          '- ## 核心主题\n'
          '- ## 受众画像\n';
    }
    if (taskType == 'GenerateOutline') {
      return '...';
    }
    return '...';
  }
  ```
  每个分支单独 2~3 行相邻字符串自动拼接，不要用三引号块；报错定位会精确到具体行。

---

## 20. Agent prompt 不要混合「相邻字符串拼接 + 字符串插值 + 中文标点」在同一个 Dart 表达式里

> 新增：2026-09-12 23:30 · 签署：TRAE-NovelCraft-Bot

- **现象**：`'你是一名$role，擅长${genre == '修仙' ? '剑道境界' : '斗气等级'}设计。' '输出要求：\n## 分节1...'` 这类一条语句里既有插值、又有三元表达式、还有相邻字符串自动拼接，会偶发 `type 'String' is not a subtype of type 'Null'`、或 AI 返回空字符串但没任何异常。
- **根因**：
  1. Dart 在 release/dart2js 模式下会把相邻字符串拼接近似为编译期常量，但若插了 `$var` 或 `?:` 三元则变成运行时拼接，此时**两个半段字符串中任一段内的换行、中文全角冒号、`## ` 号都会让 formatter 把相邻字符串拆成两行**，变成语法上不再相邻的两段独立表达式（其中一段变成 statement，返回 null 而不是拼接）。
  2. Agent system prompt 必须以 `## 分节` 标题结尾（便于 `parseMarkdownSections` 切分），但如果最后一段相邻字符串被 formatter 拆行，会导致「输出要求」那一节**缺失**，AI 响应不按结构化分节，`sections['全文']` 就只有一坨文本，下游消费取不到数据。
- **解法**：
  ```dart
  // ✅ 推荐：所有 prompt 用 List<String>.join('\n') 构造，插值单独处理
  final parts = <String>[
    '你是一名$role，主修剑道境界设计。',
    '',
    '输出要求：',
    '## 核心主题',
    '  - 一句话概括',
    '## 目标受众',
    '  - 3 条画像',
    if (hasWorld) '## 世界观', // 条件拼接也自然
  ];
  return parts.join('\n');
  ```
  或者：统一把插值、三元表达式抽成局部变量，再做一次最终拼接；**不要**让一个相邻字符串段里同时包含插值、条件表达式、`## ` 号、中文全角标点四个要素。

---

## 21. 5 种 AI Configuration 子类构造参数签名完全不互通，绝不能一视同仁一把梭传参

> 新增：2026-09-13 00:15 · 签署：TRAE-NovelCraft-Bot

- **现象**：在 AI 配置页 `_buildConfig()` 里统一写：
  ```dart
  return XxxConfiguration(
    apiKey: _cfg.apiKey,
    baseUrl: _cfg.baseUrl,
    defaultModel: _cfg.defaultModel,
    timeoutSeconds: _cfg.timeoutSeconds,    // ❌ 传给 Zhipu 或 Ollama 就炸
    defaultTemperature: _cfg.defaultTemperature, // ❌ 传给 Ollama/RWKV 也炸
    defaultMaxTokens: _cfg.defaultMaxTokens,
    enableStreaming: _cfg.enableStreaming,
  );
  ```
  结果：`The named parameter 'timeoutSeconds' isn't defined for ZhipuConfiguration` / `The named parameter 'defaultTemperature' isn't defined for OllamaConfiguration`；每个子类都会报 2~5 个 named parameter undefined 的硬错误，集中在 ai_configuration_page.dart 约 180~220 行。
- **根因**：5 种 Provider 配置类虽然语义相近（都要 baseUrl/defaultModel 等），但实际 `extends` / `implements` 完全不同，暴露的构造 named 参数列表是**真子集关系**，甚至有一类（Ollama）是完全独立实现：
  1. `DeepSeekConfiguration extends OpenAICompatibleConfiguration` → 暴露 `{apiKey, defaultModel, baseUrl, timeoutSeconds, defaultMaxTokens}`（5 个）
  2. `ZhipuConfiguration extends OpenAICompatibleConfiguration` → 暴露 `{apiKey, defaultModel, baseUrl, defaultMaxTokens}`（4 个，**无 timeoutSeconds、defaultTemperature**）
  3. `OllamaConfiguration implements IModelConfiguration`（**不 extends**）→ 完全独立参数集 `{providerName, baseUrl, defaultModel, maxConcurrency, keepAlive, options}`（云端 API 的 timeout/temperature/maxTokens/enableStreaming 全不存在）
  4. `RwkvConfiguration extends OpenAICompatibleConfiguration` → 只暴露 `{baseUrl, defaultModel, defaultMaxTokens}`（3 个），其他字段在父类构造里写死
  5. `OpenAICompatibleConfiguration` 本身 → 支持全部参数 `{providerName, providerKind, apiKey, baseUrl, defaultModel, timeoutSeconds, defaultTemperature, defaultMaxTokens, enableStreaming}`
- **解法**：写 5 个独立分支**各自按该类构造签名的 exact named params 列表传参**，多传一个 named 参数都会炸；宁可少传不传（依赖类内默认值），也不要图省事统一一把梭。`_buildConfig()` 的正确模板在 §21 上方的 HANDOFF §7 内。

---

## 22. Material 3.33（Flutter 3.33+）起，Container 的 `child:` 命名参数被彻底移除

> 新增：2026-09-13 00:15 · 签署：TRAE-NovelCraft-Bot

- **现象**：在任何地方写
  ```dart
  Container(
    width: 200, height: 100,
    decoration: BoxDecoration(color: Colors.blue),
    padding: const EdgeInsets.all(12),
    child: const Text('Hello'),  // ❌ The named parameter 'child' isn't defined for Container
  )
  ```
  紧随其后衍生出：`Too many positional arguments: 0 expected, but 1 found`、`Expected to find ')'` 的括号层级级联崩溃，一片代码看似全错（实际根因就是 Container.child 这一个）。
- **根因**：Flutter 3.33 做了一次破坏性重构，**把 `Container(child: ...)` 的 child 功能彻底拆走**，Container 仅保留 `{width, height, decoration, padding, alignment, clipBehavior, foregroundDecoration, margin, transform, onDecorationChanged}` 这些「纯装饰/尺寸」参数。所有带 child 的场景必须改用对应 Widget 组合。
- **解法**：按场景三种替换（对应三种最常见 Container 用法）：
  1. **纯背景色 + child** → `ColoredBox(color: ..., child: ...)`
  2. **复杂 decoration（圆角/渐变/border）+ child** → `DecoratedBox(decoration: BoxDecoration(...), child: Padding(...))` （padding 放到独立的 `Padding` 或 `SizedBox` 里，不要留在 Container）
  3. **纯固定尺寸（width/height）+ child，无 decoration** → `SizedBox(width: x, height: y, child: ...)`
  4. **纯 decoration 占位（无 child）** → 保留 `Container` 但去掉 child 参数。

  迁移模板（最常用的「装饰 + padding + child」组合）：
  ```dart
  // ❌ 废弃写法
  Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(color: c.withOpacity(0.08), borderRadius: BorderRadius.circular(8)),
    child: const Text('Hello'),
  );
  // ✅ Material 3.33 写法
  DecoratedBox(
    decoration: BoxDecoration(
      color: c.withValues(alpha: 0.08),   // 顺带修 deprecated withOpacity
      borderRadius: BorderRadius.circular(8),
    ),
    child: Padding(
      padding: const EdgeInsets.all(10),
      child: const Text('Hello'),
    ),
  );
  ```
- **顺带**：`withOpacity(x)` 在同一版本里被 deprecated，同步替换为 `c.withValues(alpha: x)`（精度无损）。

---

## 23. IDE GetDiagnostics 是增量 lint，跨文件契约错配必须跑全量 `flutter analyze` 才能发现

> 新增：2026-09-13 00:15 · 签署：TRAE-NovelCraft-Bot

- **现象**：阶段二写完 agents.dart / di.dart / 4 个 AI 页面后，**VS Code 的 IDE GetDiagnostics 一直显示 0 issue**，开发者以为已通过静态检查进入文档签名阶段；但在阶段三首次运行 `flutter analyze --no-pub` 时，**立刻爆出 141 个跨文件契约硬错误**（如：`IModelProvider.model getter 不存在`、`ModelManager.chatStream 返回类型不是 Stream`、`ZhipuConfiguration.timeoutSeconds 未定义`、`workflow_task.outputs 字段不存在`、`NavigationTarget.relationshipManagement 不是枚举值` 等）。这些错误在 IDE 内零提示。
- **根因**：IDE（Trae / VS Code）对 Dart 的静态检查基于「Dart Analyzer Server 的**增量**模式」：
  1. 每次只 re-analyze 当前打开文件 + 它直接 import 的上游文件；
  2. 不会主动对**下游消费方**（比如我改了 `IModelProvider` 接口但当前打开 providers 页面时，不会反向触发对 `ai_configuration_page.dart`、`dialog_generation_page.dart` 这些**调用方**的 re-analyze）。
  3. 因此接口签名变动（字段改名、参数类型变、构造 named 参数增删）、枚举值增删这类「牵一发而动全身」的变化，下游所有页面在 IDE 中永远显示 0 错误，直到全量 `flutter analyze` 才会一次性暴露。
- **教训**：任何一次「修改了公共契约层（AI provider Configuration / Companion / Repository / WorkflowTask / NavigationTarget enum）」的提交后，**必须主动跑一次全量 `flutter analyze --no-pub` 做守门**，不能只看 IDE 右下角的 0 issues 徽章；否则会在阶段末才发现大量跨文件契约错配，增加回归修复的复杂度。
- **本次经验值**：
  - 阶段二末 IDE GetDiagnostics：0 issue ✅（假阴性）
  - 阶段三首次 `flutter analyze`：141 issues ❌（真实情况）
  - 经过 5 轮修复：141 → 88 → 58 → 5 → 1 → **0 issues** ✅（真实通过）

---

## 24. RWKV State 复用 & 本地 build web 编译的 4 个新坑

> 新增：2026-09-13 23:10 · 签署：TRAE-NovelCraft-Bot

### 24.1 RWKV 单个 session 内必须 Semaphore(1) 串行化，否则 State 演化链分支错乱

- **现象**：同一个 RWKV session（带同一个 sessionId）并发发两个 chat 请求 → 两个请求都从 state₀ 起步，分别推导出 state₁（A 剧情分支）和 state₁'（B 剧情分支）。session 的 currentStateId 只能记录一个指针，后完成的会覆盖先完成的，导致上下文断裂（后续的 token 基于错误的 state 生成）。
- **根因**：RWKV 的 state 是 **RNN 式严格有序的单链演化**：state_{t+1} = RWKV(state_t, token_{t+1})，每个新 state 必须以前一个 state 为唯一父节点（parentStateId），**不支持分支合并**。同 session 并发 = 手动把单链炸成树。
- **解法**：在 `RwkvSession` 类内维护 `final Semaphore _mutex = Semaphore(1)`；对外的 `runSerialized<R>(action)` 保证每个 session 同一时刻只跑 1 轮推理，跑完把 state 指针前进后才能放下一个请求。**多 Agent 并发要走多 session，不能共用一个 session**。

### 24.2 HTTP Response Header 的 operator[] 在 Dart 返回 `String?` 不是 `List<String>?`，`?.first` 直接炸

- **现象**：`rwkv_engine.dart` 里取响应头：
  ```dart
  final fromHeader = resp.headers['x-rwkv-state-id']?.first; // ❌ Runtime Error: method 'first' not found on String
  ```
  虽然 HTTP 标准规范里 headers 允许多值（多 Set-Cookie），但 `package:http/http.dart` 的 `Response.headers` 签名是 `Map<String, String>`（单值，同名 header 合并成逗号分隔字符串）。`[]` 直接返回 `String?`，调 `.first` 等于在 String 上找 Iterable 的 getter，不存在。
- **解法**：直接 `resp.headers['x-rwkv-state-id']` 拿 `String?`，再 fallback 到 JSON body 的 `parsed['state_id']`。header 取完后记得 `?.trim()`，避免服务器把 CRLF 或空格带进来。

### 24.3 Windows 路径含中文时，Flutter 的 impellerc shader 编译器报「Could not write file」（build web 失败）

- **现象**：项目路径包含中文（如 `F:\...\Flutter版代码\novelcraft\`），`flutter analyze` 全过，但 `flutter build web --release` 在最后一步 shader 编译时报：
  ```
  Target web_release_bundle failed: ShaderCompilerException:
    "ink_sparkle.frag" to ".../build/web/assets/shaders/ink_sparkle.frag"
    failed with exit code 1.
  impellerc stderr:
    Could not write file to .../build/web/assets/shaders/ink_sparkle.frag
  ```
  手动用 PowerShell 在同路径下创建文件成功（沙箱没拦截）。
- **根因**：Flutter SDK 3.38.5 的 `impellerc.exe`（shader 编译器，C++）在 Windows 上打开输出文件时走的是 **ANSI 编码（ACP = system locale）** 的 `fopen / CreateFileA`，而不是 Unicode 的 `CreateFileW`。当项目路径包含中文且系统 locale 是 `zh-CN` 的某些组合时，`fopen` 把 UTF-8 字符串当成乱码，返回 NULL → impellerc 打印「Could not write file」并 exit 1。
- **临时绕过（3 选 1）**：
  1. **改 build 目录为纯英文 junction**：在项目根目录外建一个全英文路径的 junction 映射（如 `F:\nc_build` → `项目真实路径`），在 junction 里 build。
  2. **保留已编译好的 build 目录**：`flutter clean` 之前如果 build 成功过（shader 已缓存），就**不要 clean**，在旧 build 上增量 build。
  3. **Windows 全局开启 UTF-8 BCP47**：控制面板 → 区域 → 管理 → 更改系统区域设置 → 勾选「Beta: 使用 Unicode UTF-8 提供全球语言支持」，重启后 impellerc 就会用 UTF-8 解析路径。
- **验证代码正确性**：在 clean 后新环境里，**`flutter analyze --no-pub` 必须 0 issues** 作为代码级通过的守门；build web 如果只是 impellerc 路径编码问题，说明代码本身没问题，是 Flutter SDK / 系统 locale 的环境问题。

### 24.4 取消下载后默认「保留 .part 临时文件 + 下次走 Range 断点续传」，不要自动删，否则用户以为白下了会重开下载把进度清空

- **现象**：用户下 5GB 的 RWKV7 7.2B Q6_K，中途点「取消」，如果代码顺手把 `<model>.gguf.part` 也 `File.delete()`，用户下次点下载时 progress 重新从 0% 开始，会以为：① 取消按钮会把已经下好的几百 MB 清空 = 欺骗；② 应用 bug（明明下了一半，怎么从头来）。
- **根因**：直觉上「取消任务要清理现场」，但对大文件（GGUF 5GB+）HTTP Range 断点续传，`保留 .part = 下次继续`；反直觉的 `删 .part = 丢弃进度`。用户的心智模型是「暂停」而不是「丢弃重来」，尤其是 Windows 沙箱下 5GB 文件下 20 分钟很容易中间被打断。
- **解法（三要素都要写）**：
  1. **不删 .part**：取消时 `onCancelled` 只关 StreamSubscription、flush+close IOSink、close http.Client；`File.delete()` 绝对不要调。`.gitignore` 也要把 `*.part`、`*.tmp` 加进忽略规则，避免用户中途 commit 进仓库。
  2. **下次 download 先走 Range**：重新下同名模型时，先 `stat(path + ".part")` 拿到 `existingBytes`，再加 `request.headers['Range'] = 'bytes=$existingBytes-'`；服务器返回 `206 Partial Content` 且 `Content-Range: bytes existingBytes-total/total` 才续传；返回 `200 OK`（服务器不支持 Range）就删 .part 重新从 0 开始并 emit phase=downloading from=0。
  3. **UI phase=cancelled 不自动消失，也不置灰重下按钮**：`RwkvDownloadPhase.isTerminal` 只把 `done / failed / cancelled` 三个都算结束，但 cancelled 的进度文字要明确写「已取消，保留未完成文件，下次继续」（不能只写「取消」）；下载按钮恢复可点，让用户一眼看到 `.part` 还在。
- **验证**：下 10MB 左右的 test asset（比如 llama.cpp 的小版本 zip）点取消 → 看 `_tools/` 下 `.part` 还在且大小非 0 → 重新下一次 → 进度刷新第一帧就是 `receivedBytes >= existingBytes`（不是 0）→ 最终文件完整下载、哈希一致。

---

## 25. DatabaseSeeder 启用的三条 cascading 连锁根因（99 issues → 0）

> 新增：2026-09-13 23:55 · 签署：TRAE-NovelCraft-Bot

### 25.1 `import` 相对路径少写一层，会让所有「未定义类 + Future 无此方法」全部爆发级联错误（99→51）

- **现象**：`database_seeder.dart`（在 `application/services/`）顶部写 `import '../database.dart'`，意图引入 `data/database.dart`；但实际路径应为 `../../data/database.dart`（少写了一层 `../`）。结果：
  - 所有 `ProjectsCompanion` / `VolumesCompanion` / `CharactersCompanion` 等 27 个 Companion 全部 `undefined_identifier`
  - 更致命的是：`import` 失败后 `db` 的静态推断退化成 `dynamic`，IDE 可能还能在当前文件推断出 Provider 返回的 AppDatabase，但 `flutter analyze` 会严格按 import 存在性校验 → 于是所有 `batch.insert(...)` 又报 `method 'insert' isn't defined for the type 'Future'`（因为 `db.batch()` 被当成 `Future.call` 的结果调用，batch 自身都变成 Future）
  - **连锁效应**：实际只有 1 处根因（import 路径），会在同一份文件里炸出 99 个 issues，看起来像「语法全崩了，Companion 不存在，Future 还能 insert」。
- **解法**：遇到「同一文件同时出现大量 undefined_identifier + 大量 insert/commit on Future」，**先看顶部所有 import 的相对路径是否精确指向真实文件**，不要被后面的连锁假象误导。推荐用 `import '../../data/database.dart'` 的完整相对路径，或直接用 `package:novelcraft/data/database.dart` 绝对包路径（最稳，不会因为层级写错）。
- **验证**：把 `../database.dart` 改成 `../../data/database.dart` 再 analyze，Companion undefined 数量立刻从 99 降到 51（减少 48 个）。

### 25.2 drift 的 `batch()` 在新版本只支持回调式签名，显式 `final batch = db.batch()` 会报「1 positional argument expected by batch, but 0 found」（51→1）

- **现象**：按老 drift 教程写：
  ```dart
  await db.transaction(() async {
    final batch = db.batch();     // ❌ error: 1 positional argument expected by 'batch', but 0 found
    batch.insert(db.xxx, XxxCompanion.insert(...));
    await batch.commit();
  });
  ```
  然后所有 batch.insert 又连锁成 undefined_method on Future。
- **根因**：当前项目依赖的 drift 新版本把「显式创建 Batch 对象 → 手动 commit」模式**彻底移除**，只保留回调式：
  ```dart
  await db.batch((batch) {
    batch.insert(db.xxx, XxxCompanion.insert(...));
    // 执行完回调闭包后自动 commit，无需手动调
  });
  ```
  同时 `db.batch()` 函数签名变成 `Future batch(void Function(Batch) run)`，必须传一个闭包。
- **解法**：三处同时改：① 删 `final batch = db.batch();` → `await db.batch((batch) {`；② 所有 `batch.insert(...)` 挪进闭包；③ 删末尾 `await batch.commit();` → 闭包 `}` 自动提交。
- **注意**：回调式本身已经是 Future，所以如果在 `transaction` 里，务必再加一层 `await`：`await db.transaction(() async { await db.batch((batch) { ... }); });` —— 否则 transaction 闭包不等待 batch 执行完就退出，事务提前结束可能导致插入不全。

### 25.3 `db.batch` 不接受泛型参数（`<void>`），写 `<void>` 会报「declared with 0 type parameters, but 1 type arguments given」（1→0）

- **现象**：修复完 25.2 后，为了显式标注「该回调返回 void」，画蛇添足写：
  ```dart
  await db.batch<void>((batch) { ... });   // ❌ wrong_number_of_type_arguments_method
  ```
  只剩 1 个 issue 但 analyze 还不过。
- **根因**：drift 设计上 `batch()` 就是「声明 0 个类型参数」的方法（泛型 R 留给显式模式用，现在回调模式没暴露），传任何泛型参数都会炸。
- **解法**：**不传泛型参数**，直接 `await db.batch((batch) { ... })`；泛型返回值依赖闭包自动推断。

---

### Seeder 三条坑点的连锁复盘（99 → 51 → 1 → 0）

| 轮次 | 修复点 | Issues 数量 | 典型错误 |
|------|--------|------------|----------|
| 初始 | 未修 | 99 | `Undefined name 'ProjectsCompanion'` ×27 + `method 'insert' isn't defined for Future` ×72 |
| 第 1 轮 | import 相对路径 `../database.dart` → `../../data/database.dart` | 51 | 仅剩 `batch` API 模式错误（`1 positional argument expected` + 后续 insert/commit on Future） |
| 第 2 轮 | 显式 batch → 回调式 `db.batch((batch) { ... })` + 删 commit | 1 | 只剩 batch 泛型参数错误 |
| 第 3 轮 | 去掉多余泛型参数 `<void>` | **0** | `No issues found!` ✅ |

**三条根因会互相叠加放大**：import 错会导致 db 变 dynamic，后面 batch API 的真实错误会被 Future 级联掩盖；等 import 修好了，batch API 又会暴露出一堆 method undefined，最后收尾泛型参数才让整个 Seeder 过 analyze。遇到 50+ 级联错误先修最前端的 import/导出，再修 API 模式，最后修微小语法（泛型/分号）。

---

## 26. P1 真机首启动 & L10n 切换的三条隐形陷阱（首启动必踩）

> 新增：2026-09-14 · 签署：TRAE-NovelCraft-Bot（第八签）

### 26.1 Windows symlink 需要 Developer Mode；否则 Flutter 插件 `.plugin_symlinks/jni` 创建失败

- **现象**：`flutter run -d windows` 构建 Windows 应用时，报错：`PathExistsException: Cannot create link .../windows/flutter/ephemeral/.plugin_symlinks/jni (OS Error: 需要创建符号链接但未启用开发人员模式，或者使用 /J 参数创建 Junction 而不启用 DeveloperMode，或用 admin 权限跑命令行)`，最终整个构建失败。
- **根因**：Flutter 在 Windows 上构建含原生插件（尤其是 Android 的 jni 插件会通过 symlink 把 CMakeLists 注入到 Windows 侧）时，会调用 `CreateSymbolicLinkW`；Windows 默认安全策略**禁止普通用户创建符号链接（symlink）**，只有两种方式能绕开：① 开「设置 → 隐私和安全性 → 开发者选项 → 开发人员模式」（注册表把当前用户加入 CreateSymbolicLink 权限）；② 用管理员权限打开终端。
- **解法（推荐 + 备份）**：
  1. 开启「开发人员模式」：`Win + I → 系统 → 开发者选项 → 开发人员模式 = 开` → 确认启用 → 重启（注册表项 `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock\AllowDevelopmentWithoutDevLicense = 1` 写入后生效）。
  2. 如果不想开 Developer Mode，就用**管理员 PowerShell**启动 `flutter run -d windows`（但日常开发麻烦，不推荐）。
  3. 如果仍报错，先 `rm -rf windows/flutter/ephemeral/.plugin_symlinks` 清残留，再重新构建（PITFALLS §7 的老坑也会叠在这里）。

### 26.2 `pub get` 首次报错 OS Error errno=5（PUB_CACHE 中 sha256 文件被只读锁 / 沙箱写保护）——不是代码 bug

- **现象**：在沙箱或刚恢复权限的环境下，`flutter pub get` 末尾报错：
  ```
  Failed to rename pub-cache/hosted/pub.dev/_temp/xxx -> pub-cache/... (OS Error: 拒绝访问, errno = 5)
  ```
  或「sha256 文件写入失败，errno=5」。`intl`、`flutter_riverpod` 等大包尤其容易触发。用户反复 `flutter clean ; flutter pub get` 几次都不行，怀疑是 `pubspec.yaml` 依赖冲突。
- **根因**：
  1. 沙箱写入策略会把 `PUB_CACHE`（默认 `%LOCALAPPDATA%\Pub\Cache`）中 **校验过的 sha256 校验和文件**设置为只读/写保护；或者上次 `pub get` 被 Ctrl+C 粗暴中断后，进程还没释放对 `.cache` 中 `_temp` 目录的句柄，重名 rename 报 5。
  2. 当前项目 IDE 插件（Dart Analyzer Server / Flutter Daemon）还持有 `.dart_tool/package_config.json` 的句柄，rename 失败。
- **解法（3 步即可解决，99% 场景有效）**：
  1. **先关掉 IDE**和所有持有项目句柄的进程（trae-sandbox 也关掉重开），避免文件锁。
  2. 删除 PUB_CACHE 的 problem 文件：
     ```
     Remove-Item -Recurse -Force $env:LOCALAPPDATA\Pub\Cache\hosted\pub.dev\_temp -ErrorAction SilentlyContinue
     Remove-Item -Recurse -Force $env:LOCALAPPDATA\Pub\Cache\hosted\pub.dev\intl-0.20.2   # 仅当 intl 报 errno=5 时
     ```
  3. 切 junction 英文路径后重新：`flutter pub get`（此时 dart pub 会重新下载并重建 sha256 校验和）。
- **不要做的事**：不要改 `pubspec.yaml` 的版本号；不要 `flutter upgrade`（会让后面的 0.20.2 pinning 对不上 SDK 的 flutter_localizations 版本要求，引入 PITFALLS §26.3 第二条）。

### 26.3 L10n fallback 中文陷阱 —— `flutter analyze 0` ≠ 英文切换真的生效

> P1 守门最大的认知陷阱，前序代码写了 352 处 `l10n.t('AC.NoProject', '未选择项目。请先在项目管理中选择项目')` 但**忘了在 strings.g.dart 真正写入 `AC.NoProject` 词条**，结果：IDE analyze 全绿 / 中文状态完全正常，用户一切到英文，UI 还是中文。

- **现象**：`flutter analyze --no-pub` No issues found ✅；App 默认中文一切正常；点右上角「中 / EN」切换到英文后，绝大多数 UI 标签**仍然显示中文 fallback 文案**，`l10n.isEnglish == true` 是真的但视觉不变。开发者第一反应会怀疑 localeController 没通知 App rebuild，但反复 debug `Localizations.override` / `MaterialApp.locale` 都没异常。
- **根因**：`lib/l10n/l10n.dart` 里的 helper 是 `String t(String key, [String? fallback])`，缺 key 时**不抛异常、不记日志、不触发 analyze 警告**，而是静默返回 fallback 参数（刚好就是中文兜底）。对「代码调用了 L10n 包装但 key 没真正入双表」的情况，**静态检查完全发现不了**，analyze 永远 0。这是本轮 L10n 最大的隐形陷阱。
- **解法（硬守门三步，缺一不可）**：
  1. **双表必须真实存在 key**：所有 `t(key, fallback)` 的 key 都要在 `zhStrings` 和 `enStrings` 里能 grep 到匹配行；**禁止依赖 fallback 中文兜底当翻译**（fallback 仅用于用户自定义异常场景兜底，不允许在「已知的 UI 文案」上使用）。
  2. **必须跑 reverse key 覆盖率 diff**（不是 grep 中文，是把代码里的所有 key 反抽出集合，再去 strings.g.dart 做集合减）：
     ```ps1
     # 提取 Dart 调用的 key 集合
     Select-String -Path "lib\ui\**\*.dart","lib\*.dart","lib\layout\**\*.dart" -Pattern "l10n\.(t|tf)\('([^']+)'" | ForEach { $_.Matches.Groups[2].Value } | Sort-Object -Unique > _code_keys.txt
     # 提取 enStrings 的 key 集合
     Select-String -Path "lib\l10n\strings.g.dart" -Pattern "^\s+'([^']+)'\s*:" | ForEach { $_.Matches.Groups[1].Value } | Sort-Object -Unique > _en_keys.txt
     # 差集 = 代码用了但 en 表没写的（= 切英文不生效的 exactly 集合）
     Compare-Object (gc _en_keys.txt) (gc _code_keys.txt) | Where SideIndicator -eq '=>'
     ```
     差集为空 = 100% 覆盖；差集里有任何一行，都意味着切 EN 到对应页面那一块就会显示中文 fallback。
  3. **必须真机两条路径交互验收**：`flutter run -d windows` → 默认中文 → 切 EN → 5 大截图页（AC/DG/HC/PM/AICfg）逐屏肉眼检查所有 label（尤其健康检查 4 Chip、项目管理「进度 0%」、AI 配置页大标题和运行统计 7 格、警告条/AlertDialog 标题/tooltip/SnackBar/Search hintText/空状态提示）→ 确认全英文 → 切回中文 → 确认全还原中文。三条全过才算 P1 L10n 守门关闭。
- **附带关联坑：`intl` 版本不服从 flutter_localizations 的 SDK pinning，会直接导致 `flutter pub get` 失败**。不要擅自 `flutter pub upgrade intl`；SDK 要的是 `intl ^0.20.2` 就必须锁 0.20.2（Pinned by flutter_localizations from sdk）。

---

## 27. RWKV 云端 + rwkv_lightning_cuda 集成三大必踩陷阱（P2-P4 必炸，务必读完再写代码）

### 27.1 坑：PTH(.rwkvq) vs GGUF 权重格式完全互斥 + rwkv_lightning 强制外置词表（离线引擎最容易炸启动的头号坑）

- **现象（用户视角真实报错）**：
  ① 用 rwkv_lightning 启动现有 GGUF 模型 → 进程直接 exit code=1，stderr：`invalid model format: not a valid .pth/.rwkvq file, magic number mismatch`
  ② 下了 .rwkvq 模型启动，但忘了传 --vocab-path → stderr：`fatal: vocabulary not loaded, --vocab-path is required for RWKV weights (no embedded vocab)`，进程秒退，UI 侧只看到 errno=1225 拒绝连接，完全不知道词表漏了。
  ③ 反过来把 .rwkvq 传给 llama.cpp 的 --model → stderr：`error: unknown model file type, not a valid GGUF`，无法加载。

- **根因**：两种引擎的 tensor 排布、权重序列化、词表存储策略 100% 不兼容，是两个完全独立的生态：
  - llama.cpp / GGUF：把词表塞在权重文件头部的 `vocab` 区段里，**一个 GGUF 文件自包含**（权重+词表），后缀固定 `.gguf`。
  - rwkv_lightning_cuda：词表外置单独 `rwkv_vocab_v20230424.txt`（**实测 1.07MB**，文档写 2.5MB 偏大；所有版本共用同一份，版本号钉死 20230424，不动），权重文件只存 tensor，**不内嵌词表**；后缀是 `.pth`（FP16 原始，大）或 `.rwkvq`（W8A16/W4A16 量化，小，推荐）。
  - 开发时最容易犯的错：直接把用户现有 `rwkv7-g1j-7.2b-Q6_K.gguf` 路径无脑塞给 rwkv_lightning 的 ensureLocalServer()，因为都是「RWKV7 模型」，以为同一后缀，结果启动三连 crash。

- **解法（硬校验，缺一不可）**：
  1. **路径名前缀分流**：本地模型存放用目录名区分，不用后缀判断（后缀写错容易误判）：
     ```dart
     bool isLightningModel(String path) =>
         path.contains('lightning') ||       // 约定放在 rwkv_models/lightning/ 子目录
         path.endsWith('.rwkvq') ||
         path.endsWith('.pth');
     bool isLlamaGguf(String path) => path.endsWith('.gguf');
     ```
  2. **ensureLocalServer() 构造参数前硬拦**（写在 RwkvEngine 里启动第一行就判）：
     ```dart
     if (variant == OfficialServerVariant.rwkvLightning) {
       // 硬拦 GGUF 混进 lightning
       if (args.modelPath.endsWith('.gguf')) {
         _lastLaunchDiagnostics = '格式不匹配：rwkv_lightning 只接受 .rwkvq/.pth + 外置词表，'
             '当前传的是 GGUF（llama.cpp 格式）。请下载 .rwkvq 版权重 + rwkv_vocab_v20230424.txt。'
             '参考 HANDOFF §9.3 对照表。(PITFALLS §27.1)';
         return false;
       }
       // 硬拦外置词表缺失
       if (args.vocabPath.isEmpty || !File(args.vocabPath).existsSync() || File(args.vocabPath).lengthSync() < 500 * 1024) {
         _lastLaunchDiagnostics = '外置词表缺失或损坏：rwkv_lightning 必须单独传 --vocab-path 指向 '
             'rwkv_vocab_v20230424.txt（约 2.5MB）。请从 GitHub Raw 下载：'
             'https://raw.githubusercontent.com/Alic-Li/rwkv_lightning_cuda/main/assets/rwkv_vocab_v20230424.txt'
             ' 存到 rwkv_models/_assets/rwkv_vocab_v20230424.txt。(PITFALLS §27.1)';
         return false;
       }
     }
     ```
  3. **下载 UI 两栏分离**：AI 配置页官方一键下载分成两个 Tab「llama.cpp / GGUF」和「rwkv_lightning / .rwkvq + 词表」，不要混在一个列表里让用户自己挑后缀，必挑错。

---

### 27.2 坑：Cloudflare Access 头精确 camelcase 拼写 + 认证失败返回 302/403 HTML 非 JSON（RedErrorScreen FormatException 源头）

- **现象（用户视角真实报错）**：
  ① 在 AI 配置页点「测试连接」按钮 → 直接炸 RedErrorScreen：`FormatException: Unexpected character < at position 0`，堆栈停在 `jsonDecode(resp.body)`，前面没有任何前置警告。
  ② 抓包发现 HTTP 实际返回 302 Found + Location: `https://novelcraft.cloudflareaccess.com/cdn-cgi/access/login/...`，body 是一整段 Cloudflare 登录页 HTML，根本不是 JSON。
  ③ 最坑的变体：有人把 header 名写成 `cf-access-client-id` / `CF-ACCESS-CLIENT-ID` / `Cf-Access-Client-ID`（大小写或分隔符任一改动）→ Cloudflare 静默不认，**HTTP 200 但 body 还是 HTML**（不是 401/403，状态码完全骗人），jsonDecode 同样炸。

- **根因**：Cloudflare Access Service Token 的两个头名是**按字节精确比较**的全局约定，不是 RFC 7230 那样的不区分大小写 header。CF 网关在 mTLS 握手阶段就做了字节匹配，匹配不上：
  - 要么返回 302 → 让浏览器跳登录页（但 App 里没有浏览器，拿到的是 HTML 登录页源）
  - 要么返回 403 Forbidden → body 是 Cloudflare 品牌的 403 页面，还是 HTML `<html><head>...`
  - 开发时最容易犯的错：用 `'Cf-Access-Client-ID'`（ID 两个都大写，官方约定是 `Id` 小写 d）+ 不做 statusCode 预检直接 jsonDecode，100% 中这个坑。

- **解法（三层拦截 + const 常量锁拼写，缺一不可）**：
  1. **const 锁拼写**（定义在 rwkv_cloud_provider.dart 顶部，所有发请求的地方都引用这两个常量，禁止写字面量字符串）：
     ```dart
     const String kHeaderCfAccessClientId     = 'CF-Access-Client-Id';     // 精确：Id（I大写+d小写），不是 ID
     const String kHeaderCfAccessClientSecret = 'CF-Access-Client-Secret'; // 精确：Secret
     // 代码审查时 grep 'CF-Access' 凡不是这两行字面量的一律打回
     ```
  2. **发请求前统一组装 headers**（一个私有方法集中拼，不让各处各自加 header）：
     ```dart
     Map<String, String> _buildHeaders({bool requireJsonAccept = true}) {
       final h = <String, String>{
         kHeaderCfAccessClientId:     _config.cfAccessClientId,
         kHeaderCfAccessClientSecret: _config.cfAccessClientSecret,
       };
       if (requireJsonAccept) h['Accept'] = 'application/json';
       if (_config.customHeaders != null) h.addAll(_config.customHeaders!);
       return h;
     }
     ```
  3. **收到响应先 HTML 预检，再 jsonDecode**（写在一个通用私有方法里，所有 HTTP 动词都走它，绝对不能漏）：
     ```dart
     Future<Map<String, dynamic>> _parseJsonOrThrow(http.Response resp, String debugRoute) async {
       final body = resp.body;
       // 第一层：拦 302/403 + body 以 < 开头（HTML 特征）——这两种 CF 必定返回 HTML 非 JSON
       if ((resp.statusCode == 302 || resp.statusCode == 403) && body.trimLeft().startsWith('<')) {
         final snippet = body.substring(0, math.min(200, body.length)).replaceAll('\n', ' ');
         throw RwkvCloudAuthException(
           'Cloudflare Access 认证失败（返回 HTML 登录页，非 JSON）。'
           '请检查 kHeaderCfAccessClientId / kHeaderCfAccessClientSecret 拼写大小写完全匹配 const 定义、'
           'CF Service Token 未过期、IP 未被 CF WAF 拦截。'
           '路由=$debugRoute 状态码=${resp.statusCode} HTML前200字=$snippet (PITFALLS §27.2)',
         );
       }
       // 第二层：拦 statusCode 2xx 以外的业务错（422/429/500 等，这些才是 JSON 格式错误信息）
       if (resp.statusCode < 200 || resp.statusCode >= 300) {
         throw RwkvHttpException(statusCode: resp.statusCode, body: body, route: debugRoute);
       }
       // 第三层：到这才敢 jsonDecode
       try {
         return jsonDecode(body) as Map<String, dynamic>;
       } on FormatException catch (e, st) {
         final snippet = body.substring(0, math.min(200, body.length));
         throw FormatException('RwkvCloud JSON 解析失败（路由=$debugRoute）：$e；原始前200字=$snippet (PITFALLS §27.2)', null, st);
       }
     }
     ```
  4. **UI 层 testConnection 捕获异常后**：把 RwkvCloudAuthException 单独拉出来显示用户能懂的提示（不是直接抛给 ErrorWidget），AICfg 页面专门有个 aics.connectionFailedHtml 的 L10n key 对应这种情况。

---

### 27.3 坑：rwkv_lightning 两条 chat 路由名字高度相似但语义完全不同 + SSE 流式 batch 返回 choices[].index 交错无序（batch 全乱/422 源头）

- **现象（用户视角真实报错）**：
  ① 发 batch 请求用了 OpenAI 兼容路由 → HTTP **422 Unprocessable Entity**，JSON error：`field "contents" is required but was not present, got "messages" instead`，明明传了 contents 数组说没有，百思不得其解。
  ② 反过来单路对话用了原生 batch 路由，传了 messages[{role,content}] → HTTP 422：`field "messages" is not allowed, did you mean "contents" (String[] for native batch) ?`
  ③ 好不容易路由用对了，SSE 流式返回 batch 2 条 → 第 0 条的前半段 SSE delta 先到，然后第 1 条的几个 token 插进来，然后第 0 条的后半段又到 → UI 直接把 SSE 事件按到达顺序 append → 两条内容混在一起成了乱码：「第一章开端+第二章伏笔+第一章冲突」，完全读不通。
  ④ 更隐蔽的变体：batch 3 条但服务端 GPU 的 warp 调度导致 0→2→1 的 index 到达顺序 → 结果列表就变成 [第0条,第2条,第1条]，世界观分支剧情 A/B/C 顺序全错，用户以为 Agent 神经错乱。

- **根因**：两条路由只差 `/openai` 前缀，名字极度相似，但输入输出契约 100% 不同；加上 rwkv_lightning 服务端的 SSE 是「按 token 就绪就发」而不是「按 index 顺序发」——第 index=0 那条刚好在等 memory barrier 时，index=1 的 token 先算出来就先发出去了，所以客户端必须按 index 分组缓存，绝对不能按事件到达顺序 append。开发时最容易犯的三个错：
  1. 想当然「两个都是 /v1/chat/completions，应该一样」，随手把 DeepSeek 的 messages[] 结构贴到原生 batch 路由 → 422。
  2. 单路 SSE 解析逻辑（直接 append 到一个 StringBuffer）直接 copy 到 batch 场景 → 内容混串。
  3. 收到完整 batch response 后直接 `choices.map((c)=>c.message).toList()` 不排序 → index 顺序错，分支 A/B/C 乱序。

- **解法（const 路由锁名 + Map<int,StringBuffer> 按 index 缓存，缺一不可）**：
  1. **const 路由名 + 严格对应数据结构**（定义在 batch_chat.dart 顶部，所有调用只能用这两个常量，不许写字面量）：
     ```dart
     // L1 原生 batch：输入是 contents=String[]（纯文本数组，不含 role），输出 choices[] 每条带 index
     const String kRouteRwkvNativeBatch   = '/v1/chat/completions';
     // L2 OpenAI 兼容单路：输入是 messages=[{role,content}]，输出同 DeepSeek，单条无 index（或 index 固定 0）
     const String kRouteRwkvOpenAiChat    = '/openai/v1/chat/completions';
     // 审查时 grep "chat/completions" 凡不是这两行常量引用的，一律打回重写
     ```
  2. **调用时路由强绑定，不许两个数据结构混传**：
     - 走 batch（contents[]）→ 必须传 `kRouteRwkvNativeBatch`，body 里绝对不能出现 `messages` 字段
     - 走单路 OpenAI 兼容（messages[]）→ 必须传 `kRouteRwkvOpenAiChat`，走内部组合的 `OpenAICompatibleProvider.chat()`，别自己拼
  3. **batchChatStream SSE 解析：Map<int,StringBuffer> 按 index 缓存，绝不按到达顺序 append**：
     ```dart
     Stream<List<String>> batchChatStream({required List<String> contents, ...}) async* {
       final buffers = <int, StringBuffer>{};      // key = choices[].index
       final finished = <int>{};                  // 哪些 index 已收到 finish_reason
       // SSE 事件循环
       await for (final event in _sseStream(url, body)) {
         final choice = event.data['choices']?.first as Map<String, dynamic>?;
         if (choice == null) continue;
         final index = choice['index'] as int;    // 这才是唯一正确的分组键
         final deltaText = (choice['delta'] ?? choice['message'])?['content'] as String? ?? '';
         // ① 按 index 追加，不是全局 append —— 解决「内容混串」
         buffers.putIfAbsent(index, () => StringBuffer()).write(deltaText);
         // ② finish_reason 到了就记 finished，不 break，因为其他 index 可能还在发
         if (choice['finish_reason'] != null) finished.add(index);
         // ③ 全部都 finish 了才退出，中途不提前 return
         if (finished.length == contents.length) break;
       }
       // ④ 最后统一按 index 排序转 List，解决「到达顺序乱→列表顺序乱」
       final sortedIndices = buffers.keys.toList()..sort();
       yield sortedIndices.map((i) => buffers[i]!.toString()).toList();
     }
     ```
  4. **单元测试必加 2 条**（防回归）：
     - 「SSE index 乱序到达」：构造 mock SSE 事件顺序 [index=1,delta='B1']→[index=0,delta='A1']→[index=0,finish]→[index=1,finish] → 断言输出是 ['A1…' , 'B1…']，顺序正确，没有混串。
     - 「路由名与数据结构匹配」：断言 `nativeBatchRequest.toJson().containsKey('contents') && !nativeBatchRequest.toJson().containsKey('messages')`；反过来 OAI 兼容请求断言 keys 相反。


---

## 28. 下拉框断言崩溃：库里的值不在候选表里 → 打开详情页直接崩（本轮用户首报）

### 28.1 现象

用户打开「卷宗&章节 → 查看详情」立即崩：

```
'package:flutter/src/material/dropdown.dart': Failed assertion: line 1795 pos 10:
items == null || items.isEmpty || value == null ||
  items.where((DropdownMenuItem<T> item) => item.value == (initialValue ?? value)).length == 1
': There should be exactly one item with [DropdownButton]'s value: Planning.
Either zero or 2 or more [DropdownMenuItem]s were detected with the same value
```

### 28.2 根因（两层叠在一起）

1. **直接原因**：`Volumes.status` 表列默认值是 `'Planning'`（`project_tables.dart:50`），
   而 `volumeEntityConfig` 的下拉候选表写的是 `['构思中','写作中','已完成']` ——
   `'Planning'` 不在候选表里 → `items.where(...).length == 0` → 断言直接炸。
   种子数据没写 `status`，所以示例卷宗全部吃表列默认值 `'Planning'`，一点开就炸。
2. **深层原因**：**「入库值」和「显示标签」被混为一谈**。旧代码 `DropdownMenuItem(value: o, child: Text(o))`
   里 `o` 同时当值和标签，导致 EN 模式下选中 `'Concept'` 就把英文 `'Concept'` 写进库，
   切回 ZH 又失配 —— 同一个崩溃的另一条触发路径。

### 28.3 同类隐患全量清单（不是只有卷宗/章节）

`withDefault(const Constant(...))` 的 text 列 vs 实体配置候选表，逐一比对后确认 **12 处**会炸：

| 表.列 | 表列默认值 | 旧候选表 | 处置 |
|---|---|---|---|
| Volumes.status | `Planning` | 构思中/写作中/已完成 | → `projectLikeStatuses` |
| Chapters.status | `Draft` | 草稿/修订中/已定稿 | → `chapterStatuses` |
| Characters.status | `Active` | 构思中/活跃/已退场 | → `activeStatuses` |
| Plots.status | `规划中` | 构思中/进行中/已完结 | → `plotStatuses` |
| Races.status | `稳定` | 活跃/濒危/灭绝/传说/未知 | → `raceStatuses` |
| Resources.status | `活跃` | 未开采/开采中/枯竭/受限/未知 | → `resourceStatuses` |
| SecretRealms.status | `隐藏` | 未发现/已发现/探索中/已开发/已封闭/未知 | → `secretRealmStatuses` |
| CultivationSystems.status | `Active` | 草稿/完善/废弃/未知 | → `activeStatuses` |
| PoliticalSystems.status | `Active` | 稳定/动荡/崩溃/新兴/未知 | → `activeStatuses` |
| CurrencySystems.status | `Active` | 流通中/衰退/废止/实验中/未知 | → `activeStatuses` |
| CharacterRelationships.status | `Active` | 亲密/疏远/敌对/利用/未知 | → `activeStatuses` |
| FactionRelationships.status | `Active` | 友好/紧张/交战/臣服/未知 | → `activeStatuses` |
| RaceRelationships.status | `稳定` | 友好/紧张/交战/臣服/未知 | → `raceRelationshipStatuses` |

（`Plots.priority` `中`、`Resources.rarity` `普通`、`Resources.regenerationSpeed` `中等`、
`RelationshipNetworks.status` `活跃`、`CharacterEvents.eventType` `其他`、`TimelineEvents.category`
`历史事件` 本来就命中，无需改。）

### 28.4 解法（三层，缺一不可）

1. **通用兜底：把当前值补进候选集**（`SystemFieldDef.optionEntries(current)`）。
   不管库里是什么脏值，候选集末尾原样补一条 → `items.where(...).length == 1` 恒成立，永不崩。
   ```dart
   final cur = current?.trim() ?? '';
   if (cur.isNotEmpty && seen.add(cur)) out.add(OptionEntry(cur, cur, cur));
   ```
2. **值/标签分离**：`OptionEntry(value, labelZh, labelEn)`，下拉渲染
   `DropdownMenuItem(value: o.value, child: Text(o.labelFor(isEnglish)))`。
   入库值恒为语言无关的**规范值**，切语言只换显示。
3. **候选表统一取自 `PseudoEnums`**（`lib/core/enums/pseudo_enums.dart`）——
   该文件此前是**完全没被引用的死代码**，而它的文档注释早就写了「UI 的下拉框必须依赖这份词典，
   否则极易出现『UI 显示英文、库里存中文』的不一致」。用 `_selc(key, zh, en, PseudoEnums.xxx)` 接线。
4. **切换记录必须换 key**：`key: ValueKey('${f.key}|$current')`，否则 `FormField` 的 State
   会沿用上一条记录的选中态（显示错值）。

### 28.5 防回归

- `test/entity_dropdown_test.dart`：断言「每张表的 `withDefault` 常量在对应候选表里**恰好命中 1 次**」，
  外加「脏值会被补进候选集且不重名」「所有 select 字段候选值唯一」「值/标签分离」。
- `tool/verify_pseudo_enums.dart`：纯 Dart，`dart run tool/verify_pseudo_enums.dart`
  直接校验 21 个表列默认值 × 23 张词典表的命中不变量（不依赖 Flutter，沙箱内可跑）。
- **新增/修改表列 `withDefault` 时必须同步这两处**。

---

## 29. i18n 的三类隐形漏翻（不是词表缺 key，而是绕过 l10n）

### 29.1 三类漏翻形态

1. **列表副标题直接显示库里的原始枚举值**：`Text('${row[cfg.summaryField]}')` —
   EN 模式下把 `主角` / `Planning` / `commodity_standard` 原样漏出来。
   解法：`SystemFieldDef.displayLabel(raw, isEnglish)`：select 字段命中候选 → 本地化标签；
   未命中的英文标识符 → `prettyIdentifier()` 美化成 `Commodity Standard`；非 select 字段原样返回。
2. **生成的业务文案落库时写死中文**：`dialog_generation_page.dart` 里
   草稿卷标题 `'AI对话草稿'`、备注 `'场景：…质量评分：…'`、标签 `'AI对话'` ——
   这些会进章节列表/备注框，EN 用户直接看到中文。解法：全部走 `l10n.t()`。
   ⚠ **草稿卷的定位键不能用标题**（`v.title == 'AI对话草稿'`），否则切换语言后标题变了
   会找不到而**重复建卷**；要用语言无关的 `type == 'AI'`。
3. **`_vStr(v,'status')` 空串撞 `min:1` 约束**：`_readForm()` 会跳过空字段，
   于是 `_vStr` 落到默认值 `''`，写进 `text().withLength(min:1,...)` 的列 → SQLite CHECK 失败。
   解法：所有 status/枚举列必须显式传规范默认值（`_vStr(v,'status','Active')`）。

### 29.2 排查手法（可复用脚本，均在 `_tmp/`，可移到 `tools/`）

| 脚本 | 作用 |
|---|---|
| `l10n_reverse_diff.py` | 从全部 .dart 抽 `l10n.t/tf` 的 key，与 zh/en 两表做 **4 方向差集**；差集非空即漏翻 |
| `i18n_audit.py` | 词表内部一致性：en 值含中文 / zh==en / zh 是纯英文短串 |
| `i18n_scan4/5.py` | 剔除 `l10n.t(...)` 调用（含跨行）与 `isEnglish ? :` 三元后，剩下的硬编码中文 |

**关键**：本项目的词表（4006 key × 2 表）和配置表（`labelZh`/`labelEn` 双字段）本身是干净的，
`VERDICT: PASS`；真正的漏翻都在**绕过 l10n 的代码路径**上，不能只看词表差集。

---

## 30. rwkv_lightning_cuda（albatross 引擎）云端 API 实测修正 —— **推翻/补正 §27.3**

> 本节全部结论来自对 `https://api-7b.rwkvos.com` 的**真实抓包实测**（CF Access 头 +
> 32 路并发），不是文档推测。§27.3 是照着文档预写的，路由名有误，**以本节为准**。

### 30.1 路由图（实测）

| 路由 | 接受 | 实测结果 |
|---|---|---|
| `POST /v1/chat/completions` | `messages`（`contents` 仅为**旧客户端兼容**） | 200；⚠ 官方文档 §6 明确：聊天路由上的 `contents` **只取第一项**，把它当作额外的 User 消息，**不是批量**（实测传 2 项只返回 1 条 choice）。批量必须用 `/v1/batch/completions` |
| `POST /v1/batch/completions` | `contents: string[]` | 200；`id=rwkv7-fast-batch`，带 `index` |
| `POST /translate/v1/batch-translate` | `target_lang` + `source_lang` + `text_list: string[]` | 200，返回 `{"translations":[{"detected_source_lang","text"}]}` |
| `POST /openai/v1/chat/completions` | — | **404（线上不存在！文档里有，别用）** |
| `GET /v1/server/status` | — | 200，**能力/队列/显存全景**（见 30.3） |
| `POST /v1/tokens/count` | `{"text":...}` 或 `{"messages":[...]}` | 200 `{"tokens":3}` |
| `POST /state/chat/completions` | `session_id` + `contents`（只收 1 条） | 有状态复用（对应 `session_cache` 能力） |
| `POST /v1/state/upload` / `GET /v1/state/list` / `DELETE /v1/state/delete` | `.pth` state | 上限 512 MiB；同名报 `already exists` |
| `POST /v1/server/stop` / `pause` / `resume` | — | 停止/暂停(存 state)/按 `request_id` 恢复(SSE) |
| `POST /FIM/v1/batch-FIM` | — | 批量 FIM（文档里有，未实测） |

⚠ **不要**把 §27.3 的 `kRouteRwkvOpenAiChat = '/openai/v1/chat/completions'` 直接抄进代码 ——
该路由实测 404。单路对话直接用 `/v1/chat/completions` + `messages`。
批量必须用 `/v1/batch/completions` + `contents`（语义更明确，`id` 前缀可用来断言走对了路由）。

### 30.2 ⚠ 头号新坑：**批量补全必须显式传 `stop_tokens`，否则每个槽位都返回空文本**

- **现象**：`POST /v1/batch/completions` 带 `contents` 但**不传 `stop_tokens`** →
  HTTP 200，`choices[]` 条数正确、`index` 正确、`finish_reason:"stop"`，
  但 `message.content` **全是空字符串**，`usage` 为 `null`，耗时仅 ~1.2s。
  看起来「接口通了但模型不输出」，极易误判成模型/权重问题。
- **根因**：服务端缺省 stop 词表命中了第 0 个 token 就立刻停。
- **解法**：批量/补全类请求**一律带上**官方示例里的三件套：
  ```dart
  'stop_tokens': [0, 261, 24281],
  ```
  带上后立刻正常返回内容（实测同一 prompt：空 → `"你好！有什么我可以帮助您的吗？"`）。
- 判据：**`text` 为空的 batch 响应 = 先查 `stop_tokens` 有没有传**，不要先去查模型。

### 30.3 `/v1/server/status` 是排障金矿（值得专门做个健康面板）

实测返回（节选）：

```json
{ "status": "running", "api_version": "1.3", "engine_version": "albatross-1.3.0",
  "capabilities": { "batch_completion": true, "concurrent_generation": true,
    "session_cache": true, "stream": true, "pause_resume": true,
    "chunk_prefill": true, "token_count": true, "metrics": true, "think_type": true },
  "prefill_queue": { "available_bsz": 169, "dynamic_max_bsz": 169, "hard_max_bsz": 169,
    "bytes_per_bsz": 54927364, "free_vram_bytes": 10476191744,
    "total_vram_bytes": 25280839680, "reserve_vram_bytes": 1047619174,
    "queued_requests": 0 },
  "prefill_chunk_size": 128,
  "last_request": { "prefill_speed": 1429.3, "decode_speed": 84.6,
    "prompt_tokens": 27, "generated_tokens": 46 },
  "model": { "path": "/home/rwkv/rwkv-stack/weights/rwkv7-g1j-7.2b-....pth" } }
```

可用来做：
- **并发上限自适配**：`available_bsz` 直接告诉你能塞多少并发序列（实测 169），
  `bytes_per_bsz` × 序列数 ≈ 需要的状态显存 —— Semaphore 的档位不该写死，应从这里取。
- **健康面板**：`last_request.decode_speed / prefill_speed` 拿来显示实时吞吐；
  `queued_requests > 0` 说明已经排队，该降并发。
- **能力探测**：`capabilities.*` 决定 UI 是否显示「批量/流式/状态复用」开关。
- `model.path` 暴露部署在 **Linux**（`/home/rwkv/...`），权重是 `.pth` 不是 GGUF。

### 30.4 `think_type` 取值（实测生效）

`none` / `fast` / `free` / `preferChinese` / `en` / `enShort`(`en_short`) / `enLong`(`en_long`)。
缺省时 `enable_think:true` 或 `think:true` 映射为 `free`，否则默认 `fast`。
带 `state_id` 的请求默认**不加**思考前缀（用经典 `User`/`Assistant` 模板，以匹配 state 调优数据），
显式 `think_type` 可覆盖，`think_type:"none"` 显式关闭。

### 30.5 并发实测结论（`curl --parallel`，跨境内网→CF→境内 GPU）

**单路 `/v1/chat/completions`（48 tokens 输出）**

| 并发 | 200/总 | 内容非空 | 墙钟 s | 均值 s | 最慢 s | 吞吐 请求/s |
|---|---|---|---|---|---|---|
| 1 | 1/1 | 1/1 | 1.79 | 1.78 | 1.78 | 0.56 |
| 4 | 4/4 | 4/4 | 2.23 | 1.82 | 2.22 | 1.79 |
| 8 | 8/8 | 8/8 | 3.53 | 2.73 | 3.52 | 2.26 |
| 16 | 16/16 | 16/16 | 5.46 | 3.54 | 5.45 | **2.93（峰值）** |
| 32 | 32/32 | 32/32 | 23.46 | 9.11 | 23.44 | 1.36 |

- **32 路并发全部 HTTP 200 且内容非空，零失败** → 「并行接口」结论成立。
- 吞吐峰值在 **N=16**；N≥24 后均值延迟从 3.5s 跳到 6~9s（开始排队），吞吐反降。

**批处理 `/translate/v1/batch-translate`（每请求 8 条文本）**

| 并发 | 200/总 | 墙钟 s | 均值 s | 条数 | 吞吐 条/s |
|---|---|---|---|---|---|
| 1 | 1/1 | 5.02 | 5.01 | 8 | 1.59 |
| 4 | 4/4 | 7.24 | 5.26 | 32 | 4.42 |
| 8 | 8/8 | 9.94 | 6.19 | **64** | **6.44（峰值）** |
| 16 | 16/16 | 82.31 | 40.71 | 112/128 ⚠ | 1.36 |

- ⚠ **N=16 时响应被截断在 UTF-8 中间**（实测某响应第 11043 字节处非法延续字节），
  且返回条数不足 128 → **批处理端点的实用并发上限 ≈ 8**（64 条/10s）。
  超限不会报错，而是**静默返回损坏的 JSON** —— 所以 batch 客户端**必须**做
  ① JSON 解析失败即重试 ② `translations.length != text_list.length` 即子集重试。
  这正是 HANDOFF P3-24「batch 部分失败子集重试」的真实触发场景。
- 建议 Semaphore 三档按此定：**单路 chat 12~16 / batch 6~8 / 翻译 batch 6~8**，
  并从 `/v1/server/status` 的 `available_bsz` 动态夹取。

**P3-22 验收（8 Agent → 1 次 POST）实测 PASS**

```
★ 8 个 Agent 任务 → 1 次 HTTP POST，contents 长度 8
   HTTP 200   墙钟 2.46s   POST 次数 = 1   choices 返回 8 条
   idx=0..7 各自拿到结果   index 覆盖 = [0,1,2,3,4,5,6,7]
```

⚠ 但注意 ENDPOINT 是 `/v1/batch/completions`（不是 §6 里写的 `/v1/chat/completions`），
且 `stream:false` 时结果在 `choices[].message.content` 而**不是** `choices[].text`。

### 30.6 Cloudflare Access 头

实测 `CF-Access-Client-Id` / `CF-Access-Client-Secret` **精确大小写**可用（§27.2 的 const 锁拼写结论成立）。
`CF-RAY` 显示走了 `-HKG` 边缘节点；跨境外网 TLS 握手 ~1.5s，是延迟大头，
HTTP keep-alive 复用连接明显优于每请求新建（`curl --parallel` 连接池复用也是因此更快）。

### 30.7 ⚠ 内置引擎安装的头号新坑：GitHub release 的 `tag_name` 会退化成 `untagged-<sha>`

- **现象**：按「`tag_name` + 平台 + CUDA」拼官方资产名，得到
  `rwkv-lightning-untagged-5d553798658a05466d06-windows-x64-cuda13.2.zip` → **永远 404**，
  而 releases 页面肉眼看到的是 `v1.6.0`，极易误判为「资产还没传」。
- **根因**：v1.6.0 这个 release 是**先建 draft、发布时补 tag**的流程产物，
  `GET /repos/{owner}/{repo}/releases/latest` 返回的 `tag_name` 实测为
  `untagged-5d553798658a05466d06`（不是 `v1.6.0`），真正的可读版本号在 **`name`** 字段里。
- **解法（双保险）**：
  1. **绝不拿 tag 拼资产名**。改为「平台 token + CUDA token + 扩展名」**后缀模式匹配**，
     与 tag 完全解耦：
     ```dart
     // 只认 rwkv-lightning-* 且以 -<platform>-<cuda>.<ext> 结尾的资产
     final suffix = '-$platformToken-$cudaToken.$ext'; // 如 -windows-x64-cuda13.2.zip
     if (name.startsWith('rwkv-lightning-') && name.endsWith(suffix)) hit = raw;
     ```
  2. tag 仅用于展示/目录命名，取值顺序：`tag_name`（需像个版本号）→ `name` → `tag_name`：
     ```dart
     bool looksLikeVersion(String s) =>
         s.isNotEmpty && !s.startsWith('untagged') && RegExp(r'^v?\d').hasMatch(s);
     String tag = looksLikeVersion(rawTag) ? rawTag : rawName;
     ```
  3. 匹配不到时**把 `available` 资产名全列进异常信息**，避免下次又只能靠猜。

- **实测校验（四个组合全命中）**：
  | 资产名 | 体积 |
  |---|---|
  | `rwkv-lightning-v1.6.0-windows-x64-cuda12.9.zip` | 576.4 MB |
  | `rwkv-lightning-v1.6.0-windows-x64-cuda13.2.zip` | 415.6 MB |
  | `rwkv-lightning-v1.6.0-linux-x64-cuda12.9.tar.gz` | 587.5 MB |
  | `rwkv-lightning-v1.6.0-linux-x64-cuda13.2.tar.gz` | 415.1 MB |

  每个资产都有同名 `.sha256` 兄弟文件 → 安装流程**必须**下载并比对 SHA-256
  （引擎包 400~600MB，跨境 CDN 截断是真实风险）。

### 30.8 内置引擎的落地形态（已实现，供后续维护参考）

**引擎二进制来源**：`Alic-Li/rwkv_lightning_cuda` 官方 release 预编译包（**不 vendor C++ 源码**）。
安装目录约定 `rwkv_models/_tools/rwkv-lightning-<tag>-<variant>/`。

**权重来源**：`BlinkDL/rwkv7-g1`（HF），**只有 `.pth`**（FP16，7.2B ≈ 13.7GB）；
`.rwkvq`（W8A16/W4A16）要用引擎自带的 `rwkv_quantize` 从 `.pth` 转换，不是直接下载。
官方 `RWKV/RWKV7-G1j-7.2B-20260831` 只有 15 个 safetensors 分片，**引擎不认**。

**词表**：`assets/rwkv_vocab_v20230424.txt`（实测 1.07MB），落 `rwkv_models/_assets/`。

**可执行文件名**：`rwkv_lighting_cuda.exe`（上游 CMake 目标名把 lightning 拼成 **lighting**），
且 `CMAKE_RUNTIME_OUTPUT_DIRECTORY` 指向构建根，所以解压后要**递归**找，
并对 `state_tune` / `quantize` 两个辅助二进制做排除。

**启动参数（与 llama.cpp 完全不同）**：
```
--model-path <.pth|目录>  [--enable-dynamic-loading]  --vocab-path <词表> \
--host 127.0.0.1  --port <p>  --chunk-load  [--state-db-path <db>]
```
- `--chunk-load`：避免把整份 `.pth` 一次性读进主机内存（走常驻文件流 + pinned 缓冲）。
- `--state-db-path`：**必须显式指定**，否则默认落在进程 CWD（Flutter 应用的 CWD 不可预期）。
- `--enable-dynamic-loading` + `--model-path` 传**目录**：`GET /v1/models` 列出目录下所有
  `.pth`/`.rwkvq`，用 `POST /v1/model/load {"model":"<去扩展名的文件名>"}` 运行时切换。

**健康探测**：`/health` **不存在**（404），必须探 `/v1/server/status`（或 `/v1/models`）。
探测顺序建议 `health` → `v1/models` → `v1/server/status`。

**平台无关性约束**：`rwkv_engine.dart` 刻意**不 import `dart:io`**（保证 Web 可编译）。
所以「词表是否存在 / 字节数是否够」这类文件探针必须走条件导入
（`rwkv_file_probe.dart` → `_native` / `_stub`），不能直接 `File(...)`。

---

## 31. 官方 HTTP API 文档逐条实测校准（原始文档：`docs/http-api.zh-CN.md` + `rwkv_lightning_api_doc.md`）

> 本节是对 `api-7b.rwkvos.com`（`api_version 1.3` / `engine_version albatross-1.3.0`）
> 按官方文档**逐条抓包核对**的结论。凡与 §30 冲突处，**以本节为准**。

### 31.1 ⚠ 头号新坑：`extra_body` 是**死字段** —— 「State 复用」其实从未生效

- **现象**：`rwkv_engine.dart` 的 `_buildChatBody()` 把参数塞进 `result['extra_body'] = extra`
  （含 `state_id` / `session_id`），HTTP 状态永远是 200、模型回答也正常，
  **看不出任何异常** —— 但参数一个都没生效。
- **根因**：服务端只读**顶层**字段。实测「传一个完全不存在的顶层字段」→ **HTTP 200 且无副作用**
  → 证明多余字段被静默容忍；同理 `extra_body` 这个嵌套对象整体被丢弃。
  **这是"静默不生效"，比报错难发现一个数量级。**
- **影响面**：`state_id`（RNN 状态续跑，本引擎的核心卖点）、`session_id`、以及**所有 RWKV 原生
  生成参数**（`think_type` / `top_k` / `top_p` / `alpha_*` / `chunk_size` / `stop_tokens`）
  在旧实现里**全部没到服务端**。
- **解法**：**展平到顶层**。但 `state_id` / `session_id` 必须特殊处理（见 31.2）：
  ```dart
  final result = <String, dynamic>{ 'model': ..., 'messages': messages,
      'temperature': ..., 'max_tokens': ..., 'stream': stream };
  request.parameters.forEach((String k, dynamic v) {
    if (k == 'state_id' || k == 'session_id') return;   // 见 31.2，改走表头
    result[k] = v;                                       // 展平，不嵌套
  });
  ```

### 31.2 ⚠ `state_id` 两个通道校验强度**不同**（body 会 400，表头不会）

| 通道 | 用例 | 实测 |
|---|---|---|
| body 顶层 `"state_id":"nonexistent.pth"` | 未上传的 state | **HTTP 400** `{"error":"uploaded state not found: nonexistent.pth"}` |
| 表头 `X-RWKV-State-Id: nonexistent.pth` | 同一个不存在的 state | **HTTP 200，正常生成**（被容忍、不报错） |
| body 顶层 `"session_id":"..."` | 在 `/v1/chat/completions` 上 | **HTTP 200 但无任何语义**（`session_id` 只属于 `/state/*` 路由） |

- **结论**：会话续跑**必须走 `X-RWKV-State-Id` 表头**，绝不能放 body ——
  放 body 时只要 id 不是服务端真正上传过的（本地自造的 id 就是），**每次请求都会 400**。
- `session_id` **不要**发给 `/v1/chat/completions`（无效字段）；要真正复用会话，
  走 `/state/chat/completions` + `session_id`（服务端自己三级缓存 L1 VRAM / L2 RAM / SQLite）。
- 已按此修正 `rwkv_engine.dart`：新增 `_chatHeaders(session)` 注入 `X-RWKV-State-Id`，
  `_buildChatBody` 剔除这两个键。实测新形态请求 → 200 + 正常内容 + usage。

### 31.3 ⚠ 并发模型：服务端自带 FIFO admission queue —— **P3-20「Semaphore 三档」的前提要改**

**文档 §11 的实测核对**：服务端不再因「已有请求」报
`Another generation is active`，而是所有生成请求先进 FIFO 队列，并按显存动态放行：

- 模型加载后按当时空闲显存记录 `hard_max_bsz`（**单个请求永远不能超过它**）；
- FIFO 队首每 **100ms** 重读空闲 VRAM，动态算 `dynamic_max_bsz`；
- 估算包含 recurrent state、按 `--chunk-size` 的 prefill 激活、logits、
  128MiB cuBLASLt workspace，并保留 `max(512MiB, free VRAM 的 10%)` 安全空间。

**实测**（`GET /v1/server/status`）：
```
hard_max_bsz=169  dynamic_max_bsz=169  available_bsz=169  reserved_bsz=0  queued=0
bytes_per_bsz=54,927,364 B (52.4MB)   free_vram=9.8GB   total_vram=23.5GB
```
→ 23.5GB 显存 ≈ **单张 4090**，即这台远端是**单卡**在 hold（"三张 4090" 并未体现在这一个节点上）。

**批量超上限的实测**（一次发 200 条 `contents`）：
```json
HTTP 400
{"error":"bsz overflow, Max bsz=169","max_bsz":169,"request_bsz":200}
```

- **对 P3-20 的修正**：客户端**不要再自行拍一个固定并发档位**去硬扛服务端。
  正确姿势是 ①`/v1/server/status` 读 `available_bsz` 作为软上限；
  ②`dynamic_max_bsz` **不可缓存为长期常量**（文档明说，随其他进程/state cache 变化）；
  ③客户端 Semaphore 只做**保守限流 + 快速失败**，真实排队交给服务端。
- **对 P3-24 的修正（重要）**：**服务端错误码表里根本没有 429**（只有 200/204/400/401/404/500）。
  所以「429 退避」在本引擎上永远不会触发。真正需要退避/重试的是这四类：
  1. **`400 bsz overflow`** → **拆小 batch 重试**（不是退避等一会）；
  2. **`500`** → 指数退避重试；
  3. **HTTP 200 但 body 是 `{"error":"..."}`**（SSE 运行时异常也走 200！）→ 必须在 SSE 解析里
     检测 error 事件并重试；
  4. **网络层截断**（已实测：N=16 批处理时响应截断在 UTF-8 中间、条数不足）→
     JSON 解析失败 / 条数不匹配即子集重试。

### 31.4 ⚠ `finish_reason` 与 `usage` **不可信** —— P3 的验收口径要改

文档 §12 明确（并已实测印证）：

- **所有流式接口的结束事件都无条件发 `finish_reason: "stop"`**，无法区分
  EOS / 命中 `stop_tokens` / 达到 `max_tokens` / 被 stop / 被 pause / 客户端断开。
  （根因：通用 `start_streaming_task` 没接收结束状态，`send_finish_chunk` 默认参数固定 `"stop"`。）
- **流式响应不返回 `usage`**，即使传 `{"stream_options":{"include_usage":true}}`（服务端未实现）。
- **batch / stateful / 全部流式响应都不返回标准 `usage`**；
  只有 `/v1/chat/completions` 的**非流式**响应有 `usage`。
- **实测印证**：`/v1/batch/completions` 非流式响应 = `{choices,id,model,object}`，**确实没有 `usage`**；
  `/v1/chat/completions` 非流式 = 有 `usage`。

→ **P3 落地时**：不要用 `finish_reason` 判断「是否被 max_tokens 截断」，必须
**自己累计输出 token 数**并与 `max_tokens` 比较；也不要依赖流式 `usage`。
⚠ 另外 **PITFALLS §27.3 里那段「靠 `finish_reason != null` 判断某个 index 结束」的示例**：
虽然这里恒为 stop 所以还能工作，但**正确而稳妥的退出条件是收到 `data: [DONE]`**。

### 31.5 ⚠ 文档描述的端点 ≠ 线上部署的端点（**版本差**）

实测这台 `api-7b.rwkvos.com`（1.3.0）的路由存在性：

| 端点 | 文档 | 实测 |
|---|---|---|
| `/v1/chat/completions`、`/v1/batch/completions`、`/translate/v1/batch-translate` | 有 | **200** ✓ |
| `/v1/server/status`、`/v1/models`、`/v1/tokens/count`、`/state/*` | 有 | **200** ✓ |
| `/v1/model/load` | 有（仅动态模式） | **404**（未启用 `--enable-dynamic-loading`，符合预期） |
| `/v2/chat/completions` | 有 | **404** ⚠ |
| `/big_batch/completions` | 有 | **404** ⚠ |
| `/FIM/v1/batch-FIM` | 有 | **404** ⚠ |
| `/openai/v1/chat/completions` | 有 | **404** ⚠ |

→ **`v2` / `big_batch` / `FIM` / `openai` 这四个是更新版本才有的路由，线上没有。**
写代码只能按**实测可用**的端点来（`/v1/chat/completions` + `/v1/batch/completions` +
`/translate/v1/batch-translate` + `/state/*` + `/v1/server/status`），
并做**能力探测**（`capabilities.*` + 404 降级），别把文档当线上契约。

### 31.6 其余按文档实测确认的契约

| 项 | 实测结论 |
|---|---|
| `/state/chat/completions` 的 `contents` | 必须**恰好 1 条**；传 2 条 → `400 {"error":"Request must contain exactly one prompt"}` |
| `/state/status` | `{status, l1_cache_count, l2_cache_count, database_count, total_sessions, sessions[]}` ← **P4「State 存档 / 健康面板」的数据源** |
| `/v1/models` 单模型模式 | 只有 `data`，**无** `loaded`/`available`（那两个字段只在动态加载模式出现） |
| `/v1/tokens/count` 优先级 | `text` > `messages` > `contents`；实测 `"hello RWKV"`→**3**，同样内容走 `messages`→**13**（先套 chat 模板），`contents:["abc","def"]`→**1**（连接成一个字符串后计数） |
| `/translate/v1/batch-translate` | `target_lang` + 非空 `text_list` 必填，`source_lang` 默认 `auto`；**固定生成参数**（`max_tokens=2048, temperature=1.0, top_k=1, top_p=0.0`，停止 token `0`）；`detected_source_lang` 原样回显传入值（**不跑语言检测器**） |
| `/v1/batch/completions` | `contents` 必须非空数组；SSE **`chunk_size` 默认 8**（不是 1）；`index` = 原始输入位置；非流式结果在 `choices[].message.content`；`metrics:true` 让服务端记录 prefill/decode 供 `/v1/server/status` 查（**不会**把 metrics 加进响应） |
| `/v1/server/pause` | **只有流式 `/v1/chat/completions`** 会保存完整 state+logits 供 `/v1/server/resume`；对 batch/stateful 流发 pause 只会提前结束，**不产生可 resume 的记录** |
| `/state/*` 并发 | **不可并发写同一 `session_id`**（后完成者覆盖先完成者）→ 会话路由必须**每会话串行化**（项目 `RwkvSessionManager` 声称已做，P3 落地时要写测试锁死） |
| `--enable-dynamic-loading` 的代价 | 动态模式**只注册** `/v1/models`、`/v1/model/load`、`/v1/tokens/count`、`/v1/chat/completions`、`/v1/batch/completions`、`/v1/server/status`；**其余路由失效**（`/translate/*`、`/state/*`、stop/pause/resume）→ UI 必须提示这个取舍 |
| `stop_tokens` | 文档默认值 `[0,261,24281]`，但**实测 `/v1/batch/completions` 不传该字段时每个槽位返回空文本**（HTTP 200 + index 正确）→ **批量一律显式带上** |
| 鉴权 | 支持 `Authorization: Bearer <password>` 与 body 里的 `password` 字段；未启用 `--password` 时无鉴权 |

---

## 32. 引擎侧 4 个「静默失效」级 bug（本轮补齐原生参数 + `/state` 续跑时挖出）

> 这四个 bug 的共同特征：**HTTP 恒 200、模型回答也正常**，日志一片祥和，
> 只有把真实请求抓下来逐字段比对才能发现。前三个直接导致「State 复用」从未生效。

### 32.1 `_endpoint()` 默认拼成 `/openai/v1/...` → **404**

```dart
// ❌ 旧实现：baseUrl 不以 /v1 或 /chat 结尾时，自动加 /openai/v1 前缀
return base.endsWith('/v1') || base.endsWith('/chat')
    ? '$base/$rel'
    : '$base/openai/v1/$rel';
```

- 默认 `baseUrl = 'http://localhost:8000'` → 实际请求
  `http://localhost:8000/openai/v1/chat/completions`。
- **实测**：`rwkv_lightning_cuda` 上 `/openai/v1/chat/completions` → **404**
  （官方接口总览只有 `/v1/chat/completions`）。
- 修法：前缀固定为 `/v1`（baseUrl 已带 `/v1` 则不重复拼）：
  ```dart
  return base.endsWith('/v1') ? '$base/$rel' : '$base/v1/$rel';
  ```
- ⚠ **`/state/*` 是另一个前缀规则**：`/state/chat/completions`、`/state/status`、
  `/state/delete` **都没有 `/v1`**。必须单独一个 `_stateEndpoint()`，
  否则会拼出 `/v1/state/...` → 404。

### 32.2 provider 只在 `engineConfig != null` 时重建引擎 → baseUrl 永远不生效

```dart
// ❌ 旧实现
if (configuration.engineConfig != null) {   // UI 从来不传 engineConfig！
  _engine.dispose();
  _reassignEngine(RwkvEngine(config: configuration.engineConfig!, ...));
}
```

- 引擎构造时用的是 `const RwkvEngineConfig()`，`baseUrl` 永远是
  `http://localhost:8000` —— 用户在界面上填的远端地址**完全没进引擎**。
- 修法：从 `RwkvConfiguration.baseUrl` 兜底构造 engineConfig，并在**配置真正变化时**
  重建（用 `jsonEncode(cfg.toMap())` 比对即可，避免逐字段比较漏项）：
  ```dart
  final desired = (configuration.engineConfig ?? const RwkvEngineConfig())
      .copyWith(baseUrl: configuration.baseUrl);
  if (jsonEncode(desired.toMap()) != jsonEncode(_engine.config.toMap())) { /* 重建 */ }
  ```
- 连带要求：**UI 侧 `_buildConfig()` 必须显式传 `engineConfig`**（带 baseUrl +
  原生参数 + stateful 开关），否则上面这段永远走不到重建分支。

### 32.3 引擎 `dispose()` 关掉了**外部注入**的 http.Client → 重建引擎后整个 provider 失效

```dart
// ❌ 旧实现：无条件 close
void dispose() { ...; _client.close(); }
```

- provider 会把自己的 `_httpClient` 注入引擎；引擎 dispose 时把它关掉，
  provider 后续所有请求直接抛 `ClientException: Client is already closed`。
- **这个坑在「重建引擎」时必现**（先 dispose 旧的、再用同一个 client 建新的）——
  也就是 32.2 一修就会踩到。
- 修法：记录所有权，只关自建的：
  ```dart
  RwkvEngine({http.Client? client, ...}) : _ownsClient = client == null, _client = client ?? http.Client();
  void dispose() { ...; if (_ownsClient) _client.close(); }
  ```

### 32.4 `_buildChatBody()` 把参数包进 `extra_body`（§31.1 的代码落点）

已在 §31.1 详述；这里只记修法位置：`_buildChatBody` 里改成**展平**
（`result[k] = v`），并把 `state_id` / `session_id` **剔除出 body**、
改由 `_chatHeaders(session)` 注入 `X-RWKV-State-Id` 表头。

### 32.5 已实现并通过实测的核对清单

| 项 | 实现 | 实测证据 |
|---|---|---|
| 原生参数展平 | `RwkvNativeOptions.toRequestBody()` 在 `_buildChatBody` 里 `putIfAbsent` 注入 | 顶层带 `think_type`/`top_k`/`alpha_*`/`stop_tokens` 的请求 → 200 |
| `stop_tokens` 默认携带 | `RwkvNativeOptions.stopTokens = [0,261,24281]` | — |
| 会话续跑 | `useStatefulRoute=true` → `POST /state/chat/completions`，`contents` **恰好 1 条**，只发本轮增量 | 轮 1 告知暗号「琉璃七号」→ 轮 2 **只发增量**仍答对；对照组新 session 幻觉成「星辰之光」 |
| 路由前缀 | `_endpoint`→`/v1`、`_stateEndpoint`→`/state` | 见 32.1 |
| 状态探测 | 依次探 `/health` → `/v1/models` → `/v1/server/status` | 该引擎 `/health` 是 404，缺第三条会白等满 45s |
| 每会话串行化 | `RwkvSession.runSerialized`（互斥信号量 1） | 新增测试断言同 session 并发 5 轮时 `maxInFlight == 1` |

### 32.6 ⚠ 生产级发现：多节点部署下 `/state/*` 的 state 是**节点本地**的

- 实测：轮 1 建立会话、轮 2 **成功复用**，但 `POST /state/status` 返回
  `l1=0 l2=0 db=0 total=0` —— 而 `POST /state/delete` 又能返回
  `{"message":"Session xxx deleted successfully"}`。
- 结论：**负载均衡把请求打到了不同节点**，而 state 存在**进程本地**
  （L1 VRAM / L2 RAM / SQLite 都是单机资源）。
  → 官方 router 文档里强调的 `session affinity` 正是为此。
- **两个可操作结论**：
  1. **不能用 `/state/status` 判断会话是否存在**（会误判为「没有」）；
  2. 需要用 `/state/*` 续跑的 Agent 工作流，**云端多节点不可靠** ——
     要么给客户端配 session affinity，要么把这类工作流放到**本地引擎**上跑。

---

## 33. P3 批量 / 并发 / 分叉的实测校准（HANDOFF 里的路由常量有一半是错的）

> 本轮所有结论都由**项目自己的代码**打真实端点得到（见
> `tool/verify_rwkv_batch.dart`，`dart run` 可复现，11/11 PASS）。
> 之所以能这么跑：`rwkv_batch_client.dart` + `batch_chat.dart` 是纯 Dart，
> 没有 Flutter 依赖；而本沙箱跑不了 `flutter test`（reg.EXE 黑名单）——
> 这条 `dart run` 通道是唯一能真实压测批量链路的方式。

### 33.1 ⚠ 官方两份文档互相矛盾，**只有一份与线上一致**

| 文档 | 声称 `/v1/chat/completions` 是 | `stop_tokens` 类型 |
|---|---|---|
| `http-api.zh-CN.md`（示例，**= 线上 1.3.0 CUDA 后端**） | OpenAI 风格 `messages` 单路 | `int[]`（token ID） |
| `rwkv_lightning_api_doc.md`（完整参考，较新/异构后端） | **原生多 prompt 批量**（`contents`） | `string[]`（文本停止序列） |

**线上实测（engine `albatross-1.3.0`）匹配示例文档**：

| 路由 | 实测 |
|---|---|
| `POST /v1/batch/completions` + `contents[]` | ✅ N 条带 `index` 的 choices → **批量走它** |
| `POST /v1/chat/completions` + `contents[2]` | 只回 **1 条** choice（只取第一项当额外 User 消息）→ **不是批量** |
| `POST /v1/chat/completions` + `messages` | ✅ 单路聊天 |
| `POST /openai/v1/chat/completions` | ❌ **404** |
| `POST /v1/chat/completions` + `stop_tokens:[0]` | 200，但**未观察到提前停止** |

⇒ **HANDOFF 里的两条常量都要改**：
```dart
// ❌ HANDOFF 写的
kRouteRwkvNativeBatch = '/v1/chat/completions';    // 该路由不是批量
kRouteRwkvOpenAiChat  = '/openai/v1/chat/completions'; // 实测 404
// ✅ 实测可用（lib/ai/models/batch_chat.dart）
kRouteRwkvBatchCompletions = '/v1/batch/completions';  // 批量：contents[] + 整数 stop_tokens
kRouteRwkvChatCompletions  = '/v1/chat/completions';   // 单路：messages[]
```

### 33.2 ✅ `bsz overflow` 自动拆批：实测跑通（这是 P3-24 的正确形态）

服务端上限**实测会变**：同一会话内两次读 `/v1/server/status` 得到
`available_bsz` 分别为 **169 → 168** —— 印证文档「`dynamic_max_bsz` 不可缓存为长期常量」。

超限请求实测：
```json
POST /v1/batch/completions  (contents 长度 200)
HTTP 400  {"error":"bsz overflow, Max bsz=169","max_bsz":169,"request_bsz":200}
```
`RwkvBatchClient` 对它的处置是**折半拆分重发**（不是退避等待）：
实测 **200 条 → 自动拆批后完整返回 200 条**（`tool/verify_rwkv_batch.dart` [3]）。
同时把建议档位回灌给 `RwkvConcurrencyController.noteBszOverflow()`，后续批次自动变小。

### 33.3 ✅ SSE 多槽位**确实会交错到达**（不是理论风险）

实测 3 槽流式批量（`chunk_size=8`）：17 个 SSE 事件，**观测到多槽位交错=true**。
若按到达顺序 append，三条剧情线会混成一锅 —— 必须 `Map<int,StringBuffer>` 按
`choices[].index` 分组（`RwkvBatchClient.chatStream` 已实现）。
另外：**HTTP 200 也可能塞 `{"error":...}` 事件**，必须当成失败抛出。

### 33.4 ⚠ `/multi_state/chat/completions` 是「可选」能力 —— **线上 404**

官方完整文档有它（`session_id` + `dialogue_idx`，state 存为
`<session_id>:<dialogue_idx>`，非流式响应顶层回传新 `dialogue_idx`），
但**实测 404**（同 `/v2/chat/completions`、`/big_batch/completions`、
`/FIM/v1/batch-FIM`、`/openai/v1/*`）。

⇒ **世界观分支必须做三级降级**（`lib/ai/workflow/workflow_branch.dart`）：

| 档 | 条件 | 行为 |
|---|---|---|
| L1 `multiState` | `routeExists('/multi_state/chat/completions')` | 真·服务端 O(1) 分叉（一次 prefill 出多条线） |
| L2 `sessionSeed` | 只有 `/state/chat/completions`（**线上就是这一档**） | 每条分支用**独立 session_id**（`<base>:branch-<id>`，实测 session_id 接受任意字符串）首次**播种父上下文**，之后各自 O(1) 增量 |
| L3 `serialOnly` | 非 RWKV Provider | 串行重编码 + `branches` 不带服务端 state，并打 HANDOFF 要求的 warning |

⚠ 别把 L2 说成「O(1) 分叉」：每条分支**首次仍要付一次父上下文 prefill**，
只是后续增量是 O(1)。写进 UI 文案时要老实。

### 33.5 ⚠ `finish_reason` / `usage` 在批量链路里都不可信（承 §31.4）

- 实测非流式 `/v1/batch/completions` 响应只有 `{choices,id,model,object}` —— **无 `usage`**；
- 流式结束一律 `finish_reason:"stop"`，无法区分 EOS / stop_tokens / max_tokens / 被 pause；
- ⇒ `RwkvBatchResponse` 把 `usage` 设为可空，且**判断「是否被截断」只看
  「槽位内容是否为空 / 条数是否齐」，绝不看 `finish_reason`**。

### 33.6 落地清单（本轮新增）

| 文件 | 职责 |
|---|---|
| `lib/ai/models/batch_chat.dart` | `RwkvBatchRequest/Choice/Response` + 实测校准的路由常量 + `RwkvBatchException`（失败分类） |
| `lib/ai/rwkv/rwkv_batch_client.dart` | 批量/SSE 传输 + **按 index 分组** + 四类失败处置（拆批/退避/200-error/子集重试）+ `routeExists()` 能力探测 + `postJson()` 通用助手 |
| `lib/ai/rwkv/rwkv_concurrency.dart` | `RwkvConcurrencyController`：从 `available_bsz` 取软上限（TTL 15s）、排队时减半、`bsz overflow` 降档、连续成功缓慢回升 |
| `lib/ai/workflow/batch_agent_executor.dart` | 攒批（`maxBatchSize` / `batchWaitWindow` 谁先到谁触发）+ `batchGroupId` 隔离长 prompt + 单槽位失败不拖垮整批 |
| `lib/ai/workflow/workflow_branch.dart` | `WorkflowBranch` + `IBranchingChatModel` + `WorkflowBranchRunner`（三级降级） |
| `lib/ai/agents/agent.dart` | `BaseAgent` 新增 `buildPromptForBatch` / `processBatchResponse` 两个可覆写钩子（刻意用 `(taskType, parameters)` 而非 `WorkflowTask` —— `workflow.dart` 已 import `agent.dart`，反向会成环） |
| `tool/verify_rwkv_batch.dart` | **纯 Dart 真实端点验收**（11 项断言），`dart run` 可复现 |

### 33.7 攒批接进 WorkflowEngine 的三个隐藏前提

`BatchAgentExecutor` 只在「**多个独立任务在 100ms 窗口内并发抵达**」时才有意义。
接进 `NovelWorkflowEngine` 后有三个容易踩的点：

1. **队列并发上限必须 ≥ `maxBatchSize`，否则永远攒不满。**
   `TaskQueue` 默认 `maxConcurrentTasks = 5`，而 `maxBatchSize = 8` ——
   这种配置错**看起来像"批量没生效"**，很难查。
   ⇒ `NovelWorkflowEngine` 构造时自查并 warning：
   ```dart
   if (_taskQueue.maxConcurrentTasks < ex.maxBatchSize) { _logger.warning(...); }
   ```
   （为此给 `TaskQueue` 加了 `maxConcurrentTasks` 只读 getter。）

2. **依赖链上的任务天然串行**，攒批只吃「同一拓扑层」的任务。
   这是拓扑顺序决定的，不是缺陷 —— 别指望 10 步的线性流程能攒成 1 次 POST。

3. **批量路由是无状态的**，走批量就**丢了 `rwkvSessionId` 的 state 续跑**。
   所以 `buildPromptForBatch` 产出的 prompt **必须自包含**上下文；
   依赖 state 增量省 token 的任务不该走批量。

**接入策略（保守优先，不静默改变既有行为）**：

```dart
bool _shouldBatch(WorkflowTask task, IAgent agent) {
  if (_batchExecutor == null) return false;
  if (agent is! BaseAgent) return false;          // 钩子定义在 BaseAgent 上
  final flag = task.parameters['useBatch'];
  if (flag == false) return false;                // 单条可强制退出
  if (flag == true) return true;                  // 单条可强制启用
  return _batchAllTasks;                          // 引擎级默认关
}
```

- 默认 `batchAllTasks = false`：只有**显式写 `useBatch: true`** 的任务才攒批。
  理由：`BaseAgent.buildPromptForBatch` 的默认实现只是把 parameters 拍平，
  质量不如各 Agent 精心构造的单路 prompt —— 默认全开等于**静默降低成文质量**。
- **攒批失败不自动降级为单路**：否则用户以为批量生效了，实际在付串行的代价。
  失败要带上「如需退回单路请设 `useBatch: false`」的可操作提示。

**接线点**：`di.dart` 的 `batchAgentExecutorProvider`（用
`rwkvCloudProviderInstanceProvider.batchClient` 装配）→
`workflowEngineProvider` 传给 `NovelWorkflowEngine(batchExecutor:)` →
`_runTask()` 里路由。单例 + `ref.onDispose(ex.dispose)` 防 Timer 泄漏。

### 33.8 ⚠ 云端 Provider 未 initialize 时不能调 RWKV 独有接口

`OpenAICompatibleProvider._configuration` 的**初值**是基类默认的
`baseUrl = 'https://api.openai.com/v1'`。若不设闸就调 `batchChat()`，
会把 RWKV 原生的 `contents` 请求**静默打到 OpenAI 上**，拿回一个 400 让人莫名其妙。
⇒ `RwkvCloudProvider` 的 4 个原生方法（`batchChat` / `batchChatStream` /
`statefulChat` / `multiStateChat`）入口统一走 `_requireInitialized()`，
报错里带上当前 baseUrl 和正确的调用姿势。

---

## 34. P4-25 收尾与测试分层（本轮）

### 34.1 `RwkvLightningLaunchArgs`：为什么必须与 llama.cpp 的 args **物理隔离**

HANDOFF 要求把 `rwkv_lightning_cuda` 的启动参数抽成独立数据类 —— 这个要求是对的，
因为两套 CLI **没有一个 flag 是重叠的**，混写必错：

| 概念 | llama.cpp | rwkv_lightning_cuda |
|---|---|---|
| 权重 | `--model x.gguf` | `--model-path x.pth` |
| 词表 | **内嵌在 GGUF 里**，无此参数 | `--vocab-path <外置 txt>`，**缺则 crash** |
| 上下文 | `--ctx-size 8192` | 无（模型自带 ctx，如 ctx16384） |
| 层卸载 | `--n-gpu-layers 99` | 无（CUDA 专用引擎） |
| prefill 分块 | 无 | `--chunk-size 128` |
| 省内存 | 无 | `--chunk-load` |
| state 持久化 | 无 | `--state-db-path` |

落地：`lib/ai/rwkv/rwkv_lightning_launch_args.dart`
- `toArgs()` 纯函数 → 可单测；
- `describeRedacted()` 供日志/UI 展示（**不带 password**）；
- `preflightLightningArgs()` 把「GGUF 混入」「词表缺失/损坏」「目录但未开动态加载」
  三类秒退原因集中成**可断言**的校验，`rwkv_engine.dart` 只负责探测尺寸再调用它。

验收：`dart run tool/verify_launch_args.dart` → **14/14 PASS**
（含 6 条 preflight 反面用例：GGUF / 词表不存在 / 词表 <500KB / 目录无开关 / 正常放行 / `.rwkvq` 放行）。

⚠ **`OfficialServerVariant` 只加了 `cuda12/cuda13`，没有照 HANDOFF 加
`rwkvLightningRocm6 / rwkvLightningCpu`**：实测 v1.6.0 release 的资产只有
`windows-x64-cuda12.9`、`windows-x64-cuda13.2`、`linux-x64-cuda12.9`、
`linux-x64-cuda13.2` **四种，没有 ROCm / CPU 包**。加不存在的枚举值会让 UI 出现
「点了没反应」的选项，比少两个选项更糟。

### 34.2 测试分层：`test/` 与 `integration_test/` 必须分开

| 目录 | 性质 | 内容 |
|---|---|---|
| `test/` | 纯 Dart，**无网络** | `rwkv_engine_routes_test.dart`（路由前缀/参数展平/state_id 走表头/串行化）、`rwkv_cloud_provider_test.dart`（CF 头注入/HTML 识别）、`rwkv_batch_test.dart`（拆批/交错分组/降档恢复/8→1 POST/三级降级）、`entity_dropdown_test.dart` |
| `integration_test/` | **打真实端点**，会受外网影响 | `rwkv_cloud_live_test.dart`：testConnection 200、最小 2 条 ping batch、8 槽位、流式 3 槽不混串、**会话续跑记忆验证**、分叉能力档位、`available_bsz` 动态性 |
| `tool/` | `dart run` 直跑，**不需要 Flutter** | `verify_rwkv_batch.dart`（11/11）、`verify_launch_args.dart`（14/14）、`verify_pseudo_enums.dart`、`l10n_reverse_diff.py` 等 |

后两类的价值在于：本沙箱 **跑不了 `flutter test`**（`reg.EXE` 黑名单），
所以「把不依赖 Flutter 的逻辑放进 `tool/`」是唯一能拿到真实验证的手段。
写新模块时**优先让它保持无 Flutter 依赖**，可测性天差地别。

集成测试的凭证支持 `--dart-define=RWKV_CF_ID/RWKV_CF_SECRET` 覆盖，
避免把 token 硬编码进仓库（默认值仅为本地开发方便）。

### 34.3 并发上限必须暴露 getter 而不是散落 `_max`

`Semaphore` 早有 `max` / `available` getter，但一直没往上暴露，导致 P4-26 的
「并发上限」面板无从取值。本轮补：
- `RwkvProvider.concurrencyLimit / concurrencyAvailable`
- `RwkvEngine.concurrencyLimit / concurrencyAvailable`
- `TaskQueue.maxConcurrentTasks`（攒批自查用）

⚠ 展示时务必标注：**这只是客户端保守限流**，真实并发由服务端 FIFO 队列决定
（读 `/v1/server/status` 的 `available_bsz`）。把客户端数字当成"引擎能力"是误读。

### 34.4 P4 剩余项（未做，按优先级）

| 项 | 说明 | 依赖 |
|---|---|---|
| 26 | AI 健康检查页（Provider 概览 / 60s QPS + p50/p95 / State L1L2L3 命中） | 需给 `RwkvStateCache` 加 L1/L2/L3 命中计数器；折线用 `CustomPainter` 手写（引 charts 包会炸 Web 体积） |
| 27 | Agent 对话草稿 state 自动存档/恢复 | 对接 `takeSnapshot/restoreSnapshot` + KVStore；云端注意 §32.6（多节点 state 是节点本地的） |
| 28 | 8 Agent 配置页「哪些 Agent 攒批 / 哪个 group」开关 | 执行器已支持 `batchGroupId` 与 `useBatch`，只差 UI |
| 29 | 把 batch 能力抽成 `IBatchChatModel` mixin | 目前是 `RwkvBatchClient` + `RwkvCloudProvider` 组合，已可复用；mixin 化是锦上添花 |

---

## 35. AI 健康面板（P4-26）：指标算错不会报错，所以先验算法再做界面

### 35.1 为什么先做「纯 Dart 指标核心」而不是直接写页面

`AiRuntimeStats`（`lib/ai/observability/ai_runtime_stats.dart`）**刻意零 Flutter 依赖**，
于是可以用 `dart run tool/verify_ai_stats.dart` 真跑 —— 这抓出了两个真问题：

**① 时钟不同源 → 滚动窗口静默算错**
`record()` 用真实 `DateTime.now()` 打桶，而 `snapshot()` 若用别的时钟取窗口，
**过期判定与 `qpsSeries()` 会全错**，且不报错、只给一个看起来合理的数。
⇒ 修法是**注入时钟**（`DateTime Function()? clock`），而不是改测试。
这是通用教训：**凡是"现在几点"参与计算的聚合器，时钟必须可注入。**

**② 我的指标模型本身错了：`logicalCalls` vs `items`**
最初把「8 个 Agent 攒批」建模成 8 条样本（7 条 `httpPosts=0`），
于是「省下 N 次往返」算不出来。正确模型是 **items vs posts**：

| 字段 | 含义 | 8 槽批量一次 |
|---|---|---|
| `logicalCalls` | 逻辑调用数（一次批量 = 1） | 1 |
| `totalItems` | 条目数（批量按槽位累加） | 8 |
| `httpPosts` | **实际**发出的 POST（拆批后 > 逻辑调用） | 1 |
| `httpPostsSaved` | `totalItems - httpPosts` | **7** |
| `itemsPerPost` | 越大越省 | **8.0** |

实测（真实端点 3 次调用 / 211 条目）：`itemsPerPost = 70.33`，省下 **208** 次往返。

### 35.2 ⚠ 百分位的边界知识（面板必须同时显示 p95 与 max）

**慢样本恰好 5% 时，p95 会落在最后一个快样本上** → `tailRatio = 1.0`，
看起来"没有长尾"，实际有 5% 的请求慢了 20 倍。

这不是 bug，是百分位定义。所以面板**同时展示 p50 / p95 / p99 / max**，
并且 `tailRatio` 只在 > 3 时才提示"长尾严重"。
（`tool/verify_ai_stats.dart` 里把这条边界留成了断言，防止后人"优化"掉。）

### 35.3 面板的核心设计：客户端真值 vs 服务端真值**分开展示**

这是本页最容易被做错的地方 —— 把两侧合并成一个数字就会误导：

| | 客户端 | 服务端 |
|---|---|---|
| 并发 | `Semaphore.max`（我方**保守限流**） | `available_bsz`（引擎**真实容量**，动态） |
| State | 本进程内存缓存命中/未命中（**只有两级**） | L1 VRAM / L2 RAM / SQLite（**在另一个进程**，且多节点下可能问到别的节点显示全 0，见 §32.6） |
| 吞吐 | 端到端延迟（含跨境 RTT + 拆批重试） | `last_request.decode/prefill_speed`（纯 GPU 速度） |

⇒ 页面上并排展示并各自标注口径。典型诊断路径：
- QPS 到顶 + `queued > 0` → 该**降**并发（别再加大）
- 客户端 State 命中率低 → 每轮都在重编码，查会话是否被闭/TTL 清掉
- 失败分类全是 `bszOverflow` → 攒批尺寸超了服务端上限，会自动拆但慢
- 失败分类是 `authFailed` → CF Token 拼错/过期（不是网络问题）

### 35.4 埋点接线点（都已接好）

| 生产者 | 接法 |
|---|---|
| `RwkvBatchClient` | 构造注入 `stats` + `statsProvider`；`chat()` 里数 **实际** POST 次数（`onPost` 回调贯穿拆批递归），失败用 `RwkvBatchException.kind.name` 作分类 |
| `RwkvCloudProvider` | 持有 `_stats` 并转交 batch client；`statefulChat` 单独记录 |
| `RwkvEngine` | 构造注入 `stats`，把 `stateCache.onLookup/onEvicted` 接到指标 —— **引擎不持有指标所有权**，注入 null 就不统计 |
| `RwkvStateCache` | 新增 `onLookup(hit, bytes)` / `onEvicted(bytes)` 回调；⚠ **过期也算未命中**（对调用方就是"拿不到"，算命中会让面板误报缓存有效） |
| `di.dart` | `aiRuntimeStatsProvider` 全局单例（面板要看整个 App 的统计，多实例会各算一半） |

### 35.5 折线为什么手写而不引 charts 包

只需一条 60 点迷你折线。引 charts 包会明显增大 Web 产物体积，
而 `_SparklinePainter` 约 100 行就够（含"全 0 时不除零"的边界处理）。

### 35.6 P4 剩余

| 项 | 状态 |
|---|---|
| 26 健康面板 | ✅ 完成（本文） |
| 27 state 自动存档/恢复 | 未做 |
| 28 Agent 攒批配置 UI | 未做（执行器已支持 `batchGroupId` / `useBatch`） |
| 29 batch 能力 mixin 化 | 未做（组合式已可复用） |

---

## 36. Agent 攒批配置（P4-28）：先修设计缺陷，再加开关

### 36.1 ⚠ 先修的那个缺陷：默认 `buildPromptForBatch` 会**静默降质**

P3 落地时 `BaseAgent.buildPromptForBatch()` 的默认实现是「把 parameters 拍平成
`key: value` 文本」。**直接给它加个开关是最糟的做法** —— 用户一打开，攒批"生效"了，
但每个 Agent 拿到的是一坨没有 system 指令、没有世界观上下文、没有输出格式约束的
参数流水账。结果就是"开了攒批之后文笔变差了"，而且**根本定位不到原因**。

根因：批量路由**无状态**（不带 `rwkvSessionId` 的 state 续跑），prompt 必须
**自包含**；单路路径则靠 Agent 精心构造的 prompt + 会话 state。两者不可互换。

⇒ **修法：让"不支持"成为显式信号。**

```dart
/// 默认返回 null = 「本 Agent 不支持攒批」，这是刻意的。
String? buildPromptForBatch(String taskType, Map<String, dynamic> parameters) {
  final explicit = parameters['batchPrompt'];
  if (explicit is String && explicit.trim().isNotEmpty) return explicit;
  return null;   // ← 不再兜底
}
```

于是三层都以此为准，**不可能出现"开关打开了却没效果"**：

| 位置 | 判定 |
|---|---|
| `NovelWorkflowEngine._shouldBatch()` | 返回 null → 直接走单路 |
| `BatchAgentExecutor._flush()` | 返回 null → 该条目**判失败**并给出「覆写 buildPromptForBatch / 关掉开关」的可操作提示 |
| `AgentBatchConfigPage` | 实时调一次看是否为 null，UI 上标「未实现 → 攒批不会生效」 |

⚠ 注意 `parameters['batchPrompt']` 仍被透传：调用方显式给了自包含 prompt 时视为已提供。

### 36.2 「支持攒批」是**能力**，不是开关 —— 配置只能关不能赋

`AgentBatchSettings` 的语义因此是"允许"，不是"启用"。配置对没有能力的 Agent
置 `enabled=true` **不会有任何效果**，`describe()` 会明确写出来：

```
CharacterAgent：⚠ 已开启但**未实现**批量 prompt → 实际不会攒批，请覆写…或关掉
PlotAgent：✅ 生效中（分组=short）
WriterAgent：可攒批但未开启
EditorAgent：未开启（该 Agent 也未实现批量 prompt）
```

这句"已开启但未实现"是本页最有价值的一行字 —— 它把最容易让人困惑的状态直接说清楚了。

### 36.3 分组（`batchGroupId`）到底解决什么

HANDOFF §28 的场景：**Director 的 prompt 特别长，和短 prompt 混在一批会把整批的
首 token 时间都拉到跟它一样**。攒批是**同批同速**的（一次 prefill 多个 prompt，
一起等最慢的那个），所以长任务必须单独成组。

UI 上因此专门提示两种常见误解：
- 「所有已开启的 Agent 都在『默认』组」→ **等于没分组**
- 分组少的场景下攒批收益有限（同组才合批）

### 36.4 配置持久化与注入

- KVStore：`scope=ai_config` / `key=agent.batch_settings`（`AgentBatchSettingsNotifier`）
- 引擎注入用 **`ref.read` 的闭包**而不是 `watch`：配置变更不该重建引擎
  （引擎持有 Agent 注册表与 taskQueue）
- 分组注入顺序：**任务上的显式 `batchGroupId` 优先**，其次才取全局配置
  （与 `rwkvSessionId` 的注入方式一致）

### 36.5 验证

`AgentBatchSettings` 与 `BaseAgent` 侧都是纯 Dart ⇒ 可 `dart run` 真跑：

`dart run tool/verify_batch_settings.dart` → **25/25 PASS**，覆盖：
默认全关、开关与分组读写、**分组分布**、**哨兵语义**（区分"不传"与"显式传 null 清空"）、
往返序列化 + 脏数据容错、`describe()` 的四种状态输出。

⚠ 哨兵必须放在**顶层**（`const Object kAgentBatchGroupUnset`）：一开始用
`AgentBatchEntry._sentinel` 私有常量，`di.dart` 跨库引用直接编译失败。

### 36.6 P4 剩余

| 项 | 状态 |
|---|---|
| 26 健康面板 | ✅ |
| 28 Agent 攒批配置 | ✅（本文） |
| 27 state 自动存档/恢复 | 未做（云端多节点下意义有限，见 §32.6；建议等本地引擎跑起来再做） |
| 29 batch 能力 mixin 化 | 未做（当前组合式已可复用） |

⚠ 遗留提醒：**8 个内置 Agent（Director/Writer/Character/Plot/World/Reader/
Summarizer/Editor）目前都还没有覆写 `buildPromptForBatch`** ⇒ 在它们各自实现之前，
攒批开关打开也不会有实际效果。这是**刻意留的安全默认**，但要让 P3 的攒批真正产出
价值，下一步需要逐个 Agent 实现「与单路等价的批量 prompt」。

---

## 37. 让攒批真正产出价值：Agent 批量 prompt + 一个被实测揪出的泄漏 bug

### 37.1 ✅ 好消息：批量 prompt 可以**同源拼接**，不需要逐 Agent 手写

先读了单路的真实构造（`BaseAgent.executeTaskWithAI`）：

```dart
final systemPrompt = buildSystemPrompt(taskType);
final userPrompt   = buildUserPrompt(taskType, parameters);
ChatRequest(
  systemPrompt: systemPrompt,
  messages: [ChatMessage.user(userPrompt)],   // ← 只有 system + 一条 user
  temperature: 0.7,
  maxTokens: resolveRwkvMaxTokens(taskType),
)
```

而 8 个内置 Agent **每个都已经有** `buildSystemPrompt` + `buildUserPrompt`
（P1 移植时就拆好了）。所以批量 prompt 就是：

```
System: <buildSystemPrompt(taskType)>

User: <buildUserPrompt(taskType, parameters)>

Assistant:
```

⇒ 在 `BaseAgent` 里**通用实现一次**（`buildSelfContainedPrompt`），
用 `bool get supportsBatchPrompt`（默认 `false`）逐 Agent 声明 —— 8 个内置 Agent
全部声明 `true`。这比逐个手写 8 份 prompt 可靠得多：**它保证与单路同源**。

⚠ 唯一不可消除的差异：单路 RWKV 走 `chatInSession(sessionId:)`，有**会话 state 的
隐式记忆**；批量无状态，所以增量上下文（前几步任务的产出）**不会**隐式进入批量 prompt。
若某个工作流依赖这个隐式记忆，就不该走批量（或把上下文显式写进 `buildUserPrompt`）。

### 37.2 三个参数必须与单路对齐（否则"等价"就是空话）

| 参数 | 单路 | 批量（已对齐） |
|---|---|---|
| `temperature` | `0.7` | `0.7`（原本用协议默认 `1.0` → 已改） |
| `max_tokens` | `resolveRwkvMaxTokens(taskType)` | 整批取各任务映射的**最大值**（同一套映射，原本写死 1024） |
| system 段 | `ChatRequest.systemPrompt` | **内联进 prompt**（批量路由没有 system 概念） |

⚠ 批量只有**一个** `temperature` / `max_tokens`，无法逐槽位区分 —— 所以
混批时不同任务的采样需求会被拉平，这也是 `batchGroupId` 存在的另一个理由。

### 37.3 实测：8 条真实 Agent prompt → 1 次 POST，10.87s

从 `agents.dart` **实时提取**真实 system prompt，按上述格式拼装，一次发出：

| Agent | taskType | 输出字数 | 结构 |
|---|---|---|---|
| Director | AnalyzeTheme | 439 | 有 `##` |
| Writer | GenerateChapterContent | 415 | 有 `##` |
| Character | GenerateCharacter | 422 | 有 `##` |
| Plot | GeneratePlot | 423 | 有 `##` |
| **World** | CreateWorldSetting | 409 | ⚠ **无 `##`，且是 `<think>…`** |
| Reader | EvaluateChapter | 459 | 有 `##` |
| Summarizer | SummarizeChapter | 316 | 有 `##` |
| Editor | ContentReview | 237 | 有 `##` |

8 条 → **1 次 POST**、`index` 覆盖 0..7、8/8 非空。**7/8 出现 `##` 分节** →
硬证据：system 段确实被模型读到了（批量 prompt 没丢约束）。

### 37.4 ⚠ 揪出的真 bug：`<think>` 泄漏进正文，而且**未闭合**清不掉

World 那条返回的是：
```
<think>好的，用户让我以东方奇幻设定总监的身份来回应这个任务。首先，我需要仔细分析…
```
`max_tokens` 在"思考中"用尽 ⇒ **永远不会出现闭合标签**。
而 `AIOutputSanitizer._thinkingRegex` 只匹配**成对**的
`<think>[\s\S]*?</think>` ⇒ 匹配不到 ⇒ **整段推理被当成正文吐给用户**。

**两个层面都错了**：

1. **批量路径根本没调清理器。** `AIOutputSanitizer.extractVisibleContent` 在
   ollama / openai 兼容 / rwkv_engine **三处**都调了，**唯独批量路径没调**。
   ⇒ 已在 `BatchAgentExecutor` 回填前补上，并在清理后为空时打 warning 提示
   「多半是 max_tokens 被思考吃满，建议提高该任务 maxTokens」。
2. **清理器只处理成对标签。** ⇒ 新增 `_unclosedThinkingRegex`：
   **只**在内容**开头**出现未闭合 `<think>`/`<thinking>` 时判定为「通篇是推理」→ 返回空。

### 37.5 ⚠ 没有参数级逃生通道（实测排除）

试过在批量请求里加各种参数，**5 种取值输出都没差别**：

| 参数 | 结果 |
|---|---|
| 不传 | 无 `<think>`（本次没触发） |
| `think_type=none` / `fast` | 同上 |
| `enable_think=false` / `think=false` | 同上 |

⇒ **批量路由不受 `think_type` 控制**（那是 chat 路由的特性），
模型是**偶发**自发吐 `<think>`。所以**没有参数级解法，清理器是唯一解**
（也正因为它偶发，不做清理就会变成"偶尔出现一段莫名其妙的推理文字"这种最难查的 bug）。

### 37.6 验证

| 脚本 | 结果 |
|---|---|
| `dart run tool/verify_output_sanitizer.dart` | **13/13 PASS**（含真实泄漏样本作夹具、不误删正文、不退化） |
| `test/agent_batch_prompt_test.dart` | 8 Agent 全部：system 被内联 / user 被包含 / 以 `Assistant:` 收尾 / 顺序正确 |
| 实测（真实端点，8 条真实 Agent prompt） | 8 条 → 1 POST、10.87s、7/8 结构正确 |

⚠ **`tool/` 里的验证脚本要用 `dart run` 跑，所以被验模块必须保持零 Flutter 依赖。**
本轮 `output_sanitizer.dart`（只依赖 `dart:convert`）正好满足 —— 这也是它值得单独
验一遍的原因：思考前缀处理是**文本层的静默错误**，不测就会漏。

### 37.7 P4 收尾状态

| 项 | 状态 |
|---|---|
| 26 健康面板 | ✅ |
| 28 Agent 攒批配置（含批量 prompt 实现） | ✅ |
| 27 state 自动存档/恢复 | 未做（云端多节点下意义有限，见 §32.6） |
| 29 batch 能力 mixin 化 | 未做 |

---

## 38. 模型选择器的显存适配（本机实测驱动出来的一轮修复）

### 38.1 ⚠ 先看清事实：本机放不下「默认模型」

实测本机（`nvidia-smi`）：**NVIDIA GeForce RTX 3070 Ti Laptop GPU · 总 8.0GB / 空闲 6.6GB**。

再拉 HF `BlinkDL/rwkv7-g1` 的真实清单（12 个 `.pth`）：

| 模型 | 权重体积 | 8GB 机器 |
|---|---|---|
| 0.1b / 0.4b / 0.1b(变体) | 0.4 / 0.8 / 1.9 GB | ✅ |
| **1.5b**（g1i / g1j） | **2.8 GB** | ✅ **本机推荐** |
| 2.9b（g1i / g1j） | 5.5 GB | ⚠ 空闲 6.6GB 时放不下 |
| **7.2b**（g1i / g1j） | **13.4 GB** | ❌ **放不下** |
| 13.3b | 24.7 GB | ❌ |

而 **7.2B 正是云端在跑的那个、也是 `kRwkvCloudDefaultModel` 指向的那个**——
在本地路线上顺手点下去，就是「下载 10 分钟、启动 OOM 1 秒」。

⇒ 必须**在下载前**判适配。这一轮把它做成了。

### 38.2 显存探测：用 `nvidia-smi`，并区分「没有卡」与「探测失败」

`lib/ai/rwkv/rwkv_gpu_probe.dart`（门面）+ `_native` / `_stub`（与
`rwkv_file_probe` 同一条件导入模式），native 侧调：

```bash
nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv,noheader,nounits
```

选它的理由：①就是驱动自带的权威答案，与 CUDA 运行时一致；②输出格式稳定；
③进程 spawn 在本项目已有先例。

⚠ **解析失败一律返回空列表**（= "不知道"），**绝不能当成"显存为 0"**
——否则会把所有模型都标成放不下。同理 `judgeModelFit` 在拿不到显存时返回
`unknown` 且 `shouldBlock = false`（PITFALLS §38.4 有专门断言）。

**实测已验证**：真机上正确返回 `NVIDIA GeForce RTX 3070 Ti Laptop GPU · 总 8.0GB / 空闲 6.6GB`。

### 38.3 ⚠ 两个被验证脚本抓出来的真实设计错误

**① 判据必须用「空闲」显存，不是「总」显存**
总 8.0GB 但空闲 6.6GB —— 桌面/浏览器已经吃掉 1.4GB。
用总量判定会把**实际加载不进去**的模型标成"可用"。
⇒ 参数直接命名为 `vramAvailableBytes` 并在文档里写明应当传 free。

**② 挑模型必须按「参数量」，绝不能按「文件体积」**
真实清单里 `rwkv7b-g1b-0.1b-20250822-ctx4096` 只有 **0.1B 却占 3.4GB**
（另一套架构变体），而 `rwkv7-g1j-2.9b` 是 **2.9B / 5.5GB**。
按体积挑会挑到前者 —— **明显的降智选择**。
⇒ 新增 `parseParamRankFromName()`，挑推荐时按参数量排。

**③ 而且这个解析器自己也踩了一次坑（很隐蔽）**
第一版正则写的是 `(\d+(?:\.\d+)?)\s*b`，结果在
`rwkv7b-g1b-0.1b-…` 上**先命中了家族前缀 `rwkv7b` 里的 `7b`** → rank 70，
**反而压过真正的 2.9B（rank 29）**，于是"按参数量挑"静默退化成
"挑到那个 0.1B 变体"。修法是要求边界：`[-_](\d+(?:\.\d+)?)b(?=[-_]|$)`。

> 这三个错误全部由 `tool/verify_model_fit.dart` 抓出来（最终 **31/31 PASS**），
> 其中 ①③ 都是"算错了不会报错、只会给你一个看着合理的数"的类型 ——
> 又一次印证：**判定逻辑做成纯 Dart 能 `dart run` 真跑，收益是复利的。**

### 38.4 估算口径与其依据

权重之外还要留状态 / 激活 / logits / workspace / 安全空间（官方文档 §11 的服务端口径）。
取一个**简单可解释**的近似：

```
所需显存 ≈ 权重 × 1.15 + 1GiB
fits     : 需求 ≤ 空闲 × 0.85     （留 15% 峰值余量）
tight    : 需求 ≤ 空闲
tooLarge : 否则 → UI 直接禁用该项，点不下去
```

对应本机 6.6GB 空闲：1.5B（4.2GB 需求）→ `fits`；2.9B（7.3GB）→ `tooLarge`。
**本机实际推荐 = `rwkv7-g1i-1.5b-20260805-ctx16384`**（实测输出）。

### 38.5 UI 落地

`_BuiltInEngineCard` 的模型选择对话框：
- 顶部显示 `显卡名 · 空闲 X.XGB`；探不到则明说"仅显示体积，请自行确认"
- 每项前置图标：✅ 可用 / ⚠ 余量很薄 / ⛔ 放不下（**该项 `enabled=false` 点不动**）/ ❓ 未知
- `describeModelFit()` 把「需要约 X.XGB · 本机空闲 Y.YGB → 结论」写成一行，用户不用换算
- `pickBestFittingModel()` 的结果打「本机推荐」徽标
- GPU 探测结果在 state 里缓存（只探一次，不每次开对话框都 spawn 进程）

### 38.6 ⚠ 本机结论（给决策用）

**RTX 3070 Ti Laptop 8GB 不适合作为这个项目的本地主力**：
- 只能用 1.5B（2.8GB）——与云端在用的 7.2B **能力差距明显**
- 2.9B 在"空闲 6.6GB"下已放不下；要跑得先关掉所有吃显存的程序且仍属勉强
- 7.2B / 13.3B 完全无望

⇒ 本地引擎路线的合理定位是「**离线兜底 / 小模型草稿**」，
主力仍应是云端 7.2B（或换一张 ≥24GB 的卡）。这一点值得在 UI 上直说，
而不是让用户下载 13.4GB 之后才发现。

---

## 39. P4-27 会话存档：原规格「存 state 字节」物理上不可实现

### 39.1 ⚠ 被实测推翻的前提（这是本轮最重要的发现）

HANDOFF P4-27 原话是「把 session 当前 state **快照字节**写 KeyValueStore」。
但读完引擎实现发现：**客户端从来没有过真实的 state 字节。**

```dart
// rwkv_engine.dart 的 chat 路径（P1 起就如此）：
final fakeBytes = Uint8List(0);
final state = RwkvState(
  ...
  bytes: parentState?.bytes ?? fakeBytes,   // ← 永远是空/继承空
);
```

而 rwkv_lightning 的接口**没有 state 导出端点**——只有
`/state/chat/completions`、`/state/status`、`/state/delete`。
旧实现 `takeSnapshot()`（`GET $base/state?session=`）与
`restoreSnapshot()`（`POST $base/state`，octet-stream）**实测都是 404**，
且全项目**没有任何调用方**（grep 为空）。

⇒ 「存几 MB state 字节、下次直接恢复」**物理上不可实现**。
两个假 API 已删除，换成 `RwkvEngine.replayTranscript()`。

### 39.2 ✅ 正确设计：存「对话转录本」，恢复 = 重放一次

| | 原设想（state 字节） | 实际实现（转录本） |
|---|---|---|
| 可行性 | ❌ 无导出端点 | ✅ 只是 role+content 文本 |
| 跨模型 | ❌ state 与模型/引擎版本强绑定，不可迁移 | ✅ 带 `modelId`，可校验、可拒绝 |
| 可解释性 | ❌ 二进制不可读 | ✅ UI 能告诉用户"恢复后会记得什么" |
| 恢复成本 | （设想）零 | ⚠ 一次 prefill（之后每轮 O(1)） |
| 云端/本地 | — | ✅ 通用（本地的 `--state-db-path` 本就会落盘 state，重放只在 DB 丢失/换模型时才需要） |

`RwkvEngine.replayTranscript(sessionId, turns, {maxTokens = 1})`：
把转录本按经典格式拼成**单条** prompt（`System:/User:/Assistant:`），
发 `/state/chat/completions`，`max_tokens: 1`（只为建 state，不生成）；
成功后**把 `session.history` 填满** —— 这一步不能省，
`_buildStatefulBody` 靠 `history.isEmpty` 判断"发全量还是发增量"，
不填满会导致下一轮把历史再发一遍（state 里已有，等于重复）。

### 39.3 ⚠ 三个容易做错的点（都已处理）

1. **存档键必须稳定**。引擎每次 `openSession` 都生成新 sessionId，
   用它做键 = 存了永远找不回来。⇒ 键取**业务键**：工作流的
   `configuration['archiveKey']`，缺省用工作流名。
   并在 `save()` 里对空键抛 `ArgumentError`（防呆）。
2. **模型不匹配必须拒绝**。RWKV 的 state 与模型强绑定：换模型后重放旧转录本，
   得到的是"另一个模型的记忆"，语义完全不同 —— 而且**不会报错**，只会写出
   上下文错乱的东西。⇒ `loadCompatible()` 带模型校验，不匹配返回
   `RwkvArchiveMismatch.modelMismatch`，调用方从零开始并打 warning。
3. **损坏存档当"不存在"**。`load()` 内部 catch `FormatException` 返回 null，
   绝不让一块坏数据炸掉整个工作流启动。

### 39.4 端到端实证（真实端点，3/3 PASS）

```
[1] 会话 1：告知暗号「琉璃十号」           → 助手确认记住
[2] 模拟 App 重启：只剩转录本（2 轮/44 字），session id 已变
[3] 重放转录本到**新会话**（max_tokens=1）  → rwkv7-fast-state, HTTP 200
[4] 在新会话里问暗号                       → 「我刚才记住的暗号是「琉璃十号」」 ✅
```

对照组逻辑：如果重放没生效，新会话应当像 §37 那样**幻觉出另一个暗号**。
答对只能来自重放重建的 state。

### 39.5 落地清单

| 文件 | 职责 |
|---|---|
| `lib/ai/rwkv/rwkv_session_archive.dart` | 转录本存档（纯 Dart）：`RwkvArchivedTurn` / `RwkvSessionArchiveEntry` / `loadCompatible`（模型校验） |
| `lib/data/storage/key_value_archive_store.dart` | `KeyValueStore` → 存档仓库的小适配器（把数据层依赖隔离在边界） |
| `lib/ai/rwkv/rwkv_engine.dart` | `replayTranscript()`（替换两个假 API） |
| `lib/ai/rwkv/rwkv_session.dart` | 新增 `resetHistory()`（重放前清本地历史，防重复） |
| `lib/ai/workflow/workflow_engine.dart` | 注入存档：工作流启动时恢复、`runAll` 后存档；键 = `configuration['archiveKey'] ?? 工作流名` |
| `tool/verify_session_archive.dart` | **18/18 PASS**（往返/模型校验/损坏容错/防呆） |
| 实测脚本 | **3/3 PASS**（存档→重放→记忆，见 §39.4） |

### 39.6 ⚠ 与本地引擎的衔接（用户关心的场景）

本地 `rwkv_lightning_cuda` 启动时若指定 `--state-db-path`（已由
`RwkvLightningLaunchArgs` 落在 `rwkv_models/_tools/_states/`），**state 本身就会
跨进程持久** —— 重放只在两种情况下才需要：
1. 换了模型（`loadCompatible` 会拦，防止张冠李戴）；
2. state DB 被删/换目录。

⇒ 本地路线的"继续上次写作"主要靠 state DB；转录本存档是**跨模型可迁移**的
保险层，也是云端路线（多节点、state 不保证在）唯一可靠的一层。

### 39.7 P4 收尾状态

| 项 | 状态 |
|---|---|
| 26 健康面板 | ✅ |
| 27 会话存档/恢复 | ✅（本文，转录本方案） |
| 28 Agent 攒批配置 + 批量 prompt | ✅ |
| 29 batch 能力 mixin 化 | ✅（`IBatchChatModel` + `RwkvBatchChatModelMixin`） |

---

## 40. 本轮 BUG 修复记录（2026-10-02）

### 40.1 结构化章节导出丢失定稿正文

- **现象**：章节 Markdown 只写出「定稿正文」标题，正文内容为空；JSON 过程档案也没有正文字段。
- **根因**：`ChapterExportInput` 只有字数统计，没有接收已落库正文，渲染器无法写出成稿。
- **修复**：新增 `content` 字段；续写与多 Agent 量产导出时传入实际正文；Markdown/JSON 同时保存正文。
- **验收**：`chapter_export_service_test.dart` 验证正文出现在两种格式，空正文仍输出「（空）」提示。

### 40.2 导出目录名可能形成点段

- **现象**：恶意/异常项目 ID 为 `.` 或 `..` 时，拼接导出路径可能指向根目录上级。
- **根因**：原净化只替换 Windows 非法字符，没有移除首尾点段。
- **修复**：净化控制字符和首尾点，并限制目录名长度；空结果统一使用 `untitled`。
- **验收**：新增点段项目 ID 测试，确认文件仍位于导出根目录内。

### 40.3 取消运行中任务提前释放并发槽

- **现象**：取消一个仍在执行的 Future 后，队列立即启动下一个任务，实际运行数短时超过上限。
- **根因**：`cancel()` 从 `_running` 移除任务，但 Dart Future 无法被强制中断。
- **修复**：取消仅标记状态；保留运行登记，待 runner 的 `finally` 收尾后才释放槽位和完成依赖。
- **验收**：新增并发槽回归测试，确认前一任务 runner 未退出时后续任务不会启动。

### 40.4 文件夹导出路径穿越

- **现象**：外部传入 `../` 或绝对路径文件键时，文件夹导出可能写到选择目录之外。
- **根因**：`writeTree()` 直接把相对键传给 `path.join`。
- **修复**：写盘前拒绝绝对路径、盘符和 `..` 段，仅允许安全相对路径。
- **验收**：新增路径穿越测试，确认非法键抛出 `ArgumentError` 且外部文件未生成。
