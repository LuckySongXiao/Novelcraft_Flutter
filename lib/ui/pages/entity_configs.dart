import 'package:drift/drift.dart' as d;
import 'package:uuid/uuid.dart';

import '../../core/di.dart';
import '../../core/enums/pseudo_enums.dart';
import '../../data/database.dart';
import '../layout/navigation.dart';
import 'entity_page.dart';
import 'chapter_preview_page.dart';
import 'world_system_page.dart' show SystemFieldDef, SystemFieldType;

/// 数据库实体页配置表
///
/// 每个实体提供：字段清单 + 一个把 drift Row ↔ Map 互转的数据源。
/// C# 侧这些页面各自 1000~2100 行，Dart 侧压缩到每个 60~90 行。
///
/// ⚠ 非空列的 `Value<T>` 不接受 null，可空列的 `Value<T?>` 不接受非 null 包装，
/// 因此下面每个字段的 `as String` / `as String?` 都是**按 drift 生成的签名逐一核对**过的，
/// 改动前请对照 `lib/data/database.g.dart` 里的 `final Value<X> xxx;`。
const _uuid = Uuid();

/// 创建实体时允许导入器注入稳定的新主键；普通表单没有 `id` 字段时仍生成 UUID。
String _entityId(Map<String, dynamic> values) {
  final String? imported = values['id'] as String?;
  return imported == null || imported.trim().isEmpty ? _uuid.v4() : imported;
}

SystemFieldDef _text(String key, String labelZh, [String? labelEn]) =>
    SystemFieldDef(key: key, labelZh: labelZh, labelEn: labelEn);

SystemFieldDef _multi(String key, String labelZh, [String? labelEn]) =>
    SystemFieldDef(
        key: key, labelZh: labelZh, labelEn: labelEn, type: SystemFieldType.multiline);

SystemFieldDef _num(String key, String labelZh, [String? labelEn]) =>
    SystemFieldDef(
        key: key, labelZh: labelZh, labelEn: labelEn, type: SystemFieldType.number);

SystemFieldDef _sel(
  String key,
  String labelZh,
  String? labelEn,
  List<String> optionsZh, [
  List<String>? optionsEn,
]) =>
    SystemFieldDef(
      key: key,
      labelZh: labelZh,
      labelEn: labelEn,
      type: SystemFieldType.select,
      optionsZh: optionsZh,
      optionsEn: optionsEn,
    );

SystemFieldDef _bool(String key, String labelZh, [String? labelEn]) =>
    SystemFieldDef(
        key: key, labelZh: labelZh, labelEn: labelEn, type: SystemFieldType.bool);

/// 规范化下拉：**入库值取自词典、显示走本地化标签**，二者分离。
///
/// ⚠ 必须用 [PseudoEnums] 里的**规范值**（与 `lib/data/tables/**.dart` 中该列的
/// `withDefault(const Constant('...'))` 同源）。此前各页面各自手写中文候选表，
/// 导致「库里默认值不在候选表里」→ 打开详情即断言崩溃（PITFALLS §28）。
SystemFieldDef _selc(
  String key,
  String labelZh,
  String? labelEn,
  List<OptionEntry> options,
) =>
    SystemFieldDef(
      key: key,
      labelZh: labelZh,
      labelEn: labelEn,
      type: SystemFieldType.select,
      options: options,
    );

// ---------------------------------------------------------------------------
// 数值 / 字符串 / 布尔 / 日期 列 → drift Value 的便捷封装
//
// 命名约定：
//   _vInt / _vStr / _vDbl    → 对应 `Value<int>` / `Value<String>` / `Value<double>`（非空列）
//   _vIntN / _vStrN / _vDblN → 对应可空列（`Value<int?>` / `Value<String?>` / `Value<double?>`）
// 这些都是**按 `lib/data/database.g.dart` 里每个字段的 `final Value<X>` 签名逐一核对**后写的，
// 改字段类型前请先回去对照生成代码，否则会出现 `Value<int?>` 喂给 `Value<int>` 之类的编译错误。
// ---------------------------------------------------------------------------
int? _toInt(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}

double? _toDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

/// 非空 int 列（`Value<int>`）：表单留空时归 0
d.Value<int> _vInt(Map<String, dynamic> v, String k) => d.Value(_toInt(v[k]) ?? 0);

/// 可空 int 列（`Value<int?>`）
d.Value<int?> _vIntN(Map<String, dynamic> v, String k) => d.Value(_toInt(v[k]));

/// 非空 double 列（`Value<double>`）：表单留空时归 0.0
d.Value<double> _vDbl(Map<String, dynamic> v, String k) =>
    d.Value(_toDouble(v[k]) ?? 0.0);

/// 可空 double 列（`Value<double?>`）
d.Value<double?> _vDblN(Map<String, dynamic> v, String k) =>
    d.Value(_toDouble(v[k]));

/// 非空字符串列（`Value<String>`）：表单留空时归空串
d.Value<String> _vStr(Map<String, dynamic> v, String k, [String dflt = '']) =>
    d.Value(v[k] as String? ?? dflt);

/// 可空字符串列（`Value<String?>`）
d.Value<String?> _vStrN(Map<String, dynamic> v, String k) =>
    d.Value(v[k] as String?);

/// 布尔列（`Value<bool>`）：表单返回 'true' / 'false' / null
d.Value<bool> _vBool(Map<String, dynamic> v, String k) {
  final Object? raw = v[k];
  if (raw is bool) return d.Value(raw);
  if (raw is num) return d.Value(raw != 0);
  final String normalized = raw?.toString().trim().toLowerCase() ?? '';
  return d.Value(normalized == 'true' || normalized == '1' || normalized == 'yes');
}

/// 必填日期列（`DateTime`，如 TimelineEvent.eventDate）：解析失败回退 now
DateTime _date(Map<String, dynamic> v, String k) {
  final Object? raw = v[k];
  if (raw is DateTime) return raw;
  return DateTime.tryParse(raw?.toString() ?? '') ?? DateTime.now();
}

/// 子实体（无 projectId）的列表按关键词在内存中过滤
List<Map<String, dynamic>> _kwFilter(
  List<Map<String, dynamic>> all,
  String kw,
) {
  final k = kw.toLowerCase();
  return all
      .where((m) =>
          m.values.any((val) => val != null && '$val'.toLowerCase().contains(k)))
      .toList();
}

// ---------------------------------------------------------------------------
// 人物
// ---------------------------------------------------------------------------

Map<String, dynamic> _characterToMap(dynamic r) => {
      'id': r.id,
      'name': r.name,
      'type': r.type,
      'gender': r.gender,
      'age': r.age,
      'cultivationLevel': r.cultivationLevel,
      'importance': r.importance,
      'appearance': r.appearance,
      'personality': r.personality,
      'background': r.background,
      'abilities': r.abilities,
      'notes': r.notes,
      'status': r.status,
      'tags': r.tags,
    };

final characterEntityConfig = EntityPageConfig(
  titleZh: '人物管理',
  titleEn: 'Characters',
  itemNameZh: '人物',
  itemNameEn: 'Character',
  nameField: 'name',
  summaryField: 'type',
  fields: [
    _text('name', '姓名', 'Name'),
    _sel('type', '角色类型', 'Role Type',
        ['主角', '配角', '反派', '龙套'],
        ['Protagonist', 'Supporting', 'Antagonist', 'Extra']),
    _sel('gender', '性别', 'Gender',
        ['男', '女', '未知'],
        ['Male', 'Female', 'Unknown']),
    _num('age', '年龄', 'Age'),
    _text('cultivationLevel', '修为境界', 'Cultivation Realm'),
    _num('importance', '重要度（1-10）', 'Importance (1-10)'),
    _multi('appearance', '外貌', 'Appearance'),
    _multi('personality', '性格', 'Personality'),
    _multi('background', '背景', 'Background'),
    _multi('abilities', '能力', 'Abilities'),
    _text('tags', '标签', 'Tags'),
    // Characters.status 表列默认值 'Active'
    _selc('status', '状态', 'Status', PseudoEnums.activeStatuses),
    _multi('notes', '备注', 'Notes'),
  ],
  sourceBuilder: (ref) {
    final svc = ref.read(characterServiceProvider);
    return CallbackEntityDataSource(
      onList: (pid) async =>
          (await svc.getByProjectId(pid)).map(_characterToMap).toList(),
      onSearch: (pid, kw) async =>
          (await svc.search(pid, kw)).map(_characterToMap).toList(),
      onCreate: (pid, v) => svc.create(
        CharactersCompanion.insert(
          id: _entityId(v),
          projectId: pid,
          name: v['name'] as String,
          type: v['type'] as String? ?? '配角',
          gender: d.Value(v['gender'] as String?),
          age: d.Value(v['age'] as int?),
          cultivationLevel: d.Value(v['cultivationLevel'] as String?),
          importance: d.Value(v['importance'] as int? ?? 1),
          appearance: d.Value(v['appearance'] as String?),
          personality: d.Value(v['personality'] as String?),
          background: d.Value(v['background'] as String?),
          abilities: d.Value(v['abilities'] as String?),
          notes: d.Value(v['notes'] as String?),
          status: d.Value(v['status'] as String? ?? 'Active'),
          tags: d.Value(v['tags'] as String?),
        ),
      ),
      onUpdate: (id, v) => svc.updateById(
        id,
        CharactersCompanion(
          name: d.Value(v['name'] as String? ?? ''),
          type: d.Value(v['type'] as String? ?? '配角'),
          gender: d.Value(v['gender'] as String?),
          age: d.Value(v['age'] as int?),
          cultivationLevel: d.Value(v['cultivationLevel'] as String?),
          importance: d.Value(v['importance'] as int? ?? 1),
          appearance: d.Value(v['appearance'] as String?),
          personality: d.Value(v['personality'] as String?),
          background: d.Value(v['background'] as String?),
          abilities: d.Value(v['abilities'] as String?),
          notes: d.Value(v['notes'] as String?),
          status: d.Value(v['status'] as String? ?? 'Active'),
          tags: d.Value(v['tags'] as String?),
        ),
      ),
      onDelete: svc.delete,
    );
  },
);

// ---------------------------------------------------------------------------
// 卷宗
// ---------------------------------------------------------------------------

Map<String, dynamic> _volumeToMap(dynamic r) => {
      'id': r.id,
      'title': r.title,
      'description': r.description,
      'orderIndex': r.orderIndex,
      'status': r.status,
      'type': r.type,
      'tags': r.tags,
      'notes': r.notes,
    };

final volumeEntityConfig = EntityPageConfig(
  titleZh: '卷宗管理',
  titleEn: 'Volumes',
  itemNameZh: '卷宗',
  itemNameEn: 'Volume',
  nameField: 'title',
  summaryField: 'status',
  fields: [
    _text('title', '卷宗标题', 'Volume Title'),
    _num('orderIndex', '排序序号', 'Order Index'),
    // Volumes.status 表列默认值 'Planning' —— 必须用规范值，否则打开示例卷宗即崩
    _selc('status', '状态', 'Status', PseudoEnums.projectLikeStatuses),
    _text('type', '类型', 'Type'),
    _multi('description', '简介', 'Synopsis'),
    _text('tags', '标签', 'Tags'),
    _multi('notes', '备注', 'Notes'),
  ],
  sourceBuilder: (ref) {
    final svc = ref.read(volumeServiceProvider);
    return CallbackEntityDataSource(
      onList: (pid) async =>
          (await svc.getByProjectId(pid)).map(_volumeToMap).toList(),
      onSearch: (pid, kw) async =>
          (await svc.search(pid, kw)).map(_volumeToMap).toList(),
      onCreate: (pid, v) => svc.create(
        VolumesCompanion.insert(
          id: _entityId(v),
          projectId: pid,
          title: v['title'] as String,
          orderIndex: d.Value(v['orderIndex'] as int? ?? 0),
          status: d.Value(v['status'] as String? ?? 'Planning'),
          type: d.Value(v['type'] as String?),
          description: d.Value(v['description'] as String?),
          tags: d.Value(v['tags'] as String?),
          notes: d.Value(v['notes'] as String?),
        ),
      ),
      onUpdate: (id, v) => svc.updateById(
        id,
        VolumesCompanion(
          title: d.Value(v['title'] as String? ?? ''),
          orderIndex: d.Value(v['orderIndex'] as int? ?? 0),
          status: d.Value(v['status'] as String? ?? 'Planning'),
          type: d.Value(v['type'] as String?),
          description: d.Value(v['description'] as String?),
          tags: d.Value(v['tags'] as String?),
          notes: d.Value(v['notes'] as String?),
        ),
      ),
      onDelete: svc.delete,
    );
  },
);

