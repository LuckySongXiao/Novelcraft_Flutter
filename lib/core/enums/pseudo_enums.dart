/// 「字符串伪枚举」选项词典
///
/// ⚠ 这是本项目最重要的一处隐性知识：C# 实体里所有 Type / Status / Priority /
/// Rarity 等字段**全部用 string 存储**，候选值只存在于源码注释与默认值里，
/// 中英文混用。UI 的下拉框、筛选器、以及 AI 生成内容时的取值都必须依赖这份词典，
/// 否则极易出现「UI 显示英文、库里存中文」的不一致。
///
/// 每个词条给出：值（写入数据库的原文）+ 中文标签 + 英文标签。
///
/// ⚠ 不变量（**改动前务必核对**）：`value` 必须与 `lib/data/tables/**.dart` 里
/// 该列的 `withDefault(const Constant('...'))` 严格一致 —— 下拉框的 value 命中不了
/// 候选集时 Flutter 的 `DropdownButton` 会直接断言崩溃（详见 PITFALLS §28）。
library;

/// 下拉选项条目：值 + 中英标签
class OptionEntry {
  const OptionEntry(this.value, this.labelZh, [this.labelEn]);

  /// 写入数据库的原始字符串（**与表列默认值同源**）
  final String value;

  /// 界面显示用的中文标签
  final String labelZh;

  /// 界面显示用的英文标签；为空时回落中文
  final String? labelEn;

  String labelFor(bool isEnglish) =>
      (isEnglish && labelEn != null && labelEn!.isNotEmpty) ? labelEn! : labelZh;

  @override
  String toString() => labelZh;
}

/// 全部伪枚举选项，按实体字段归类
class PseudoEnums {
  // ---------- 剧情 Plot ----------
  static const plotTypes = [
    OptionEntry('主线', '主线', 'Main Plot'),
    OptionEntry('支线', '支线', 'Subplot'),
    OptionEntry('暗线', '暗线', 'Hidden Thread'),
    OptionEntry('伏笔', '伏笔', 'Foreshadowing'),
  ];

  /// Plots.status 表列默认值 = '规划中'
  static const plotStatuses = [
    OptionEntry('规划中', '规划中', 'Planning'),
    OptionEntry('进行中', '进行中', 'In Progress'),
    OptionEntry('已完成', '已完成', 'Completed'),
    OptionEntry('暂停', '暂停', 'Paused'),
  ];

  /// Plots.priority 表列默认值 = '中'
  static const plotPriorities = [
    OptionEntry('高', '高', 'High'),
    OptionEntry('中', '中', 'Medium'),
    OptionEntry('低', '低', 'Low'),
  ];

  // ---------- 种族 Race ----------
  static const raceTypes = [
    OptionEntry('人类', '人类', 'Human'),
    OptionEntry('精灵', '精灵', 'Elf'),
    OptionEntry('魔法', '魔法', 'Magic'),
    OptionEntry('兽族', '兽族', 'Beastkin'),
    OptionEntry('元素', '元素', 'Elemental'),
    OptionEntry('不死', '不死', 'Undead'),
    OptionEntry('修罗', '修罗', 'Asura'),
    OptionEntry('灵异', '灵异', 'Spirit'),
    OptionEntry('神族', '神族', 'Divine'),
  ];

  /// Races.status 表列默认值 = '稳定'
  static const raceStatuses = [
    OptionEntry('繁荣', '繁荣', 'Flourishing'),
    OptionEntry('稳定', '稳定', 'Stable'),
    OptionEntry('衰落', '衰落', 'Declining'),
    OptionEntry('濒危', '濒危', 'Endangered'),
    OptionEntry('灭绝', '灭绝', 'Extinct'),
  ];

  // ---------- 秘境 SecretRealm ----------
  static const secretRealmTypes = [
    OptionEntry('地下城', '地下城', 'Dungeon'),
    OptionEntry('豢兽乐园', '豢兽乐园', 'Beast Sanctuary'),
    OptionEntry('祭天法坛', '祭天法坛', 'Heaven Altar'),
    OptionEntry('野兽森林', '野兽森林', 'Wild Beast Forest'),
    OptionEntry('海妖诞生地', '海妖诞生地', 'Siren Birthplace'),
    OptionEntry('天庭碎片', '天庭碎片', 'Heavenly Fragment'),
    OptionEntry('佛陀道场', '佛陀道场', 'Buddha Dojo'),
    OptionEntry('菩萨道场', '菩萨道场', 'Bodhisattva Dojo'),
    OptionEntry('小酆都', '小酆都', 'Lesser Fengdu'),
  ];

