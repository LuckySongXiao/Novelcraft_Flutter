// 项目重名解决回归测试。
//
// 背景（用户截图报错）：多智能体协同写书在第 2 步「建项目」时报
//   SqliteException(2067): UNIQUE constraint failed: projects.name
// 根因：`idx_projects_name` 是**全表**唯一索引（不是 WHERE is_deleted = 0 的
// 部分索引），而旧实现只用 `getByName()`（带 notDeleted 过滤）查重 ——
// **软删除的同名项目查不到，插入时却撞唯一约束**。
//
// 运行：flutter test test/project_name_resolution_test.dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novelcraft/data/database.dart';
import 'package:novelcraft/data/repositories/project_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late ProjectRepository repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = ProjectRepository(db);
  });

  tearDown(() async => db.close());

  ProjectsCompanion project(String id, String name) =>
      ProjectsCompanion.insert(id: id, name: name, type: 'Xianxia');

  test('名字空闲：直接插入，不改名不复活', () async {
    final ProjectNameResolution r =
        await repo.createResolvingName(project('p1', '暗夜袭营'));
    expect(r.actualName, '暗夜袭营');
    expect(r.renamed, isFalse);
    expect(r.revived, isFalse);
    expect(r.adjusted, isFalse);
    expect(await repo.getAll(), hasLength(1));
  });

  test('存在活跃同名项目 → 追加序号后缀，不动原项目（不再抛 2067）', () async {
    await repo.createResolvingName(project('p1', '暗夜袭营'));
    final ProjectNameResolution r =
        await repo.createResolvingName(project('p2', '暗夜袭营'));

    expect(r.renamed, isTrue);
    expect(r.revived, isFalse);
    expect(r.actualName, '暗夜袭营 (2)');
    expect(r.row.id, 'p2');
    // 原项目保持原名
    expect((await repo.getById('p1'))!.name, '暗夜袭营');
    expect((await repo.getAll()), hasLength(2));

    // 第三次继续递增
    final ProjectNameResolution r3 =
        await repo.createResolvingName(project('p3', '暗夜袭营'));
    expect(r3.actualName, '暗夜袭营 (3)');
  });

  test('存在软删除同名项目 → 复活复用原行（这是截图报错的直接场景）', () async {
    await repo.createResolvingName(project('p1', '暗夜袭营'));
    await repo.delete('p1');
    expect(await repo.getAll(), isEmpty, reason: '已删除，列表看不到');

    // 关键：软删除行仍占用名字 —— 旧实现的 getByName 查不到它
    expect(await repo.getByName('暗夜袭营'), isNull);
    expect(await repo.isNameTaken('暗夜袭营'), isTrue,
        reason: '唯一索引是全表的，软删除行也算占用');

    final ProjectNameResolution r =
        await repo.createResolvingName(project('p2', '暗夜袭营'));
    expect(r.revived, isTrue, reason: '应复活而不是新建 (2)');
    expect(r.renamed, isFalse);
    expect(r.actualName, '暗夜袭营');
    expect(r.row.id, 'p1', reason: '复用被软删除的原行 id');
    expect(r.row.isDeleted, isFalse);
    expect(r.row.deletedAt, isNull);
    expect(await repo.getAll(), hasLength(1));
  });

  test('resolveAvailableName 递增并可被 isNameTaken 校验', () async {
    expect(await repo.resolveAvailableName('书名'), '书名');
    await repo.createResolvingName(project('p1', '书名'));
    final String next = await repo.resolveAvailableName('书名');
    expect(next, '书名 (2)');
    expect(await repo.isNameTaken(next), isFalse);
  });

  test('isUniqueViolation 识别 sqlite 唯一约束异常', () {
    expect(
      ProjectRepository.isUniqueViolation(
        Exception('SqliteException(2067): UNIQUE constraint failed: '
            'projects.name, constraint failed (code 2067)'),
      ),
      isTrue,
    );
    expect(
      ProjectRepository.isUniqueViolation(Exception('disk I/O error')),
      isFalse,
    );
  });
}
