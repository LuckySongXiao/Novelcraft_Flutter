import 'dart:convert';

import '../../ai/prompts/prompt_template.dart';
import '../../data/storage/key_value_store.dart';
import 'writing_prompt_catalog.dart';

class WritingPromptStage {
  const WritingPromptStage({
    required this.id,
    required this.title,
    required this.defaultBody,
    this.variables = const {},
    this.asset = false,
  });

  final String id;
  final String title;
  final String defaultBody;
  final Map<String, String> variables;
  final bool asset;

  String? validate(String body) {
    if (body.trim().isEmpty) return '提示词不能为空';
    if (body.length > 64000) return '提示词不能超过 64000 字符';
    final pattern = asset
        ? RegExp(r'\{([A-Za-z]\w*)\}')
        : RegExp(r'\{\{([^{}]+)\}\}');
    final used = pattern.allMatches(body).map((match) => match[1]!).toSet();
    final unknown = used.difference(variables.keys.toSet());
    if (unknown.isNotEmpty) return '未知变量：${unknown.join('、')}';
    final missing = variables.keys.toSet().difference(used);
    if (missing.isNotEmpty) return '请保留动态变量：${missing.join('、')}';
    if (!asset && body.replaceAll(pattern, '').contains(RegExp(r'\{\{|\}\}'))) {
      return '变量括号不完整，请使用 {{变量名}}';
    }
    return null;
  }
}

class WritingPromptVariant {
  const WritingPromptVariant({
    required this.id,
    required this.name,
    required this.body,
  });
  final String id;
  final String name;
  final String body;
  Map<String, String> toJson() => {'id': id, 'name': name, 'body': body};
}

class WritingPromptTemplates {
  WritingPromptTemplates({
    required List<WritingPromptStage> stages,
    Map<String, List<WritingPromptVariant>> variants = const {},
    Map<String, String> selected = const {},
    this.loadWarning,
  }) : stages = List.unmodifiable(stages),
       variants = Map.unmodifiable(
         variants.map(
           (key, value) =>
               MapEntry(key, List<WritingPromptVariant>.unmodifiable(value)),
         ),
       ),
       selected = Map.unmodifiable(selected);

  factory WritingPromptTemplates.defaults() =>
      WritingPromptTemplates(stages: bookPromptStages);

  final List<WritingPromptStage> stages;
  final Map<String, List<WritingPromptVariant>> variants;
  final Map<String, String> selected;
  final String? loadWarning;

  WritingPromptStage stage(String id) =>
      stages.firstWhere((item) => item.id == id);

  String body(String id) {
    final definition = stage(id);
    for (final item in variants[id] ?? <WritingPromptVariant>[]) {
      if (item.id == selected[id] && definition.validate(item.body) == null) {
        return item.body;
      }
    }
    return definition.defaultBody;
  }

  String render(String id, Map<String, String> values) {
    final definition = stage(id);
    if (definition.variables.keys.any((key) => !values.containsKey(key))) {
      throw ArgumentError('节点 $id 缺少运行时变量');
    }
    return body(id).replaceAllMapped(
      RegExp(r'\{\{([^{}]+)\}\}'),
      (match) => values[match[1]]!,
    );
  }

  WritingPromptTemplates withStage(
    String id,
    List<WritingPromptVariant> items,
    String active,
  ) {
    final definition = stage(id);
    final ids = <String>{};
    final names = <String>{};
    for (final item in items) {
      if (item.id.isEmpty ||
          !ids.add(item.id) ||
          item.name.trim().isEmpty ||
          !names.add(item.name.trim())) {
        throw const FormatException('模板名称和标识不能为空或重复');
      }
      final error = definition.validate(item.body);
      if (error != null) throw FormatException(error);
    }
    if (active.isNotEmpty && !ids.contains(active)) {
      throw const FormatException('选中的模板不存在');
    }
    return WritingPromptTemplates(
      stages: stages,
      variants: {...variants, id: items},
      selected: {...selected, id: active},
    );
  }

  PromptTemplateRegistry overlay(PromptTemplateRegistry base) =>
      base.withOverrides({
        for (final item in stages.where((item) => item.asset))
          item.id.substring(6): body(item.id),
      });

  Map<String, Object> toJson() => {
    'version': 1,
    'selected': selected,
    'variants': variants.map(
      (key, value) =>
          MapEntry(key, value.map((item) => item.toJson()).toList()),
    ),
  };

  static Future<WritingPromptTemplates> load(
    KeyValueStore store,
    List<WritingPromptStage> stages,
  ) async {
    var result = WritingPromptTemplates(stages: stages);
    final raw = await store.readJson('ai_config', 'writing_prompt_templates');
    if (raw == null) return result;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (json['version'] != 1) throw const FormatException('不支持的模板版本');
      final variants = json['variants'] as Map<String, dynamic>;
      final selected = json['selected'] as Map<String, dynamic>;
      for (final entry in variants.entries) {
        if (!stages.any((stage) => stage.id == entry.key)) continue;
        final items = (entry.value as List).map((raw) {
          final item = raw as Map<String, dynamic>;
          return WritingPromptVariant(
            id: item['id'] as String,
            name: item['name'] as String,
            body: item['body'] as String,
          );
        }).toList();
        result = result.withStage(
          entry.key,
          items,
          selected[entry.key] as String? ?? '',
        );
      }
      return result;
    } on Object {
      return WritingPromptTemplates(
        stages: stages,
        loadWarning: '已保存的提示词配置损坏或不兼容，当前使用内置模板；原配置未覆盖。保存新配置会替换原配置。',
      );
    }
  }

  Future<void> save(KeyValueStore store) => store.writeJson(
    'ai_config',
    'writing_prompt_templates',
    jsonEncode(toJson()),
  );
}
