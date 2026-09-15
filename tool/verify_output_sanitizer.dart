// ignore_for_file: avoid_print
//
// `AIOutputSanitizer` 的思考前缀过滤验证。
//
// 触发本轮修复的实测样本（`/v1/batch/completions`，2026-09-15）：
//   World 的 CreateWorldSetting 偶发返回以 `<think>好的，用户让我以东方奇幻设定
//   总监的身份来回应这个任务。首先，我需要仔细分析…` 开头的整段推理，
//   `max_tokens` 在思考中用尽 → **永远不会出现闭合标签** → 旧实现
//   （只匹配成对 `<think>...</think>`）会把它整段当正文吐给用户。
//
// `output_sanitizer.dart` 只依赖 `dart:convert` ⇒ 纯 Dart ⇒ 能在这里真跑。
//
// 运行：dart run tool/verify_output_sanitizer.dart
import 'dart:io';

import 'package:novelcraft/ai/utils/output_sanitizer.dart';

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

String clean(String s) => AIOutputSanitizer.extractVisibleContent(s);

void main() {
  print('=' * 78);
  print('[1] 未闭合 <think>（实测泄漏形态）—— 必须识别为「通篇是推理」');
  print('=' * 78);
  // 这段就是真实抓到的形态（截取）
  const String leaked =
      '<think>好的，用户让我以东方奇幻设定总监的身份来回应这个任务。'
      '首先，我需要仔细分析他提供的参数和指令。用户给出的项目 ID 是 proj-1，'
      '任务类型是 CreateWorldSetting，还可能有一个章节索引和其他元数据。'
      '他们要求构建一个东方奇幻世界，包含地理、修炼体系、货币资源、势力、禁忌历史'
      '以及近百年大事年表，并且强调逻辑自洽，不能混杂现代或西方元素。';
  check('开头未闭合 <think> → 清理为空', clean(leaked).isEmpty,
      'len=${clean(leaked).length}');

  check('前导空白 + 未闭合 <think> 也能识别',
      clean('\n\n  <think>正在思考…').isEmpty, 'ok');
  check('<thinking> 长标签同样处理', clean('<thinking>思考中…').isEmpty, 'ok');

  print('');
  print('=' * 78);
  print('[2] 成对标签（原有能力不能退化）');
  print('=' * 78);
  check('成对 <think> 被剥掉、保留正文',
      clean('<think>内部推理</think>## 地理\n青冥山脉') == '## 地理\n青冥山脉',
      clean('<think>内部推理</think>## 地理\n青冥山脉'));
  check('成对标签在中间也能剥',
      clean('前文<thinking>推理</thinking>后文') == '前文后文',
      clean('前文<thinking>推理</thinking>后文'));

  print('');
  print('=' * 78);
  print('[3] 不能误删正文（宁可少删）');
  print('=' * 78);
  final String midTag = '## 说明\n本章会用 <think> 标记内部推理，请勿外泄。';
  check('正文中间的裸 <think> 不被整段删除', clean(midTag).isNotEmpty,
      clean(midTag));
  final String normal = '## 核心主题\n凡人逆天改命，打破天道桎梏';
  check('普通正文原样保留', clean(normal).contains('## 核心主题'), 'ok');
  check('普通正文不被截断', clean(normal).length == normal.length,
      '${clean(normal).length}/${normal.length}');

  print('');
  print('=' * 78);
  print('[4] 客套前缀（原有能力）');
  print('=' * 78);
  final String polite = '好的，遵照您的指示，以下是世界设定：\n## 地理\n青冥山脉';
  final String pc = clean(polite);
  check('客套前缀被剥掉后仍保留 ## 正文',
      pc.contains('## 地理') && !pc.startsWith('好的，遵照'),
      pc.split('\n').first);

  print('');
  print('=' * 78);
  print('[5] 边界：空 / 全空白 / 只有标签');
  print('=' * 78);
  check('空字符串', clean('') == '', 'ok');
  check('全空白', clean('   \n  ').trim().isEmpty, 'ok');
  check('只有一对标签 → 空', clean('<think>x</think>').isEmpty,
      'len=${clean('<think>x</think>').length}');
  check('不抛异常（脏输入）', () {
    clean('<think>');
    clean('</think>');
    clean('<think><think>嵌套');
    return true;
  }(), 'ok');

  print('');
  print('=' * 78);
  print('VERDICT: $pass passed, $fail failed');
  print('=' * 78);
  if (fail > 0) exitCode = 1;
}
