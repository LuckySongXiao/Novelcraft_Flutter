// 拆书（文风研读）的规则模型。
//
// 一份「规则集」= 拆一本书得到的东西，它同时承担两个用途：
//   1. 「文风研读」页展示（按维度 + 按技法大类阅读）；
//   2. 注入整书生成的提示词（见 `StyleRuleSet.toPromptBlock`）。
//
// 为什么模型与存储分开：本文件只做**数据 + 序列化 + 渲染**，是纯 Dart，
// 可以被 `tools/style_rule_selftest.dart` 离线直跑；真正的模型调用在
// `style_digest_service.dart`。与 `style_digest_text.dart` 的分工是
// 「那边管采样与合并的字符串规则，这边管产物长什么样」。
import 'dart:convert';

import '../../ai/utils/style_digest_text.dart';

/// 一条可复用的写作技法。
///
/// 形态照用户既有的拆书产物（`作家技能库.md` 的「技能名 + 实现方式」）定：
/// [title] 是技能名，[detail] 是可复用写法，[category] 是所属大类
/// （取值见 [kStyleTechniqueCategories]）。
class StyleTechnique {
  const StyleTechnique({
    required this.category,
    required this.title,
    required this.detail,
  });

  final String category;
  final String title;
  final String detail;

  StyleTechnique copyWith({String? category, String? title, String? detail}) =>
      StyleTechnique(
        category: category ?? this.category,
        title: title ?? this.title,
        detail: detail ?? this.detail,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'category': category,
    'title': title,
    'detail': detail,
  };

  /// 宽容解析：缺字段 / 类型不对一律降级为空串，不抛异常。
  ///
  /// 这份 JSON 是模型产出的，也可能是用户手改过的旧文件 —— 解析路径上
  /// 任何一处抛异常都会让整个「文风研读」页打不开，代价远大于少一条技法。
  factory StyleTechnique.fromJson(Map<String, dynamic> json) => StyleTechnique(
    category: _str(json['category']),
    title: _str(json['title']),
    detail: _str(json['detail']),
  );

  static String _str(Object? v) => v is String ? v.trim() : '';
}

/// 一份文风规则集。
class StyleRuleSet {
  const StyleRuleSet({
    this.id = '',
    this.name = '',
    this.sourceLabel = '',
    this.createdAt = 0,
    this.aspects = const <String, String>{},
    this.techniques = const <StyleTechnique>[],
    this.notes = '',
  });

  final String id;

  /// 规则集名称（默认取书名或文件名，用于列表显示）。
  final String name;

  /// 样本来源描述（如「本地文件：众仙俯首.txt（10.6 MB）」）。
  final String sourceLabel;

  /// 生成时间，epoch 秒。
  ///
  /// 与工程里其他时间列一致用秒 —— drift 的 `GeneratedColumn<DateTime>` 也是
  /// epoch 秒（`projects.updated_at` 是唯一例外）。存进 JSON 时若混用毫秒，
  /// 列表排序会莫名其妙地把新规则排到最后。
  final int createdAt;

  /// 文本维度：键取 [kStyleAspectLabels] 的键，值是该维度的结论。
  final Map<String, String> aspects;

  final List<StyleTechnique> techniques;

  /// 拆解过程中的说明（用了降级路径、模型返回不可用等），供 UI 提示。
  final String notes;

  bool get isEmpty =>
      techniques.isEmpty &&
      aspects.values.every((String v) => v.trim().isEmpty);

  /// 规则集是否可用（能否注入提示词）。
  bool get isUsable => !isEmpty;

  /// 按大类分组后的技法，供 UI 分节渲染。顺序跟随 [kStyleTechniqueCategories]。
  Map<String, List<StyleTechnique>> get techniquesByCategory {
    final Map<String, List<StyleTechnique>> out =
        <String, List<StyleTechnique>>{
          for (final String c in kStyleTechniqueCategories)
            c: <StyleTechnique>[],
        };
    for (final StyleTechnique t in techniques) {
      (out[t.category] ??= <StyleTechnique>[]).add(t);
    }
    out.removeWhere((String _, List<StyleTechnique> v) => v.isEmpty);
    return out;
  }

  StyleRuleSet copyWith({
    String? id,
    String? name,
    String? sourceLabel,
    int? createdAt,
    Map<String, String>? aspects,
    List<StyleTechnique>? techniques,
    String? notes,
  }) => StyleRuleSet(
    id: id ?? this.id,
    name: name ?? this.name,
    sourceLabel: sourceLabel ?? this.sourceLabel,
    createdAt: createdAt ?? this.createdAt,
    aspects: aspects ?? this.aspects,
    techniques: techniques ?? this.techniques,
    notes: notes ?? this.notes,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'sourceLabel': sourceLabel,
    'createdAt': createdAt,
    'aspects': aspects,
    'techniques': <Object?>[
      for (final StyleTechnique t in techniques) t.toJson(),
    ],
    'notes': notes,
  };

