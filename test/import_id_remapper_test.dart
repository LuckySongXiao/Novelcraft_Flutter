import 'package:flutter_test/flutter_test.dart';
import 'package:novelcraft/application/services/import_id_remapper.dart';

void main() {
  test('为所有记录生成新 ID，并改写章节和关系外键', () {
    final ImportIdRemap remap = ImportIdRemap.build(<String, dynamic>{
      'volumeManagement': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'vol-old', 'title': '第一卷'},
      ],
      'chapterManagement': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'ch-old',
          'volumeId': 'vol-old',
          'title': '第一章',
        },
      ],
      'characterManagement': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'a-old', 'name': '甲'},
        <String, dynamic>{'id': 'b-old', 'name': '乙'},
      ],
      'characterRelationshipManagement': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'rel-old',
          'sourceCharacterId': 'a-old',
          'targetCharacterId': 'b-old',
        },
      ],
    });
    final Map<String, dynamic> chapter = remap.remap(remap.records('chapterManagement').single);
    final Map<String, dynamic> relationship = remap.remap(
      remap.records('characterRelationshipManagement').single,
    );
    expect(chapter['id'], isNot('ch-old'));
    expect(chapter['volumeId'], remap.remap(remap.records('volumeManagement').single)['id']);
    expect(relationship['id'], isNot('rel-old'));
    expect(relationship['sourceCharacterId'], remap.remap(remap.records('characterManagement').first)['id']);
    expect(relationship['targetCharacterId'], remap.remap(remap.records('characterManagement').last)['id']);
  });

  test('没有 id 的外部引用保持原值，避免破坏未导出的记录', () {
    final ImportIdRemap remap = ImportIdRemap.build(<String, dynamic>{
      'chapterManagement': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'ch-old', 'volumeId': 'volume-outside-backup'},
      ],
    });
    final Map<String, dynamic> result = remap.remap(remap.records('chapterManagement').single);
    expect(result['volumeId'], 'volume-outside-backup');
  });
}
