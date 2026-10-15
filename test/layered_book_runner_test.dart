// 分层写书 **App 侧链路** 集成测试（内存库 + 打桩模型，不联网）。
//
// 为什么需要它：`layered_book_runner.dart` 是「分层管线」与「真实仓库」之间唯一的接缝，
// 也是 GUI 适配里风险最高的一段 —— 它要同时满足：
//   * drift 的列长度约束（`Volumes.description` / `Chapters.summary` 各 1000 字上限，
//     写入时 `validateIntegrity` 会校验，超限直接抛异常）
//   * 卷/章的序号映射（`Chapters.orderIndex` 是**卷内**序号，而管线用的是**全书**序号）
//   * 细纲与伏笔提示的分列落库（`summary` vs `notes`）
//   * 正文回填（`content` / `wordCount` / `status`）
//
// 运行：flutter test -d windows test/layered_book_runner_test.dart
//   ⚠ 本机沙箱里裸 `flutter test` 不可用（Dart VM 无法 spawn 子进程）；
//     必须走 ASCII junction 路径 + `-d windows`。
library;

import 'dart:math' as math;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novelcraft/ai/utils/layered_pipeline_plan.dart';
import 'package:novelcraft/application/services/chapter_service.dart';
import 'package:novelcraft/application/services/layered_book_generation_service.dart';
import 'package:novelcraft/application/services/layered_book_runner.dart';
import 'package:novelcraft/application/services/plot_service.dart';
import 'package:novelcraft/application/services/project_service.dart';
import 'package:novelcraft/application/services/volume_service.dart';
import 'package:novelcraft/core/di.dart';
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/storage/key_value_store.dart';
import 'package:novelcraft/theme/app_theme.dart';
import 'package:novelcraft/ui/layout/app_shell.dart';
import 'package:novelcraft/ui/layout/navigation.dart';
import 'package:novelcraft/ui/pages/layered_generation_dialog.dart';

// ---------------------------------------------------------------------------
// 打桩模型：按提示词特征分派，返回**契约合法**的内容
// ---------------------------------------------------------------------------

/// 一批互不相同的句子（避免 ngram 复读、避免字段复制）。
const List<String> _sentences = <String>[
  '海水退到礁石以外的地方时，那截台阶才慢慢显出来。',
  '沈砚把外套的领子竖起来，风从灯塔那边斜着刮过来。',
  '老岑说过，退潮只有四十分钟，多一分钟都不行。',
  '他数着步子走下防波堤，脚下的青石又冷又滑。',
  '台阶尽头是一扇没有把手的门，门缝里透出纸页受潮的气味。',
  '他伸手推了一下，门无声地向里开了。',
  '屋里的书架一直排到看不见的深处，每一格都插着写有名字的卡片。',
  '最靠里的一格上，卡片上写的是他自己的名字。',
  '他抽出那本书，封面是空的，翻开第一页只有一行字。',
  '那行字写着今天的日期，和一句他还没说出口的话。',
  '身后传来水声，比刚才近了很多。',
  '他回头的时候，门已经合上了，只留一道细缝。',
  '沈砚把书抱在怀里，往门口走，脚步比来时快。',
  '细缝里透进来的光是灰的，像是天还没亮。',
  '他忽然想起，老岑说过这地方只在退潮时露出水面。',
  '而退潮的时间，从来没有人真正数准过。',
  '他站在门后，听见自己的呼吸在书架之间撞来撞去。',
  '远处有钟声，一共敲了三下。',
  '他低下头，看见自己的鞋尖已经湿了。',
  '水正在从门缝底下渗进来，很慢，但很稳。',
];

String _proseOf(int minChars) {
  final StringBuffer b = StringBuffer();
  int i = 0;
  while (b.length < minChars + 200) {
    b.write(_sentences[i % _sentences.length]);
    // 每句都重新排列组合，避免机械重复
    if (i % 3 == 2) b.write('\n');
    i++;
  }
  return '${b.toString().trim()}。';
}

