// 文风规则集的持久化。
//
// 复用 `KeyValueStore`（Native=文件 / Web=localStorage），与
// `ai_config/book_review.settings` 同一套机制：单独一个 scope，避免
// 和 AI 配置互相覆盖。
//
// 为什么不做成 drift 表：规则集是「一坨嵌套 JSON」（7 个文本维度 + 40 条技法），
// 建表要拆成两张表加外键，而它的访问模式永远是「整份读、整份写」——
// 关系表的收益为零，迁移成本却是实打实的。
import 'dart:convert';

import '../../data/storage/key_value_store.dart';
import 'style_rule.dart';

class StyleRuleStore {
  const StyleRuleStore(this._store);

  static const String scope = 'style_digest';
  static const String key = 'rules';

  final Future<KeyValueStore> Function() _store;

  Future<StyleRuleLibrary> load() async {
    try {
      final String? raw = await (await _store()).readJson(scope, key);
      if (raw == null || raw.isEmpty) return const StyleRuleLibrary();
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return const StyleRuleLibrary();
      return StyleRuleLibrary.fromJson(
        decoded.map(
          (Object? k, Object? v) => MapEntry<String, dynamic>('$k', v),
        ),
      );
    } on Object {
      // 文件损坏 / 编码异常 → 退化成空库，让用户重拆，而不是让页面崩。
      return const StyleRuleLibrary();
    }
  }

  Future<void> save(StyleRuleLibrary library) async {
    await (await _store()).writeJson(scope, key, jsonEncode(library.toJson()));
  }

  Future<void> removeAll() async {
    await (await _store()).remove(scope, key);
  }
}
