// ignore_for_file: avoid_print
//
// 提示词模板资产完整性验证（对应 C# `PromptTemplates/` 的 17 个 txt）。
//
// `prompt_template.dart` 只依赖 Dart 核心库 ⇒ 纯 Dart ⇒ 能在这里真跑，无需 Flutter。
//
// 校验项：
//   [1] 磁盘上 17 个 txt 全部存在，且与 kPromptTemplateIds × kPromptTemplateLangs 完全对应
//   [2] 已知特例：Prerequisite/Cultivation.User 只有 en（zh 缺失 → get() 返回 null）
//   [3] en / zh 双版本齐备的模板，两种语种都能取到且内容不同
//   [4] 模板正文里的占位符必须逐个存在（调用方靠 replaceAll 替换，缺一个就静默失效）
//   [5] sanitizeId 防目录穿越；normalizeLang 按 '-' 截断
//
// 运行：dart run tool/verify_prompt_templates.dart
import 'dart:io';

import 'package:novelcraft/ai/prompts/prompt_template.dart';

int pass = 0;
int fail = 0;

void check(String name, bool ok, String detail) {
  if (ok) {
    pass++;
    print('  ✅ $name — $detail');
  } else {
    fail++;
    print('  ❌ $name — $detail');
  }
}

/// 各模板必须出现的占位符（与 C# 调用方的 `.Replace("{X}", …)` 一一对应）。
const Map<String, List<String>> expectedPlaceholders = <String, List<String>>{
  'RWKV/ChapterWriting.Instruction': <String>['{TargetWords}'],
  'Prerequisite/Cultivation.System': <String>[],
  'Prerequisite/Cultivation.User': <String>[],
  'Workflow/MainAgent.System': <String>['{RoleDescription}', '{TaskName}'],
  'Workflow/SubAgentRequirement.System': <String>['{RoleDescription}'],
  'Workflow/SubAgentRefine.System': <String>['{RoleDescription}', '{TaskName}'],
  'WriterAgent/GenerateChapterContent.System': <String>[],
  'WriterAgent/GenerateChapterContent.User': <String>[
    '{Title}',
    '{Type}',
    '{TargetWordCount}',
    '{Style}',
    '{Outline}',
    '{KeyPlots}',
    '{Characters}',
    '{SpecialRequirements}',
  ],
  'WriterAgent/ContinueChapter.System': <String>[],
};

const String baseDir = 'assets/prompts';

File _fileOf(String id, String lang) =>
    File('$baseDir/$id/$lang.txt');