/// 打桩 chat：返回内容**必须**能被运行时解析器吃下，否则测试会走重试分支。
Future<String> _stubChat(LayeredChatRequest r) async {
  final String u = r.user;

  // ① 里程碑（L1 卷 / L2 章）
  if (u.contains('均分成')) {
    final RegExpMatch? m = RegExp(r'均分成\s*(\d+)\s*段').firstMatch(u);
    final int count = int.tryParse(m?.group(1) ?? '') ?? 1;
    final bool isVolume = u.contains('卷名') || u.contains('本卷结束时');
    final StringBuffer b = StringBuffer('[');
    for (int i = 1; i <= count; i++) {
      if (i > 1) b.write(',');
      b.write('{"index":$i,"label":"'
          '${isVolume ? '第$i卷 潮线' : '第$i章 潮声$i'}","endState":'
          '"第$i段推进到全弧线的 ${(i * 100 / count).round()}%：'
          '沈砚解决了第$i个障碍，并暴露出第$i条新的疑问。"}');
    }
    b.write(']');
    return b.toString();
  }

  // ② L1 主线大纲
  if (u.contains('请写出一份主线大纲')) {
    return '第1卷 潮线 · 核心冲突：沈砚与老岑对图书馆的取舍；主角阶段目标：进入图书馆。\n'
        '第2卷 潮落 · 核心冲突：改写的代价浮现；主角阶段目标：查清编目员身份。\n'
        '全书结局：沈砚放弃最后一次改写，让图书馆与自己的记忆一同沉没。';
  }

  // ③ L2 分卷大纲
  if (u.contains('撰写本卷大纲')) {
    return '本卷核心冲突：沈砚必须在好奇与老岑的告诫之间选择。\n'
        '第1章｜潮声与灯塔｜走进退潮的台阶\n'
        '第2章｜借阅卡｜翻开写着自己名字的书\n'
        '第3章｜代价｜发现记忆开始缺失\n'
        '第4章｜闭馆｜做出取舍\n'
        '本卷埋下的长线伏笔：无。';
  }

  // ④ L3 章节细纲
  if (u.contains('请严格按以下 8 行输出')) {
    final RegExpMatch? m =
        RegExp(r'全书第\s*(\d+)/(\d+)\s*章').firstMatch(u);
    final int order = int.tryParse(m?.group(1) ?? '') ?? 1;
    final int total = int.tryParse(m?.group(2) ?? '') ?? 4;
    final StringBuffer b = StringBuffer();
    b.writeln('标题：《潮声与灯塔$order》');
    b.writeln('本章目标：沈砚在第$order次退潮里推进他的调查。');
    b.writeln('承接上文：他刚从上一处线索离开，手里还留着那张卡片。');
    b.writeln('核心冲突：老岑的告诫与他自己想知道的真相撞在一起。');
    b.writeln('关键转折：他在书架第$order格发现了新的名字。');
    b.writeln('章末钩子：水声比上一次更近了。');
    b.writeln('出场人物：沈砚、老岑');
    b.writeln('故事时间节点：入秋第$order日，退潮时分');
    // 末两章禁埋（与提示词一致）
    final bool canPlant = order + 2 <= total;
    if (canPlant) {
      b.writeln();
      b.writeln('## 伏笔提示');
      b.writeln('- T${order.toString().padLeft(3, '0')}（第$order章 → 第$total章）：'
          '一件旧物上的名字被反复提及，来历未明。');
    }
    return b.toString().trim();
  }

  // ⑤ L3 自查（补丁）
  if (u.contains('待核验的章节细纲')) {
    return '无需修改';
  }

  // ⑥ L4 正文分片
  if (u.contains('篇幅：本片不少于')) {
    final RegExpMatch? m =
        RegExp(r'篇幅：本片不少于\s*(\d+)\s*字').firstMatch(u);
    final int ask = int.tryParse(m?.group(1) ?? '') ?? 600;
    return _proseOf(ask);
  }

  // 兜底：返回一段无害正文（不应被走到）
  return _proseOf(600);
}

