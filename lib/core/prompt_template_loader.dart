// 提示词模板资源加载器 —— **唯一持有 `rootBundle` 的地方**。
//
// 刻意放在 `lib/core/` 而不是 `lib/ai/`：`lib/ai/**` 必须保持纯 Dart
// （`tool/verify_*.dart` 依赖这一点用 `dart run` 直跑，不启动 Flutter 运行时）。
library;

import 'package:flutter/services.dart';

import '../ai/prompts/prompt_template.dart';

/// 加载全部已登记的提示词模板。
///
/// 缺失的文件**静默忽略**，对应 C# `PromptTemplate.Read` 的
/// `File.Exists(path) ? File.ReadAllText(path) : null` 语义。
/// 已知特例：`Prerequisite/Cultivation.User` 只有 en 版本，没有 zh。
Future<PromptTemplateRegistry> loadPromptTemplateRegistry() async {
  final Map<String, String> files = <String, String>{};
  for (final String id in kPromptTemplateIds) {
    for (final String lang in kPromptTemplateLangs) {
      try {
        files['$id/$lang'] =
            await rootBundle.loadString(promptTemplateAssetPath(id, lang));
      } on Object {
        // 资源不存在 → 跳过（调用方会回退到代码内置默认值）。
      }
    }
  }
  return PromptTemplateRegistry.fromRaw(files);
}