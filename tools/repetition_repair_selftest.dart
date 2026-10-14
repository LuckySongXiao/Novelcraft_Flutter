// 正文复读修复自检（纯 Dart，离线直跑）：
//   dart --disable-dart-dev tools/repetition_repair_selftest.dart
//
// ⚠ 夹具必须**互不重复**：早期版本用「同一段散文 × N」当健康样本，
// 结果它本身就是复读（ngram=0.83），把用例判成了误报。这里改用 30 句
// 各不相同的散文拼成长样本。
import '../lib/ai/utils/repetition_guard.dart';
import '../lib/ai/utils/repetition_repair_text.dart';

int pass = 0;
int fail = 0;

void ok(String name, bool cond, [String detail = '']) {
  if (cond) {
    pass++;
    print('PASS  $name');
  } else {
    fail++;
    print('FAIL  $name  $detail');
  }
}

/// 30 句**互不重复**的散文（约 800 字）——「健康正文」样本。
const List<String> healthySentences = <String>[
  '陈九把最后一扇窗掩上，回身看见桌上那盏油灯正一跳一跳地烧着。',
  '他伸手拨了拨灯芯，火光稳下来，照出墙角那只落了灰的木箱。',
  '木箱的锁是新的，铜面还亮着，显然不久前才被人换过。',
  '他盯着那把锁看了很久，直到门外传来脚步声，才慢慢直起身。',
  '那脚步声不紧不慢，在门槛外停住了，接着是三下轻轻的叩门。',
  '他没有应声，只是把手按在锁扣上，指节一点点收紧。',
  '门外的人也没有再敲，像是笃定他一定会开门。',
  '风从门缝里钻进来，把灯苗吹得偏向一边，影子在墙上晃了晃。',
  '陈九终于开口，声音比他自己预想的还要哑。',
  '回答他的是一阵沉默，然后是衣料摩擦的轻响。',
  '祠堂的檐角挂着一串旧铃，风过时只发出很轻的哑响。',
  '井台边的青苔厚得能掐出水来，木桶搁在上面留下一圈湿痕。',
  '三叔公的烟锅敲在石阶上，火星溅开又很快熄灭。',
  '供桌上的香灰积了半寸，扫帚扫过时扬起一小片灰雾。',
  '牌位一排排立着，黑漆在烛火里泛出暗红的光。',
  '他想起小时候跟着父亲来上香，那时牌位还没有这么多。',
  '村道尽头的槐树被雷劈过，只剩半边树冠歪歪地撑着。',
  '谁家的狗在远处叫了两声，随即又安静下来。',
  '河面结着薄冰，月光落在上面像撒了一层碎银。',
  '他把蓑衣挂在门后，水珠顺着草茎一颗颗往下滴。',
  '灶膛里的火已经熄了，铁锅底还留着余温。',
  '他掀开锅盖，里面只有半碗冷掉的糙米饭。',
  '扁担靠在墙角，绳结磨得发亮，看得出用了很多年。',
  '窗外有只夜鸟掠过，翅膀扇动的声音很短促。',
  '他吹灭了灯，黑暗一下子涌上来，把屋子填得满满当当。',
  '他躺下时听见自己的心跳，比平常要慢一些。',
  '天快亮的时候，雾从河面漫上来，把整个村子裹了进去。',
  '鸡叫头遍时，他翻身坐起，发现鞋底沾了一层白霜。',
  '院子里的水缸结了冰，他用瓢敲了两下才敲开。',
  '他挑起扁担出门，脚下的雪被踩得咯吱作响。',
  '他沿着河岸往南走，脚下的碎石被霜冻得发硬。',
  '芦苇丛里传来水鸟扑翅的声响，很快又归于寂静。',
  '渡口的木船系在桩上，船身积了薄薄一层雪。',
  '船头挂着的马灯早已熄灭，玻璃罩上蒙着一层灰。',
  '对岸的灯火稀疏，只有一两户人家还亮着窗。',
  '他把扁担横在肩上，另一头挑着一只旧布包。',
  '布包里装着几件换洗衣裳和半块干粮。',
  '走到岔路口时，他停下来辨认了一下方向。',
  '左边的路通向山里，右边的路沿着河继续往南。',
  '他选了左边，因为山里的雾看起来更薄一些。',
  '山路两旁的松树被雪压弯了枝，偶尔抖落一团白。',
  '走了约莫半个时辰，他听见前面有砍柴的声音。',
  '循声过去，看见一个老人正蹲在树下捆柴。',
  '老人抬头看了他一眼，没有说话，又低下头去。',
  '陈九在离他三步远的地方站住，把扁担放了下来。',
];

String get healthyText => healthySentences.join();