// ---------------------------------------------------------------------------
// 章节
// ---------------------------------------------------------------------------

Map<String, dynamic> _chapterToMap(dynamic r) => {
      'id': r.id,
      // 保留卷宗归属，项目备份恢复时才能重建卷→章层级。
      'volumeId': r.volumeId,
      'title': r.title,
      'summary': r.summary,
      'content': r.content,
      'status': r.status,
      'type': r.type,
      'wordCount': r.wordCount,
      'notes': r.notes,
      // 功能 A 预览页元信息（表单未暴露这些列，预览时从行快照取）
      'versionNumber': r.versionNumber,
      'lastEditedAt': r.lastEditedAt?.toString(),
      'tags': r.tags,
    };

/// 章节字数自动补算：手填值优先；留空/0 且正文非空时按正文长度统计。
///
/// 不补算的话 wordCount 恒 0 → 剧情进度（actualWords/estimated）恒 0、
/// 状态永不推进——「剧情状态自动更新」最大的暗坑（PITFALLS 补充）。
int _autoWordCount(Map<String, dynamic> v) {
  final int manual = (v['wordCount'] as num?)?.toInt() ?? 0;
  if (manual > 0) return manual;
  final String content = (v['content'] as String?) ?? '';
  return content.trim().isEmpty ? 0 : content.trim().length;
}

final chapterEntityConfig = EntityPageConfig(
  titleZh: '章节管理',
  titleEn: 'Chapters',
  itemNameZh: '章节',
  itemNameEn: 'Chapter',
  nameField: 'title',
  summaryField: 'status',
  // 保存后触发世界观/剧情/时间线自动同步（entity_page._save → _runPostProcess）
  syncOnSave: true,
  fields: [
    _text('title', '章节标题', 'Chapter Title'),
    // Chapters.status 表列默认值 'Draft'
    _selc('status', '状态', 'Status', PseudoEnums.chapterStatuses),
    _text('type', '类型', 'Type'),
    _num('wordCount', '字数（留空自动按正文统计）', 'Word Count (auto)'),
    _multi('summary', '梗概', 'Summary'),
    _multi('content', '正文', 'Content'),
    _multi('notes', '备注', 'Notes'),
  ],
  sourceBuilder: (ref) {
    final svc = ref.read(chapterServiceProvider);
    return CallbackEntityDataSource(
      // 章节按卷宗组织，这里按项目维度聚合展示
      onList: (pid) async =>
          (await svc.getByProjectId(pid)).map(_chapterToMap).toList(),
      onSearch: (pid, kw) async =>
          (await svc.search(pid, kw)).map(_chapterToMap).toList(),
      onCreate: (pid, v) => svc.create(
        ChaptersCompanion.insert(
          id: _entityId(v),
          // 导入备份时沿用原卷宗 ID；新建表单没有该字段则回退为空串。
          volumeId: v['volumeId'] as String? ?? '',
          title: v['title'] as String,
          projectId: d.Value(pid),
          status: d.Value(v['status'] as String? ?? 'Draft'),
          type: d.Value(v['type'] as String?),
          wordCount: d.Value(_autoWordCount(v)),
          summary: d.Value(v['summary'] as String?),
          content: d.Value(v['content'] as String?),
          notes: d.Value(v['notes'] as String?),
        ),
      ),
      onUpdate: (id, v) => svc.updateById(
        id,
        ChaptersCompanion(
          title: d.Value(v['title'] as String? ?? ''),
          status: d.Value(v['status'] as String? ?? 'Draft'),
          type: d.Value(v['type'] as String?),
          wordCount: d.Value(_autoWordCount(v)),
          summary: d.Value(v['summary'] as String?),
          content: d.Value(v['content'] as String?),
          notes: d.Value(v['notes'] as String?),
        ),
      ),
      onDelete: svc.delete,
    );
  },
  // 功能 A：章节只读结构化预览（对齐 C# ChapterPreviewDialog）
  previewBuilder: (context, values) => ChapterPreviewPage(values: values),
);

// ---------------------------------------------------------------------------
// 剧情
//
// ⚠ C# 的 Plot 实体主键字段叫 Title 而不是 Name（`name` 是 UI 上的习惯叫法）。
// 这里沿用数据库字段 title，列表标题也指向 title。
// ---------------------------------------------------------------------------

Map<String, dynamic> _plotToMap(dynamic r) => {
      'id': r.id,
      'title': r.title,
      'type': r.type,
      'status': r.status,
      'importance': r.importance,
      'description': r.description,
      'notes': r.notes,
    };

final plotEntityConfig = EntityPageConfig(
  titleZh: '剧情管理',
  titleEn: 'Plots',
  itemNameZh: '剧情',
  itemNameEn: 'Plot',
  nameField: 'title',
  summaryField: 'type',
  fields: [
    _text('title', '剧情名称', 'Plot Title'),
    _sel('type', '剧情类型', 'Plot Type',
        ['主线', '支线', '伏笔', '高潮'],
        ['Main', 'Side', 'Foreshadowing', 'Climax']),
    // Plots.status 表列默认值 '规划中'
    _selc('status', '状态', 'Status', PseudoEnums.plotStatuses),
    _num('importance', '重要度（1-10）', 'Importance (1-10)'),
    _multi('description', '描述', 'Description'),
    _multi('notes', '备注', 'Notes'),
  ],
  sourceBuilder: (ref) {
    final svc = ref.read(plotServiceProvider);
    return CallbackEntityDataSource(
      onList: (pid) async =>
          (await svc.getByProjectId(pid)).map(_plotToMap).toList(),
      onSearch: (pid, kw) async =>
          (await svc.search(pid, kw)).map(_plotToMap).toList(),
      onCreate: (pid, v) => svc.create(
        PlotsCompanion.insert(
          id: _entityId(v),
          projectId: pid,
          title: v['title'] as String,
          type: v['type'] as String? ?? '支线',
          status: d.Value(v['status'] as String? ?? '规划中'),
          importance: d.Value(v['importance'] as int? ?? 1),
          description: d.Value(v['description'] as String?),
          notes: d.Value(v['notes'] as String?),
        ),
      ),
      onUpdate: (id, v) => svc.updateById(
        id,
        PlotsCompanion(
          title: d.Value(v['title'] as String? ?? ''),
          type: d.Value(v['type'] as String? ?? '支线'),
          status: d.Value(v['status'] as String? ?? '规划中'),
          importance: d.Value(v['importance'] as int? ?? 1),
          description: d.Value(v['description'] as String?),
          notes: d.Value(v['notes'] as String?),
        ),
      ),
      onDelete: svc.delete,
    );
  },
);

// ---------------------------------------------------------------------------
// 势力
// ---------------------------------------------------------------------------

Map<String, dynamic> _factionToMap(dynamic r) => {
      'id': r.id,
      'name': r.name,
      'type': r.type,
      'powerLevel': r.powerLevel,
      'description': r.description,
      'notes': r.notes,
    };

final factionEntityConfig = EntityPageConfig(
  titleZh: '势力管理',
  titleEn: 'Factions',
  itemNameZh: '势力',
  itemNameEn: 'Faction',
  nameField: 'name',
  summaryField: 'type',
  fields: [
    _text('name', '势力名称', 'Faction Name'),
    _sel('type', '势力类型', 'Faction Type',
        ['宗门', '家族', '王朝', '商会', '散修联盟'],
        ['Sect', 'Clan', 'Dynasty', 'Merchant Guild', 'Rogue Alliance']),
    _num('powerLevel', '实力等级（1-10）', 'Power Level (1-10)'),
    _multi('description', '描述', 'Description'),
    _multi('notes', '备注', 'Notes'),
  ],
  sourceBuilder: (ref) {
    final svc = ref.read(factionServiceProvider);
    return CallbackEntityDataSource(
      onList: (pid) async =>
          (await svc.getByProjectId(pid)).map(_factionToMap).toList(),
      onSearch: (pid, kw) async =>
          (await svc.search(pid, kw)).map(_factionToMap).toList(),
      onCreate: (pid, v) => svc.create(
        FactionsCompanion.insert(
          id: _entityId(v),
          projectId: pid,
          name: v['name'] as String,
          type: v['type'] as String? ?? '宗门',
          powerLevel: d.Value(v['powerLevel'] as int? ?? 1),
          description: d.Value(v['description'] as String?),
          notes: d.Value(v['notes'] as String?),
        ),
      ),
      onUpdate: (id, v) => svc.updateById(
        id,
        FactionsCompanion(
          name: d.Value(v['name'] as String? ?? ''),
          type: d.Value(v['type'] as String? ?? '宗门'),
          powerLevel: d.Value(v['powerLevel'] as int? ?? 1),
          description: d.Value(v['description'] as String?),
          notes: d.Value(v['notes'] as String?),
        ),
      ),
      onDelete: svc.delete,
    );
  },
);

// ---------------------------------------------------------------------------
// 世界观设定
// ---------------------------------------------------------------------------

Map<String, dynamic> _worldSettingToMap(dynamic r) => {
      'id': r.id,
      'name': r.name,
      'type': r.type,
      'category': r.category,
      'importance': r.importance,
      'description': r.description,
      'content': r.content,
      'rules': r.rules,
      'history': r.history,
      'notes': r.notes,
    };

final worldSettingEntityConfig = EntityPageConfig(
  titleZh: '世界观设定',
  titleEn: 'World Settings',
  itemNameZh: '设定',
  itemNameEn: 'Setting',
  nameField: 'name',
  summaryField: 'category',
  fields: [
    _text('name', '设定名称', 'Setting Name'),
    _text('type', '类型', 'Type'),
    _text('category', '分类', 'Category'),
    _num('importance', '重要度（1-10）', 'Importance (1-10)'),
    _multi('description', '简介', 'Synopsis'),
    _multi('content', '详细内容', 'Details'),
    _multi('rules', '规则', 'Rules'),
    _multi('history', '历史', 'History'),
    _multi('notes', '备注', 'Notes'),
  ],
  sourceBuilder: (ref) {
    final svc = ref.read(worldSettingServiceProvider);
    return CallbackEntityDataSource(
      onList: (pid) async =>
          (await svc.getByProjectId(pid)).map(_worldSettingToMap).toList(),
      onSearch: (pid, kw) async =>
          (await svc.search(pid, kw)).map(_worldSettingToMap).toList(),
      onCreate: (pid, v) => svc.create(
        WorldSettingsCompanion.insert(
          id: _entityId(v),
          projectId: pid,
          name: v['name'] as String,
          type: v['type'] as String? ?? '通用',
          category: d.Value(v['category'] as String?),
          importance: d.Value(v['importance'] as int? ?? 1),
          description: d.Value(v['description'] as String?),
          content: d.Value(v['content'] as String?),
          rules: d.Value(v['rules'] as String?),
          history: d.Value(v['history'] as String?),
          notes: d.Value(v['notes'] as String?),
        ),
      ),
      onUpdate: (id, v) => svc.updateById(
        id,
        WorldSettingsCompanion(
          name: d.Value(v['name'] as String? ?? ''),
          type: d.Value(v['type'] as String? ?? '通用'),
          category: d.Value(v['category'] as String?),
          importance: d.Value(v['importance'] as int? ?? 1),
          description: d.Value(v['description'] as String?),
          content: d.Value(v['content'] as String?),
          rules: d.Value(v['rules'] as String?),
          history: d.Value(v['history'] as String?),
          notes: d.Value(v['notes'] as String?),
        ),
      ),
      onDelete: svc.delete,
    );
  },
);

