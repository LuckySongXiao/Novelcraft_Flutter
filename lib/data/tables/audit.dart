import 'package:drift/drift.dart';

/// 审计字段 mixin —— 对应 C# 的 [BaseEntity]。
///
/// 类型映射说明（C# → Dart/drift）：
///   Guid      → TEXT      （由 uuid 包生成字符串形式）
///   DateTime  → INTEGER   （drift 默认按毫秒时间戳存储）
///   byte[]    → INTEGER   （C# 的 `[Timestamp] byte[] Version` 在 SQLite 上本就不生效，
///                          这里直接降级为自增整数做乐观锁）
///   bool      → INTEGER   （0/1）
mixin AuditFields on Table {
  TextColumn get id => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  TextColumn get createdBy => text().nullable()();
  TextColumn get updatedBy => text().nullable()();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  TextColumn get deletedBy => text().nullable()();

  /// 乐观锁版本号。C# 侧为 EF 行版本的 `byte[] Version`，
  /// Dart 侧改为整数，由 Repository 层在更新时自增。
  IntColumn get version => integer().withDefault(const Constant(0))();
}