  /// SecretRealms.status 表列默认值 = '隐藏'
  static const secretRealmStatuses = [
    OptionEntry('开放', '开放', 'Open'),
    OptionEntry('封印', '封印', 'Sealed'),
    OptionEntry('毁坏', '毁坏', 'Ruined'),
    OptionEntry('隐藏', '隐藏', 'Hidden'),
  ];

  // ---------- 资源 Resource ----------
  static const resourceTypes = [
    OptionEntry('矿脉', '矿脉', 'Ore Vein'),
    OptionEntry('灵脉', '灵脉', 'Spirit Vein'),
    OptionEntry('龙脉', '龙脉', 'Dragon Vein'),
    OptionEntry('草药', '草药', 'Herbs'),
    OptionEntry('灵兽', '灵兽', 'Spirit Beast'),
    OptionEntry('水源', '水源', 'Water Source'),
    OptionEntry('人口', '人口', 'Population'),
    OptionEntry('装备', '装备', 'Equipment'),
    OptionEntry('灵宝', '灵宝', 'Spirit Treasure'),
  ];

  /// Resources.rarity 表列默认值 = '普通'
  static const resourceRarities = [
    OptionEntry('普通', '普通', 'Common'),
    OptionEntry('不常见', '不常见', 'Uncommon'),
    OptionEntry('稀有', '稀有', 'Rare'),
    OptionEntry('史诗', '史诗', 'Epic'),
    OptionEntry('传说', '传说', 'Legendary'),
  ];

  /// Resources.regenerationSpeed 表列默认值 = '中等'
  static const resourceRegenerationSpeeds = [
    OptionEntry('极慢', '极慢', 'Very Slow'),
    OptionEntry('缓慢', '缓慢', 'Slow'),
    OptionEntry('中等', '中等', 'Medium'),
    OptionEntry('快速', '快速', 'Fast'),
    OptionEntry('极快', '极快', 'Very Fast'),
  ];

  /// Resources.status 表列默认值 = '活跃'
  static const resourceStatuses = [
    OptionEntry('活跃', '活跃', 'Active'),
    OptionEntry('濒临枯竭', '濒临枯竭', 'Depleting'),
    OptionEntry('枯竭', '枯竭', 'Depleted'),
    OptionEntry('废弃', '废弃', 'Abandoned'),
    OptionEntry('受保护', '受保护', 'Protected'),
    OptionEntry('争夺中', '争夺中', 'Contested'),
  ];

  // ---------- 关系网络 RelationshipNetwork ----------
  static const networkTypes = [
    OptionEntry('家族网络', '家族网络', 'Family Network'),
    OptionEntry('势力网络', '势力网络', 'Faction Network'),
    OptionEntry('朋友圈', '朋友圈', 'Social Circle'),
    OptionEntry('敌对网络', '敌对网络', 'Hostile Network'),
    OptionEntry('师承网络', '师承网络', 'Mentorship Network'),
  ];

  /// RelationshipNetworks.status 表列默认值 = '活跃'
  static const networkStatuses = [
    OptionEntry('活跃', '活跃', 'Active'),
    OptionEntry('衰落', '衰落', 'Declining'),
    OptionEntry('重组', '重组', 'Restructuring'),
    OptionEntry('解散', '解散', 'Dissolved'),
  ];

  // ---------- 种族关系 RaceRelationship ----------
  static const raceRelationshipTypes = [
    OptionEntry('盟友', '盟友', 'Ally'),
    OptionEntry('敌对', '敌对', 'Hostile'),
    OptionEntry('中立', '中立', 'Neutral'),
    OptionEntry('附庸', '附庸', 'Vassal'),
    OptionEntry('宗主', '宗主', 'Suzerain'),
  ];

