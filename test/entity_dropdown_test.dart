import 'package:flutter_test/flutter_test.dart';

import 'package:novelcraft/core/enums/pseudo_enums.dart';
import 'package:novelcraft/ui/pages/entity_configs.dart' as cfgs;
import 'package:novelcraft/ui/pages/entity_page.dart';
import 'package:novelcraft/ui/pages/system_configs.dart';
import 'package:novelcraft/ui/pages/world_system_page.dart';

/// 下拉框崩溃回归测试（对应 PITFALLS §28）
///
/// 背景：`DropdownButton` 要求 items 里**恰好一个** item 的 value 等于当前 value，
/// 否则抛：
///   There should be exactly one item with [DropdownButton]'s value: X.
///   Either zero or 2 or more [DropdownMenuItem]s were detected with the same value
///
/// 触发场景：库里存的是**表列 default**（如 Volumes.status='Planning'、
/// Chapters.status='Draft'、Characters.status='Active'），而实体配置的下拉候选表
/// 里根本没有这个值 → 打开详情页直接崩。
///
/// 运行：`flutter test test/entity_dropdown_test.dart`
void main() {
  /// 各实体「下拉字段 → 该列在 lib/data/tables/**.dart 里的 withDefault 常量」
  ///
  /// ⚠ 新增/修改表列默认值时必须同步这张表 —— 它就是防回归的锚点。
  final canonicalDefaults = <String, (EntityPageConfig, String, String)>{
    'Volumes.status': (cfgs.volumeEntityConfig, 'status', 'Planning'),
    'Chapters.status': (cfgs.chapterEntityConfig, 'status', 'Draft'),
    'Characters.status': (cfgs.characterEntityConfig, 'status', 'Active'),
    'Plots.status': (cfgs.plotEntityConfig, 'status', '规划中'),
    'Races.status': (cfgs.raceEntityConfig, 'status', '稳定'),
    'Resources.status': (cfgs.resourceEntityConfig, 'status', '活跃'),
    'Resources.rarity': (cfgs.resourceEntityConfig, 'rarity', '普通'),
    'SecretRealms.status': (cfgs.secretRealmEntityConfig, 'status', '隐藏'),
    'CultivationSystems.status':
        (cfgs.cultivationSystemEntityConfig, 'status', 'Active'),
    'PoliticalSystems.status':
        (cfgs.politicalSystemEntityConfig, 'status', 'Active'),
    'CurrencySystems.status':
        (cfgs.currencySystemEntityConfig, 'status', 'Active'),
    'RelationshipNetworks.status':
        (cfgs.relationshipNetworkEntityConfig, 'status', '活跃'),
    'CharacterRelationships.status':
        (cfgs.characterRelationshipEntityConfig, 'status', 'Active'),
    'FactionRelationships.status':
        (cfgs.factionRelationshipEntityConfig, 'status', 'Active'),
    'RaceRelationships.status':
        (cfgs.raceRelationshipEntityConfig, 'status', '稳定'),
  };

  group('表列默认值必须命中下拉候选集（否则打开详情即崩）', () {
    canonicalDefaults.forEach((label, spec) {
      final (config, fieldKey, dbDefault) = spec;
      test('$label：默认值 "$dbDefault" 在候选表内且唯一', () {
        final def = config.fields.firstWhere(
          (f) => f.key == fieldKey,
          orElse: () => throw StateError('$label 找不到字段 $fieldKey'),
        );
        expect(def.type, SystemFieldType.select,
            reason: '$label 必须是 select 字段');

        final values =
            def.optionEntries(null).map((o) => o.value).toList();
        expect(values.where((v) => v == dbDefault).length, 1,
            reason: '$label：候选表里 "$dbDefault" 出现 '
                '${values.where((v) => v == dbDefault).length} 次（必须恰好 1 次）');
      });
    });
  });

  group('optionEntries 的健壮性', () {
    test('任意历史脏值都会被原样补进候选集（不再断言崩溃）', () {
      final def = cfgs.volumeEntityConfig.fields
          .firstWhere((f) => f.key == 'status');
      const dirty = 'LegacyStatus_2024';
      final entries = def.optionEntries(dirty);
      expect(entries.where((o) => o.value == dirty).length, 1,
          reason: '当前值应被补进候选集且只出现一次');
    });

    test('补进来的脏值在渲染时不会与已有项重名', () {
      final def =
          cfgs.chapterEntityConfig.fields.firstWhere((f) => f.key == 'status');
      // 已经存在的规范值不应被重复追加
      final entries = def.optionEntries('Draft');
      expect(entries.where((o) => o.value == 'Draft').length, 1);
    });

    test('空串/空白不会产生多余选项', () {
      final def =
          cfgs.characterEntityConfig.fields.firstWhere((f) => f.key == 'status');
      final base = def.optionEntries(null).length;
      expect(def.optionEntries('').length, base);
      expect(def.optionEntries('   ').length, base);
    });

    test('全部实体配置的 select 字段：候选值唯一', () {
      for (final config in cfgs.entityConfigByTarget.values) {
        for (final f in config.fields) {
          if (f.type != SystemFieldType.select) continue;
          final values = f.optionEntries(null).map((o) => o.value).toList();
          expect(values.toSet().length, values.length,
              reason: '${config.titleEn}.${f.key} 候选值有重复');
        }
      }
    });

    test('全部 JSON 体系页的 select 字段：候选值唯一', () {
      for (final config in wSystemConfigs) {
        for (final f in config.fields) {
          if (f.type != SystemFieldType.select) continue;
          final values = f.optionEntries(null).map((o) => o.value).toList();
          expect(values.toSet().length, values.length,
              reason: '${config.titleEn}.${f.key} 候选值有重复');
        }
      }
    });
  });

  group('值 / 标签分离（切语言不污染库里的值）', () {
    test('Volumes.status 的入库值恒为英文枚举，标签随语言变', () {
      final def =
          cfgs.volumeEntityConfig.fields.firstWhere((f) => f.key == 'status');
      final entries = def.optionEntries('Planning');
      final planning = entries.firstWhere((o) => o.value == 'Planning');
      expect(planning.value, 'Planning', reason: '入库值必须与表列默认值同源');
      expect(planning.labelFor(true), 'Planning');
      expect(planning.labelFor(false), '规划中');
    });

    test('JSON 体系页：EN 模式只换标签，不改入库值', () {
      // 功法分类的候选值为中文原文，optionsEn 仅作显示
      final cfg = wSystemConfigs.firstWhere((c) => c.scope == 'techniques');
      final def = cfg.fields.firstWhere((f) => f.key == 'category');
      final entries = def.optionEntries(null);
      expect(entries.first.value, '攻击类', reason: '入库值应保持中文原文');
      expect(entries.first.labelFor(false), '攻击类');
      expect(entries.first.labelFor(true), 'Offensive');
    });
  });

  group('列表副标题展示', () {
    test('displayLabel 把枚举原始值翻成标签，非 select 字段原样返回', () {
      final statusDef =
          cfgs.volumeEntityConfig.fields.firstWhere((f) => f.key == 'status');
      expect(statusDef.displayLabel('Planning', false), '规划中');
      expect(statusDef.displayLabel('Planning', true), 'Planning');

      final titleDef = cfgs.volumeEntityConfig.fields
          .firstWhere((f) => f.key == 'title');
      expect(titleDef.displayLabel('第一卷 · 青云少年行', true),
          '第一卷 · 青云少年行');
    });

    test('未收录的英文标识符会被美化成可读文案', () {
      expect(SystemFieldDef.prettyIdentifier('commodity_standard'),
          'Commodity Standard');
      expect(SystemFieldDef.prettyIdentifier('currency_material'),
          'Currency Material');
      // 已经是普通词的不要瞎改
      expect(SystemFieldDef.prettyIdentifier('Planning'), 'Planning');
      // 中文/带符号的不要动
      expect(SystemFieldDef.prettyIdentifier('主线'), '主线');
    });
  });

  group('词典自检', () {
    test('PseudoEnums 所有条目都提供英文标签', () {
      final lists = <String, List<OptionEntry>>{
        'plotTypes': PseudoEnums.plotTypes,
        'plotStatuses': PseudoEnums.plotStatuses,
        'plotPriorities': PseudoEnums.plotPriorities,
        'raceTypes': PseudoEnums.raceTypes,
        'raceStatuses': PseudoEnums.raceStatuses,
        'secretRealmTypes': PseudoEnums.secretRealmTypes,
        'secretRealmStatuses': PseudoEnums.secretRealmStatuses,
        'resourceTypes': PseudoEnums.resourceTypes,
        'resourceRarities': PseudoEnums.resourceRarities,
        'resourceRegenerationSpeeds': PseudoEnums.resourceRegenerationSpeeds,
        'resourceStatuses': PseudoEnums.resourceStatuses,
        'networkTypes': PseudoEnums.networkTypes,
        'networkStatuses': PseudoEnums.networkStatuses,
        'raceRelationshipTypes': PseudoEnums.raceRelationshipTypes,
        'raceRelationshipStatuses': PseudoEnums.raceRelationshipStatuses,
        'monetarySystems': PseudoEnums.monetarySystems,
        'characterEventTypes': PseudoEnums.characterEventTypes,
        'timelineCategories': PseudoEnums.timelineCategories,
        'timelineImportances': PseudoEnums.timelineImportances,
        'timelineStatuses': PseudoEnums.timelineStatuses,
        'projectLikeStatuses': PseudoEnums.projectLikeStatuses,
        'chapterStatuses': PseudoEnums.chapterStatuses,
        'activeStatuses': PseudoEnums.activeStatuses,
      };
      lists.forEach((name, entries) {
        for (final e in entries) {
          expect(e.value.trim(), isNotEmpty, reason: '$name 有空的 value');
          expect(e.labelEn, isNotNull, reason: '$name 的 "${e.value}" 缺英文标签');
          expect(e.labelEn!.trim(), isNotEmpty,
              reason: '$name 的 "${e.value}" 英文标签为空');
        }
        final values = entries.map((e) => e.value).toList();
        expect(values.toSet().length, values.length,
            reason: '$name 的 value 有重复');
      });
    });
  });
}
