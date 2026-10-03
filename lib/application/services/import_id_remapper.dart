/// JSON 备份恢复时为所有实体生成新主键，并同步改写实体间的外键。
///
/// 导入器不能复用备份中的 UUID：同一备份重复导入到已有项目会主键冲突。
/// 先建立完整旧→新映射，再创建任何记录，才能保证父子关系和关系表不悬空。
library;

import 'package:uuid/uuid.dart';

const List<String> importedReferenceKeys = <String>[
  'volumeId',
  'characterId',
  'sourceCharacterId',
  'targetCharacterId',
  'sourceFactionId',
  'targetFactionId',
  'sourceRaceId',
  'targetRaceId',
  'cultivationSystemId',
  'politicalSystemId',
];

class ImportIdRemap {
  ImportIdRemap._(this.idMap, this.recordsByEntity);

  final Map<String, String> idMap;
  final Map<String, List<Map<String, dynamic>>> recordsByEntity;

  static ImportIdRemap build(Map<String, dynamic> entities) {
    final Map<String, String> ids = <String, String>{};
    final Map<String, List<Map<String, dynamic>>> normalized =
        <String, List<Map<String, dynamic>>>{};
    final Uuid uuid = Uuid();
    for (final MapEntry<String, dynamic> entry in entities.entries) {
      if (entry.value is! List) continue;
      final List<Map<String, dynamic>> records = <Map<String, dynamic>>[];
      for (final dynamic raw in entry.value as List<dynamic>) {
        if (raw is! Map) continue;
        final Map<String, dynamic> copy = <String, dynamic>{
          for (final MapEntry<dynamic, dynamic> field
              in raw.entries) '${field.key}': field.value,
        };
        final String? oldId = _string(copy['id']);
        if (oldId != null) ids.putIfAbsent(oldId, uuid.v4);
        records.add(copy);
      }
      normalized[entry.key] = records;
    }
    return ImportIdRemap._(ids, normalized);
  }

  List<Map<String, dynamic>> records(String entityName) =>
      recordsByEntity[entityName] ?? const <Map<String, dynamic>>[];

  Map<String, dynamic> remap(Map<String, dynamic> source) {
    final Map<String, dynamic> result = Map<String, dynamic>.of(source);
    final String? oldId = _string(result['id']);
    if (oldId != null) result['id'] = idMap[oldId] ?? oldId;
    for (final String key in importedReferenceKeys) {
      final String? reference = _string(result[key]);
      if (reference != null && idMap.containsKey(reference)) {
        result[key] = idMap[reference];
      }
    }
    return result;
  }

  static String? _string(dynamic value) {
    if (value is! String) return null;
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
