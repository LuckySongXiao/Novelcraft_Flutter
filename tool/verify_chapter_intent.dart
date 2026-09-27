// ignore_for_file: avoid_print
//
// 「关联章节」输入意图判定验证（对应 C# `LooksLikeChapterQuestion` / `ChapterOpKeywords`）。
//
// 为什么值得单独验：判定错的后果是**数据事故** ——
//   把提问当处理要求 → 作者随口问一句，章节正文被重写；
//   把处理要求当提问 → 作者要改稿，Agent 只回一段评论，正文没动。
// 纯 Dart 模块 ⇒ 能在这里真跑，无需 Flutter。
//
// 运行：dart run tool/verify_chapter_intent.dart
import 'package:novelcraft/ai/utils/chapter_intent.dart';

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

ChapterRefIntent zh(String s) => ChapterIntent.resolve(s, isEnglish: false);
ChapterRefIntent en(String s) => ChapterIntent.resolve(s, isEnglish: true);

void main() {
  print('=' * 78);
  print('[1] 中文：疑问句必须走"只作答"，绝不改正文');
  print('=' * 78);
  check('带问号的提问', zh('这章的节奏有什么问题？') == ChapterRefIntent.question, 'question');
  check('半角问号也算', zh('开头是不是太拖了?') == ChapterRefIntent.question, 'question');
  check('「吗」结尾无问号', zh('这章写得还行吗') == ChapterRefIntent.question, 'question');
  check('英文提问（中文语种下）',
      zh('What is wrong with the pacing?') == ChapterRefIntent.question, 'question');
  check('空串按处理要求兜底（不误判为提问）',
      zh('   ') == ChapterRefIntent.operation, 'operation');

  print('');
  print('=' * 78);
  print('[2] 中文：处理要求必须走改稿（含关键词优先于问号）');
  print('=' * 78);
  for (final String k in ChapterIntent.zhOpKeywords) {
    check('关键词「$k」→ 处理要求', zh('请$k一下这段') == ChapterRefIntent.operation, 'operation');
  }
  check('带关键词 + 问号 → 仍是处理要求（对齐 C#）',
      zh('能帮我润色一下吗？') == ChapterRefIntent.operation, 'operation');
  check('无关键词无问号 → 按处理要求',
      zh('主角这里应该更狠一点') == ChapterRefIntent.operation, 'operation');
  check('"续写" 与 "改写" 都命中',
      zh('续写结尾') == ChapterRefIntent.operation &&
          zh('改写开头') == ChapterRefIntent.operation,
      'operation');

  print('');
  print('=' * 78);
  print('[3] 英文：关键词与提问');
  print('=' * 78);
  check('polish → operation', en('Polishing the ending, please') == ChapterRefIntent.operation,
      'operation');
  check('大小写不敏感', en('REWRITE it') == ChapterRefIntent.operation, 'operation');
  check('疑问句 → question', en('Is the pacing too slow?') == ChapterRefIntent.question,
      'question');
  check('带关键词的问句 → operation', en('can you rewrite it?') == ChapterRefIntent.operation,
      'operation');
  check('英文模式不认「吗」结尾（避免误判）',
      en('this chapter is fine 吗') == ChapterRefIntent.operation, 'operation');

  print('');
  print('=' * 78);
  print('[4] 「取消关联」命令（防两种误伤）');
  print('=' * 78);
  check('取消关联', zh('取消关联') == ChapterRefIntent.unlink, 'unlink');
  check('解除关联', zh('解除关联') == ChapterRefIntent.unlink, 'unlink');
  check('带语气词「取消关联吧」', zh('取消关联吧') == ChapterRefIntent.unlink, 'unlink');
  check('带标点「取消关联。」', zh('取消关联。') == ChapterRefIntent.unlink, 'unlink');
  check('unlink / UNLINK', en('unlink') == ChapterRefIntent.unlink &&
      en('  UNLINK  ') == ChapterRefIntent.unlink, 'unlink');
  check('cancel link', en('cancel link') == ChapterRefIntent.unlink, 'unlink');
  check('长句里提到「取消关联」不解除（C# 会误解除）',
      zh('这段先别取消关联，帮我润色一下') == ChapterRefIntent.operation, 'operation');
  check('意见里的"关联"字样不触发解除',
      zh('把师徒关系的关联写得更明显') == ChapterRefIntent.operation, 'operation');

  print('');
  print('=' * 78);
  print('[5] 关键词表自检');
  print('=' * 78);
  check('中文关键词表与 C# 对齐（17 条）',
      ChapterIntent.zhOpKeywords.length == 17, '${ChapterIntent.zhOpKeywords.length}');
  check('英文关键词非空', ChapterIntent.enOpKeywords.isNotEmpty,
      '${ChapterIntent.enOpKeywords.length} 条');
  check('取消关联命令非空', ChapterIntent.unlinkCommands.length >= 4,
      '${ChapterIntent.unlinkCommands.length} 条');
  check('isUnlinkCommand 对空串返回 false', !ChapterIntent.isUnlinkCommand(''), 'ok');
  check('hasOperationKeyword 中英互通（英文模式下也认「润色」）',
      ChapterIntent.hasOperationKeyword('请润色', isEnglish: true), 'ok');

  print('');
  print('=' * 78);
  print('VERDICT: $pass passed, $fail failed');
  print('=' * 78);
}