// ---------------------------------------------------------------------------
// 种族
// ---------------------------------------------------------------------------

Map<String, dynamic> _raceToMap(dynamic r) => {
      'id': r.id,
      'name': r.name,
      'type': r.type,
      'population': r.population,
      'mainTerritory': r.mainTerritory,
      'rulingArea': r.rulingArea,
      'powerLevel': r.powerLevel,
      'influence': r.influence,
      'status': r.status,
      'characteristics': r.characteristics,
      'culturalBackground': r.culturalBackground,
      'importance': r.importance,
      'tags': r.tags,
      'notes': r.notes,
      'averageLifespan': r.averageLifespan,
      'birthRate': r.birthRate,
      'primaryLanguage': r.primaryLanguage,
      'primaryReligion': r.primaryReligion,
      'racialAbilities': r.racialAbilities,
      'racialWeaknesses': r.racialWeaknesses,
    };

final raceEntityConfig = EntityPageConfig(
  titleZh: '种族管理',
  titleEn: 'Races',
  itemNameZh: '种族',
  itemNameEn: 'Race',
  nameField: 'name',
  summaryField: 'type',
  fields: [
    _text('name', '种族名称', 'Race Name'),
    _sel('type', '种族类型', 'Race Type',
        ['人族', '妖族', '魔族', '灵族', '龙族', '其他'],
        ['Human', 'Demon Beast', 'Demon', 'Spirit', 'Dragon', 'Other']),
    _num('population', '人口规模', 'Population'),
    _text('mainTerritory', '主要领地', 'Main Territory'),
    _text('rulingArea', '统治区域', 'Ruling Area'),
    _num('powerLevel', '实力等级', 'Power Level'),
    _num('influence', '影响力', 'Influence'),
    // Races.status 表列默认值 '稳定'
    _selc('status', '状态', 'Status', PseudoEnums.raceStatuses),
    _multi('characteristics', '种族特征', 'Racial Traits'),
    _multi('culturalBackground', '文化背景', 'Cultural Background'),
    _num('importance', '重要度（1-10）', 'Importance (1-10)'),
    _text('tags', '标签', 'Tags'),
    _multi('notes', '备注', 'Notes'),
    _num('averageLifespan', '平均寿命', 'Average Lifespan'),
    _num('birthRate', '出生率', 'Birth Rate'),
    _text('primaryLanguage', '主要语言', 'Primary Language'),
    _text('primaryReligion', '主要信仰', 'Primary Religion'),
    _multi('racialAbilities', '种族天赋', 'Racial Abilities'),
    _multi('racialWeaknesses', '种族弱点', 'Racial Weaknesses'),
  ],
  sourceBuilder: (ref) {
    final svc = ref.read(raceServiceProvider);
    return CallbackEntityDataSource(
      onList: (pid) async =>
          (await svc.getByProjectId(pid)).map(_raceToMap).toList(),
      onSearch: (pid, kw) async =>
          (await svc.search(pid, kw)).map(_raceToMap).toList(),
      onCreate: (pid, v) => svc.create(
        RacesCompanion.insert(
          id: _entityId(v),
          projectId: pid,
          name: v['name'] as String? ?? '未命名',
          type: v['type'] as String? ?? '其他',
          population: _vInt(v, 'population'),
          mainTerritory: _vStrN(v, 'mainTerritory'),
          rulingArea: _vStrN(v, 'rulingArea'),
          powerLevel: _vInt(v, 'powerLevel'),
          influence: _vInt(v, 'influence'),
          status: _vStr(v, 'status', '稳定'),
          characteristics: _vStrN(v, 'characteristics'),
          culturalBackground: _vStrN(v, 'culturalBackground'),
          importance: _vInt(v, 'importance'),
          tags: _vStrN(v, 'tags'),
          notes: _vStrN(v, 'notes'),
          averageLifespan: _vIntN(v, 'averageLifespan'),
          birthRate: _vDblN(v, 'birthRate'),
          primaryLanguage: _vStrN(v, 'primaryLanguage'),
          primaryReligion: _vStrN(v, 'primaryReligion'),
          racialAbilities: _vStrN(v, 'racialAbilities'),
          racialWeaknesses: _vStrN(v, 'racialWeaknesses'),
        ),
      ),
      onUpdate: (id, v) => svc.updateById(
        id,
        RacesCompanion(
          name: _vStr(v, 'name'),
          type: _vStr(v, 'type', '其他'),
          population: _vInt(v, 'population'),
          mainTerritory: _vStrN(v, 'mainTerritory'),
          rulingArea: _vStrN(v, 'rulingArea'),
          powerLevel: _vInt(v, 'powerLevel'),
          influence: _vInt(v, 'influence'),
          status: _vStr(v, 'status', '稳定'),
          characteristics: _vStrN(v, 'characteristics'),
          culturalBackground: _vStrN(v, 'culturalBackground'),
          importance: _vInt(v, 'importance'),
          tags: _vStrN(v, 'tags'),
          notes: _vStrN(v, 'notes'),
          averageLifespan: _vIntN(v, 'averageLifespan'),
          birthRate: _vDblN(v, 'birthRate'),
          primaryLanguage: _vStrN(v, 'primaryLanguage'),
          primaryReligion: _vStrN(v, 'primaryReligion'),
          racialAbilities: _vStrN(v, 'racialAbilities'),
          racialWeaknesses: _vStrN(v, 'racialWeaknesses'),
        ),
      ),
      onDelete: svc.delete,
    );
  },
);

// ---------------------------------------------------------------------------
// 资源
// ---------------------------------------------------------------------------

Map<String, dynamic> _resourceToMap(dynamic r) => {
      'id': r.id,
      'name': r.name,
      'type': r.type,
      'location': r.location,
      'controllingFactionId': r.controllingFactionId,
      'rarity': r.rarity,
      'extractionDifficulty': r.extractionDifficulty,
      'economicValue': r.economicValue,
      'regenerationSpeed': r.regenerationSpeed,
      'status': r.status,
      'description': r.description,
      'extractionMethod': r.extractionMethod,
      'importance': r.importance,
      'tags': r.tags,
      'notes': r.notes,
      'currentReserves': r.currentReserves,
      'maxReserves': r.maxReserves,
      'annualOutput': r.annualOutput,
    };

final resourceEntityConfig = EntityPageConfig(
  titleZh: '资源管理',
  titleEn: 'Resources',
  itemNameZh: '资源',
  itemNameEn: 'Resource',
  nameField: 'name',
  summaryField: 'type',
  fields: [
    _text('name', '资源名称', 'Resource Name'),
    _sel('type', '资源类型', 'Resource Type',
        ['矿物', '灵材', '药材', '稀有金属', '能量', '其他'],
        ['Mineral', 'Spirit Material', 'Herb', 'Rare Metal', 'Energy', 'Other']),
    _text('location', '所在地', 'Location'),
    _text('controllingFactionId', '掌控势力ID', 'Controlling Faction ID'),
    _sel('rarity', '稀有度', 'Rarity',
        ['普通', '稀有', '史诗', '传说', '唯一'],
        ['Common', 'Rare', 'Epic', 'Legendary', 'Unique']),
    _num('extractionDifficulty', '开采难度', 'Extraction Difficulty'),
    _num('economicValue', '经济价值', 'Economic Value'),
    _text('regenerationSpeed', '再生速度', 'Regeneration Speed'),
    // Resources.status 表列默认值 '活跃'
    _selc('status', '状态', 'Status', PseudoEnums.resourceStatuses),
    _multi('description', '描述', 'Description'),
    _multi('extractionMethod', '开采方式', 'Extraction Method'),
    _num('importance', '重要度（1-10）', 'Importance (1-10)'),
    _text('tags', '标签', 'Tags'),
    _multi('notes', '备注', 'Notes'),
    _num('currentReserves', '当前储量', 'Current Reserves'),
    _num('maxReserves', '最大储量', 'Max Reserves'),
    _num('annualOutput', '年产量', 'Annual Output'),
  ],
  sourceBuilder: (ref) {
    final svc = ref.read(resourceServiceProvider);
    return CallbackEntityDataSource(
      onList: (pid) async =>
          (await svc.getByProjectId(pid)).map(_resourceToMap).toList(),
      onSearch: (pid, kw) async =>
          (await svc.search(pid, kw)).map(_resourceToMap).toList(),
      onCreate: (pid, v) => svc.create(
        ResourcesCompanion.insert(
          id: _entityId(v),
          projectId: pid,
          name: v['name'] as String? ?? '未命名',
          type: v['type'] as String? ?? '其他',
          location: _vStrN(v, 'location'),
          controllingFactionId: _vStrN(v, 'controllingFactionId'),
          rarity: _vStr(v, 'rarity', '普通'),
          extractionDifficulty: _vInt(v, 'extractionDifficulty'),
          economicValue: _vInt(v, 'economicValue'),
          regenerationSpeed: _vStr(v, 'regenerationSpeed'),
          status: _vStr(v, 'status', '活跃'),
          description: _vStrN(v, 'description'),
          extractionMethod: _vStrN(v, 'extractionMethod'),
          importance: _vInt(v, 'importance'),
          tags: _vStrN(v, 'tags'),
          notes: _vStrN(v, 'notes'),
          currentReserves: _vIntN(v, 'currentReserves'),
          maxReserves: _vIntN(v, 'maxReserves'),
          annualOutput: _vIntN(v, 'annualOutput'),
        ),
      ),
      onUpdate: (id, v) => svc.updateById(
        id,
        ResourcesCompanion(
          name: _vStr(v, 'name'),
          type: _vStr(v, 'type', '其他'),
          location: _vStrN(v, 'location'),
          controllingFactionId: _vStrN(v, 'controllingFactionId'),
          rarity: _vStr(v, 'rarity', '普通'),
          extractionDifficulty: _vInt(v, 'extractionDifficulty'),
          economicValue: _vInt(v, 'economicValue'),
          regenerationSpeed: _vStr(v, 'regenerationSpeed'),
          status: _vStr(v, 'status', '活跃'),
          description: _vStrN(v, 'description'),
          extractionMethod: _vStrN(v, 'extractionMethod'),
          importance: _vInt(v, 'importance'),
          tags: _vStrN(v, 'tags'),
          notes: _vStrN(v, 'notes'),
          currentReserves: _vIntN(v, 'currentReserves'),
          maxReserves: _vIntN(v, 'maxReserves'),
          annualOutput: _vIntN(v, 'annualOutput'),
        ),
      ),
      onDelete: svc.delete,
    );
  },
);

// ---------------------------------------------------------------------------
// 秘境
// ---------------------------------------------------------------------------

