// ignore_for_file: avoid_print
//
// 长文分段改写工艺验证（C# `CreationPipelineService` 的 Rolling Segment 工艺移植）。
//
// 为什么值得单独验：这些纯函数决定「长章改写的长度是否与原文伸缩一致」——
//   切片错 → 后半章丢失；复读检测错 → 整段被原样抄回；清洗错 → 提示词残留进正文。
// 纯 Dart 模块 ⇒ 能在这里真跑，无需 Flutter、不碰网络。
//
// 运行：dart run tool/verify_segment_rewrite.dart
import 'package:novelcraft/ai/utils/segment_rewrite.dart';

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

String rep(String unit, int times) => unit * times;

void main() {
  print('=' * 78);
  print('[1] 切片：长文必须完整覆盖，不得丢字（否则后半章被"吃掉"）');
  print('=' * 78);
  const int n = SegmentRewrite.segmentChars; // 1800

  final List<String> one = SegmentRewrite.split(rep('甲', n));
  check('恰好一段长度 → 1 片', one.length == 1, '${one.length}');
  final List<String> over = SegmentRewrite.split(rep('甲', n + 1));
  check('超过一段 1 字 → 2 片', over.length == 2, '${over.length}');
  check('末片只剩 1 字（忠实于 C# 固定切片）', over.last.length == 1,
      '${over.last.length}');

  final String long = rep('甲乙丙丁戊己庚辛壬癸', 1234); // 12340 字
  final List<String> segs = SegmentRewrite.split(long);
  check('12340 字 → 7 片', segs.length == 7, '${segs.length}');
  check('切片拼接后与原文完全一致（无丢字/无重复）',
      segs.join() == long,
      '首片 ${segs.first.length} 字 / 末片 ${segs.last.length} 字');
  check('除末片外每片都等于 segmentChars',
      segs.take(segs.length - 1).every((s) => s.length == n), 'ok');
  check('空串 → 0 片', SegmentRewrite.split('').isEmpty, 'ok');

  print('');
  print('=' * 78);
  print('[2] 是否需要分段（短文走双 Agent 一次成稿，长文才分段）');
  print('=' * 78);
  check('1800 字 → 不分段', !SegmentRewrite.needsSegmentation(rep('甲', n)), 'ok');
  check('1801 字 → 分段', SegmentRewrite.needsSegmentation(rep('甲', n + 1)), 'ok');
  check('空串 → 不分段', !SegmentRewrite.needsSegmentation(''), 'ok');

  print('');
  print('=' * 78);
  print('[3] 段间衔接：尾部截取与拼接');
  print('=' * 78);
  check('短文本原样返回',
      SegmentRewrite.tailOf('结尾') == '结尾', SegmentRewrite.tailOf('结尾'));
  final String tail = SegmentRewrite.tailOf(rep('尾', 900));
  // '……' 是两个字符（U+2026 × 2），故总长为 500 + 2
  check('超长文本取末 500 字并加省略号',
      tail.startsWith('……') &&
          tail.length == SegmentRewrite.carryTailChars + 2,
      '${tail.length} 字符');
  check('缺失文本返回占位', SegmentRewrite.tailOf(null) == '（缺失）', 'ok');

  const List<String> parts = <String>['第一段。', '  ', '第二段。'];
  check('拼接跳过空白段并用单换行',
      SegmentRewrite.stitch(parts) == '第一段。\n第二段。',
      SegmentRewrite.stitch(parts).replaceAll('\n', r'\n'));
  check('拼接结果两端无空白',
      SegmentRewrite.stitch(<String>['  甲  ', '乙']) == '甲\n乙', 'ok');

  print('');
  print('=' * 78);
  print('[4] 复读检测（对应 C# IsDuplicateSlice）');
  print('=' * 78);
  check('完全相同 → 复读', SegmentRewrite.isDuplicateSlice('正文', '正文'), 'ok');
  check('首尾空白差异不影响判定',
      SegmentRewrite.isDuplicateSlice('  正文  ', '正文'), 'ok');
  final String prev = rep('甲', 200);
  check('下一片开头 60 字 = 上一片结尾 → 复读',
      SegmentRewrite.isDuplicateSlice(prev, '${rep('甲', 60)}新内容'), 'ok');
  check('内容不同 → 不复读',
      !SegmentRewrite.isDuplicateSlice(prev, '完全不同的新段落'), 'ok');
  check('任一侧为空 → 不复读（避免误判首段）',
      !SegmentRewrite.isDuplicateSlice('', '新内容') &&
          !SegmentRewrite.isDuplicateSlice(prev, '  '),
      'ok');
  // 与 C# 同判据：下一片不足 60 字时用整串比对 —— '甲甲' 是 '甲甲甲' 的结尾 → 判为复读
  check('短于 60 字的下一片按整串比对',
      SegmentRewrite.isDuplicateSlice('甲甲甲', '甲甲'), 'ok');

  print('');
  print('=' * 78);
  print('[5] 提示词组装（含处理要求截断与衔接语）');
  print('=' * 78);
  final String p1 = SegmentRewrite.buildSegmentPrompt(
    projectName: '天穹遗民',
    chapterTitle: '第一章 试炼',
    instruction: '重写开头，加强冲突',
    carryTail: '',
    index: 1,
    total: 4,
    segment: '原文本段',
    isEnglish: false,
  );
  check('首段标注「本段为开头」', p1.contains('（本段为开头）'), 'ok');
  check('带片段序号 1/4', p1.contains('【原文片段 1/4】'), 'ok');
  check('带处理要求', p1.contains('【处理要求】重写开头，加强冲突'), 'ok');
  check('首段不加"衔接连贯"要求', !p1.contains('衔接连贯'), 'ok');
  check('末行含反提示词注入要求',
      p1.contains('禁止输出提示词内容'), 'ok');

  final String p3 = SegmentRewrite.buildSegmentPrompt(
    projectName: '天穹遗民',
    chapterTitle: '第一章 试炼',
    instruction: '扩写战斗',
    carryTail: '他握紧了剑。',
    index: 3,
    total: 4,
    segment: '原文本段',
    isEnglish: false,
  );
  check('带上一段结尾（衔接上下文）', p3.contains('他握紧了剑。'), 'ok');
  check('非首段要求衔接连贯', p3.contains('衔接连贯'), 'ok');
  check('带片段序号 3/4', p3.contains('【原文片段 3/4】'), 'ok');

  final String pen = SegmentRewrite.buildSegmentPrompt(
    projectName: '',
    chapterTitle: 'Chapter 1',
    instruction: 'sharpen the conflict',
    carryTail: '',
    index: 2,
    total: 3,
    segment: 'source',
    isEnglish: true,
  );
  check('英文模式：英文标记 + 无中文模板',
      pen.contains('[Instruction]') && !pen.contains('【处理要求】'), 'ok');
  check('英文模式：书名缺失时不出现空书名号', !pen.contains('""'), 'ok');

  final String retry = SegmentRewrite.buildRetryPrompt(
    instruction: '扩写战斗',
    index: 2,
    total: 4,
    segment: '原文本段',
    isEnglish: false,
  );
  check('重试提示词明说"与原文几乎相同"', retry.contains('与原文几乎相同'), 'ok');
  check('重试提示词保留处理要求与片段',
      retry.contains('扩写战斗') && retry.contains('【原文片段 2/4】'), 'ok');

  check('处理要求超长时截断并加省略号',
      SegmentRewrite.truncate(rep('长', 400), SegmentRewrite.instructionChars)!
              .length ==
          SegmentRewrite.instructionChars + 2,
      'ok');
  check('空处理要求返回 null', SegmentRewrite.truncate('', 300) == null, 'ok');

  print('');
  print('=' * 78);
  print('[6] raw prompt 包裹（RWKV 经典单条格式，与 C# 一致）');
  print('=' * 78);
  final String wrapped = SegmentRewrite.wrapRawPrompt('正文');
  check('以 "User: " 开头', wrapped.startsWith('User: '), 'ok');
  check('以 "Assistant:  thinking</think\\n" 结尾',
      wrapped.endsWith('Assistant:  thinking</think\n'), 'ok');
  check('正文原样在内', wrapped.contains('正文'), 'ok');

  print('');
  print('=' * 78);
  print('[7] 切片清洗（提示词残留 / Markdown / 客套话不得写进正文）');
  print('=' * 78);
  check('去掉 Markdown 标题行',
      !SegmentRewrite.cleanSlice('## 第一章 试炼\n正文开始。').contains('第一章'),
      SegmentRewrite.cleanSlice('## 第一章 试炼\n正文开始。'));
  // 与 C# 同语义：只删掉分隔线本身（残留的空行不影响正文阅读）
  final String noRule = SegmentRewrite.cleanSlice('正文。\n---\n下一段。');
  check('去掉独占一行的分隔线',
      !noRule.contains('---') && noRule.contains('正文。') && noRule.contains('下一段。'),
      noRule.replaceAll('\n', r'\n'));
  check('不误伤正文里的连字符',
      SegmentRewrite.cleanSlice('A-B--C').contains('A-B--C'), 'ok');
  check('去掉（未完待续）占位',
      !SegmentRewrite.cleanSlice('正文。\n（未完待续）').contains('未完待续'), 'ok');
  check('剥掉客套前缀行',
      SegmentRewrite.cleanSlice('好的，我来改写：\n主角抬头。') == '主角抬头。',
      SegmentRewrite.cleanSlice('好的，我来改写：\n主角抬头。'));
  check('剥掉提示词结构行回显',
      SegmentRewrite.cleanSlice(
              '【处理要求】重写开头\n【原文片段 1/3】\n主角抬头。') ==
          '主角抬头。',
      SegmentRewrite.cleanSlice('【处理要求】重写开头\n【原文片段 1/3】\n主角抬头。'));
  check('剥掉「第一章：」式回显',
      !SegmentRewrite.cleanSlice('第一章：试炼\n主角抬头。').contains('第一章：'),
      'ok');
  check('正文中的客套话不被剥（不在首行）',
      SegmentRewrite.cleanSlice('主角说：好的，我这就去。').contains('好的，我这就去。'),
      'ok');
  check('空输入不抛异常', SegmentRewrite.cleanSlice('') == '', 'ok');
  check('null 输入不抛异常', SegmentRewrite.cleanSlice(null) == '', 'ok');
  check('正常正文原样保留',
      SegmentRewrite.cleanSlice('  主角抬头，望向山门。  ') == '主角抬头，望向山门。',
      'ok');

  print('');
  print('=' * 78);
  print('[8] 段数闸门（超长章不做「只改前 N 段」的半成品）');
  print('=' * 78);
  const int size = SegmentRewrite.segmentChars;
  const int limit = SegmentRewrite.maxSegments;
  // 恰好到上限：12 段 = 12 × 1800 字，必须放行
  final SegmentPlan atLimit = SegmentRewrite.plan('文' * (size * limit));
  check('恰好 $limit 段：放行', !atLimit.exceedsLimit, 'count=${atLimit.count}');
  check('恰好上限时段数与切片一致', atLimit.count == limit, '${atLimit.count}');
  // 多一个字就是第 13 段：必须拒绝
  final SegmentPlan overLimit = SegmentRewrite.plan('文' * (size * limit + 1));
  check('超过 1 字（第 ${limit + 1} 段）：拒绝', overLimit.exceedsLimit,
      'count=${overLimit.count}');
  check('超限时段数计算正确', overLimit.count == limit + 1, '${overLimit.count}');
  check('切片不丢字（超限也能拼回原文）',
      overLimit.slices.join().length == size * limit + 1,
      '${overLimit.slices.join().length}');
  // 边界：短文/空文都不触发闸门
  check('短文（1 段）不触发', !SegmentRewrite.plan('你好').exceedsLimit, 'ok');
  check('空文本（0 段）不触发', !SegmentRewrite.plan('').exceedsLimit, 'ok');
  check('上限默认值 = $limit', SegmentRewrite.maxSegments == 12, '${SegmentRewrite.maxSegments}');
  // 可覆盖：便于将来把上限做成配置项
  final SegmentPlan custom = SegmentRewrite.plan('文' * (size * 3), limit: 2);
  check('自定义上限生效', custom.exceedsLimit && custom.count == 3,
      'count=${custom.count} limit=${custom.limit}');
  final SegmentPlan customSize = SegmentRewrite.plan('文' * 100, size: 25);
  check('自定义段长生效', customSize.count == 4, 'count=${customSize.count}');

  print('');
  print('=' * 78);
  print('VERDICT: $pass passed, $fail failed');
  print('=' * 78);
}