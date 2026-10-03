// 写作档案服务测试：项目/分卷/章节三档 + 四段描述格式 + 元数据往返。
//
// 运行：flutter test test/writing_archive_service_test.dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:novelcraft/application/services/project_content_archive_service.dart';
import 'package:novelcraft/application/services/writing_archive_service.dart';
import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/project_repository.dart';
import 'package:novelcraft/data/storage/key_value_store.dart';

const Uuid _uuid = Uuid();

class _MemKv extends KeyValueStore {
  final Map<String, String> data = <String, String>{};

  @override
  Future<void> init() async {}

  @override
  Future<String?> readJson(String scope, String key) async =>
      data['$scope/$key'];

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

void main() {
  late AppDatabase db;
  late _MemKv kv;
  late ProjectContentArchiveService baseArchive;
  late WritingArchiveService svc;
  late String projectId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    kv = _MemKv();
    baseArchive = ProjectContentArchiveService(
      store: () async => kv,
      projects: ProjectRepository(db),
    );
    svc = WritingArchiveService(archive: baseArchive);
    projectId = _uuid.v4();
    await db.into(db.projects).insert(ProjectsCompanion.insert(
          id: projectId,
          name: '档案测试书',
          type: '东方玄幻',
        ));
  });

  tearDown(() async => db.close());

  test('三档档案写入：taskType 与 level 元数据正确', () async {
    await svc.write(
      level: ArchiveLevel.project,
      projectId: projectId,
      title: '档案测试书',
      content: '主线大纲正文',
      desc: const ArchiveDescription(
        timeRange: '2026-09-29 起',
        themeTask: '全书主线编制',
        gainsLosses: '大纲定稿',
        safeguards: '冲突以主线为准',
      ),
    );
    await svc.write(
      level: ArchiveLevel.volume,
      projectId: projectId,
      title: '第一卷',
      content: '第一卷大纲正文',
      volumeId: 'vol-1',
      desc: const ArchiveDescription(
        timeRange: '第一卷（共 10 章）',
        themeTask: '入门与试炼',
        gainsLosses: '分卷大纲落库',
        safeguards: '章节不得冲突卷末状态',
      ),
    );
    await svc.write(
      level: ArchiveLevel.chapter,
      projectId: projectId,
      title: '第一章',
      content: '正文……',
      volumeId: 'vol-1',
      chapterId: 'ch-1',
      desc: const ArchiveDescription(
        timeRange: '入门第一天',
        themeTask: '拜入玄穹宗',
        gainsLosses: '正文 3000 字定稿',
        safeguards: '注意师姐身份线',
      ),
    );

    final List<ProjectArchiveEntry> entries =
        await baseArchive.listEntries(projectId);
    expect(entries.length, 3);
    expect(
      entries.map((ProjectArchiveEntry e) => e.taskType).toSet(),
      <String>{'ArchiveProject', 'ArchiveVolume', 'ArchiveChapter'},
    );

    final ProjectArchiveEntry chapter = entries
        .firstWhere((ProjectArchiveEntry e) => e.taskType == 'ArchiveChapter');
    expect(chapter.metadata[ArchiveDescription.kLevel], 'chapter');
    expect(chapter.metadata['chapterId'], 'ch-1');
    expect(chapter.metadata['volumeId'], 'vol-1');
    // 四段描述必须出现在 content 首部（只读回看契约）
    expect(
      chapter.content,
      startsWith('时间范围：入门第一天\n主题任务：拜入玄穹宗\n'
          '得失总结：正文 3000 字定稿\n规避措施：注意师姐身份线'),
    );
  });

  test('手动删减 / 修改归档条目（按列表下标，新→旧）', () async {
    await baseArchive.writeCleanContent(
      projectId: projectId,
      taskType: 'GenerateChapterContent',
      content: '第一章正文',
      titleHint: '第一章',
    );
    await baseArchive.writeCleanContent(
      projectId: projectId,
      taskType: 'GenerateChapterContent',
      content: '第二章正文',
      titleHint: '第二章',
    );
    List<ProjectArchiveEntry> list = await baseArchive.listEntries(projectId);
    expect(list.length, 2);
    expect(list[0].title, '第二章', reason: '列表新→旧，下标 0 是最新一条');

    // —— 修改 ——
    final bool okUpdate = await baseArchive.updateEntry(
      projectId,
      0,
      title: '第二章（改）',
      content: '改写后的正文',
    );
    expect(okUpdate, isTrue);
    list = await baseArchive.listEntries(projectId);
    expect(list[0].title, '第二章（改）');
    expect(list[0].content, '改写后的正文');
    expect(list[1].title, '第一章', reason: '只改一条，另一条不受影响');

    // —— 删除 ——
    final bool okDelete = await baseArchive.deleteEntry(projectId, 1);
    expect(okDelete, isTrue);
    list = await baseArchive.listEntries(projectId);
    expect(list.length, 1);
    expect(list.single.title, '第二章（改）');

    // 越界 / 空 projectId 一律返回 false，且不抛异常
    expect(await baseArchive.deleteEntry(projectId, 5), isFalse);
    expect(await baseArchive.updateEntry('', 0, title: 'x'), isFalse);
  });

  test('ArchiveDescription.fromMetadata 往返 / format 缺省补破折号', () {
    const ArchiveDescription d = ArchiveDescription(
      timeRange: 'T',
      themeTask: '',
      gainsLosses: 'G',
      safeguards: 'S',
    );
    final ArchiveDescription back =
        ArchiveDescription.fromMetadata(d.toMetadata());
    expect(back.timeRange, 'T');
    expect(back.gainsLosses, 'G');
    expect(back.format(), contains('主题任务：—'), reason: '空字段必须补 —');
  });

  test('deterministicChapterDesc：确定性四段描述', () {
    final ArchiveDescription d = WritingArchiveService.deterministicChapterDesc(
      chapterTitle: '第一章',
      wordCount: 3000,
      outlineOrSummary: '主角初入宗门，结识师姐。\n第二行',
      at: DateTime(2026, 9, 29),
    );
    expect(d.timeRange, contains('2026-09-29'));
    expect(d.themeTask, '主角初入宗门，结识师姐。');
    expect(d.gainsLosses, contains('3000'));
    expect(d.safeguards, isNotEmpty);
  });

  test('空 projectId 跳过（noProject），不落 KV', () async {
    final ProjectArchiveWriteResult r = await svc.write(
      level: ArchiveLevel.chapter,
      projectId: '',
      title: 'x',
      content: 'y',
      desc: const ArchiveDescription(
        timeRange: 'a', themeTask: 'b', gainsLosses: 'c', safeguards: 'd',
      ),
    );
    expect(r.isSkipped, isTrue);
    expect(r.code, 'noProject');
  });
}