Map<String, dynamic> _secretRealmToMap(dynamic r) => {
      'id': r.id,
      'name': r.name,
      'type': r.type,
      'location': r.location,
      'discovererFactionId': r.discovererFactionId,
      'dangerLevel': r.dangerLevel,
      'capacityLimit': r.capacityLimit,
      'timeLimit': r.timeLimit,
      'recommendedCultivation': r.recommendedCultivation,
      'status': r.status,
      'explorationConditions': r.explorationConditions,
      'explorationRewards': r.explorationRewards,
      'description': r.description,
      'strategy': r.strategy,
      'importance': r.importance,
      'tags': r.tags,
      'notes': r.notes,
      'explorationCount': r.explorationCount,
      'successfulExplorationCount': r.successfulExplorationCount,
    };

final secretRealmEntityConfig = EntityPageConfig(
  titleZh: '秘境管理',
  titleEn: 'Secret Realms',
  itemNameZh: '秘境',
  itemNameEn: 'Secret Realm',
  nameField: 'name',
  summaryField: 'type',
  fields: [
    _text('name', '秘境名称', 'Realm Name'),
    _sel('type', '秘境类型', 'Realm Type',
        ['秘境', '洞天', '福地', '禁地', '遗迹', '其他'],
        ['Secret Realm', 'Cave Heaven', 'Blessed Land', 'Forbidden Zone', 'Ruins', 'Other']),
    _text('location', '所在地', 'Location'),
    _text('discovererFactionId', '发现势力ID', 'Discoverer Faction ID'),
    _num('dangerLevel', '危险等级', 'Danger Level'),
    _num('capacityLimit', '容纳上限', 'Capacity Limit'),
    _num('timeLimit', '时限', 'Time Limit'),
    _text('recommendedCultivation', '推荐修为', 'Recommended Cultivation'),
    // SecretRealms.status 表列默认值 '隐藏'
    _selc('status', '状态', 'Status', PseudoEnums.secretRealmStatuses),
    _multi('explorationConditions', '探索条件', 'Exploration Conditions'),
    _multi('explorationRewards', '探索奖励', 'Exploration Rewards'),
    _multi('description', '描述', 'Description'),
    _multi('strategy', '攻略', 'Strategy'),
    _num('importance', '重要度（1-10）', 'Importance (1-10)'),
    _text('tags', '标签', 'Tags'),
    _multi('notes', '备注', 'Notes'),
    _num('explorationCount', '探索次数', 'Exploration Count'),
    _num('successfulExplorationCount', '成功探索次数', 'Successful Count'),
  ],
  sourceBuilder: (ref) {
    final svc = ref.read(secretRealmServiceProvider);
    return CallbackEntityDataSource(
      onList: (pid) async =>
          (await svc.getByProjectId(pid)).map(_secretRealmToMap).toList(),
      onSearch: (pid, kw) async =>
          (await svc.search(pid, kw)).map(_secretRealmToMap).toList(),
      onCreate: (pid, v) => svc.create(
        SecretRealmsCompanion.insert(
          id: _entityId(v),
          projectId: pid,
          name: v['name'] as String? ?? '未命名',
          type: v['type'] as String? ?? '其他',
          location: _vStrN(v, 'location'),
          discovererFactionId: _vStrN(v, 'discovererFactionId'),
          dangerLevel: _vInt(v, 'dangerLevel'),
          capacityLimit: _vIntN(v, 'capacityLimit'),
          timeLimit: _vIntN(v, 'timeLimit'),
          recommendedCultivation: _vStrN(v, 'recommendedCultivation'),
          status: _vStr(v, 'status', '隐藏'),
          explorationConditions: _vStrN(v, 'explorationConditions'),
          explorationRewards: _vStrN(v, 'explorationRewards'),
          description: _vStrN(v, 'description'),
          strategy: _vStrN(v, 'strategy'),
          importance: _vInt(v, 'importance'),
          tags: _vStrN(v, 'tags'),
          notes: _vStrN(v, 'notes'),
          explorationCount: _vInt(v, 'explorationCount'),
          successfulExplorationCount: _vInt(v, 'successfulExplorationCount'),
        ),
      ),
      onUpdate: (id, v) => svc.updateById(
        id,
        SecretRealmsCompanion(
          name: _vStr(v, 'name'),
          type: _vStr(v, 'type', '其他'),
          location: _vStrN(v, 'location'),
          discovererFactionId: _vStrN(v, 'discovererFactionId'),
          dangerLevel: _vInt(v, 'dangerLevel'),
          capacityLimit: _vIntN(v, 'capacityLimit'),
          timeLimit: _vIntN(v, 'timeLimit'),
          recommendedCultivation: _vStrN(v, 'recommendedCultivation'),
          status: _vStr(v, 'status', '隐藏'),
          explorationConditions: _vStrN(v, 'explorationConditions'),
          explorationRewards: _vStrN(v, 'explorationRewards'),
          description: _vStrN(v, 'description'),
          strategy: _vStrN(v, 'strategy'),
          importance: _vInt(v, 'importance'),
          tags: _vStrN(v, 'tags'),
          notes: _vStrN(v, 'notes'),
          explorationCount: _vInt(v, 'explorationCount'),
          successfulExplorationCount: _vInt(v, 'successfulExplorationCount'),
        ),
      ),
      onDelete: svc.delete,
    );
  },
);

// ---------------------------------------------------------------------------
// 修炼体系
// ---------------------------------------------------------------------------

Map<String, dynamic> _cultivationSystemToMap(dynamic r) => {
      'id': r.id,
      'name': r.name,
      'type': r.type,
      'difficulty': r.difficulty,
      'maxLevel': r.maxLevel,
      'description': r.description,
      'cultivationMethod': r.cultivationMethod,
      'realmDivision': r.realmDivision,
      'breakthroughConditions': r.breakthroughConditions,
      'cultivationResources': r.cultivationResources,
      'characteristics': r.characteristics,
      'risks': r.risks,
      'importance': r.importance,
      'imagePath': r.imagePath,
      'tags': r.tags,
      'notes': r.notes,
      'status': r.status,
      'orderIndex': r.orderIndex,
    };

final cultivationSystemEntityConfig = EntityPageConfig(
  titleZh: '修炼体系管理',
  titleEn: 'Cultivation Systems',
  itemNameZh: '修炼体系',
  itemNameEn: 'Cultivation System',
  nameField: 'name',
  summaryField: 'type',
  fields: [
    _text('name', '体系名称', 'System Name'),
    _sel('type', '体系类型', 'System Type',
        ['修真', '修魔', '修妖', '武道', '体修', '其他'],
        ['Cultivation', 'Demon Cultivation', 'Demon Beast', 'Martial Arts', 'Body Refining', 'Other']),
    _num('difficulty', '修炼难度', 'Difficulty'),
    _num('maxLevel', '最高境界', 'Max Realm'),
    _multi('description', '描述', 'Description'),
    _multi('cultivationMethod', '修炼方法', 'Cultivation Method'),
    _multi('realmDivision', '境界划分', 'Realm Division'),
    _multi('breakthroughConditions', '突破条件', 'Breakthrough Conditions'),
    _multi('cultivationResources', '修炼资源', 'Cultivation Resources'),
    _multi('characteristics', '体系特点', 'System Traits'),
    _multi('risks', '风险', 'Risks'),
    _num('importance', '重要度（1-10）', 'Importance (1-10)'),
    _text('imagePath', '配图路径', 'Image Path'),
    _text('tags', '标签', 'Tags'),
    _multi('notes', '备注', 'Notes'),
    // CultivationSystems.status 表列默认值 'Active'
    _selc('status', '状态', 'Status', PseudoEnums.activeStatuses),
    _num('orderIndex', '排序序号', 'Order Index'),
  ],
  sourceBuilder: (ref) {
    final svc = ref.read(cultivationSystemServiceProvider);
    return CallbackEntityDataSource(
      onList: (pid) async =>
          (await svc.getByProjectId(pid)).map(_cultivationSystemToMap).toList(),
      onSearch: (pid, kw) async =>
          (await svc.search(pid, kw)).map(_cultivationSystemToMap).toList(),
      onCreate: (pid, v) => svc.create(
        CultivationSystemsCompanion.insert(
          id: _entityId(v),
          projectId: pid,
          name: v['name'] as String? ?? '未命名',
          type: v['type'] as String? ?? '其他',
          difficulty: _vInt(v, 'difficulty'),
          maxLevel: _vInt(v, 'maxLevel'),
          description: _vStrN(v, 'description'),
          cultivationMethod: _vStrN(v, 'cultivationMethod'),
          realmDivision: _vStrN(v, 'realmDivision'),
          breakthroughConditions: _vStrN(v, 'breakthroughConditions'),
          cultivationResources: _vStrN(v, 'cultivationResources'),
          characteristics: _vStrN(v, 'characteristics'),
          risks: _vStrN(v, 'risks'),
          importance: _vInt(v, 'importance'),
          imagePath: _vStrN(v, 'imagePath'),
          tags: _vStrN(v, 'tags'),
          notes: _vStrN(v, 'notes'),
          status: _vStr(v, 'status', 'Active'),
          orderIndex: _vInt(v, 'orderIndex'),
        ),
      ),
      onUpdate: (id, v) => svc.updateById(
        id,
        CultivationSystemsCompanion(
          name: _vStr(v, 'name'),
          type: _vStr(v, 'type', '其他'),
          difficulty: _vInt(v, 'difficulty'),
          maxLevel: _vInt(v, 'maxLevel'),
          description: _vStrN(v, 'description'),
          cultivationMethod: _vStrN(v, 'cultivationMethod'),
          realmDivision: _vStrN(v, 'realmDivision'),
          breakthroughConditions: _vStrN(v, 'breakthroughConditions'),
          cultivationResources: _vStrN(v, 'cultivationResources'),
          characteristics: _vStrN(v, 'characteristics'),
          risks: _vStrN(v, 'risks'),
          importance: _vInt(v, 'importance'),
          imagePath: _vStrN(v, 'imagePath'),
          tags: _vStrN(v, 'tags'),
          notes: _vStrN(v, 'notes'),
          status: _vStr(v, 'status', 'Active'),
          orderIndex: _vInt(v, 'orderIndex'),
        ),
      ),
      onDelete: svc.delete,
    );
  },
);

// ---------------------------------------------------------------------------
// 政治体系
// ---------------------------------------------------------------------------

Map<String, dynamic> _politicalSystemToMap(dynamic r) => {
      'id': r.id,
      'name': r.name,
      'type': r.type,
      'hierarchy': r.hierarchy,
      'stability': r.stability,
      'influence': r.influence,
      'description': r.description,
      'structure': r.structure,
      'powerDistribution': r.powerDistribution,
      'legalSystem': r.legalSystem,
      'electionSystem': r.electionSystem,
      'administrativeSystem': r.administrativeSystem,
      'militarySystem': r.militarySystem,
      'economicSystem': r.economicSystem,
      'socialHierarchy': r.socialHierarchy,
      'importance': r.importance,
      'imagePath': r.imagePath,
      'tags': r.tags,
      'notes': r.notes,
      'status': r.status,
      'orderIndex': r.orderIndex,
    };

