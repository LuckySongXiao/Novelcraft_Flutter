import 'package:drift/drift.dart';

import 'audit.dart';

/// 书籍项目 —— 对应 Core/Entities/Project.cs
///
/// C# 原实体有 13 个数据字段与 13 个导航集合；
/// drift 不做导航属性，子集合由 DAO 层按需装配。
@DataClassName('ProjectRow')
class Projects extends Table with AuditFields {
  TextColumn get name => text().withLength(min: 1, max: 200)();
  TextColumn get description => text().nullable().withLength(max: 1000)();
  TextColumn get type => text().withLength(min: 1, max: 50)();
  TextColumn get status =>
      text().withLength(min: 1, max: 50).withDefault(const Constant('Planning'))();
  TextColumn get coverImagePath => text().nullable().withLength(max: 500)();

  /// 项目设置（JSON 字符串）
  TextColumn get settings => text().nullable()();

  /// 项目统计（JSON 字符串）
  TextColumn get statistics => text().nullable()();

  TextColumn get tags => text().nullable().withLength(max: 500)();
  IntColumn get priority => integer().withDefault(const Constant(0))();

  /// 项目进度 0-100
  IntColumn get progress => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastAccessedAt => dateTime().nullable()();
  TextColumn get projectPath => text().nullable().withLength(max: 1000)();
  TextColumn get notes => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 卷宗 —— 对应 Core/Entities/Volume.cs
///
/// 注意：C# 的 `WordCount` 是 `ActualWordCount` 的同义别名（getter/setter 转发），
/// Dart 不支持成员别名，这里只保留 `actualWordCount`，
/// 业务层需要 WordCount 语义时统一使用同一字段。
@DataClassName('VolumeRow')
class Volumes extends Table with AuditFields {
  TextColumn get title => text().withLength(min: 1, max: 200)();
  TextColumn get description => text().nullable().withLength(max: 1000)();

  /// 卷宗序号（C# 字段名为 `Order`，Dart 侧改名避免与 SQL ORDER 冲突）
  IntColumn get orderIndex => integer().withDefault(const Constant(0))();
  TextColumn get status =>
      text().withLength(min: 1, max: 50).withDefault(const Constant('Planning'))();

  /// 所属项目，删除项目时级联删除卷宗
  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();

  TextColumn get type => text().nullable().withLength(max: 50)();
  TextColumn get tags => text().nullable().withLength(max: 500)();
  TextColumn get notes => text().nullable()();
  IntColumn get estimatedWordCount => integer().nullable()();
  IntColumn get actualWordCount => integer().withDefault(const Constant(0))();

  /// 完成进度。C# 为 decimal，Dart/SQLite 用 REAL
  RealColumn get progress => real().withDefault(const Constant(0.0))();
  DateTimeColumn get startDate => dateTime().nullable()();
  DateTimeColumn get endDate => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 章节 —— 对应 Core/Entities/Chapter.cs
///
/// 与 C# 原实体两处差异：
/// 1. `Order` → `orderIndex`（同上）
/// 2. **新增 `projectId` 冗余字段**：C# 实体没有 ProjectId，按项目查章节必须
///    经 Volume 反查做 JOIN。这里补上冗余字段规避 JOIN，
///    写入时由 Repository 层从所属卷宗同步。
@DataClassName('ChapterRow')
class Chapters extends Table with AuditFields {
  TextColumn get title => text().withLength(min: 1, max: 200)();

  /// 正文字段可能是大文本，Web 端走 sqlite3 wasm 时需注意内存占用
  TextColumn get content => text().nullable()();
  TextColumn get summary => text().nullable().withLength(max: 1000)();
  IntColumn get orderIndex => integer().withDefault(const Constant(0))();
  TextColumn get status =>
      text().withLength(min: 1, max: 50).withDefault(const Constant('Draft'))();

  /// 所属卷宗，删除卷宗级联删除章节
  TextColumn get volumeId =>
      text().references(Volumes, #id, onDelete: KeyAction.cascade)();

  /// 冗余字段：所属项目的直接引用（C# 版本缺失，需经 Volume 反查）
  TextColumn get projectId => text().nullable()();

  TextColumn get type => text().nullable().withLength(max: 50)();
  TextColumn get tags => text().nullable().withLength(max: 500)();
  TextColumn get notes => text().nullable()();
  IntColumn get wordCount => integer().withDefault(const Constant(0))();

  /// 阅读时长（分钟）
  IntColumn get readingTime => integer().nullable()();
  IntColumn get difficultyLevel => integer().nullable()();
  IntColumn get importance => integer().nullable()();
  DateTimeColumn get publishedAt => dateTime().nullable()();
  DateTimeColumn get lastEditedAt => dateTime().nullable()();

  /// 业务版本号（C# 为 `VersionNumber`，与基类 Version 概念重复，此处保留）
  IntColumn get versionNumber => integer().withDefault(const Constant(1))();

  @override
  Set<Column> get primaryKey => {id};
}
