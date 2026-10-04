// 多智能体写书全链路（假执行器）测试：
// 固定 1+9 编制 / 偏向派活 / 组长验收 / 打回返工 / 章节落库 / 档案钩子 / 更新分派。
//
// 运行：flutter test test/multi_agent_book_generation_test.dart
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novelcraft/ai/models/chat.dart';
import 'package:novelcraft/ai/workflow/agent_state_manager.dart';
import 'package:novelcraft/application/services/multi_agent_book_generation_service.dart';
import 'package:novelcraft/application/services/chapter_dedup_guard.dart';
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/chapter_repository.dart';
import 'package:novelcraft/data/repositories/plot_repository.dart';
import 'package:novelcraft/data/repositories/project_repository.dart';
import 'package:novelcraft/data/repositories/volume_repository.dart';
import 'package:uuid/uuid.dart';

const Uuid _uuid = Uuid();

/// 脚本化假执行器：按 system/user 关键词路由到固定回复，并记录全部调用。
class _ScriptedChat {
  final List<String> systemCalls = <String>[];
  final List<String> userCalls = <String>[];

  Future<String> call(
    String systemPrompt,
    List<ChatMessage> messages, {
    required int maxTokens,
    double temperature = 0.85,
  }) async {
    final String user = messages.isEmpty ? '' : messages.last.content;
    systemCalls.add(systemPrompt);
    userCalls.add(user);

    // 主线大纲（规划组组长）
    if (systemPrompt.contains('MainAgent')) {
      return '核心冲突：玄穹宗面临魔渊复苏。\n主角成长线：叶知秋从外门到掌门。';
    }
    // 规划组写手：分卷 / 章节大纲
    if (systemPrompt.contains('大纲规划智能体')) {
      if (user.contains('制定本卷大纲')) {
        return '本卷起承转合：入门→历练→宗门大比。卷末状态：主角筑基成功。';
      }
      if (user.contains('制定章节大纲')) {
        return '本章大纲：主角初入宗门，结识师姐，通过入门试炼。';
      }
      return '大纲内容。';
    }
    // 章节组长：派活 / 验收 / 补写 / 拼接
    if (systemPrompt.contains('Team Lead')) {
      if (user.contains('输出 JSON 数组')) {
        return '[{"agent":1,"persona":"combat","title":"试炼之战",'
            '"brief":"打斗：主角与傀儡交手","boundary":"止于傀儡倒下","wordTarget":100},'
            '{"agent":2,"persona":"psych","title":"入门心声",'
            '"brief":"心理：主角内心挣扎与决心","boundary":"止于拜师完成","wordTarget":100}]';
      }
      if (user.contains('逐段验收')) {
        return '{"paragraphs":[{"agent":1,"accepted":true,"problems":""},'
            '{"agent":2,"accepted":false,"problems":"情绪层次不足"}],'
            '"report":{"timeRange":"入门第一天","themeTask":"主角拜入玄穹宗",'
            '"gains":"主角完成拜师，埋下师姐伏笔","safeguards":"下一章注意师姐身份线的推进节奏"},'
            '"updates":[{"target":"character","action":"create","name":"叶知秋",'
            '"field":"history","content":"拜入玄穹宗，成为外门弟子"}]}';
      }
      if (user.contains('请你亲自补写')) {
        return '组长补写：' * 60;
      }
      if (user.contains('拼接为整章正文')) {
        // 质量闸要求定稿 ≥ 4000 字
        return '【终稿】主角初入宗门，试炼之战后拜师入门，整章正文完整成稿。' * 150;
      }
      return '组长回复。';
    }
    // 写手：初稿（段落 2 故意写太短触发返工）/ 返工
    if (systemPrompt.contains('SubAgent Writer')) {
      if (user.contains('未通过组长验收')) {
        return '返工后的段落：' * 30;
      }
      if (user.startsWith('【主线大纲】') && user.contains('段落 1/')) {
        return '第一段：主角拔剑与傀儡激战，' * 40;
      }
      if (user.startsWith('【主线大纲】') && user.contains('段落 2/')) {
        return '太短';
      }
      return '写手正文。';
    }
    // 更新分派阶段的写手产出
    if (systemPrompt.contains('writer-')) {
      return '人物履历：拜入玄穹宗，成为外门弟子。';
    }
    return '';
  }
}