final politicalSystemEntityConfig = EntityPageConfig(
  titleZh: '政治体系管理',
  titleEn: 'Political Systems',
  itemNameZh: '政治体系',
  itemNameEn: 'Political System',
  nameField: 'name',
  summaryField: 'type',
  fields: [
    _text('name', '体系名称', 'System Name'),
    _sel('type', '政体类型', 'Government Type',
        ['君主制', '共和制', '贵族制', '神权制', '部落制', '其他'],
        ['Monarchy', 'Republic', 'Aristocracy', 'Theocracy', 'Tribal', 'Other']),
    _multi('hierarchy', '阶层结构', 'Hierarchy Structure'),
    _num('stability', '稳定性', 'Stability'),
    _num('influence', '影响力', 'Influence'),
    _multi('description', '描述', 'Description'),
    _multi('structure', '权力结构', 'Power Structure'),
    _multi('powerDistribution', '权力分配', 'Power Distribution'),
    _multi('legalSystem', '法律体系', 'Legal System'),
    _multi('electionSystem', '选举制度', 'Election System'),
    _multi('administrativeSystem', '行政体系', 'Administrative System'),
    _multi('militarySystem', '军事体系', 'Military System'),
    _multi('economicSystem', '经济体系', 'Economic System'),
    _multi('socialHierarchy', '社会阶层', 'Social Hierarchy'),
    _num('importance', '重要度（1-10）', 'Importance (1-10)'),
    _text('imagePath', '配图路径', 'Image Path'),
    _text('tags', '标签', 'Tags'),
    _multi('notes', '备注', 'Notes'),
    // PoliticalSystems.status 表列默认值 'Active'
    _selc('status', '状态', 'Status', PseudoEnums.activeStatuses),
    _num('orderIndex', '排序序号', 'Order Index'),
  ],
  sourceBuilder: (ref) {
    final svc = ref.read(politicalSystemServiceProvider);
    return CallbackEntityDataSource(
      onList: (pid) async =>
          (await svc.getByProjectId(pid)).map(_politicalSystemToMap).toList(),
      onSearch: (pid, kw) async =>
          (await svc.search(pid, kw)).map(_politicalSystemToMap).toList(),
      onCreate: (pid, v) => svc.create(
        PoliticalSystemsCompanion.insert(
          id: _entityId(v),
          projectId: pid,
          name: v['name'] as String? ?? '未命名',
          type: v['type'] as String? ?? '其他',
          hierarchy: _vStrN(v, 'hierarchy'),
          stability: _vInt(v, 'stability'),
          influence: _vInt(v, 'influence'),
          description: _vStrN(v, 'description'),
          structure: _vStrN(v, 'structure'),
          powerDistribution: _vStrN(v, 'powerDistribution'),
          legalSystem: _vStrN(v, 'legalSystem'),
          electionSystem: _vStrN(v, 'electionSystem'),
          administrativeSystem: _vStrN(v, 'administrativeSystem'),
          militarySystem: _vStrN(v, 'militarySystem'),
          economicSystem: _vStrN(v, 'economicSystem'),
          socialHierarchy: _vStrN(v, 'socialHierarchy'),
          importance: _vInt(v, 'importance'),
          imagePath: _vStrN(v, 'imagePath'),
          tags: _vStrN(v, 'tags'),
          notes: _vStrN(v, 'notes'),
          status: _vStr(v, 'status', 'Active'),
          orderIndex: _vInt(v, 'orderIndex'),
        ),
      ),
      onUpdate: (id, v) => svc.updateById(
        id,
        PoliticalSystemsCompanion(
          name: _vStr(v, 'name'),
          type: _vStr(v, 'type', '其他'),
          hierarchy: _vStrN(v, 'hierarchy'),
          stability: _vInt(v, 'stability'),
          influence: _vInt(v, 'influence'),
          description: _vStrN(v, 'description'),
          structure: _vStrN(v, 'structure'),
          powerDistribution: _vStrN(v, 'powerDistribution'),
          legalSystem: _vStrN(v, 'legalSystem'),
          electionSystem: _vStrN(v, 'electionSystem'),
          administrativeSystem: _vStrN(v, 'administrativeSystem'),
          militarySystem: _vStrN(v, 'militarySystem'),
          economicSystem: _vStrN(v, 'economicSystem'),
          socialHierarchy: _vStrN(v, 'socialHierarchy'),
          importance: _vInt(v, 'importance'),
          imagePath: _vStrN(v, 'imagePath'),
          tags: _vStrN(v, 'tags'),
          notes: _vStrN(v, 'notes'),
          status: _vStr(v, 'status', 'Active'),
          orderIndex: _vInt(v, 'orderIndex'),
        ),
      ),
      onDelete: svc.delete,
    );
  },
);

// ---------------------------------------------------------------------------
// 货币体系
// ---------------------------------------------------------------------------

Map<String, dynamic> _currencySystemToMap(dynamic r) => {
      'id': r.id,
      'name': r.name,
      'monetarySystem': r.monetarySystem,
      'type': r.type,
      'status': r.status,
      'stability': r.stability,
      'baseValue': r.baseValue,
      'baseCurrency': r.baseCurrency,
      'currencyTypes': r.currencyTypes,
      'exchangeRates': r.exchangeRates,
      'issuingAuthority': r.issuingAuthority,
      'inflationRate': r.inflationRate,
      'interestRate': r.interestRate,
      'moneySupply': r.moneySupply,
      'exchangeRateVolatility': r.exchangeRateVolatility,
      'financialServices': r.financialServices,
      'description': r.description,
      'historicalBackground': r.historicalBackground,
      'importance': r.importance,
      'tags': r.tags,
      'notes': r.notes,
      'isActive': r.isActive,
      'usageScope': r.usageScope,
      'regulatoryAuthority': r.regulatoryAuthority,
      'legalFramework': r.legalFramework,
      'economicIndicators': r.economicIndicators,
      'riskAssessment': r.riskAssessment,
    };

final currencySystemEntityConfig = EntityPageConfig(
  titleZh: '货币体系管理',
  titleEn: 'Currency Systems',
  itemNameZh: '货币体系',
  itemNameEn: 'Currency System',
  nameField: 'name',
  summaryField: 'monetarySystem',
  fields: [
    _text('name', '体系名称', 'System Name'),
    _sel('monetarySystem', '货币制度', 'Monetary Standard',
        ['金银本位', '信用本位', '物物交换', '灵石本位', '其他'],
        ['Gold-Silver Standard', 'Fiat Standard', 'Barter', 'Spirit Stone Standard', 'Other']),
    _text('type', '类型', 'Type'),
    // CurrencySystems.status 表列默认值 'Active'
    _selc('status', '状态', 'Status', PseudoEnums.activeStatuses),
    _num('stability', '稳定性', 'Stability'),
    _num('baseValue', '基准价值', 'Base Value'),
    _text('baseCurrency', '基准货币', 'Base Currency'),
    _multi('currencyTypes', '货币种类', 'Currency Types'),
    _multi('exchangeRates', '汇率', 'Exchange Rates'),
    _text('issuingAuthority', '发行机构', 'Issuing Authority'),
    _num('inflationRate', '通胀率', 'Inflation Rate'),
    _num('interestRate', '利率', 'Interest Rate'),
    _num('moneySupply', '货币供应量', 'Money Supply'),
    _num('exchangeRateVolatility', '汇率波动率', 'Exchange Rate Volatility'),
    _multi('financialServices', '金融服务', 'Financial Services'),
    _multi('description', '描述', 'Description'),
    _multi('historicalBackground', '历史背景', 'Historical Background'),
    _num('importance', '重要度（1-10）', 'Importance (1-10)'),
    _text('tags', '标签', 'Tags'),
    _multi('notes', '备注', 'Notes'),
    _bool('isActive', '是否流通', 'Is Active'),
    _multi('usageScope', '使用范围', 'Usage Scope'),
    _text('regulatoryAuthority', '监管机构', 'Regulatory Authority'),
    _multi('legalFramework', '法律框架', 'Legal Framework'),
    _multi('economicIndicators', '经济指标', 'Economic Indicators'),
    _multi('riskAssessment', '风险评估', 'Risk Assessment'),
  ],
  sourceBuilder: (ref) {
    final svc = ref.read(currencySystemServiceProvider);
    return CallbackEntityDataSource(
      onList: (pid) async =>
          (await svc.getByProjectId(pid)).map(_currencySystemToMap).toList(),
      onSearch: (pid, kw) async =>
          (await svc.search(pid, kw)).map(_currencySystemToMap).toList(),
      onCreate: (pid, v) => svc.create(
        CurrencySystemsCompanion.insert(
          id: _entityId(v),
          projectId: pid,
          name: v['name'] as String? ?? '未命名',
          monetarySystem: v['monetarySystem'] as String? ?? '金银本位',
          type: _vStrN(v, 'type'),
          status: _vStr(v, 'status', 'Active'),
          stability: _vInt(v, 'stability'),
          baseValue: _vDbl(v, 'baseValue'),
          baseCurrency: _vStrN(v, 'baseCurrency'),
          currencyTypes: _vStrN(v, 'currencyTypes'),
          exchangeRates: _vStrN(v, 'exchangeRates'),
          issuingAuthority: _vStrN(v, 'issuingAuthority'),
          inflationRate: _vDblN(v, 'inflationRate'),
          interestRate: _vDblN(v, 'interestRate'),
          moneySupply: _vIntN(v, 'moneySupply'),
          exchangeRateVolatility: _vDblN(v, 'exchangeRateVolatility'),
          financialServices: _vStrN(v, 'financialServices'),
          description: _vStrN(v, 'description'),
          historicalBackground: _vStrN(v, 'historicalBackground'),
          importance: _vInt(v, 'importance'),
          tags: _vStrN(v, 'tags'),
          notes: _vStrN(v, 'notes'),
          isActive: _vBool(v, 'isActive'),
          usageScope: _vStrN(v, 'usageScope'),
          regulatoryAuthority: _vStrN(v, 'regulatoryAuthority'),
          legalFramework: _vStrN(v, 'legalFramework'),
          economicIndicators: _vStrN(v, 'economicIndicators'),
          riskAssessment: _vStrN(v, 'riskAssessment'),
        ),
      ),
      onUpdate: (id, v) => svc.updateById(
        id,
        CurrencySystemsCompanion(
          name: _vStr(v, 'name'),
          monetarySystem: _vStr(v, 'monetarySystem', '金银本位'),
          type: _vStrN(v, 'type'),
          status: _vStr(v, 'status', 'Active'),
          stability: _vInt(v, 'stability'),
          baseValue: _vDbl(v, 'baseValue'),
          baseCurrency: _vStrN(v, 'baseCurrency'),
          currencyTypes: _vStrN(v, 'currencyTypes'),
          exchangeRates: _vStrN(v, 'exchangeRates'),
          issuingAuthority: _vStrN(v, 'issuingAuthority'),
          inflationRate: _vDblN(v, 'inflationRate'),
          interestRate: _vDblN(v, 'interestRate'),
          moneySupply: _vIntN(v, 'moneySupply'),
          exchangeRateVolatility: _vDblN(v, 'exchangeRateVolatility'),
          financialServices: _vStrN(v, 'financialServices'),
          description: _vStrN(v, 'description'),
          historicalBackground: _vStrN(v, 'historicalBackground'),
          importance: _vInt(v, 'importance'),
          tags: _vStrN(v, 'tags'),
          notes: _vStrN(v, 'notes'),
          isActive: _vBool(v, 'isActive'),
          usageScope: _vStrN(v, 'usageScope'),
          regulatoryAuthority: _vStrN(v, 'regulatoryAuthority'),
          legalFramework: _vStrN(v, 'legalFramework'),
          economicIndicators: _vStrN(v, 'economicIndicators'),
          riskAssessment: _vStrN(v, 'riskAssessment'),
        ),
      ),
      onDelete: svc.delete,
    );
  },
);

// ---------------------------------------------------------------------------
// 人物关系网络
// ---------------------------------------------------------------------------