void main() {
  print('=' * 78);
  print('[1] 磁盘文件齐全（17 个 txt / 9 个模板 ID）');
  print('=' * 78);
  int diskCount = 0;
  final Map<String, String> raw = <String, String>{};
  for (final String id in kPromptTemplateIds) {
    for (final String lang in kPromptTemplateLangs) {
      final File f = _fileOf(id, lang);
      if (f.existsSync()) {
        diskCount++;
        raw['$id/$lang'] = f.readAsStringSync();
      }
    }
  }
  check('模板 ID 数量 = 9', kPromptTemplateIds.length == 9,
      '${kPromptTemplateIds.length}');
  check('磁盘文件数量 = 17（9 个双版本 + 1 个仅 en = 18 缺 zh → 17）',
      diskCount == 17, '$diskCount');
  check('Cultivation.User/zh.txt 确实不存在（C# 原始状态）',
      !_fileOf('Prerequisite/Cultivation.User', 'zh').existsSync(), 'ok');
  check('其它 8 个模板 en/zh 双版本都在',
      diskCount == 17, '$diskCount');

  print('');
  print('=' * 78);
  print('[2] 语种回退语义（对齐 C# Get(id)）');
  print('=' * 78);
  final PromptTemplateRegistry reg = PromptTemplateRegistry.fromRaw(raw);
  check('注册表条目数 = 17', reg.length == 17, '${reg.length}');
  check('Cultivation.User 中文 → 回退 zh 也缺失 → null（调用方用代码内置）',
      reg.get('Prerequisite/Cultivation.User', isEnglish: false) == null,
      'null');
  final String? userEn =
      reg.get('Prerequisite/Cultivation.User', isEnglish: true);
  check('Cultivation.User 英文 → 取到 en 正文',
      userEn != null && userEn.contains('Cultivation System'), 'len=${userEn?.length}');
  check('MainAgent.System 中文取 zh',
      (reg.get('Workflow/MainAgent.System', isEnglish: false) ?? '')
          .contains('你是 MainAgent'),
      'ok');
  check('MainAgent.System 英文取 en',
      (reg.get('Workflow/MainAgent.System', isEnglish: true) ?? '')
          .contains('You are MainAgent'),
      'ok');
  check('exists() 只查当前语种、不回退',
      !reg.exists('Prerequisite/Cultivation.User', isEnglish: false) &&
          reg.exists('Prerequisite/Cultivation.User', isEnglish: true),
      'ok');
  check('未知模板 ID → null',
      reg.get('Not/Existing.Template', isEnglish: true) == null, 'null');
  check('空模板 ID → null', reg.get('   ', isEnglish: true) == null, 'null');
  check('空注册表 → 全部 null',
      const PromptTemplateRegistry.empty()
              .get('Workflow/MainAgent.System', isEnglish: true) ==
          null,
      'null');

  print('');
  print('=' * 78);
  print('[3] 占位符完整性（缺一个 → 调用方 replaceAll 静默失效）');
  print('=' * 78);
  expectedPlaceholders.forEach((String id, List<String> keys) {
    for (final String lang in kPromptTemplateLangs) {
      final String? body = reg.getForLang(id, lang);
      if (body == null) continue;
      for (final String key in keys) {
        check('$id/$lang 含 $key', body.contains(key),
            body.contains(key) ? 'ok' : 'MISSING');
      }
    }
  });
  // 反向检查：不应存在未登记的占位符（避免文案改写后调用方漏替换）
  final RegExp placeholder = RegExp(r'\{[A-Za-z][A-Za-z0-9_]*\}');
  final Set<String> registered = <String>{
    for (final List<String> v in expectedPlaceholders.values) ...v,
  };
  int unexpected = 0;
  final List<String> unexpectedList = <String>[];
  for (final String id in kPromptTemplateIds) {
    for (final String lang in kPromptTemplateLangs) {
      final String? body = reg.getForLang(id, lang);
      if (body == null) continue;
      for (final RegExpMatch m in placeholder.allMatches(body)) {
        final String hit = m.group(0)!;
        if (!registered.contains(hit)) {
          unexpected++;
          unexpectedList.add('$id/$lang → $hit');
        }
      }
    }
  }
  check('无未登记的占位符', unexpected == 0,
      unexpected == 0 ? 'ok' : unexpectedList.join(', '));

  print('');
  print('=' * 78);
  print('[4] sanitizeId 防目录穿越 / normalizeLang');
  print('=' * 78);
  check('sanitizeId 去掉 .. 与前导斜杠 → etc/passwd',
      PromptTemplateRegistry.sanitizeId('../../etc/passwd') == 'etc/passwd',
      PromptTemplateRegistry.sanitizeId('../../etc/passwd'));
  check('sanitizeId 去掉前导斜杠',
      PromptTemplateRegistry.sanitizeId('/Workflow/MainAgent.System') ==
          'Workflow/MainAgent.System',
      PromptTemplateRegistry.sanitizeId('/Workflow/MainAgent.System'));
  check('sanitizeId 去掉前导反斜杠',
      PromptTemplateRegistry.sanitizeId('\\Workflow\\x') == 'Workflow\\x',
      PromptTemplateRegistry.sanitizeId('\\Workflow\\x'));
  check('normalizeLang 按 - 截断',
      PromptTemplateRegistry.normalizeLang('en-US') == 'en', 'en');
  check('normalizeLang 空值回落 zh',
      PromptTemplateRegistry.normalizeLang('  ') == 'zh', 'zh');
  check('sanitizeId 结果不含 ..（遍历全部恶意样本）',
      <String>['..', '../..', 'a/../b', '..\\..\\c']
          .every((String s) => !PromptTemplateRegistry.sanitizeId(s).contains('..')),
      'ok');

  print('');
  print('=' * 78);
  print('[5] 资源路径拼接与 pubspec 声明一致');
  print('=' * 78);
  check('promptTemplateAssetPath 形态',
      promptTemplateAssetPath('Workflow/MainAgent.System', 'zh') ==
          'assets/prompts/Workflow/MainAgent.System/zh.txt',
      promptTemplateAssetPath('Workflow/MainAgent.System', 'zh'));
  final File pubspec = File('pubspec.yaml');
  final String yaml = pubspec.existsSync() ? pubspec.readAsStringSync() : '';
  check('pubspec.yaml 声明了 9 个模板目录',
      kPromptTemplateIds
          .every((String id) => yaml.contains('assets/prompts/$id/')),
      'ok');

  print('');
  print('=' * 78);
  print('VERDICT: $pass passed, $fail failed');
  print('=' * 78);
  if (fail > 0) exitCode = 1;
}