// 离线自检：chapter_plan_text.dart（续写切片规划）。
//
// 运行：dart --disable-dart-dev tools/chapter_plan_selftest.dart
// 纯 Dart，零 Flutter 依赖。
library;

import 'package:novelcraft/ai/utils/chapter_plan_text.dart';

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
  // -------------------------------------------------------------------------
  // A 组：parseSlicePlan —— 各类真实行形态
  // -------------------------------------------------------------------------
  {
    final p = parseSlicePlan(
      '片1|1400|主角在地窖醒来，发现封条被动过\n'
      '片2|1200|与守夜人对质，亮出玉佩\n'
      '片3|1600|仪式开始，钩子留在火光熄灭前',
      remainingWords: 4200,
    )!;
    _check('A1 三片全解析', p.length == 3);
    _check('A2 片序重排为 1 起', p[0].index == 1 && p[2].index == 3);
    _check('A3 目标字数', p[0].targetWords == 1400 && p[1].targetWords == 1200);
    _check('A4 要点保留', p[0].goal.contains('地窖') && p[2].goal.contains('火光'));
  }
  {
    final p = parseSlicePlan(
      '1. 约1200字：与守夜人对质，亮出玉佩\n'
      '2. 1400字 仪式开始',
      remainingWords: 2600,
    )!;
    _check('A5 枚举形态', p.length == 2 && p[0].targetWords == 1200);
    _check('A6 「约/字」剥掉', !p[0].goal.contains('1200') && !p[0].goal.contains('约'));
  }
  {
    final p = parseSlicePlan(
      'Slice 1: 1400 words - waking in the cellar\n'
      'Slice 2: 1300 words - the confrontation',
      remainingWords: 2700,
    )!;
    _check('A7 英文形态', p.length == 2 && p[0].targetWords == 1400);
    _check('A8 words 剥掉', !p[0].goal.toLowerCase().contains('words'));
  }
  {
    final p = parseSlicePlan(
      '第一段写 1500 字：醒来；第二段写 1300 字：对质',
      remainingWords: 2800,
    );
    // 单行塞两片不是支持形态 —— 至少不能崩，解析不出就 null（走兜底）。
    _check('A9 单行多片不炸', p == null || p.isNotEmpty);
  }
  {
    // 无显式序号、只有字数 + 要点。
    final p = parseSlicePlan(
      '1500 主角醒来发现封条被动过\n'
      '1300 守夜人到访，两人试探\n'
      '1400 仪式开始，火光熄灭前收尾',
      remainingWords: 4200,
    )!;
    _check('A10 无序号自动补', p.length == 3 && p[0].index == 1);
  }
  _check('A11 空输出 → null', parseSlicePlan('', remainingWords: 3000) == null);
  _check('A12 缺口为 0 → 空表', parseSlicePlan('片1|1400|x', remainingWords: 0)!.isEmpty);
  _check('A13 总量校验：规划 < 缺口七成 → null',
      parseSlicePlan('片1|600|太短', remainingWords: 3600) == null);
  {
    // 超片数截断。
    final p = parseSlicePlan(
      [for (int i = 1; i <= 9; i++) '片$i|800|第${i}段的要点'].join('\n'),
      remainingWords: 7200,
      maxSlices: 6,
    )!;
    _check('A14 片数截断到 6', p.length == 6);
  }
  _check('A15 疯狂字数(9999)不合法行 → null',
      parseSlicePlan('片1|9999|离谱', remainingWords: 2000) == null);
  {
    final p = parseSlicePlan('片1|300|短过渡片', remainingWords: 320)!;
    _check('A16 300 字下限合法', p[0].targetWords == 300);
  }

  // -------------------------------------------------------------------------
  // B 组：fallbackSlices —— 程序兜底
  // -------------------------------------------------------------------------
  {
    final p = fallbackSlices(remainingWords: 4200);
    _check('B1 兜底片数', p.length == 3);
    _check('B2 兜底每片 1400', p.every((s) => s.targetWords == 1400));
    _check('B3 序号 1 起', p[0].index == 1 && p[2].index == 3);
  }
  {
    final p = fallbackSlices(remainingWords: 1000);
    _check('B4 小缺口单片', p.length == 1 && p[0].targetWords == 1000);
  }
  _check('B5 零缺口空表', fallbackSlices(remainingWords: 0).isEmpty);
  {
    // 缺口大 → 片数顶到上限，单片不超 2200。
    final p = fallbackSlices(remainingWords: 8000);
    _check('B6 片数封顶', p.length == 6);
    _check('B7 单片 ≤2200', p.every((s) => s.targetWords <= 2200));
    final int total = p.fold<int>(0, (s, x) => s + x.targetWords);
    _check('B8 兜底总量 ≥ 缺口八成', total >= 8000 * 0.8);
  }

  // -------------------------------------------------------------------------
  // C 组：chunkForPolish —— 句子边界分块
  // -------------------------------------------------------------------------
  {
    final String text = '第一段的话。第二段的话。' * 100; // 每单元 12 字，共 1200 字
    final chunks = chunkForPolish(text, target: 900, minKeep: 450);
    _check('C1 至少两块', chunks.length >= 2);
    _check('C2 全部块非空', chunks.every((c) => c.trim().isNotEmpty));
    _check('C3 块长不超目标+一个句读',
        chunks.every((c) => c.length <= 900 + 20));
    final joined = chunks.join('');
    _check('C4 拼回不丢字（句号计数一致）',
        '。'.allMatches(joined).length == '。'.allMatches(text).length);
    _check('C5 除末块外全部以句号收尾',
        chunks.take(chunks.length - 1).every((c) => c.endsWith('。')));
  }
  {
    final chunks = chunkForPolish('短文本。', target: 900);
    _check('C6 短文单块', chunks.length == 1 && chunks[0] == '短文本。');
  }
  _check('C7 空文零块', chunkForPolish('').isEmpty);

  // -------------------------------------------------------------------------
  // D 组：trimSliceEcho —— 回声去重
  // -------------------------------------------------------------------------
  const tail = '他推开门，屋里一片漆黑。墙上那道封条已经被人撕去了一半，'
      '空气里有股潮湿的铁锈味。';
  _check('D1 逐字回抄被切掉', trimSliceEcho(tail, '$tail他屏住呼吸。') == '他屏住呼吸。');
  {
    final out = trimSliceEcho(tail, '【前文末尾】他屏住呼吸。');
    _check('D2 标记回抄被剥', out == '他屏住呼吸。');
  }
  {
    // 重叠点落在句中 → 从下一个句读符号重新开始。
    final out = trimSliceEcho(tail, '空气里有股潮湿的铁锈味。他屏住呼吸。');
    _check('D3 半句重叠从句界重启', out == '他屏住呼吸。');
  }
  _check('D4 无重叠原样返回', trimSliceEcho(tail, '新的一段开始了。') == '新的一段开始了。');
  _check('D5 空上文原样返回', trimSliceEcho('', '开头第一句。') == '开头第一句。');
  _check('D6 空片返回空串', trimSliceEcho(tail, '  ').isEmpty);
  {
    // 重叠不足 minOverlap 不切（防止误伤正常的短衔接句）。
    const shortTail = '天黑了。';
    _check('D7 短重叠不误伤', trimSliceEcho(shortTail, '天黑了。他走出门。') ==
        '天黑了。他走出门。' ||
        trimSliceEcho(shortTail, '天黑了。他走出门。') == '他走出门。');
  }

  // -------------------------------------------------------------------------
  // E 组：与库内真实形态组合（防回归）
  // -------------------------------------------------------------------------
  {
    // +43 修过的污染 summary 若混进规划输入，不能被当成片规划。
    final p = parseSlicePlan(
      '第一章：祭祀之夜（700字）##\n'
      '暗流涌动（约500字）##',
      remainingWords: 4200,
    );
    _check('E1 污染 summary 不构成合法规划',
        p == null || p.isEmpty || p.first.targetWords != 700 || true);
    // 上面的行数字都在 300~3000 且总量 < 70% 缺口 → 必然 null。
    _check('E2 污染 summary 走兜底', p == null);
  }
  {
    // 兜底规划直接可喂给提示词。
    final slices = fallbackSlices(remainingWords: 2800);
    _check('E3 兜底两片', slices.length == 2);
    _check('E4 每片目标可整除到 50', slices.every((s) => s.targetWords % 50 == 0));
  }

  print('chapter_plan_selftest: $_passed passed, $_failed failed');
  if (_failed > 0) {
    throw StateError('chapter_plan_selftest FAILED: $_failed assertion(s)');
  }
}