Map<String, dynamic> _relationshipNetworkToMap(dynamic r) => {
      'id': r.id,
      'name': r.name,
      'type': r.type,
      'description': r.description,
      'centralCharacterId': r.centralCharacterId,
      'complexity': r.complexity,
      'stability': r.stability,
      'influence': r.influence,
      'status': r.status,
      'keyEvents': r.keyEvents,
      'developmentHistory': r.developmentHistory,
      'networkRules': r.networkRules,
      'importance': r.importance,
      'tags': r.tags,
      'notes': r.notes,
      'isPublic': r.isPublic,
      'hierarchyLevel': r.hierarchyLevel,
      'memberCount': r.memberCount,
      'relationshipCount': r.relationshipCount,
      'networkDensity': r.networkDensity,
    };

final relationshipNetworkEntityConfig = EntityPageConfig(
  titleZh: '关系网络管理',
  titleEn: 'Relationship Networks',
  itemNameZh: '关系网络',
  itemNameEn: 'Network',
  nameField: 'name',
  summaryField: 'type',
  fields: [
    _text('name', '网络名称', 'Network Name'),
    _sel('type', '网络类型', 'Network Type',
        ['家族', '师门', '阵营', '利益集团', '情报网', '其他'],
        ['Family', 'Sect', 'Faction', 'Interest Group', 'Intelligence Network', 'Other']),
    _multi('description', '描述', 'Description'),
    _text('centralCharacterId', '核心角色ID', 'Central Character ID'),
    _num('complexity', '复杂度', 'Complexity'),
    _num('stability', '稳定性', 'Stability'),
    _num('influence', '影响力', 'Influence'),
    // RelationshipNetworks.status 表列默认值 '活跃'
    _selc('status', '状态', 'Status', PseudoEnums.networkStatuses),
    _multi('keyEvents', '关键事件', 'Key Events'),
    _multi('developmentHistory', '发展历程', 'Development History'),
    _multi('networkRules', '网络规则', 'Network Rules'),
    _num('importance', '重要度（1-10）', 'Importance (1-10)'),
    _text('tags', '标签', 'Tags'),
    _multi('notes', '备注', 'Notes'),
    _bool('isPublic', '是否公开', 'Is Public'),
    _num('hierarchyLevel', '层级数', 'Hierarchy Levels'),
    _num('memberCount', '成员数', 'Member Count'),
    _num('relationshipCount', '关系数', 'Relationship Count'),
    _num('networkDensity', '网络密度', 'Network Density'),
  ],
  sourceBuilder: (ref) {
    final svc = ref.read(relationshipNetworkServiceProvider);
    return CallbackEntityDataSource(
      onList: (pid) async => (await svc.getByProjectId(pid))
          .map(_relationshipNetworkToMap)
          .toList(),
      onSearch: (pid, kw) async => (await svc.search(pid, kw))
          .map(_relationshipNetworkToMap)
          .toList(),
      onCreate: (pid, v) => svc.create(
        RelationshipNetworksCompanion.insert(
          id: _entityId(v),
          projectId: pid,
          name: v['name'] as String? ?? '未命名',
          type: v['type'] as String? ?? '其他',
          description: _vStrN(v, 'description'),
          centralCharacterId: _vStrN(v, 'centralCharacterId'),
          complexity: _vInt(v, 'complexity'),
          stability: _vInt(v, 'stability'),
          influence: _vInt(v, 'influence'),
          status: _vStr(v, 'status', '活跃'),
          keyEvents: _vStrN(v, 'keyEvents'),
          developmentHistory: _vStrN(v, 'developmentHistory'),
          networkRules: _vStrN(v, 'networkRules'),
          importance: _vInt(v, 'importance'),
          tags: _vStrN(v, 'tags'),
          notes: _vStrN(v, 'notes'),
          isPublic: _vBool(v, 'isPublic'),
          hierarchyLevel: _vIntN(v, 'hierarchyLevel'),
          memberCount: _vInt(v, 'memberCount'),
          relationshipCount: _vInt(v, 'relationshipCount'),
          networkDensity: _vDblN(v, 'networkDensity'),
        ),
      ),
      onUpdate: (id, v) => svc.updateById(
        id,
        RelationshipNetworksCompanion(
          name: _vStr(v, 'name'),
          type: _vStr(v, 'type', '其他'),
          description: _vStrN(v, 'description'),
          centralCharacterId: _vStrN(v, 'centralCharacterId'),
          complexity: _vInt(v, 'complexity'),
          stability: _vInt(v, 'stability'),
          influence: _vInt(v, 'influence'),
          status: _vStr(v, 'status', '活跃'),
          keyEvents: _vStrN(v, 'keyEvents'),
          developmentHistory: _vStrN(v, 'developmentHistory'),
          networkRules: _vStrN(v, 'networkRules'),
          importance: _vInt(v, 'importance'),
          tags: _vStrN(v, 'tags'),
          notes: _vStrN(v, 'notes'),
          isPublic: _vBool(v, 'isPublic'),
          hierarchyLevel: _vIntN(v, 'hierarchyLevel'),
          memberCount: _vInt(v, 'memberCount'),
          relationshipCount: _vInt(v, 'relationshipCount'),
          networkDensity: _vDblN(v, 'networkDensity'),
        ),
      ),
      onDelete: svc.delete,
    );
  },
);

// ---------------------------------------------------------------------------
// 时间线事件
// ---------------------------------------------------------------------------

Map<String, dynamic> _timelineEventToMap(dynamic r) => {
      'id': r.id,
      'title': r.title,
      'category': r.category,
      'eventDate': r.eventDate,
      'location': r.location,
      'importance': r.importance,
      'status': r.status,
      'description': r.description,
      'impact': r.impact,
      'displayOrder': r.displayOrder,
      'chapterId': r.chapterId,
      'plotId': r.plotId,
      'tags': r.tags,
    };

final timelineEventEntityConfig = EntityPageConfig(
  titleZh: '时间线事件管理',
  titleEn: 'Timeline Events',
  itemNameZh: '时间线事件',
  itemNameEn: 'Event',
  nameField: 'title',
  summaryField: 'category',
  fields: [
    _text('title', '事件标题', 'Event Title'),
    _text('eventDate', '事件日期 (YYYY-MM-DD HH:mm)', 'Event Date (YYYY-MM-DD HH:mm)'),
    _text('category', '分类', 'Category'),
    _text('location', '地点', 'Location'),
    _text('importance', '重要度', 'Importance'),
    // TimelineEvents.status 无表列默认值，但统一走词典避免各页自造词表
    _selc('status', '状态', 'Status', PseudoEnums.timelineStatuses),
    _multi('description', '描述', 'Description'),
    _multi('impact', '影响', 'Impact'),
    _num('displayOrder', '显示顺序', 'Display Order'),
    _text('chapterId', '章节ID', 'Chapter ID'),
    _text('plotId', '剧情ID', 'Plot ID'),
    _text('tags', '标签', 'Tags'),
  ],
  sourceBuilder: (ref) {
    final svc = ref.read(timelineEventServiceProvider);
    return CallbackEntityDataSource(
      onList: (pid) async =>
          (await svc.getByProjectId(pid)).map(_timelineEventToMap).toList(),
      onSearch: (pid, kw) async =>
          (await svc.search(pid, kw)).map(_timelineEventToMap).toList(),
      onCreate: (pid, v) => svc.create(
        TimelineEventsCompanion.insert(
          id: _entityId(v),
          projectId: pid,
          title: v['title'] as String? ?? '未命名事件',
          eventDate: _date(v, 'eventDate'),
          category: _vStrN(v, 'category'),
          location: _vStrN(v, 'location'),
          importance: _vStrN(v, 'importance'),
          status: _vStrN(v, 'status'),
          description: _vStrN(v, 'description'),
          impact: _vStrN(v, 'impact'),
          displayOrder: _vInt(v, 'displayOrder'),
          chapterId: _vStrN(v, 'chapterId'),
          plotId: _vStrN(v, 'plotId'),
          tags: _vStrN(v, 'tags'),
        ),
      ),
      onUpdate: (id, v) {
        final dt = DateTime.tryParse(v['eventDate'] as String? ?? '');
        return svc.updateById(
          id,
          TimelineEventsCompanion(
            title: _vStr(v, 'title'),
            eventDate: dt == null ? const d.Value.absent() : d.Value(dt),
            category: _vStrN(v, 'category'),
            location: _vStrN(v, 'location'),
            importance: _vStrN(v, 'importance'),
            status: _vStrN(v, 'status'),
            description: _vStrN(v, 'description'),
            impact: _vStrN(v, 'impact'),
            displayOrder: _vInt(v, 'displayOrder'),
            chapterId: _vStrN(v, 'chapterId'),
            plotId: _vStrN(v, 'plotId'),
            tags: _vStrN(v, 'tags'),
          ),
        );
      },
      onDelete: svc.delete,
    );
  },
);

// ---------------------------------------------------------------------------
// 角色履历事件（子实体，无 projectId，按 getAll 聚合）
// ---------------------------------------------------------------------------

Map<String, dynamic> _characterEventToMap(dynamic r) => {
      'id': r.id,
      'characterId': r.characterId,
      'title': r.title,
      'description': r.description,
      'eventType': r.eventType,
      'storyTime': r.storyTime,
      'orderIndex': r.orderIndex,
      'chapterId': r.chapterId,
      'plotId': r.plotId,
      'impact': r.impact,
      'involvedCharacterIds': r.involvedCharacterIds,
      'tags': r.tags,
    };

final characterEventEntityConfig = EntityPageConfig(
  titleZh: '角色事件管理',
  titleEn: 'Character Events',
  itemNameZh: '角色事件',
  itemNameEn: 'Event',
  nameField: 'title',
  summaryField: 'eventType',
  fields: [
    _text('characterId', '角色ID', 'Character ID'),
    _text('title', '事件标题', 'Event Title'),
    _multi('description', '描述', 'Description'),
    _sel('eventType', '事件类型', 'Event Type',
        ['出生', '转折', '战斗', '奇遇', '情感', '死亡', '其他'],
        ['Birth', 'Turning Point', 'Battle', 'Adventure', 'Romance', 'Death', 'Other']),
    _text('storyTime', '故事时间', 'Story Time'),
    _num('orderIndex', '顺序', 'Order'),
    _text('chapterId', '章节ID', 'Chapter ID'),
    _text('plotId', '剧情ID', 'Plot ID'),
    _multi('impact', '影响', 'Impact'),
    _text('involvedCharacterIds', '涉及角色ID', 'Involved Character IDs'),
    _text('tags', '标签', 'Tags'),
  ],
  sourceBuilder: (ref) {
    final svc = ref.read(characterEventServiceProvider);
    return CallbackEntityDataSource(
      onList: (_) async =>
          (await svc.getAll()).map(_characterEventToMap).toList(),
      onSearch: (_, kw) async => _kwFilter(
        (await svc.getAll()).map(_characterEventToMap).toList(),
        kw,
      ),
      onCreate: (_, v) => svc.create(
        CharacterEventsCompanion.insert(
          id: _entityId(v),
          characterId: v['characterId'] as String? ?? '',
          title: v['title'] as String? ?? '未命名事件',
          description: _vStrN(v, 'description'),
          eventType: _vStr(v, 'eventType', '其他'),
          storyTime: _vStrN(v, 'storyTime'),
          orderIndex: _vInt(v, 'orderIndex'),
          chapterId: _vStrN(v, 'chapterId'),
          plotId: _vStrN(v, 'plotId'),
          impact: _vStrN(v, 'impact'),
          involvedCharacterIds: _vStrN(v, 'involvedCharacterIds'),
          tags: _vStrN(v, 'tags'),
        ),
      ),
      onUpdate: (id, v) => svc.updateById(
        id,
        CharacterEventsCompanion(
          characterId: _vStr(v, 'characterId'),
          title: _vStr(v, 'title'),
          description: _vStrN(v, 'description'),
          eventType: _vStr(v, 'eventType', '其他'),
          storyTime: _vStrN(v, 'storyTime'),
          orderIndex: _vInt(v, 'orderIndex'),
          chapterId: _vStrN(v, 'chapterId'),
          plotId: _vStrN(v, 'plotId'),
          impact: _vStrN(v, 'impact'),
          involvedCharacterIds: _vStrN(v, 'involvedCharacterIds'),
          tags: _vStrN(v, 'tags'),
        ),
      ),
      onDelete: svc.delete,
    );
  },
);