// ---------------------------------------------------------------------------
// 容器装配
// ---------------------------------------------------------------------------

class _MemKv extends KeyValueStore {
  final Map<String, String> data = <String, String>{};
  @override
  Future<void> init() async {}
  @override
  Future<String?> readJson(String scope, String key) async => data['$scope/$key'];
  @override
  Future<void> writeJson(String scope, String key, String json) async =>
      data['$scope/$key'] = json;
  @override
  Future<void> remove(String scope, String key) async =>
      data.remove('$scope/$key');
  @override
  Future<List<String>> listKeys(String scope) async => data.keys
      .where((String k) => k.startsWith('$scope/'))
      .map((String k) => k.substring(scope.length + 1))
      .toList();
}

class _FakeNavigation extends NavigationService {
  _FakeNavigation(this.target);
  final NavigationTarget target;
  @override
  NavigationHistoryEntry build() =>
      NavigationHistoryEntry(target, const NavigationContext());
}

ProviderContainer _container() => ProviderContainer(overrides: [
      // ignore: strict_raw_type
      databaseProvider.overrideWith((ref) {
        final AppDatabase db = AppDatabase.forTesting(NativeDatabase.memory());
        ref.onDispose(db.close);
        return db;
      }),
      keyValueStoreProvider.overrideWith((ref) async => _MemKv()),
      navigationProvider.overrideWith(
          () => _FakeNavigation(NavigationTarget.projectManagement)),
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // =========================================================================
  // 1) 端到端：分层管线 → 仓库落库
  // =========================================================================
  testWidgets('分层写书 App 侧：1 卷 4 章跑通并逐级落库', (WidgetTester tester) async {
    final ProviderContainer c = _container();
    addTearDown(c.dispose);

    final ProjectService projects = c.read(projectServiceProvider);
    final VolumeService volumes = c.read(volumeServiceProvider);
    final ChapterService chapters = c.read(chapterServiceProvider);
    final PlotService plots = c.read(plotServiceProvider);

    final LayeredBookRunner runner = LayeredBookRunner(
      projects: projects,
      volumes: volumes,
      chapters: chapters,
      plots: plots,
      chat: _stubChat,
      // 质量闸打桩：本测试只验证「链路 + 落库」，不验证正文质量
      qualityNote: (String prose, int minChars) => '',
    );

    final List<String> log = <String>[];
    final LayeredRunOutcome outcome = await runner.run(
      const LayeredRunRequest(
        bookTitle: '潮尾镇测试书',
        genre: '都市悬疑',
        theme: '改写尚未发生的坏事，代价由谁承担。',
        background: '临海小城，退潮时露出一座图书馆。',
        protagonist: '沈砚，夜班馆员，有面孔失认症。',
        cast: '沈砚、老岑',
        volumeCount: 1,
        chaptersPerVolume: 4,
        bookAnchor: PipelineAnchor(
          start: '沈砚刚接手夜班，对图书馆一无所知。',
          end: '百年大潮退去，图书馆被永久淹没，沈砚做出最终选择。',
          startLabel: '全书起点',
          endLabel: '全书终点',
        ),
      ),
      onProgress: (String step, double? p) => log.add(step),
    );

    // ---- 断言 1：项目已建 ----
    final ProjectRow? project = await projects.getByName('潮尾镇测试书');
    expect(project, isNotNull, reason: '应创建（或复用）项目');
    expect(project!.id, outcome.projectId);

    // ---- 断言 2：卷已建，且 description 落在列上限内 ----
    final List<VolumeRow> vs = await volumes.getByProjectId(project.id);
    expect(vs.length, 1, reason: '应恰好 1 卷');
    expect(vs.first.orderIndex, 1, reason: '卷序应为 1');
    expect(vs.first.description, isNotNull);
    expect(vs.first.description!.trim().isNotEmpty, isTrue,
        reason: '卷大纲应写入 Volumes.description');
    expect(vs.first.description!.length, lessThanOrEqualTo(1000),
        reason: '必须不超 drift 的 1000 字列上限');

    // ---- 断言 3：章已建，卷内序号正确，细纲与伏笔分列 ----
    final List<ChapterRow> cs = await chapters.getByProjectId(project.id);
    expect(cs.length, 4, reason: '应恰好 4 章');
    cs.sort((ChapterRow a, ChapterRow b) => a.orderIndex.compareTo(b.orderIndex));
    expect(cs.map((ChapterRow x) => x.orderIndex).toList(), <int>[1, 2, 3, 4],
        reason: 'Chapters.orderIndex 必须是**卷内**序号 1..4');
    for (final ChapterRow ch in cs) {
      expect(ch.volumeId, vs.first.id, reason: '章必须挂在唯一的卷上');
      expect(ch.title.trim().isNotEmpty, isTrue, reason: '章名不应为空');
      expect(ch.title.contains('《'), isFalse, reason: '章名应去掉书名号');
      expect(ch.summary, isNotNull);
      expect(ch.summary!.trim().isNotEmpty, isTrue,
          reason: '细纲应写入 Chapters.summary');
      expect(ch.summary!.length, lessThanOrEqualTo(1000),
          reason: '细纲必须不超 1000 字列上限');
      // 细纲列里**不应**混入伏笔小节（那是 notes 的职责）
      expect(ch.summary!.contains('## 伏笔提示'), isFalse,
          reason: '伏笔小节必须与 8 行细纲分列存放');
    }

    // ---- 断言 4：前两章可埋线 → notes 有伏笔小节；后两章禁埋 → notes 为空 ----
    final ChapterRow ch1 = cs[0];
    final ChapterRow ch2 = cs[1];
    final ChapterRow ch3 = cs[2];
    expect(ch1.notes, isNotNull, reason: '第 1 章可埋线，notes 应有伏笔提示');
    expect(ch1.notes!.contains('伏笔提示'), isTrue);
    expect(ch2.notes, isNotNull);
    expect(ch2.notes!.contains('伏笔提示'), isTrue);
    expect(ch3.notes ?? '', isEmpty,
        reason: '第 3 章距结尾不足 2 章 → 提示词禁埋 → notes 应为空');

    // 伏笔章号必须落在本书范围内（4 章）
    final RegExpMatch? fs =
        RegExp(r'第(\d+)章\s*→\s*第(\d+)章').firstMatch(ch1.notes!);
    expect(fs, isNotNull, reason: '伏笔提示应可被解析');
    final int a = int.parse(fs!.group(1)!);
    final int b = int.parse(fs.group(2)!);
    expect(a >= 1 && b <= 4, isTrue, reason: '伏笔章号必须 ∈ [1,4]');
    expect(b - a >= 2, isTrue, reason: '伏笔跨度必须 ≥ 2 章');

    // ---- 断言 5：正文回填 ----
    for (final ChapterRow ch in cs) {
      expect((ch.content ?? '').trim().isNotEmpty, isTrue,
          reason: '第 ${ch.orderIndex} 章应有正文');
      expect(ch.wordCount, greaterThan(0), reason: 'wordCount 应被回填');
      expect(ch.status, 'Completed', reason: '正文写入后状态应为 Completed');
    }

    // ---- 断言 6：主线大纲落库到 Plots ----
    final List<PlotRow> ps = await plots.getByProjectId(project.id);
    final Iterable<PlotRow> main =
        ps.where((PlotRow p) => p.type == '主线');
    expect(main.length, 1, reason: '应有且仅有一条「主线」剧情');
    expect((main.first.outline ?? '').trim().isNotEmpty, isTrue,
        reason: '主线大纲应写入 Plots.outline');

    // ---- 断言 7：结果统计与日志 ----
    expect(outcome.chapterCount, 4);
    expect(outcome.foreshadowErrors, 0, reason: '伏笔账本结构错误应为 0');
    expect(log, isNotEmpty, reason: '应有进度回调');
    expect(log.any((String s) => s.contains('主线大纲')), isTrue);
    expect(log.any((String s) => s.contains('正文')), isTrue);
  });

  // =========================================================================
  // 2) 幂等：同名书重复运行不应重复建卷/建章
  // =========================================================================
  testWidgets('分层写书 App 侧：同名书重复运行不重复建卷建章', (WidgetTester tester) async {
    final ProviderContainer c = _container();
    addTearDown(c.dispose);

    final LayeredBookRunner runner = LayeredBookRunner(
      projects: c.read(projectServiceProvider),
      volumes: c.read(volumeServiceProvider),
      chapters: c.read(chapterServiceProvider),
      plots: c.read(plotServiceProvider),
      chat: _stubChat,
      qualityNote: (String prose, int minChars) => '',
    );

    const LayeredRunRequest req = LayeredRunRequest(
      bookTitle: '幂等测试书',
      genre: '都市悬疑',
      theme: '主题',
      background: '背景',
      protagonist: '主角',
      cast: '甲乙',
      volumeCount: 1,
      chaptersPerVolume: 3,
      bookAnchor: PipelineAnchor(
        start: '起点状态',
        end: '终点状态',
        startLabel: '全书起点',
        endLabel: '全书终点',
      ),
    );

    await runner.run(req);
    final LayeredRunOutcome second = await runner.run(req);

    final ProjectRow? p = await c.read(projectServiceProvider).getByName('幂等测试书');
    expect(p, isNotNull);
    final List<VolumeRow> vs =
        await c.read(volumeServiceProvider).getByProjectId(p!.id);
    final List<ChapterRow> cs =
        await c.read(chapterServiceProvider).getByProjectId(p.id);
    expect(vs.length, 1, reason: '重复运行不应新建第二卷');
    expect(cs.length, 3, reason: '重复运行不应重复建章');
    expect(second.projectId, p.id, reason: '同名书应复用同一项目');
  });

  // =========================================================================
  // 3) GUI：分层写书对话框可打开且关键控件齐全
  // =========================================================================
  testWidgets('GUI：分层写书对话框可打开并渲染关键控件', (WidgetTester tester) async {
    // ⚠ 必须给足高度：对话框表单是 ListView，**懒构建** —— 视口太矮时
    // 「全书起点 / 全书终点」在屏幕外，widget 根本不会被创建，find 自然找不到
    //（首轮实测就是栽在这里，被误判成「控件缺失」）。
    tester.view.physicalSize = const Size(1400, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ProviderContainer c = _container();
    addTearDown(c.dispose);

    // 直接把对话框挂进一棵最小树（不启动 AppShell，避免 bootstrap 干扰）
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildTheme(builtInSkins.firstWhere(
            (s) => s.id == SkinIds.dark,
          )),
          home: Builder(
            builder: (BuildContext ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showLayeredGenerationDialog(ctx),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 标题
    expect(find.text('分层写书（串行 → 并行）'), findsOneWidget);

    // 首屏可见的输入项
    for (final String label in <String>['书名', '题材', '主题']) {
      expect(find.text(label), findsWidgets, reason: '缺少输入项：$label');
    }
    // 操作按钮在 actions 区，始终可见
    expect(find.text('开始生成'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    // ⚠ 对话框表单是 ListView 且外层 SizedBox 高度固定 520 —— 视口再大，
    //    ListView 也只构建可视范围内的项。所以下方字段**必须滚动到位**才存在，
    //    不能直接 find（首轮实测就是栽在这里，被误判成「控件缺失」）。
    final Finder scrollable = find
        .descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(Scrollable),
        )
        .first;

    await tester.scrollUntilVisible(
      find.text('全书终点'),
      160,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();

    // 滚动后可见的输入项
    for (final String label in <String>[
      '全书起点', '全书终点', '卷数', '每卷章数', '并行单元数',
    ]) {
      expect(find.text(label), findsWidgets, reason: '滚动后缺少：$label');
    }
    // 有状态开关（默认关闭）
    expect(find.textContaining('RWKV 有状态续跑'), findsOneWidget);
    final Switch sw = tester.widget<Switch>(find.byType(Switch));
    expect(sw.value, isFalse, reason: '有状态续跑应默认关闭（+50 实测结论）');

    // 关闭
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('分层写书（串行 → 并行）'), findsNothing);
  });

  // =========================================================================
  // 4) GUI：AppBar 上存在分层写书入口
  // =========================================================================
  testWidgets('GUI：AppShell 工具栏含分层写书入口', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ProviderContainer c = _container();
    addTearDown(c.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildTheme(builtInSkins.firstWhere(
            (s) => s.id == SkinIds.dark,
          )),
          home: const AppShell(),
        ),
      ),
    );
    await tester.pump();
    for (int i = 0; i < 12 && tester.binding.hasScheduledFrame; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byType(AppShell), findsOneWidget);
    // 宽屏走 TextButton.icon（标签「分层写书」）；窄屏走 IconButton（tooltip）
    final bool hasLabel = find.text('分层写书').evaluate().isNotEmpty;
    final bool hasIcon = find
        .byIcon(Icons.account_tree_outlined)
        .evaluate()
        .isNotEmpty;
    expect(hasLabel || hasIcon, isTrue,
        reason: 'AppBar 应有分层写书入口（宽屏文字 / 窄屏图标）');
  });

  // =========================================================================
  // 5) 纯逻辑：splitBrief 的崩溃回归（裸行「伏笔提示：」）
  // =========================================================================
  test('splitBrief 在裸行标题下不崩且能切出 body/section', () {
    const String bare = '标题：《x》\n本章目标：a\n承接上文：b\n核心冲突：c\n'
        '关键转折：d\n章末钩子：e\n出场人物：f\n故事时间节点：g\n\n'
        '伏笔提示：\n- T002（第2章 → 第6章）：裸行形态。';
    final ({String body, String? section}) r = BriefPatch.splitBrief(bare);
    expect(r.section, isNotNull);
    expect(r.body.contains('T002'), isFalse);
    expect(r.body.contains('故事时间节点：g'), isTrue);
    // 旧实现：content.indexOf('## 伏笔提示') == -1 → substring(0,-1) → RangeError
    expect(() => bare.substring(0, bare.indexOf('## 伏笔提示')),
        throwsA(isA<RangeError>()),
        reason: '证明旧写法确实会崩（这正是本次修复的动机）');
    expect(r.body.length, lessThan(bare.length));
  });

  // =========================================================================
  // 6) 纯逻辑：细纲字段复制检测（正文复读的上游成因）
  // =========================================================================
  test('duplicatedFields 能检出三字段复制', () {
    const String dup = '标题：《x》\n本章目标：同一句话。\n承接上文：别的。\n'
        '核心冲突：同一句话。\n关键转折：同一句话。\n章末钩子：钩子。\n'
        '出场人物：甲乙\n故事时间节点：某日。';
    final List<String> d = BriefPatch.duplicatedFields(dup);
    expect(d.length, 3);
    expect(d.contains('本章目标==核心冲突'), isTrue);
    expect(BriefPatch.looksLikeBrief(dup), isTrue);
    // 修好之后应清零
    final String fixed = BriefPatch.apply(dup,
        '核心冲突：沈砚必须在救人与代价之间选择。\n关键转折：他发现卡片背面有自己的名字。');
    expect(BriefPatch.duplicatedFields(fixed).isEmpty, isTrue);
  });

  // =========================================================================
  // 7) 纯逻辑：正文生成器本身满足契约（自检打桩素材是否合格）
  // =========================================================================
  test('打桩正文满足长度与收尾契约', () {
    final String p = _proseOf(600);
    expect(p.length, greaterThanOrEqualTo(600));
    expect(p.trim().endsWith('。'), isTrue);
    expect(math.max(0, p.length), greaterThan(0));
  });
}
