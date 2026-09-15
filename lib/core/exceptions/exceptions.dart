/// 自定义异常体系 —— 对应 Core/Exceptions/NovelManagementException.cs
///
/// ⚠ 原 C# 实现里这套异常**几乎没有被上层使用** —— 21 个应用服务全部采用
/// `try { ... } catch (Exception ex) { _logger.LogError(...); throw; }` 模板，
/// 异常既不被转换也不被包装。因此 Dart 侧保留类结构（便于逐步引入），
/// 但服务层不再写无信息增益的 try/catch 模板，统一由 UI 状态管理层捕获。
library;

/// 错误码枚举。C# 侧是硬编码字符串常量，这里改为类型安全枚举。
enum NmErrorCode {
  entityNotFound('ENTITY_NOT_FOUND'),
  businessRuleViolation('BUSINESS_RULE_VIOLATION'),
  validationError('VALIDATION_ERROR');

  const NmErrorCode(this.code);

  /// 与 C# 保持一致的字符串码，便于日志对照
  final String code;
}

/// 应用根异常
class NovelManagementException implements Exception {
  NovelManagementException(
    this.message, {
    this.errorCode,
    this.inner,
  });

  final String message;

  /// C# 侧为可空字符串，这里改为枚举（无错误码时为 null）
  final NmErrorCode? errorCode;

  /// C# 的 InnerException
  final Object? inner;

  @override
  String toString() => errorCode == null
      ? 'NovelManagementException: $message'
      : 'NovelManagementException(${errorCode!.code}): $message';
}

/// 实体未找到 —— 对应 EntityNotFoundException
///
/// 注意：C# 版本的消息是英文（`$"{entityName} with id '{entityId}' was not found."`），
/// 尽管项目整体是中文。这里改为中文，UI 层可直接展示。
class EntityNotFoundException extends NovelManagementException {
  EntityNotFoundException(this.entityName, this.entityId)
      : super(
          '未找到 $entityName（标识：$entityId）',
          errorCode: NmErrorCode.entityNotFound,
        );

  final String entityName;
  final Object entityId;
}

/// 业务规则冲突 —— 对应 BusinessRuleViolationException
class BusinessRuleViolationException extends NovelManagementException {
  BusinessRuleViolationException(super.message)
      : super(errorCode: NmErrorCode.businessRuleViolation);
}

/// 数据校验失败 —— 对应 ValidationException
///
/// C# 侧用 `IReadOnlyDictionary<string, string[]>` 承载「字段 → 错误列表」
class ValidationException extends NovelManagementException {
  ValidationException(this.errors)
      : super(
          '存在一个或多个校验错误',
          errorCode: NmErrorCode.validationError,
        );

  final Map<String, List<String>> errors;

  /// 是否有任何校验错误
  bool get hasErrors => errors.isNotEmpty;

  /// 取第一个错误（用于 SnackBar 提示）
  String? get firstError {
    for (final entry in errors.entries) {
      if (entry.value.isNotEmpty) return entry.value.first;
    }
    return null;
  }
}