  /// RaceRelationships.status 表列默认值 = '稳定'
  static const raceRelationshipStatuses = [
    OptionEntry('稳定', '稳定', 'Stable'),
    OptionEntry('紧张', '紧张', 'Tense'),
    OptionEntry('恶化', '恶化', 'Deteriorating'),
    OptionEntry('改善', '改善', 'Improving'),
    OptionEntry('破裂', '破裂', 'Broken'),
  ];

  // ---------- 货币体系 CurrencySystem ----------
  static const monetarySystems = [
    OptionEntry('金本位制', '金本位制', 'Gold Standard'),
    OptionEntry('银本位制', '银本位制', 'Silver Standard'),
    OptionEntry('信用货币制', '信用货币制', 'Credit Money'),
    OptionEntry('物物交换制', '物物交换制', 'Barter'),
    OptionEntry('灵石货币制', '灵石货币制', 'Spirit Stone Standard'),
    OptionEntry('混合货币制', '混合货币制', 'Mixed Standard'),
  ];

  // ---------- 角色事件 CharacterEvent ----------
  /// CharacterEvents.eventType 表列默认值 = '其他'
  static const characterEventTypes = [
    OptionEntry('出生', '出生', 'Birth'),
    OptionEntry('拜师', '拜师', 'Apprenticeship'),
    OptionEntry('突破', '突破', 'Breakthrough'),
    OptionEntry('参战', '参战', 'Battle'),
    OptionEntry('结盟', '结盟', 'Alliance'),
    OptionEntry('离队', '离队', 'Departure'),
    OptionEntry('死亡', '死亡', 'Death'),
    OptionEntry('其他', '其他', 'Other'),
  ];

  // ---------- 时间线 TimelineEvent ----------
  /// TimelineEvents.category 表列默认值 = '历史事件'
  static const timelineCategories = [
    OptionEntry('历史事件', '历史事件', 'Historical'),
    OptionEntry('剧情事件', '剧情事件', 'Plot'),
    OptionEntry('角色事件', '角色事件', 'Character'),
    OptionEntry('势力事件', '势力事件', 'Faction'),
    OptionEntry('世界事件', '世界事件', 'World'),
    OptionEntry('修炼事件', '修炼事件', 'Cultivation'),
  ];

  static const timelineImportances = [
    OptionEntry('极高', '极高', 'Critical'),
    OptionEntry('高', '高', 'High'),
    OptionEntry('中', '中', 'Medium'),
    OptionEntry('低', '低', 'Low'),
  ];

  static const timelineStatuses = [
    OptionEntry('已完成', '已完成', 'Completed'),
    OptionEntry('进行中', '进行中', 'In Progress'),
    OptionEntry('计划中', '计划中', 'Planned'),
    OptionEntry('已取消', '已取消', 'Cancelled'),
  ];

  // ---------- 通用状态（英文值，各实体表列默认值同源） ----------
  /// Projects / Volumes 的状态（两表 status 列默认值均为 'Planning'）
  static const projectLikeStatuses = [
    OptionEntry('Planning', '规划中', 'Planning'),
    OptionEntry('InProgress', '进行中', 'In Progress'),
    OptionEntry('Paused', '暂停', 'Paused'),
    OptionEntry('Completed', '已完成', 'Completed'),
    OptionEntry('Cancelled', '已取消', 'Cancelled'),
    OptionEntry('Published', '已发布', 'Published'),
    OptionEntry('Archived', '归档', 'Archived'),
  ];

  /// Chapters.status 表列默认值 = 'Draft'
  static const chapterStatuses = [
    OptionEntry('Draft', '草稿', 'Draft'),
    OptionEntry('InProgress', '进行中', 'In Progress'),
    OptionEntry('Completed', '已完成', 'Completed'),
    OptionEntry('Published', '已发布', 'Published'),
  ];

  /// Characters / Factions / WorldSettings / CultivationSystems /
  /// PoliticalSystems / CurrencySystems / CharacterRelationships /
  /// FactionRelationships 等表的 status 列默认值均为 'Active'
  static const activeStatuses = [
    OptionEntry('Active', '启用', 'Active'),
    OptionEntry('Inactive', '停用', 'Inactive'),
    OptionEntry('Archived', '归档', 'Archived'),
  ];
}