/// 同一句循环——退化的尾部。
const String loopSentence = '他终于明白，这一切都指向同一个答案。';

String loopTail(int n) => loopSentence * n;

void main() {
  print('===== A. 健康正文：不得误判、不得误截 =====');
  {
    final String text = healthyText;
    final RepetitionReport r = RepetitionRepair.analyze(text);
    print('   healthy len=${r.length} ngram=${r.ngram.toStringAsFixed(3)} '
        'para=${r.paragraph.toStringAsFixed(3)} onset=${r.onset}');
    ok('A1 健康长文不判退化', !r.degenerate, 'ngram=${r.ngram}');
    ok('A2 健康长文无退化起点', r.onset == 0, 'onset=${r.onset}');
    ok('A3 健康长文不产出修复稿', r.repaired.isEmpty);
    ok('A4 canTruncate=false', !r.canTruncate);
  }

  print('');
  print('===== B. 前半健康 + 后半复读：应定位并截断 =====');
  {
    // 总长必须 > window*4（1600）——退化起点检测才有足够滑窗。
    final String text = healthyText + loopTail(60);
    final RepetitionReport r = RepetitionRepair.analyze(text);
    print('   len=${r.length} ngram=${r.ngram.toStringAsFixed(3)} '
        'para=${r.paragraph.toStringAsFixed(3)} onset=${r.onset} '
        'keep=${r.keepChars} drop=${r.dropChars}');
    ok('B1 判为退化', r.degenerate, 'ngram=${r.ngram}');
    ok('B2 检出退化起点', r.onset > 0, 'onset=${r.onset}');
    ok('B3 可截断修复', r.canTruncate);
    ok('B4 修复稿不退化', !RepetitionGuard.isDegenerate(r.repaired),
        'ngram=${RepetitionGuard.charNgramRepeatRatio(r.repaired)}');
    ok('B5 修复稿比原文短', r.repaired.length < r.length);
    ok('B6 保留量 ≥ 下限', r.keepChars >= RepetitionRepair.kMinRepairedChars,
        'keep=${r.keepChars}');
    ok('B7 保留的是健康前缀（含开头）',
        r.repaired.startsWith('陈九把最后一扇窗掩上'));
    ok('B8 预览含标记', r.preview.contains('从这里开始复读'), r.preview);
    ok('B9 幂等：修复稿再体检不再退化',
        !RepetitionRepair.analyze(r.repaired).degenerate);
  }

  print('');
  print('===== C. 整篇复读：不可截断，应引导重写 =====');
  {
    final String text = loopTail(200);
    final RepetitionReport r = RepetitionRepair.analyze(text);
    print('   len=${r.length} ngram=${r.ngram.toStringAsFixed(3)} onset=${r.onset}');
    ok('C1 判为退化', r.degenerate);
    ok('C2 无可用截断（onset=0）', r.onset == 0, 'onset=${r.onset}');
    ok('C3 canTruncate=false（应重写）', !r.canTruncate);
  }

  print('');
  print('===== D. 边界 =====');
  {
    final RepetitionReport r = RepetitionRepair.analyze('');
    ok('D1 空文本安全', r.length == 0 && !r.degenerate && !r.canTruncate);
  }
  {
    final RepetitionReport r = RepetitionRepair.analyze('很短的一句话。');
    ok('D2 短文本不判', !r.degenerate && r.onset == 0);
  }
  {
    // 健康前缀太短（10 句 ≈ 270 字，< 全文 30%）→ 不给修复稿。
    final String text =
        healthySentences.take(10).join() + loopTail(90);
    final RepetitionReport r = RepetitionRepair.analyze(text);
    print('   short-prefix: len=${r.length} onset=${r.onset} keep=${r.keepChars}');
    ok('D3 前缀过短 → 不截断（应重写）', !r.canTruncate, 'onset=${r.onset}');
  }

  print('');
  print('===== E. 截断清理：收在句末、不留半句 =====');
  {
    final String cleaned = RepetitionRepair.cleanTruncated(
      '第一句写完了。第二句也写完了。这是一段没收尾的半句',
    );
    ok('E1 收在句末', cleaned.endsWith('。'), cleaned);
    ok('E2 不留半句', !cleaned.contains('这是一段没收尾的半句'), cleaned);
  }
  {
    final String cleaned = RepetitionRepair.cleanTruncated(
      '段落一。\n\n段落一。\n\n段落二。',
    );
    ok('E3 折叠紧邻重复段', cleaned == '段落一。\n\n段落二。', cleaned);
  }

  print('');
  print('=== pass=$pass fail=$fail ===');
  if (fail > 0) throw StateError('repetition_repair_selftest FAILED: $fail');
}