  factory StyleRuleSet.fromJson(Map<String, dynamic> json) {
    final Map<String, String> aspects = <String, String>{};
    final Object? rawAspects = json['aspects'];
    if (rawAspects is Map) {
      for (final MapEntry<Object?, Object?> e in rawAspects.entries) {
        final String k = '${e.key}'.trim();
        if (k.isEmpty) continue;
        // 只收已知维度的键：旧文件里若残留已废弃的维度名，展示时会出现
        // 一个没有中文名的一级标题。
        if (!kStyleAspectLabels.containsKey(k)) continue;
        final String v = e.value is String ? (e.value as String).trim() : '';
        if (v.isEmpty) continue;
        aspects[k] = v;
      }
    }

    final List<StyleTechnique> techniques = <StyleTechnique>[];
    final Object? rawTech = json['techniques'];
    if (rawTech is List) {
      for (final Object? item in rawTech) {
        if (item is! Map) continue;
        final StyleTechnique t = StyleTechnique.fromJson(
          item.map(
            (Object? k, Object? v) => MapEntry<String, dynamic>('$k', v),
          ),
        );
        if (t.title.isEmpty) continue;
        techniques.add(t);
      }
    }

    return StyleRuleSet(
      id: _s(json['id']),
      name: _s(json['name']),
      sourceLabel: _s(json['sourceLabel']),
      createdAt: json['createdAt'] is num
          ? (json['createdAt'] as num).toInt()
          : 0,
      aspects: aspects,
      techniques: techniques,
      notes: _s(json['notes']),
    );
  }

  /// 精简版规则块 —— 给「续写优选」候选提示词用（见 [toPromptBlockBrief]）。
  static const List<String> kBriefAspectOrder = <String>[
    'taboo',
    'sentence',
    'dialogue',
    'perspective',
  ];

  /// 渲染成可注入提示词的一段文本。
  ///
  /// 输出刻意紧凑（条目化、去空行）：这段文本通常要进**每一章**的写作提示词，
  /// 每多 100 字就多浪费一次上下文，且稀释指令密度。
  ///
  /// 参数说明：
  /// * [maxChars] 截断保护 —— 规则是模型产出的，长度不可控，不能让它把
  ///   章节大纲挤出上下文窗口；超限时**优先切在行边界**（切在行中间会留下
  ///   半句话，模型容易把它当成残缺指令）。
  /// * [aspectOrder] 指定维度顺序（null = 按 [aspects] 的插入顺序）。
  ///   精简版需要把「禁忌表达」提到最前 —— 它若排在末尾，一截断就没了。
  /// * [includeTechniques] false 时只输出维度结论，不带技法清单。
  String toPromptBlock({
    int maxChars = 2000,
    Map<String, String> labels = kStyleAspectLabels,
    List<String> categories = kStyleTechniqueCategories,
    List<String>? aspectOrder,
    bool includeTechniques = true,
  }) {
    final List<String> lines = <String>[];
    final List<String> keys = <String>[
      for (final String k in aspectOrder ?? aspects.keys)
        if (aspects.containsKey(k)) k,
    ];
    for (final String k in keys) {
      final String v = (aspects[k] ?? '').trim();
      if (v.isEmpty) continue;
      lines.add('- ${labels[k] ?? k}：$v');
    }
    if (includeTechniques) {
      final Map<String, List<StyleTechnique>> grouped = techniquesByCategory;
      for (final String c in categories) {
        final List<StyleTechnique>? items = grouped[c];
        if (items == null || items.isEmpty) continue;
        if (lines.isNotEmpty) lines.add('');
        lines.add('【$c】');
        for (final StyleTechnique t in items) {
          lines.add(
            t.detail.isEmpty ? '- ${t.title}' : '- ${t.title}：${t.detail}',
          );
        }
      }
    }
    final String joined = lines.join('\n').trim();
    if (joined.length <= maxChars) return joined;
    // 切在行边界：最后一个换行离 maxChars 太远（说明首行本身就超长）时
    // 才退回硬切，否则会几乎什么都不剩。
    final int cut = joined.lastIndexOf('\n', maxChars);
    final int end = cut >= maxChars ~/ 2 ? cut : maxChars;
    return joined.substring(0, end).trimRight();
  }