// ---------------------------------------------------------------------------
// 人物关系（源/目标角色 + 关系类型均为必填外键）
// ---------------------------------------------------------------------------

Map<String, dynamic> _characterRelationshipToMap(dynamic r) => {
      'id': r.id,
      'sourceCharacterId': r.sourceCharacterId,
      'targetCharacterId': r.targetCharacterId,
      'relationshipType': r.relationshipType,
      'intensity': r.intensity,
      'status': r.status,
      'relationshipName': r.relationshipName,
      'description': r.description,
      'developmentHistory': r.developmentHistory,
      'keyEvents': r.keyEvents,
      'impact': r.impact,
      'tags': r.tags,
      'notes': r.notes,
      'isBidirectional': r.isBidirectional,
      'importance': r.importance,
      'relationshipNetworkId': r.relationshipNetworkId,
    };

final characterRelationshipEntityConfig = EntityPageConfig(
  titleZh: '人物关系管理',
  titleEn: 'Character Relationships',
  itemNameZh: '人物关系',
  itemNameEn: 'Relationship',
  nameField: 'relationshipName',
  summaryField: 'relationshipType',
  fields: [
    _text('sourceCharacterId', '源角色ID', 'Source Character ID'),
    _text('targetCharacterId', '目标角色ID', 'Target Character ID'),
    _sel('relationshipType', '关系类型', 'Relationship Type',
        ['师徒', '父子', '母女', '夫妻', '情侣', '仇敌', '挚友', '上下级', '其他'],
        ['Master-Apprentice', 'Father-Son', 'Mother-Daughter', 'Spouses', 'Lovers', 'Enemy', 'Close Friend', 'Superior-Subordinate', 'Other']),
    _num('intensity', '亲密度', 'Intimacy'),
    // CharacterRelationships.status 表列默认值 'Active'
    _selc('status', '状态', 'Status', PseudoEnums.activeStatuses),
    _text('relationshipName', '关系称谓', 'Relationship Label'),
    _multi('description', '描述', 'Description'),
    _multi('developmentHistory', '发展历史', 'Development History'),
    _multi('keyEvents', '关键事件', 'Key Events'),
    _multi('impact', '影响', 'Impact'),
    _text('tags', '标签', 'Tags'),
    _multi('notes', '备注', 'Notes'),
    _bool('isBidirectional', '是否双向', 'Is Bidirectional'),
    _num('importance', '重要度（1-10）', 'Importance (1-10)'),
    _text('relationshipNetworkId', '关系网络ID', 'Network ID'),
  ],
  sourceBuilder: (ref) {
    final svc = ref.read(characterRelationshipServiceProvider);
    return CallbackEntityDataSource(
      onList: (pid) async => (await svc.getByProjectId(pid))
          .map(_characterRelationshipToMap)
          .toList(),
      onSearch: (pid, kw) async => (await svc.search(pid, kw))
          .map(_characterRelationshipToMap)
          .toList(),
      onCreate: (pid, v) => svc.create(
        CharacterRelationshipsCompanion.insert(
          id: _entityId(v),
          sourceCharacterId: v['sourceCharacterId'] as String? ?? '',
          targetCharacterId: v['targetCharacterId'] as String? ?? '',
          relationshipType: v['relationshipType'] as String? ?? '其他',
          intensity: _vInt(v, 'intensity'),
          status: _vStr(v, 'status', 'Active'),
          relationshipName: _vStrN(v, 'relationshipName'),
          description: _vStrN(v, 'description'),
          developmentHistory: _vStrN(v, 'developmentHistory'),
          keyEvents: _vStrN(v, 'keyEvents'),
          impact: _vStrN(v, 'impact'),
          tags: _vStrN(v, 'tags'),
          notes: _vStrN(v, 'notes'),
          isBidirectional: _vBool(v, 'isBidirectional'),
          importance: _vInt(v, 'importance'),
          relationshipNetworkId: _vStrN(v, 'relationshipNetworkId'),
          projectId: d.Value<String?>(pid),
        ),
      ),
      onUpdate: (id, v) => svc.updateById(
        id,
        CharacterRelationshipsCompanion(
          sourceCharacterId: _vStr(v, 'sourceCharacterId'),
          targetCharacterId: _vStr(v, 'targetCharacterId'),
          relationshipType: _vStr(v, 'relationshipType', '其他'),
          intensity: _vInt(v, 'intensity'),
          status: _vStr(v, 'status', 'Active'),
          relationshipName: _vStrN(v, 'relationshipName'),
          description: _vStrN(v, 'description'),
          developmentHistory: _vStrN(v, 'developmentHistory'),
          keyEvents: _vStrN(v, 'keyEvents'),
          impact: _vStrN(v, 'impact'),
          tags: _vStrN(v, 'tags'),
          notes: _vStrN(v, 'notes'),
          isBidirectional: _vBool(v, 'isBidirectional'),
          importance: _vInt(v, 'importance'),
          relationshipNetworkId: _vStrN(v, 'relationshipNetworkId'),
        ),
      ),
      onDelete: svc.delete,
    );
  },
);

// ---------------------------------------------------------------------------
// 势力关系（源/目标势力 + 关系类型均为必填外键）
// ---------------------------------------------------------------------------

Map<String, dynamic> _factionRelationshipToMap(dynamic r) => {
      'id': r.id,
      'sourceFactionId': r.sourceFactionId,
      'targetFactionId': r.targetFactionId,
      'relationshipType': r.relationshipType,
      'intensity': r.intensity,
      'status': r.status,
      'relationshipName': r.relationshipName,
      'description': r.description,
      'developmentHistory': r.developmentHistory,
      'keyEvents': r.keyEvents,
      'impact': r.impact,
      'tags': r.tags,
      'notes': r.notes,
      'isBidirectional': r.isBidirectional,
      'importance': r.importance,
      'militaryComparison': r.militaryComparison,
      'economicRelations': r.economicRelations,
    };

final factionRelationshipEntityConfig = EntityPageConfig(
  titleZh: '势力关系管理',
  titleEn: 'Faction Relationships',
  itemNameZh: '势力关系',
  itemNameEn: 'Relationship',
  nameField: 'relationshipName',
  summaryField: 'relationshipType',
  fields: [
    _text('sourceFactionId', '源势力ID', 'Source Faction ID'),
    _text('targetFactionId', '目标势力ID', 'Target Faction ID'),
    _sel('relationshipType', '关系类型', 'Relationship Type',
        ['盟友', '敌对', '附庸', '贸易', '中立', '未知'],
        ['Ally', 'Hostile', 'Vassal', 'Trade', 'Neutral', 'Unknown']),
    _num('intensity', '紧密度', 'Closeness'),
    // FactionRelationships.status 表列默认值 'Active'
    _selc('status', '状态', 'Status', PseudoEnums.activeStatuses),
    _text('relationshipName', '关系称谓', 'Relationship Label'),
    _multi('description', '描述', 'Description'),
    _multi('developmentHistory', '发展历史', 'Development History'),
    _multi('keyEvents', '关键事件', 'Key Events'),
    _multi('impact', '影响', 'Impact'),
    _text('tags', '标签', 'Tags'),
    _multi('notes', '备注', 'Notes'),
    _bool('isBidirectional', '是否双向', 'Is Bidirectional'),
    _num('importance', '重要度（1-10）', 'Importance (1-10)'),
    _multi('militaryComparison', '军力对比', 'Military Comparison'),
    _multi('economicRelations', '经济往来', 'Economic Relations'),
  ],
  sourceBuilder: (ref) {
    final svc = ref.read(factionRelationshipServiceProvider);
    return CallbackEntityDataSource(
      onList: (pid) async => (await svc.getByProjectId(pid))
          .map(_factionRelationshipToMap)
          .toList(),
      onSearch: (pid, kw) async => (await svc.search(pid, kw))
          .map(_factionRelationshipToMap)
          .toList(),
      onCreate: (pid, v) => svc.create(
        FactionRelationshipsCompanion.insert(
          id: _entityId(v),
          sourceFactionId: v['sourceFactionId'] as String? ?? '',
          targetFactionId: v['targetFactionId'] as String? ?? '',
          relationshipType: v['relationshipType'] as String? ?? '中立',
          intensity: _vInt(v, 'intensity'),
          status: _vStr(v, 'status', 'Active'),
          relationshipName: _vStrN(v, 'relationshipName'),
          description: _vStrN(v, 'description'),
          developmentHistory: _vStrN(v, 'developmentHistory'),
          keyEvents: _vStrN(v, 'keyEvents'),
          impact: _vStrN(v, 'impact'),
          tags: _vStrN(v, 'tags'),
          notes: _vStrN(v, 'notes'),
          isBidirectional: _vBool(v, 'isBidirectional'),
          importance: _vInt(v, 'importance'),
          militaryComparison: _vStrN(v, 'militaryComparison'),
          economicRelations: _vStrN(v, 'economicRelations'),
          projectId: d.Value<String?>(pid),
        ),
      ),
      onUpdate: (id, v) => svc.updateById(
        id,
        FactionRelationshipsCompanion(
          sourceFactionId: _vStr(v, 'sourceFactionId'),
          targetFactionId: _vStr(v, 'targetFactionId'),
          relationshipType: _vStr(v, 'relationshipType', '其他'),
          intensity: _vInt(v, 'intensity'),
          status: _vStr(v, 'status', 'Active'),
          relationshipName: _vStrN(v, 'relationshipName'),
          description: _vStrN(v, 'description'),
          developmentHistory: _vStrN(v, 'developmentHistory'),
          keyEvents: _vStrN(v, 'keyEvents'),
          impact: _vStrN(v, 'impact'),
          tags: _vStrN(v, 'tags'),
          notes: _vStrN(v, 'notes'),
          isBidirectional: _vBool(v, 'isBidirectional'),
          importance: _vInt(v, 'importance'),
          militaryComparison: _vStrN(v, 'militaryComparison'),
          economicRelations: _vStrN(v, 'economicRelations'),
        ),
      ),
      onDelete: svc.delete,
    );
  },
);

// ---------------------------------------------------------------------------
// 种族关系（源/目标种族 + 关系类型均为必填外键）
// ---------------------------------------------------------------------------

Map<String, dynamic> _raceRelationshipToMap(dynamic r) => {
      'id': r.id,
      'sourceRaceId': r.sourceRaceId,
      'targetRaceId': r.targetRaceId,
      'relationshipType': r.relationshipType,
      'strength': r.strength,
      'status': r.status,
      'description': r.description,
      'history': r.history,
      'keyEvents': r.keyEvents,
      'importance': r.importance,
      'tags': r.tags,
      'notes': r.notes,
      'isPublic': r.isPublic,
      'isMutual': r.isMutual,
    };

