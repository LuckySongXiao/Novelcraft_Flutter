import 'world_system_page.dart';

/// 10 个「JSON 文件存储」的世界观体系配置（中英双字段，L10n 切换时按 isEnglish 走对应字段）
///
/// 对应 C# 的 10 个 *DataService + 12 个体系 View（合计约 11,400 行）。
/// 每项体系的字段取自 README 的功能说明与 C# ViewModel 定义。
///
/// ⚠ 注意：修炼体系（cultivation）与政治体系（political）不在此列 ——
/// 那两个是真正的数据库实体（有 CultivationSystems / PoliticalSystems 表），
/// 由各自的页面处理。

const wSystemConfigs = <WorldSystemConfig>[
  // ---------- 功法体系 ----------
  WorldSystemConfig(
    scope: 'techniques',
    titleZh: '功法体系',
    titleEn: 'Techniques',
    itemNameZh: '功法',
    itemNameEn: 'Technique',
    summaryField: 'category',
    fields: [
      SystemFieldDef(key: 'name', labelZh: '功法名称', labelEn: 'Name'),
      SystemFieldDef(
        key: 'category',
        labelZh: '功法分类',
        labelEn: 'Category',
        type: SystemFieldType.select,
        optionsZh: ['攻击类', '防御类', '辅助类', '身法类', '炼体类', '神魂类'],
        optionsEn: ['Offensive', 'Defensive', 'Support', 'Movement', 'Body Tempering', 'Soul'],
      ),
      SystemFieldDef(
        key: 'rank',
        labelZh: '品阶',
        labelEn: 'Rank',
        type: SystemFieldType.select,
        optionsZh: ['黄阶', '玄阶', '地阶', '天阶', '圣阶', '神阶'],
        optionsEn: ['Yellow', 'Mystery', 'Earth', 'Heaven', 'Saint', 'Divine'],
      ),
      SystemFieldDef(
        key: 'requirements',
        labelZh: '修炼要求',
        labelEn: 'Requirements',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'skills',
        labelZh: '技能招式',
        labelEn: 'Skills & Moves',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'inheritance',
        labelZh: '传承信息',
        labelEn: 'Inheritance',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'description',
        labelZh: '描述',
        labelEn: 'Description',
        type: SystemFieldType.multiline,
      ),
    ],
  ),

  // ---------- 装备体系 ----------
  WorldSystemConfig(
    scope: 'equipment',
    titleZh: '装备体系',
    titleEn: 'Equipment',
    itemNameZh: '装备',
    itemNameEn: 'Equipment',
    summaryField: 'category',
    fields: [
      SystemFieldDef(key: 'name', labelZh: '装备名称', labelEn: 'Name'),
      SystemFieldDef(
        key: 'category',
        labelZh: '装备分类',
        labelEn: 'Category',
        type: SystemFieldType.select,
        optionsZh: ['兵器', '防具', '饰品', '法宝', '消耗品'],
        optionsEn: ['Weapon', 'Armor', 'Accessory', 'Talisman', 'Consumable'],
      ),
      SystemFieldDef(
        key: 'rank',
        labelZh: '品级',
        labelEn: 'Grade',
        type: SystemFieldType.select,
        optionsZh: ['凡品', '灵品', '宝品', '仙品', '神品'],
        optionsEn: ['Mortal', 'Spirit', 'Treasure', 'Immortal', 'Divine'],
      ),
      SystemFieldDef(
        key: 'attributes',
        labelZh: '属性加成',
        labelEn: 'Attributes',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'enhancement',
        labelZh: '强化系统',
        labelEn: 'Enhancement',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'crafting',
        labelZh: '制作信息',
        labelEn: 'Crafting Info',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'description',
        labelZh: '描述',
        labelEn: 'Description',
        type: SystemFieldType.multiline,
      ),
    ],
  ),

  // ---------- 宠物体系 ----------
  WorldSystemConfig(
    scope: 'pets',
    titleZh: '宠物体系',
    titleEn: 'Pets & Familiars',
    itemNameZh: '宠物',
    itemNameEn: 'Pet',
    summaryField: 'category',
    fields: [
      SystemFieldDef(key: 'name', labelZh: '宠物名称', labelEn: 'Name'),
      SystemFieldDef(
        key: 'category',
        labelZh: '宠物分类',
        labelEn: 'Category',
        type: SystemFieldType.select,
        optionsZh: ['兽类', '禽类', '虫类', '灵体', '元素生物'],
        optionsEn: ['Beast', 'Avian', 'Insect', 'Spirit', 'Elemental'],
      ),
      SystemFieldDef(
        key: 'rarity',
        labelZh: '稀有度',
        labelEn: 'Rarity',
        type: SystemFieldType.select,
        optionsZh: ['普通', '不常见', '稀有', '史诗', '传说'],
        optionsEn: ['Common', 'Uncommon', 'Rare', 'Epic', 'Legendary'],
      ),
      SystemFieldDef(
        key: 'skills',
        labelZh: '技能系统',
        labelEn: 'Skills',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'evolution',
        labelZh: '进化系统',
        labelEn: 'Evolution',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'training',
        labelZh: '培养系统',
        labelEn: 'Training',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'description',
        labelZh: '描述',
        labelEn: 'Description',
        type: SystemFieldType.multiline,
      ),
    ],
  ),

  // ---------- 灵宝体系 ----------
  WorldSystemConfig(
    scope: 'treasures',
    titleZh: '灵宝体系',
    titleEn: 'Treasures',
    itemNameZh: '灵宝',
    itemNameEn: 'Treasure',
    summaryField: 'category',
    fields: [
      SystemFieldDef(key: 'name', labelZh: '灵宝名称', labelEn: 'Name'),
      SystemFieldDef(
        key: 'category',
        labelZh: '灵宝分类',
        labelEn: 'Category',
        type: SystemFieldType.select,
        optionsZh: ['攻击类', '防御类', '辅助类', '封印类', '空间类'],
        optionsEn: ['Offensive', 'Defensive', 'Support', 'Sealing', 'Spatial'],
      ),
      SystemFieldDef(
        key: 'rank',
        labelZh: '品级等级',
        labelEn: 'Rank',
        type: SystemFieldType.select,
        optionsZh: ['下品', '中品', '上品', '极品', '先天'],
        optionsEn: ['Low', 'Mid', 'High', 'Supreme', 'Innate'],
      ),
      SystemFieldDef(
        key: 'spiritLevel',
        labelZh: '灵性等级',
        labelEn: 'Spirit Level',
        type: SystemFieldType.select,
        optionsZh: ['无灵', '初启', '通灵', '化灵', '神灵'],
        optionsEn: ['Dormant', 'Awakening', 'Attuned', 'Sentient', 'Godly'],
      ),
      SystemFieldDef(
        key: 'refining',
        labelZh: '炼制信息',
        labelEn: 'Refining',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'spirit',
        labelZh: '器灵系统',
        labelEn: 'Artifact Spirit',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'description',
        labelZh: '描述',
        labelEn: 'Description',
        type: SystemFieldType.multiline,
      ),
    ],
  ),

  // ---------- 商业体系 ----------
  WorldSystemConfig(
    scope: 'businesses',
    titleZh: '商业体系',
    titleEn: 'Commerce & Guilds',
    itemNameZh: '商业组织',
    itemNameEn: 'Org',
    summaryField: 'economicSystem',
    fields: [
      SystemFieldDef(key: 'name', labelZh: '组织名称', labelEn: 'Name'),
      SystemFieldDef(
        key: 'economicSystem',
        labelZh: '经济制度',
        labelEn: 'Economic System',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'marketStructure',
        labelZh: '市场结构',
        labelEn: 'Market Structure',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'tradeSystem',
        labelZh: '贸易体系',
        labelEn: 'Trade System',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'organizations',
        labelZh: '商业组织',
        labelEn: 'Organizations',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'mechanism',
        labelZh: '市场机制',
        labelEn: 'Mechanisms',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'description',
        labelZh: '描述',
        labelEn: 'Description',
        type: SystemFieldType.multiline,
      ),
    ],
  ),

  // ---------- 职业体系 ----------
  WorldSystemConfig(
    scope: 'professions',
    titleZh: '职业体系',
    titleEn: 'Professions',
    itemNameZh: '职业',
    itemNameEn: 'Profession',
    summaryField: 'category',
    fields: [
      SystemFieldDef(key: 'name', labelZh: '职业名称', labelEn: 'Name'),
      SystemFieldDef(
        key: 'category',
        labelZh: '职业分类',
        labelEn: 'Category',
        type: SystemFieldType.select,
        optionsZh: ['战斗类', '生产类', '辅助类', '管理类', '特殊类'],
        optionsEn: ['Combat', 'Production', 'Support', 'Management', 'Special'],
      ),
      SystemFieldDef(
        key: 'skills',
        labelZh: '技能体系',
        labelEn: 'Skill System',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'promotion',
        labelZh: '晋升路径',
        labelEn: 'Promotion Path',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'salary',
        labelZh: '薪酬体系',
        labelEn: 'Salary & Compensation',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'environment',
        labelZh: '工作环境',
        labelEn: 'Work Environment',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'description',
        labelZh: '描述',
        labelEn: 'Description',
        type: SystemFieldType.multiline,
      ),
    ],
  ),

  // ---------- 司法体系 ----------
  WorldSystemConfig(
    scope: 'judicial',
    titleZh: '司法体系',
    titleEn: 'Judiciary',
    itemNameZh: '司法机构',
    itemNameEn: 'Institution',
    summaryField: 'legalSystem',
    fields: [
      SystemFieldDef(key: 'name', labelZh: '机构名称', labelEn: 'Name'),
      SystemFieldDef(
        key: 'legalSystem',
        labelZh: '法律体系',
        labelEn: 'Legal System',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'courtSystem',
        labelZh: '法院体系',
        labelEn: 'Court System',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'procedure',
        labelZh: '审判程序',
        labelEn: 'Trial Procedure',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'enforcement',
        labelZh: '执法机构',
        labelEn: 'Enforcement',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'punishment',
        labelZh: '刑罚制度',
        labelEn: 'Penalties',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'description',
        labelZh: '描述',
        labelEn: 'Description',
        type: SystemFieldType.multiline,
      ),
    ],
  ),

  // ---------- 生民体系 ----------
  WorldSystemConfig(
    scope: 'population',
    titleZh: '生民体系',
    titleEn: 'Population',
    itemNameZh: '族群',
    itemNameEn: 'Group',
    summaryField: 'socialClass',
    fields: [
      SystemFieldDef(key: 'name', labelZh: '族群名称', labelEn: 'Name'),
      SystemFieldDef(
        key: 'populationCount',
        labelZh: '人口统计',
        labelEn: 'Population Count',
        type: SystemFieldType.number,
        defaultValue: 0,
      ),
      SystemFieldDef(
        key: 'socialClass',
        labelZh: '社会阶层',
        labelEn: 'Social Class',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'education',
        labelZh: '教育体系',
        labelEn: 'Education',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'medical',
        labelZh: '医疗体系',
        labelEn: 'Medical Care',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'culture',
        labelZh: '文化生活',
        labelEn: 'Culture & Life',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'description',
        labelZh: '描述',
        labelEn: 'Description',
        type: SystemFieldType.multiline,
      ),
    ],
  ),

  // ---------- 地图结构 ----------
  WorldSystemConfig(
    scope: 'maps',
    titleZh: '地图结构',
    titleEn: 'Maps',
    itemNameZh: '地域',
    itemNameEn: 'Region',
    summaryField: 'terrainType',
    fields: [
      SystemFieldDef(key: 'name', labelZh: '地域名称', labelEn: 'Name'),
      SystemFieldDef(
        key: 'level',
        labelZh: '层级',
        labelEn: 'Level',
        type: SystemFieldType.select,
        optionsZh: ['大陆', '国家', '州域', '城池', '区域'],
        optionsEn: ['Continent', 'Country', 'Province', 'City', 'Region'],
      ),
      SystemFieldDef(
        key: 'terrainType',
        labelZh: '地形类型',
        labelEn: 'Terrain',
        type: SystemFieldType.select,
        optionsZh: ['平原', '山地', '森林', '沙漠', '水域', '雪原', '沼泽'],
        optionsEn: ['Plains', 'Mountains', 'Forest', 'Desert', 'Waters', 'Snowlands', 'Wetland'],
      ),
      SystemFieldDef(
        key: 'climate',
        labelZh: '气候类型',
        labelEn: 'Climate',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'resources',
        labelZh: '资源分布',
        labelEn: 'Resources',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'specialAreas',
        labelZh: '特殊区域',
        labelEn: 'Special Areas',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'description',
        labelZh: '描述',
        labelEn: 'Description',
        type: SystemFieldType.multiline,
      ),
    ],
  ),

  // ---------- 维度结构 ----------
  WorldSystemConfig(
    scope: 'dimensions',
    titleZh: '维度结构',
    titleEn: 'Dimensions',
    itemNameZh: '维度',
    itemNameEn: 'Dimension',
    summaryField: 'category',
    fields: [
      SystemFieldDef(key: 'name', labelZh: '维度名称', labelEn: 'Name'),
      SystemFieldDef(
        key: 'category',
        labelZh: '维度分类',
        labelEn: 'Category',
        type: SystemFieldType.select,
        optionsZh: ['主位面', '次位面', '元素位面', '虚空', '秘境空间'],
        optionsEn: ['Prime Material', 'Secondary Plane', 'Elemental Plane', 'Void', 'Secret Realm'],
      ),
      SystemFieldDef(
        key: 'stability',
        labelZh: '稳定性',
        labelEn: 'Stability',
        type: SystemFieldType.select,
        optionsZh: ['稳定', '波动', '不稳定', '崩坏中'],
        optionsEn: ['Stable', 'Fluctuating', 'Unstable', 'Collapsing'],
      ),
      SystemFieldDef(
        key: 'accessLevel',
        labelZh: '访问等级',
        labelEn: 'Access Level',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'environment',
        labelZh: '环境特征',
        labelEn: 'Environment',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'connection',
        labelZh: '连接传送',
        labelEn: 'Travel & Portals',
        type: SystemFieldType.multiline,
      ),
      SystemFieldDef(
        key: 'description',
        labelZh: '描述',
        labelEn: 'Description',
        type: SystemFieldType.multiline,
      ),
    ],
  ),
];
