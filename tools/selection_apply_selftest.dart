// 离线自检：selection_apply_text.dart（选节 AI 结果采纳应用）。
//
// 运行：dart --disable-dart-dev tools/selection_apply_selftest.dart
library;

import 'package:novelcraft/ai/utils/selection_apply_text.dart';

int _passed = 0;
int _failed = 0;

void _check(String name, bool cond) {
  if (cond) {
    _passed++;
  } else {
    _failed++;
    print('FAIL  $name');
  }
}

void main() {
  const content = '第一段开头的话。\n\n第二段整段都在讲追击的经过，主角跑得飞快，'
      '一路追到山谷口才停下脚步。\n\n第三段收尾。';

  // -------------------------------------------------------------------------
  // A 组：替换语义（润色 / 去重润色 / 扩写 / 重写）
  // -------------------------------------------------------------------------
  {
    final out = applySelectionResult(
      content: content,
      selected: '主角跑得飞快',
      result: '主角像离弦的箭一样掠过山道。',
      insertAfter: false,
    );
    _check('A1 选区被替换', out.contains('像离弦的箭一样'));
    _check('A2 原选区文本消失', !out.contains('主角跑得飞快'));
    _check('A3 前后文保留',
        out.contains('第一段开头的话。') && out.contains('第三段收尾。'));
  }
  {
    // 整段替换。
    const para = '第二段整段都在讲追击的经过，主角跑得飞快，一路追到山谷口才停下脚步。';
    final out = applySelectionResult(
      content: content,
      selected: para,
      result: '追击持续到天明。',
      insertAfter: false,
    );
    _check('A4 整段替换干净', out == '第一段开头的话。\n\n追击持续到天明。\n\n第三段收尾。');
  }

  // -------------------------------------------------------------------------
  // B 组：续写语义（插入到所选段落的下一段）
  // -------------------------------------------------------------------------
  {
    // 选区停在段中 → 续写必须插到该段之后，不能插进句子中间。
    final out = applySelectionResult(
      content: content,
      selected: '主角跑得飞快',
      result: '风声在耳边呼啸。',
      insertAfter: true,
    );
    _check('B1 原选区保留', out.contains('主角跑得飞快'));
    _check('B2 剩余半段仍在续写之前',
        out.indexOf('一路追到山谷口') < out.indexOf('风声在耳边呼啸'));
    _check('B3 续写成独立段', out.contains('才停下脚步。\n\n风声在耳边呼啸。\n\n第三段收尾。'));
  }
  {
    // 选区正好是完整段 → 插到它的下一段。
    const para = '第二段整段都在讲追击的经过，主角跑得飞快，一路追到山谷口才停下脚步。';
    final out = applySelectionResult(
      content: content,
      selected: para,
      result: '新的一段从这里开始。',
      insertAfter: true,
    );
    _check('B4 段后插入', out.contains('$para\n\n新的一段从这里开始。\n\n第三段收尾。'));
  }
  {
    // 选区在末段 → 追加到文末。
    final out = applySelectionResult(
      content: content,
      selected: '第三段收尾。',
      result: '文末续写的一段。',
      insertAfter: true,
    );
    _check('B5 文末追加', out.endsWith('第三段收尾。\n\n文末续写的一段。'));
  }
  {
    // 选区在首段 → 插在第一、二段之间。
    final out = applySelectionResult(
      content: content,
      selected: '第一段开头的话。',
      result: '紧跟第一段的续写。',
      insertAfter: true,
    );
    _check('B6 首段后插入',
        out.startsWith('第一段开头的话。\n\n紧跟第一段的续写。\n\n第二段整段'));
  }

  // -------------------------------------------------------------------------
  // C 组：边界与防回归
  // -------------------------------------------------------------------------
  _check('C1 选区不在正文中 → 抛错', () {
    try {
      applySelectionResult(
          content: content, selected: '不存在的文本', result: 'x', insertAfter: false);
      return false;
    } on StateError {
      return true;
    }
  }());
  _check('C2 空结果 → 抛错', () {
    try {
      applySelectionResult(
          content: content, selected: '第一段开头的话。', result: '  ', insertAfter: false);
      return false;
    } on StateError {
      return true;
    }
  }());
  {
    // 结果带首尾空白 → trim 后写入。
    final out = applySelectionResult(
      content: content,
      selected: '第一段开头的话。',
      result: '  提交前清理过空白。 \n',
      insertAfter: true,
    );
    _check('C3 结果被 trim', out.contains('\n\n提交前清理过空白。\n\n'));
  }
  {
    // 原文段落间多空行（展示态已归一，但容忍残留）→ 续写后 rest 不带连续空行头。
    const messy = '段一。\n\n\n\n段二结尾。';
    final out = applySelectionResult(
      content: messy,
      selected: '段一。',
      result: '插入段。',
      insertAfter: true,
    );
    _check('C4 连续空行被归一', out.contains('段一。\n\n插入段。\n\n段二结尾。'));
  }
  {
    // 与展示态归一（\n\n 连接）配合幂等：应用一次后再应用同选区不再命中。
    const display = '段A第一句。\n\n段B第一句。';
    final once = applySelectionResult(
      content: display, selected: '段A第一句。', result: '续', insertAfter: true);
    _check('C5 展示态续写一次成功', once == '段A第一句。\n\n续\n\n段B第一句。');
  }

  print('selection_apply_selftest: $_passed passed, $_failed failed');
  if (_failed > 0) {
    throw StateError('selection_apply_selftest FAILED: $_failed assertion(s)');
  }
}