  /// 精简版规则块 —— 只留最影响「落笔口吻」的四个维度，不带技法清单。
  ///
  /// 为什么需要它：`WritingCraft.beam`（续写优选，默认工艺）的候选提示词是
  /// **刻意极简**的 —— 提示词越像一段被截断的小说，产出越像小说；塞一大段
  /// 技法清单进去，模型就会跑去「复述要求 / 输出元信息」。所以那边只给
  /// 「别用什么词、句子多长、对白多少、视角在哪」这四件最直接的事。
  String toPromptBlockBrief({
    int maxChars = 800,
    Map<String, String> labels = kStyleAspectLabels,
  }) => toPromptBlock(
    maxChars: maxChars,
    labels: labels,
    aspectOrder: kBriefAspectOrder,
    includeTechniques: false,
  );

  static String _s(Object? v) => v is String ? v.trim() : '';
}

/// 规则集库 —— 全局一份，按项目标记启用哪一个。
///
/// 为什么不按项目存：拆书产物是**可复用素材**（一本《众仙俯首》的文风规则，
/// 可以拿去指导任何新书），按项目隔离会让用户每次新建项目都要重拆一遍。
/// 而「哪个项目在用哪套规则」是项目级的，所以单独一层 [active] 映射。
class StyleRuleLibrary {
  const StyleRuleLibrary({
    this.sets = const <StyleRuleSet>[],
    this.active = const <String, String>{},
  });

  final List<StyleRuleSet> sets;

  /// 项目 id → 启用的规则集 id。
  final Map<String, String> active;

  bool get isEmpty => sets.isEmpty;

  StyleRuleSet? byId(String id) {
    if (id.isEmpty) return null;
    for (final StyleRuleSet s in sets) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// 取某项目当前启用的规则集（未启用 / 已删除 → null）。
  StyleRuleSet? activeSetFor(String projectId) {
    if (projectId.isEmpty) return null;
    final StyleRuleSet? s = byId(active[projectId] ?? '');
    return (s != null && s.isUsable) ? s : null;
  }

  /// 插入或替换一套规则（按 id），并移到列表最前（最近拆的排前面）。
  StyleRuleLibrary upsert(StyleRuleSet set) {
    final List<StyleRuleSet> next = <StyleRuleSet>[
      set,
      for (final StyleRuleSet s in sets)
        if (s.id != set.id) s,
    ];
    return copyWith(sets: next);
  }

  /// 删除一套规则，并清掉所有指向它的启用标记。
  StyleRuleLibrary remove(String id) {
    final Map<String, String> next = <String, String>{
      for (final MapEntry<String, String> e in active.entries)
        if (e.value != id) e.key: e.value,
    };
    return StyleRuleLibrary(
      sets: <StyleRuleSet>[
        for (final StyleRuleSet s in sets)
          if (s.id != id) s,
      ],
      active: next,
    );
  }

  /// 把某项目启用到指定规则集（[setId] 传空串 = 取消启用）。
  StyleRuleLibrary activate(String projectId, String setId) {
    if (projectId.isEmpty) return this;
    final Map<String, String> next = Map<String, String>.of(active);
    if (setId.isEmpty) {
      next.remove(projectId);
    } else {
      next[projectId] = setId;
    }
    return copyWith(active: next);
  }

  StyleRuleLibrary copyWith({
    List<StyleRuleSet>? sets,
    Map<String, String>? active,
  }) =>
      StyleRuleLibrary(sets: sets ?? this.sets, active: active ?? this.active);

  Map<String, Object?> toJson() => <String, Object?>{
    'sets': <Object?>[for (final StyleRuleSet s in sets) s.toJson()],
    'active': active,
  };

  factory StyleRuleLibrary.fromJson(Map<String, dynamic> json) {
    final List<StyleRuleSet> sets = <StyleRuleSet>[];
    final Object? rawSets = json['sets'];
    if (rawSets is List) {
      for (final Object? item in rawSets) {
        if (item is! Map) continue;
        final StyleRuleSet s = StyleRuleSet.fromJson(
          item.map(
            (Object? k, Object? v) => MapEntry<String, dynamic>('$k', v),
          ),
        );
        if (s.id.isEmpty) continue; // 没有 id 的规则无法被启用/删除
        sets.add(s);
      }
    }
    final Map<String, String> active = <String, String>{};
    final Object? rawActive = json['active'];
    if (rawActive is Map) {
      for (final MapEntry<Object?, Object?> e in rawActive.entries) {
        final String k = '${e.key}'.trim();
        final String v = e.value is String ? (e.value as String).trim() : '';
        if (k.isEmpty || v.isEmpty) continue;
        // 启动时自愈：启用标记指向已不存在的规则 → 直接丢掉，
        // 否则 UI 的「当前启用」下拉会拿到一个不在候选里的值。
        if (!sets.any((StyleRuleSet s) => s.id == v)) continue;
        active[k] = v;
      }
    }
    return StyleRuleLibrary(sets: sets, active: active);
  }

  /// 入库前做一次规范化：去掉空规则、修掉悬空启用标记。
  StyleRuleLibrary normalized() => StyleRuleLibrary.fromJson(
    jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>,
  );
}