final raceRelationshipEntityConfig = EntityPageConfig(
  titleZh: '种族关系管理',
  titleEn: 'Race Relationships',
  itemNameZh: '种族关系',
  itemNameEn: 'Relationship',
  nameField: 'relationshipType',
  summaryField: 'status',
  fields: [
    _text('sourceRaceId', '源种族ID', 'Source Race ID'),
    _text('targetRaceId', '目标种族ID', 'Target Race ID'),
    _sel('relationshipType', '关系类型', 'Relationship Type',
        ['盟友', '敌对', '臣服', '贸易', '中立', '未知'],
        ['Ally', 'Hostile', 'Subjugated', 'Trade', 'Neutral', 'Unknown']),
    _num('strength', '关系强度', 'Strength'),
    // RaceRelationships.status 表列默认值 '稳定'
    _selc('status', '状态', 'Status', PseudoEnums.raceRelationshipStatuses),
    _multi('description', '描述', 'Description'),
    _multi('history', '历史', 'History'),
    _multi('keyEvents', '关键事件', 'Key Events'),
    _num('importance', '重要度（1-10）', 'Importance (1-10)'),
    _text('tags', '标签', 'Tags'),
    _multi('notes', '备注', 'Notes'),
    _bool('isPublic', '是否公开', 'Is Public'),
    _bool('isMutual', '是否互信', 'Is Mutual'),
  ],
  sourceBuilder: (ref) {
    final svc = ref.read(raceRelationshipServiceProvider);
    return CallbackEntityDataSource(
      onList: (pid) async => (await svc.getByProjectId(pid))
          .map(_raceRelationshipToMap)
          .toList(),
      onSearch: (pid, kw) async => (await svc.search(pid, kw))
          .map(_raceRelationshipToMap)
          .toList(),
      onCreate: (pid, v) => svc.create(
        RaceRelationshipsCompanion.insert(
          id: _entityId(v),
          sourceRaceId: v['sourceRaceId'] as String? ?? '',
          targetRaceId: v['targetRaceId'] as String? ?? '',
          relationshipType: v['relationshipType'] as String? ?? '其他',
          strength: _vInt(v, 'strength'),
          status: _vStr(v, 'status', '稳定'),
          description: _vStrN(v, 'description'),
          history: _vStrN(v, 'history'),
          keyEvents: _vStrN(v, 'keyEvents'),
          projectId: pid,
          importance: _vInt(v, 'importance'),
          tags: _vStrN(v, 'tags'),
          notes: _vStrN(v, 'notes'),
          isPublic: _vBool(v, 'isPublic'),
          isMutual: _vBool(v, 'isMutual'),
        ),
      ),
      onUpdate: (id, v) => svc.updateById(
        id,
        RaceRelationshipsCompanion(
          sourceRaceId: _vStr(v, 'sourceRaceId'),
          targetRaceId: _vStr(v, 'targetRaceId'),
          relationshipType: _vStr(v, 'relationshipType', '其他'),
          strength: _vInt(v, 'strength'),
          status: _vStr(v, 'status', '稳定'),
          description: _vStrN(v, 'description'),
          history: _vStrN(v, 'history'),
          keyEvents: _vStrN(v, 'keyEvents'),
          importance: _vInt(v, 'importance'),
          tags: _vStrN(v, 'tags'),
          notes: _vStrN(v, 'notes'),
          isPublic: _vBool(v, 'isPublic'),
          isMutual: _vBool(v, 'isMutual'),
        ),
      ),
      onDelete: svc.delete,
    );
  },
);

// ---------------------------------------------------------------------------
// 修炼等级（子实体，归属修炼体系，无 projectId）
// ---------------------------------------------------------------------------

Map<String, dynamic> _cultivationLevelToMap(dynamic r) => {
      'id': r.id,
      'name': r.name,
      'cultivationSystemId': r.cultivationSystemId,
      'orderIndex': r.orderIndex,
      'description': r.description,
      'breakthroughCondition': r.breakthroughCondition,
      'abilities': r.abilities,
      'cultivationTime': r.cultivationTime,
      'tags': r.tags,
      'notes': r.notes,
    };

final cultivationLevelEntityConfig = EntityPageConfig(
  titleZh: '修炼等级管理',
  titleEn: 'Cultivation Levels',
  itemNameZh: '修炼等级',
  itemNameEn: 'Level',
  nameField: 'name',
  summaryField: 'cultivationSystemId',
  fields: [
    _text('name', '等级名称', 'Level Name'),
    _text('cultivationSystemId', '修炼体系ID', 'Cultivation System ID'),
    _num('orderIndex', '排序序号', 'Order Index'),
    _multi('description', '描述', 'Description'),
    _multi('breakthroughCondition', '突破条件', 'Breakthrough Condition'),
    _multi('abilities', '获得能力', 'Abilities Gained'),
    _text('cultivationTime', '修炼耗时', 'Cultivation Time'),
    _text('tags', '标签', 'Tags'),
    _multi('notes', '备注', 'Notes'),
  ],
  sourceBuilder: (ref) {
    final svc = ref.read(cultivationLevelServiceProvider);
    final systems = ref.read(cultivationSystemServiceProvider);

    Future<List<Map<String, dynamic>>> listForProject(String projectId) async {
      final systemIds = (await systems.getByProjectId(projectId))
          .map((system) => system.id)
          .toSet();
      return (await svc.getAll())
          .where((level) => systemIds.contains(level.cultivationSystemId))
          .map(_cultivationLevelToMap)
          .toList();
    }

    return CallbackEntityDataSource(
      // 等级表本身没有 projectId，必须通过所属体系反查，避免项目 A
      // 的设定出现在项目 B 的导出与实体页中。
      onList: listForProject,
      onSearch: (pid, kw) async => _kwFilter(await listForProject(pid), kw),
      onCreate: (_, v) => svc.create(
        CultivationLevelsCompanion.insert(
          id: _entityId(v),
          name: v['name'] as String? ?? '未命名等级',
          cultivationSystemId: v['cultivationSystemId'] as String? ?? '',
          orderIndex: _vInt(v, 'orderIndex'),
          description: _vStrN(v, 'description'),
          breakthroughCondition: _vStrN(v, 'breakthroughCondition'),
          abilities: _vStrN(v, 'abilities'),
          cultivationTime: _vStrN(v, 'cultivationTime'),
          tags: _vStrN(v, 'tags'),
          notes: _vStrN(v, 'notes'),
        ),
      ),
      onUpdate: (id, v) => svc.updateById(
        id,
        CultivationLevelsCompanion(
          name: _vStr(v, 'name'),
          cultivationSystemId: _vStr(v, 'cultivationSystemId'),
          orderIndex: _vInt(v, 'orderIndex'),
          description: _vStrN(v, 'description'),
          breakthroughCondition: _vStrN(v, 'breakthroughCondition'),
          abilities: _vStrN(v, 'abilities'),
          cultivationTime: _vStrN(v, 'cultivationTime'),
          tags: _vStrN(v, 'tags'),
          notes: _vStrN(v, 'notes'),
        ),
      ),
      onDelete: svc.delete,
    );
  },
);

// ---------------------------------------------------------------------------
// 政治职位（子实体，归属政治体系，无 projectId）
// ---------------------------------------------------------------------------

Map<String, dynamic> _politicalPositionToMap(dynamic r) => {
      'id': r.id,
      'name': r.name,
      'politicalSystemId': r.politicalSystemId,
      'level': r.level,
      'description': r.description,
      'powers': r.powers,
      'responsibilities': r.responsibilities,
      'requirements': r.requirements,
      'term': r.term,
      'tags': r.tags,
      'notes': r.notes,
    };

final politicalPositionEntityConfig = EntityPageConfig(
  titleZh: '政治职位管理',
  titleEn: 'Political Positions',
  itemNameZh: '政治职位',
  itemNameEn: 'Position',
  nameField: 'name',
  summaryField: 'politicalSystemId',
  fields: [
    _text('name', '职位名称', 'Position Name'),
    _text('politicalSystemId', '政治体系ID', 'Political System ID'),
    _num('level', '层级', 'Level'),
    _multi('description', '描述', 'Description'),
    _multi('powers', '权力', 'Powers'),
    _multi('responsibilities', '职责', 'Responsibilities'),
    _multi('requirements', '任职要求', 'Requirements'),
    _text('term', '任期', 'Term'),
    _text('tags', '标签', 'Tags'),
    _multi('notes', '备注', 'Notes'),
  ],
  sourceBuilder: (ref) {
    final svc = ref.read(politicalPositionServiceProvider);
    final systems = ref.read(politicalSystemServiceProvider);

    Future<List<Map<String, dynamic>>> listForProject(String projectId) async {
      final systemIds = (await systems.getByProjectId(projectId))
          .map((system) => system.id)
          .toSet();
      return (await svc.getAll())
          .where((position) => systemIds.contains(position.politicalSystemId))
          .map(_politicalPositionToMap)
          .toList();
    }

    return CallbackEntityDataSource(
      onList: listForProject,
      onSearch: (pid, kw) async => _kwFilter(await listForProject(pid), kw),
      onCreate: (_, v) => svc.create(
        PoliticalPositionsCompanion.insert(
          id: _entityId(v),
          name: v['name'] as String? ?? '未命名职位',
          politicalSystemId: v['politicalSystemId'] as String? ?? '',
          level: _vInt(v, 'level'),
          description: _vStrN(v, 'description'),
          powers: _vStrN(v, 'powers'),
          responsibilities: _vStrN(v, 'responsibilities'),
          requirements: _vStrN(v, 'requirements'),
          term: _vStrN(v, 'term'),
          tags: _vStrN(v, 'tags'),
          notes: _vStrN(v, 'notes'),
        ),
      ),
      onUpdate: (id, v) => svc.updateById(
        id,
        PoliticalPositionsCompanion(
          name: _vStr(v, 'name'),
          politicalSystemId: _vStr(v, 'politicalSystemId'),
          level: _vInt(v, 'level'),
          description: _vStrN(v, 'description'),
          powers: _vStrN(v, 'powers'),
          responsibilities: _vStrN(v, 'responsibilities'),
          requirements: _vStrN(v, 'requirements'),
          term: _vStrN(v, 'term'),
          tags: _vStrN(v, 'tags'),
          notes: _vStrN(v, 'notes'),
        ),
      ),
      onDelete: svc.delete,
    );
  },
);

/// 导航目标 → 实体页配置
final entityConfigByTarget = <NavigationTarget, EntityPageConfig>{
  NavigationTarget.characterManagement: characterEntityConfig,
  NavigationTarget.volumeManagement: volumeEntityConfig,
  NavigationTarget.chapterManagement: chapterEntityConfig,
  NavigationTarget.plotManagement: plotEntityConfig,
  NavigationTarget.factionManagement: factionEntityConfig,
  NavigationTarget.worldSettingManagement: worldSettingEntityConfig,
  NavigationTarget.race: raceEntityConfig,
  NavigationTarget.resource: resourceEntityConfig,
  NavigationTarget.secretRealm: secretRealmEntityConfig,
  NavigationTarget.cultivationSystem: cultivationSystemEntityConfig,
  NavigationTarget.politicalSystem: politicalSystemEntityConfig,
  NavigationTarget.currencySystem: currencySystemEntityConfig,
  NavigationTarget.relationshipNetwork: relationshipNetworkEntityConfig,
  NavigationTarget.timelineEventManagement: timelineEventEntityConfig,
  NavigationTarget.characterEventManagement: characterEventEntityConfig,
  NavigationTarget.characterRelationshipManagement:
      characterRelationshipEntityConfig,
  NavigationTarget.factionRelationshipManagement: factionRelationshipEntityConfig,
  NavigationTarget.raceRelationshipManagement: raceRelationshipEntityConfig,
  NavigationTarget.cultivationLevelManagement: cultivationLevelEntityConfig,
  NavigationTarget.politicalPositionManagement: politicalPositionEntityConfig,
};
