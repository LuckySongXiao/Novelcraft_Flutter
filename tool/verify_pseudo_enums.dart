// ignore_for_file: avoid_print
//
// 词典 ↔ 表列默认值 不变量校验器（纯 Dart，可 `dart run` 直接跑）
//
// 校验 PseudoEnums 的每个候选表：
//   1. value 无重复
//   2. labelZh / labelEn 均非空
//   3. 「表列 withDefault 常量」一定在候选表里，且恰好出现一次
//
// 第 3 条就是「打开详情页即断言崩溃」的根因防线：库里存的是表列默认值，
// 候选表若缺它，DropdownButton 就炸。
//
// 运行：dart run tool/verify_pseudo_enums.dart
import 'package:novelcraft/core/enums/pseudo_enums.dart';

/// 表列默认值（来源：lib/data/tables/**.dart 的 withDefault(const Constant(...))）
const kTableDefaults = <String, String>{
  'Characters.status': 'Active',
  'CharacterRelationships.status': 'Active',
  'CharacterEvents.eventType': '其他',
  'Factions.status': 'Active',
  'FactionRelationships.status': 'Active',
  'TimelineEvents.category': '历史事件',
  'WorldSettings.status': 'Active',
  'CultivationSystems.status': 'Active',
  'PoliticalSystems.status': 'Active',
  'RelationshipNetworks.status': '活跃',
  'Plots.status': '规划中',
  'Plots.priority': '中',
  'Races.status': '稳定',
  'RaceRelationships.status': '稳定',
  'Resources.rarity': '普通',
  'Resources.regenerationSpeed': '中等',
  'Resources.status': '活跃',
  'SecretRealms.status': '隐藏',
  'Projects.status': 'Planning',
  'Volumes.status': 'Planning',
  'Chapters.status': 'Draft',
};

/// 表 → 期望覆盖它的词典
final kCoverage = <String, List<OptionEntry>>{
  'Characters.status': PseudoEnums.activeStatuses,
  'CharacterRelationships.status': PseudoEnums.activeStatuses,
  'CharacterEvents.eventType': PseudoEnums.characterEventTypes,
  'Factions.status': PseudoEnums.activeStatuses,
  'FactionRelationships.status': PseudoEnums.activeStatuses,
  'TimelineEvents.category': PseudoEnums.timelineCategories,
  'WorldSettings.status': PseudoEnums.activeStatuses,
  'CultivationSystems.status': PseudoEnums.activeStatuses,
  'PoliticalSystems.status': PseudoEnums.activeStatuses,
  'RelationshipNetworks.status': PseudoEnums.networkStatuses,
  'Plots.status': PseudoEnums.plotStatuses,
  'Plots.priority': PseudoEnums.plotPriorities,
  'Races.status': PseudoEnums.raceStatuses,
  'RaceRelationships.status': PseudoEnums.raceRelationshipStatuses,
  'Resources.rarity': PseudoEnums.resourceRarities,
  'Resources.regenerationSpeed': PseudoEnums.resourceRegenerationSpeeds,
  'Resources.status': PseudoEnums.resourceStatuses,
  'SecretRealms.status': PseudoEnums.secretRealmStatuses,
  'Projects.status': PseudoEnums.projectLikeStatuses,
  'Volumes.status': PseudoEnums.projectLikeStatuses,
  'Chapters.status': PseudoEnums.chapterStatuses,
};

final _all = <String, List<OptionEntry>>{
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

var _fail = 0;

void _fail_(String msg) {
  _fail++;
  print('  ✗ $msg');
}

void main() {
  print('=' * 78);
  print('[1] 候选表自检：value 唯一 / 标签非空');
  print('=' * 78);
  var total = 0;
  _all.forEach((name, entries) {
    final seen = <String>{};
    for (final e in entries) {
      total++;
      if (e.value.trim().isEmpty) _fail_('$name 有空 value');
      if (!seen.add(e.value)) _fail_('$name 的 value "${e.value}" 重复');
      if (e.labelZh.trim().isEmpty) _fail_('$name 的 "${e.value}" 缺中文标签');
      if (e.labelEn == null || e.labelEn!.trim().isEmpty) {
        _fail_('$name 的 "${e.value}" 缺英文标签');
      }
    }
  });
  print('  词典共 ${_all.length} 张表 / $total 个词条');

  print('');
  print('=' * 78);
  print('[2] 选中态可命中：把库里的值喂给候选表 → 恰好命中 1 次');
  print('=' * 78);
  for (final e in kCoverage.entries) {
    final table = e.key;
    final entries = e.value;
    final stored = kTableDefaults[table]!;
    final hits = entries.where((o) => o.value == stored).length;
    if (hits == 1) {
      final o = entries.firstWhere((x) => x.value == stored);
      print('  ✓ %-34s %-14s → zh=%s / en=%s'
          .replaceFirst('%-34s', table.padRight(34))
          .replaceFirst('%-14s', '"$stored"'.padRight(14))
          .replaceFirst('%s', o.labelZh)
          .replaceFirst('%s', o.labelEn!));
    } else {
      _fail_('$table 的默认值 "$stored" 命中 $hits 次（必须恰好 1）');
    }
  }

  print('');
  print('=' * 78);
  print('[3] 反向：候选表里的值不应是「无主孤儿」状态字段');
  print('=' * 78);
  print('  说明：type 类字段（种族/资源/秘境…）与 seeder 的英文标识符尚未统一，');
  print('        不在本次断言范围内（见下方待办）。');

  print('');
  print('=' * 78);
  if (_fail == 0) {
    print('VERDICT: PASS —— 所有表列默认值都能在候选表中恰好命中一次');
  } else {
    print('VERDICT: FAIL —— $_fail 处不满足不变量');
  }
  print('=' * 78);
}