void main() {
  late AppDatabase db;
  late _ScriptedChat chat;
  late AgentStateManager states;
  final List<String> archiveLevels = <String>[];
  final List<Map<String, String>> archiveMeta = <Map<String, String>>[];
  final List<Map<String, Object?>> dispatchedItems = <Map<String, Object?>>[];

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    chat = _ScriptedChat();
    states = AgentStateManager();
    archiveLevels.clear();
    archiveMeta.clear();
    dispatchedItems.clear();
  });

  tearDown(() async => db.close());

  MultiAgentBookGenerationService buildService() =>
      MultiAgentBookGenerationService(
        projects: ProjectRepository(db),
        plots: PlotRepository(db),
        volumes: VolumeRepository(db),
        chapters: ChapterRepository(db),
        writingProvider: () => null,
        stateManager: states,
        chatExecutor: chat.call,
        archiveHook:
            ({
              required String level,
              required String? projectId,
              required String title,
              required String content,
              required Map<String, String> metadata,
            }) async {
              archiveLevels.add(level);
              archiveMeta.add(metadata);
            },
        updateDispatch:
            ({
              required String projectId,
              required List<Map<String, Object?>> items,
              required Future<String> Function(int writerSlot, String prompt)
              writerChat,
            }) async {
              dispatchedItems.addAll(items);
              for (int i = 0; i < items.length; i++) {
                await writerChat(i + 1, '按模板产出：${items[i]['name']}');
              }
              return const <String>['ok'];
            },
      );

  test('大纲由 MainAgent 执行，章节正文由 SubAgent 执行', () async {
    final List<String> mainCalls = <String>[];
    final List<String> subCalls = <String>[];
    final MultiAgentBookGenerationService service =
        MultiAgentBookGenerationService(
          projects: ProjectRepository(db),
          plots: PlotRepository(db),
          volumes: VolumeRepository(db),
          chapters: ChapterRepository(db),
          writingProvider: () => null,
          stateManager: states,
          planningChatExecutor:
              (
                String system,
                List<ChatMessage> messages, {
                required int maxTokens,
                double temperature = 0.85,
              }) {
                mainCalls.add(system);
                return chat.call(
                  system,
                  messages,
                  maxTokens: maxTokens,
                  temperature: temperature,
                );
              },
          chatExecutor:
              (
                String system,
                List<ChatMessage> messages, {
                required int maxTokens,
                double temperature = 0.85,
              }) {
                subCalls.add(system);
                return chat.call(
                  system,
                  messages,
                  maxTokens: maxTokens,
                  temperature: temperature,
                );
              },
        );
    await service.generate(
      config: const MultiAgentBookConfig(
        bookTitle: '模型分工测试',
        authorName: '作者',
        targetVolumes: 1,
        chaptersPerVolume: 1,
        craft: WritingCraft.team,
      ),
    );
    expect(mainCalls.any((s) => s.contains('MainAgent')), isTrue);
    expect(mainCalls.any((s) => s.contains('大纲规划智能体')), isTrue);
    expect(mainCalls.any((s) => s.contains('SubAgent Writer')), isFalse);
    expect(subCalls.any((s) => s.contains('SubAgent Writer')), isTrue);
    expect(subCalls.any((s) => s.contains('大纲规划智能体')), isFalse);
  });

  test('全链路：固定编制 / 偏向派活 / 验收返工 / 落库 / 档案 / 更新分派', () async {
    final MultiAgentBookResult r = await buildService().generate(
      config: const MultiAgentBookConfig(
        bookTitle: '测试书',
        authorName: '作者',
        targetVolumes: 1,
        chaptersPerVolume: 1,
        // 本用例验证的是「组长 + 9 写手」旧工艺链路（派活/验收/返工/分派），
        // 而默认工艺已改为 duo —— 必须显式指定 team。
        craft: WritingCraft.team,
      ),
    );

    expect(r.isSuccess, isTrue, reason: r.message);
    expect(r.chaptersWritten, 1);
    expect(r.volumesPlanned, 1);
    expect(
      r.warnings.every((String w) => !w.contains('大纲生成失败')),
      isTrue,
      reason: '分卷/章节大纲不允许出现空结果（重试必须补齐）：${r.warnings}',
    );

    // 固定编制：写手人设 9 位，state 分组恰好 10 成员且全部在结束后关闭释放
    expect(states.totalGroups, 2, reason: '规划组 + 1 个章节团队');
    expect(states.activeGroupCount, 0, reason: '组用完必须关闭释放 state');

    // 组长验收 → 打回返工链路真实发生（验收 JSON 标记段落2不合格 + 写手短稿）
    final int reworkCalls = chat.userCalls
        .where((String u) => u.contains('未通过组长验收'))
        .length;
    expect(reworkCalls, 1, reason: '不合格段必须打回对应写手返工一轮');

    // 偏向派活：段落计划必须带 persona，且提示词列出 9 位写手偏向
    final String planCall = chat.userCalls.firstWhere(
      (String u) => u.contains('输出 JSON 数组'),
    );
    expect(planCall, contains('persona'));

    // 章节落库：验收后的终稿写入
    final ChapterRepository chapters = ChapterRepository(db);
    final ProjectRepository projects = ProjectRepository(db);
    final List<ProjectRow> projectRows = await projects.getAll();
    final List<ChapterRow> chapterRows = await chapters.getByProjectId(
      projectRows.first.id,
    );
    expect(chapterRows, hasLength(1));
    expect(chapterRows.single.content!, contains('【终稿】'));
    expect(chapterRows.single.status, 'Completed');
    expect(chapterRows.single.orderIndex, 1);

    // 写作档案：项目（大纲）/ 分卷 / 章节 三档齐全
    // + 写作结束时的**收尾全书档案**（第二档 project）
    expect(archiveLevels, <String>['project', 'volume', 'chapter', 'project']);
    expect(
      archiveMeta.last['themeTask'],
      contains('全书成稿'),
      reason: '最后一条必须是书籍（项目）成稿总账',
    );
    // 档案顺序：project(主线大纲) / volume / chapter / project(收尾全书档案)
    final Map<String, String> chapterMeta = archiveMeta[2];
    for (final String k in <String>[
      'timeRange',
      'themeTask',
      'gainsLosses',
      'safeguards',
    ]) {
      expect(chapterMeta.containsKey(k), isTrue, reason: '章节档案缺 $k');
    }
    expect(chapterMeta['gainsLosses']!, contains('伏笔'));
    expect(chapterMeta['safeguards']!, contains('师姐'));

    // 验收后更新分派：固定模板接口收到组长罗列的待更新项
    expect(dispatchedItems, hasLength(1));
    expect(dispatchedItems.single['target'], 'character');
    expect(dispatchedItems.single['action'], 'create');
  });

  test('章节查重守卫：同卷同序号 / 同标题命中既有章节', () async {
    final ProjectRepository projects = ProjectRepository(db);
    final VolumeRepository volumes = VolumeRepository(db);
    final ChapterRepository chapters = ChapterRepository(db);
    final String pid = _uuid.v4();
    await projects.create(
      ProjectsCompanion.insert(id: pid, name: '查重书', type: '玄幻'),
    );
    final String vid = _uuid.v4();
    await volumes.create(
      VolumesCompanion.insert(
        id: vid,
        title: '第一卷',
        projectId: pid,
        orderIndex: const Value(1),
      ),
    );
    await chapters.create(
      ChaptersCompanion.insert(
        id: _uuid.v4(),
        volumeId: vid,
        title: '第一章',
        projectId: Value(pid),
        orderIndex: const Value(1),
      ),
    );

    final List<ChapterRow> rows = await chapters.getByVolumeId(vid);

    expect(
      ChapterDedupGuard.findExisting(
        existing: rows,
        orderIndex: 1,
        title: '第一章',
      ),
      isNotNull,
      reason: '同序号必须命中',
    );
    expect(
      ChapterDedupGuard.findExisting(
        existing: rows,
        orderIndex: 2,
        title: '第一章',
      ),
      isNotNull,
      reason: '同标题（即使序号不同）也必须命中，防止重复创建',
    );
    expect(
      ChapterDedupGuard.findExisting(
        existing: rows,
        orderIndex: 2,
        title: '第二章',
      ),
      isNull,
    );
  });

  test('parseAcceptanceReport：容错解析 / 坏 JSON 返回 null', () {
    final TeamAcceptance?
    a = MultiAgentBookGenerationService.parseAcceptanceReport(
      '组长验收结果如下：\n```json\n'
      '{"paragraphs":[{"agent":1,"accepted":true},{"agent":2,"accepted":false,"problems":"偏题"}],'
      '"report":{"timeRange":"第一章当日","themeTask":"入门","gains":"G","safeguards":"S"},'
      '"updates":[{"target":"world","action":"update","name":"玄穹宗","field":"history","content":"x"}]}\n'
      '```\n请查阅。',
    );
    expect(a, isNotNull);
    expect(a!.verdicts, hasLength(2));
    expect(a.verdicts.last.accepted, isFalse);
    expect(a.verdicts.last.problems, '偏题');
    expect(a.timeRange, '第一章当日');
    expect(a.gainsLosses, 'G');
    expect(a.safeguards, 'S');
    expect(a.updateItems, hasLength(1));
    expect(a.allAccepted, isFalse);

    expect(
      MultiAgentBookGenerationService.parseAcceptanceReport('不是 JSON'),
      isNull,
      reason: '解析失败必须返回 null（调用方按原流程放行防回归）',
    );
  });

  test('normalize：并发语义 = 并行章节数（1-9999），编制强制 10', () {
    final MultiAgentBookConfig a = const MultiAgentBookConfig(
      bookTitle: '书',
      authorName: '作者',
      concurrency: 0,
      subAgentCount: 32,
    ).normalize().normalized;
    expect(a.concurrency, 1, reason: '下限 1（至少 1 个团队）');
    expect(a.subAgentCount, 10, reason: '固定编制：任何输入都强制 1 组长 + 9 写手');
    expect(a.writerCount, 9);

    final MultiAgentBookConfig b = const MultiAgentBookConfig(
      bookTitle: '书',
      authorName: '作者',
      concurrency: 10,
    ).normalize().normalized;
    expect(b.concurrency, 10, reason: '并发 10 = 10 个章节团队并行写 10 章');

    final MultiAgentBookConfig d = const MultiAgentBookConfig(
      bookTitle: '书',
      authorName: '作者',
      concurrency: 99999,
    ).normalize().normalized;
    expect(d.concurrency, 9999, reason: '上限 9999 个并行团队');
  });
}
