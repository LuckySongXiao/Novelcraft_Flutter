// 「写作工艺」端到端冒烟测试 —— **不启动 GUI，直接跑完整写作链路**。
//
// 为什么需要它：本项目的写作工艺（分片续写 / 清洗 / 质量闸 / 复读守卫）此前只能
// 通过 GUI 验证，而 GUI 需要能构建的机器。本工具把同一套**真实提示词 + 真实采样
// 参数 + 真实清洗闸门**搬到命令行，用真实 RWKV 端点跑一遍「分卷大纲 → 章大纲 →
// 分片续写 → 清洗 → 质量闸」，输出可量化的成书报告。
//
// 用法：
//   dart --disable-dart-dev tools/book_craft_smoketest.dart [chapters] [outDir]
//     chapters 本章数（默认 5）
//     outDir   输出目录（默认 _book_out）
//
// 环境变量：RWKV_BASE_URL / RWKV_MODEL / RWKV_NO_PROXY（同 rwkv_writing_bench.dart）
//
// ⚠ 会真实调用模型（付费 + 耗时）。不适合放进 CI。
library;

import 'dart:convert';
import 'dart:io';

import '../lib/ai/utils/chapter_plan_text.dart' show trimSliceEcho;
import '../lib/ai/utils/output_sanitizer.dart';
import '../lib/ai/utils/repetition_guard.dart';
import '../lib/ai/utils/repetition_repair_text.dart';

final String kBase = Platform.environment['RWKV_BASE_URL'] ??
    'https://api-7b.rwkvos.com/v1/chat/completions';
final String kModel = Platform.environment['RWKV_MODEL'] ??
    'rwkv7-g1k-7.2b-20260930-ctx25600';
final bool kNoProxy = Platform.environment['RWKV_NO_PROXY'] == '1';

const List<int> kStop = <int>[0, 261, 24281];

/// 成稿质量闸：单章最少字数（本项目定稿闸为 3200；冒烟测试用 1600 控成本）。
const int kMinChapterChars = 1600;

/// 每片续写目标字数。
const int kSliceChars = 1400;

/// 单片的输出预算系数（相对目标字数）。
///
/// ⚠ +47 实测：**单次生成越长，进入 n-gram 循环的概率越高**。
/// 本冒烟测试第一轮用 2.0 系数（1400 目标 → 2800 token 预算），模型两次
/// 冲到 ~2900 字，其中一次直接复读（ngram 0.884）；而参数实验里 2200 token
/// 预算下 0/3 退化。因此把系数收到 1.5，用**更多、更短的片**去凑总字数
/// （不足由补片循环兜底），换取稳定性。
const double kSliceBudgetFactor = 1.5;

/// 单章过不了闸时的重试次数（整章重写）。
const int kChapterRetries = 1;

/// +47 实测选定的正文采样参数（官方档原值 + decay 0.999）。
const Map<String, Object?> kProseParams = <String, Object?>{
  'top_k': 50,
  'top_p': 0.6,
  'alpha_presence': 2.0,
  'alpha_frequency': 0.2,
  'alpha_decay': 0.999,
  'dry_multiplier': 0.8,
  'dry_base': 1.75,
  'dry_allowed_length': 2,
  'dry_penalty_last_n': 2048,
  'stop_tokens': kStop,
};

/// 正文温度（+47 实测：0.88→1/3 退化，1.0→0/3）。
const double kProseTemperature = 1.0;

/// 结构化任务温度（大纲/JSON）。
const double kStructuredTemperature = 0.7;

// ---------------------------------------------------------------------------
// 书籍设定（由作者设定，**刻意选非修仙题材**以验证「去硬编码」）
// ---------------------------------------------------------------------------

const String kBookTitle = '低潮图书馆';
const String kGenre = '都市悬疑 · 轻奇幻';
const String kTheme = '人是否应该改写尚未发生的坏事 —— 以及改写的代价由谁承担。';
const String kBackground = '临海小城「潮尾镇」。镇东海岬的旧灯塔下，有一座只在退潮时'
    '露出水面的图书馆：涨潮时它被海水淹没，退潮的四十分钟里，门会开。'
    '馆内每一本书都记录着一件**尚未发生**的事，按人名编目。'
    '镇上的人只知道「退潮时别往东岬走」，没人知道那些书的存在。';
const String kProtagonist = '沈砚，28 岁，市立图书馆夜班管理员。'
    '有轻度面孔失认症：认不出人脸，只能靠声音、步态和习惯认人 —— '
    '这让他在低潮图书馆里只能靠**书名上的人名**去辨认「谁即将出事」。';
const String kCast = '沈砚（主角，夜班馆员）；周晓棠（海防派出所民警，行动派，不信邪）；'
    '老岑（灯塔守，守了四十年，知道图书馆的来历）；'
    '「编目员」（低潮图书馆的真正主人，从未露脸，只在借阅卡上留字）。';

/// 分卷（3 卷 × 5 章）。冒烟测试默认只跑第一卷。
const String kVolumeOutline = '## 第一卷 · 退潮四十分钟\n'
    '简介：沈砚在一次退潮中第一次走进低潮图书馆，发现书架按人名编目，'
    '其中一本书上写着周晓棠的名字，记录她将在三日后溺亡。他决定改写它。\n'
    '核心冲突：改写「尚未发生的事」的代价会落在别处 —— 沈砚必须在救人与代价之间选择。\n'
    '主角阶段目标：弄清图书馆的规则，并救下周晓棠。\n'
    '## 第二卷 · 借阅卡上的字\n'
    '简介：沈砚发现借阅卡上出现了自己的名字，且「编目员」开始回应他。\n'
    '核心冲突：他越是想弄清真相，越发现自己可能才是这座图书馆的一部分。\n'
    '主角阶段目标：找到「编目员」，问出图书馆的来历。\n'
    '## 第三卷 · 涨潮\n'
    '简介：百年一遇的大潮将至，图书馆将被永久淹没；镇上所有人的名字都出现在同一本书上。\n'
    '核心冲突：救全城，还是保住图书馆与老岑。\n'
    '主角阶段目标：在涨潮前做出选择并承担后果。';

/// 第一卷五章的章大纲（作者给出，模拟「章大纲」输入）。
const List<String> kChapterOutlines = <String>[
  '本章目标：沈砚在夜班整理旧书时，从一本被海水泡烂的登记册里读到「低潮图书馆」四个字，'
      '并发现归还日期写着三天后。\n'
      '承接上文：全书开篇。沈砚刚接手市立图书馆的夜班，镇上正在传「东岬退潮时别去」。\n'
      '核心冲突：沈砚的职业习惯（按登记册核对）与镇上的禁忌相冲突。\n'
      '关键转折：他在登记册最后一页看到周晓棠的名字，日期是三天后。\n'
      '章末钩子：窗外传来退潮的声响，钟指向凌晨三点。\n'
      '出场人物：沈砚、周晓棠（电话里）、门卫老周。\n'
      '故事时间节点：入秋第一场大潮前的第三天，凌晨。',
  '本章目标：沈砚在退潮的四十分钟里第一次走进低潮图书馆，确认书架按人名编目。\n'
      '承接上文：上一章结尾他决定去东岬看一眼。\n'
      '核心冲突：他想找到写有周晓棠名字的那本书，但馆内没有灯，只有退潮的光。\n'
      '关键转折：他找到了那本书，书里写着她将在三天后溺亡于防波堤下。\n'
      '章末钩子：他抽出那本书的瞬间，另一本书从架上掉了下来 —— 封面是他的名字。\n'
      '出场人物：沈砚。\n'
      '故事时间节点：同一夜的退潮四十分钟内。',
  '本章目标：沈砚试图警告周晓棠，却因面孔失认症在人群中认不出她；他改用「念名字」的方式接近她。\n'
      '承接上文：上一章结尾他看见写有自己名字的书，但没敢翻开。\n'
      '核心冲突：周晓棠是民警，本能地不信超自然说法；沈砚又拿不出证据。\n'
      '关键转折：周晓棠随口说出一件只有登记册上才有的事，让沈砚确认「书是真的」。\n'
      '章末钩子：周晓棠说她三天后要去防波堤处理一桩案子。\n'
      '出场人物：沈砚、周晓棠、老岑（远处观望）。\n'
      '故事时间节点：第二日白天。',
  '本章目标：沈砚向老岑求证图书馆的来历，并第一次知道「改写的代价」。\n'
      '承接上文：上一章结尾他意识到警告无用，必须自己动手。\n'
      '核心冲突：老岑警告他「改一条，坏一条」—— 图书馆会把代价挪到别处。\n'
      '关键转折：沈砚在借阅卡上写下自己的名字，替周晓棠「借」走那本书。\n'
      '章末钩子：借阅卡背面浮现一行陌生的字迹：「你确定要拿自己换吗？」\n'
      '出场人物：沈砚、老岑。\n'
      '故事时间节点：第二日黄昏，退潮前。',
  '本章目标：沈砚完成改写，代价显形 —— 镇上另一个人被卷进同一起事故。\n'
      '承接上文：上一章结尾他签下了借阅卡。\n'
      '核心冲突：救周晓棠的代价是门卫老周将代替她出现在防波堤下。\n'
      '关键转折：沈砚必须在「救谁」之间做第一次真正的选择，并承担它。\n'
      '章末钩子：退潮的水位比往常更低，露出了一级从未见过的台阶。\n'
      '出场人物：沈砚、周晓棠、老周、老岑。\n'
      '故事时间节点：第三日，大潮当日。',
];

// ---------------------------------------------------------------------------
// 采样 / 提示
// ---------------------------------------------------------------------------

const String kSystemProse =
    '你是专业中文小说主笔作家。要求：严格中文、第三人称、只用给定的人物与设定'
    '（不得引入其它作品的人物或名词）；只输出章节正文，不要输出标题、分节标记、'
    '解释、字数统计或大纲复述；开头抓眼球，结尾留钩子；必须写满要求的字数。';
const String kSystemStructured = '你是专业中文小说编辑。只输出要求的结构化内容，不要解释。';

Future<Map<String, Object?>> post(Map<String, Object?> body) async {
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30);
  if (kNoProxy) client.findProxy = ((Uri uri) => 'DIRECT');
  try {
    final HttpClientRequest req = await client.postUrl(Uri.parse(kBase));
    req.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
    req.add(utf8.encode(jsonEncode(body)));
    final HttpClientResponse resp =
        await req.close().timeout(const Duration(seconds: 300));
    final String text = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      return <String, Object?>{'err': 'HTTP ${resp.statusCode}'};
    }
    final dynamic d = jsonDecode(text);
    if (d is Map && d['choices'] is List && (d['choices'] as List).isNotEmpty) {
      final dynamic m = (d['choices'] as List).first;
      final dynamic c =
          (m is Map && m['message'] is Map) ? m['message']['content'] : null;
      return <String, Object?>{'content': c?.toString() ?? ''};
    }
    return <String, Object?>{'err': 'shape'};
  } finally {
    client.close(force: true);
  }
}

/// 一次生成（带一次重试）。
Future<String> generate({
  required String system,
  required String user,
  required int maxTokens,
  required double temperature,
  bool prose = true,
  int retries = 1,
}) async {
  for (int attempt = 0; attempt <= retries; attempt++) {
    try {
      final Map<String, Object?> r = await post(<String, Object?>{
        'model': kModel,
        'messages': <Map<String, String>>[
          <String, String>{'role': 'system', 'content': system},
          <String, String>{'role': 'user', 'content': user},
        ],
        'stream': false,
        'max_tokens': maxTokens,
        'temperature': temperature,
        if (prose) ...kProseParams,
      });
      final String c = (r['content'] ?? '').toString().trim();
      if (c.isNotEmpty) return c;
    } catch (_) {
      // 网络抖动 → 重试
    }
  }
  return '';
}

// ---------------------------------------------------------------------------
// 清洗与质量闸（镜像 `MultiAgentBookGenerationService._cleanFinalChapter`
// / `_qualityNoteParams`，只依赖纯 Dart 工具）
// ---------------------------------------------------------------------------

String cleanChapter(String raw) {
  String t = AIOutputSanitizer.stripStateUpdateBlocks(raw);
  t = AIOutputSanitizer.stripMetaPreambles(t);
  t = t.replaceAll(
    RegExp(r'<think>[\s\S]*?</think>|<thinking>[\s\S]*?</thinking>',
        caseSensitive: false),
    '',
  );
  t = t.replaceFirst(
    RegExp(r'^\s*<(?:think|thinking)>[\s\S]*$', caseSensitive: false),
    '',
  );
  t = t.replaceAll(RegExp(r'</?(?:think|thinking)>', caseSensitive: false), '');
  t = t.replaceAll(RegExp(r'【段落\d+[^】]*】'), '');
  t = t.replaceAll(RegExp(r'<\|[^|]{0,24}\|>'), '');
  t = t.replaceFirst(RegExp(r'^[\s>＞]+'), '');
  t = t.replaceAll(RegExp(r'^[ \t]*#{1,6}[ \t]*.*$', multiLine: true), '');
  t = t.replaceAll(RegExp(r'^[ \t]*[-*+][ \t]+', multiLine: true), '');
  t = t.replaceAll('**', '');
  // 相邻重复段折叠 + 尾部退化截断（与 App 同策）。
  final List<String> paras =
      t.split(RegExp(r'\n\s*\n')).map((String p) => p.trim()).toList();
  final StringBuffer sb = StringBuffer();
  String prev = '';
  for (final String p in paras) {
    if (p.isEmpty || p == prev) continue;
    if (sb.isNotEmpty) sb.write('\n\n');
    sb.write(p);
    prev = p;
  }
  t = sb.toString();
  final int onset = RepetitionRepair.degenerationOnset(t);
  if (onset > 0) t = RepetitionRepair.cleanTruncated(t.substring(0, onset));
  return t.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

/// 质量闸：空串 = 通过；非空 = 原因。
String qualityNote(String text) {
  final int len = text.trim().length;
  if (len == 0) return '正文为空';
  if (len < kMinChapterChars) return '字数不足（$len < $kMinChapterChars）';
  // 大纲体检测（与 App `_looksLikeOutline` 同口径）。
  int hits = 0;
  for (final String raw in text.split(RegExp(r'\r?\n'))) {
    final String l = raw.trim();
    if (l.isEmpty) continue;
    if (RegExp(r'^#{1,6}\s').hasMatch(l) ||
        RegExp(r'^[-*+]\s{1,2}\S').hasMatch(l) ||
        RegExp(
          r'^(?:地点|时间|人物|事件|主题|冲突|场景|目标|伏笔|钩子|'
          r'章节|大纲|要求|设定|简介|概览|说明)[：:]',
        ).hasMatch(l)) {
      hits++;
    }
  }
  if (hits >= 4) return '疑似大纲式输出';
  if (RepetitionGuard.isDegenerate(text)) {
    return '复读率过高（${RepetitionGuard.diagnose(text)}）';
  }
  return '';
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

Future<void> main(List<String> args) async {
  final int chapterCount = args.isNotEmpty ? (int.tryParse(args[0]) ?? 5) : 5;
  final String outDir = args.length > 1 ? args[1] : '_book_out';
  Directory(outDir).createSync(recursive: true);

  final StringBuffer log = StringBuffer();
  void w(String s) {
    log.writeln(s);
    stdout.writeln(s);
  }

  w('=== 写作工艺冒烟测试 ===');
  w('书：《$kBookTitle》 [$kGenre]');
  w('模型：$kModel');
  w('参数：$kProseParams');
  w('正文温度：$kProseTemperature  章数：$chapterCount  输出：$outDir');
  w('');

  // ---- 阶段 1：章大纲（模型按主题/背景/卷纲生成，用于验证大纲链路）----
  w('--- 阶段 1：生成章大纲 ---');
  final StringBuffer outlineAsk = StringBuffer()
    ..writeln('书名：《$kBookTitle》  题材：$kGenre')
    ..writeln('主题：$kTheme')
    ..writeln('背景：$kBackground')
    ..writeln('主角：$kProtagonist')
    ..writeln('主要人物：$kCast')
    ..writeln('分卷大纲：\n$kVolumeOutline')
    ..writeln('请为第一卷生成 $chapterCount 章的章大纲，每章严格按以下 7 行输出'
        '（不要 Markdown 标记、不要解释）：')
    ..writeln('第N章：《章名》')
    ..writeln('本章目标：…')
    ..writeln('承接上文：…')
    ..writeln('核心冲突：…')
    ..writeln('关键转折：…')
    ..writeln('章末钩子：…')
    ..writeln('出场人物：…');
  final String rawOutlines = await generate(
    system: kSystemStructured,
    user: outlineAsk.toString(),
    maxTokens: 2048,
    temperature: kStructuredTemperature,
    prose: false,
  );
  // 无论模型给什么，都以**作者给定的章大纲**为准（冒烟测试要可复现）。
  final List<String> outlines = kChapterOutlines.take(chapterCount).toList();
  w('模型大纲产出 ${rawOutlines.length} 字（仅作观察；写作以下方作者大纲为准）');
  File('$outDir/00_model_outlines.txt').writeAsStringSync(rawOutlines);
  w('');

  // ---- 阶段 2：逐章分片续写 ----
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
  // 微调示范样本（prompt → 通过闸门的正文），格式对齐 state_tuning 数据集。
  final List<Map<String, String>> pairs = <Map<String, String>>[];
  String tail = '';
  for (int i = 0; i < outlines.length; i++) {
    final int no = i + 1;
    final String outline = outlines[i];
    w('--- 第 $no 章 ---');
    // 整章重试：过不了闸就整章重写（复读是随机事件，重试即好）。
    String cleaned = '';
    String note = '';
    int sliceNo = 0;
    for (int attempt = 1; attempt <= kChapterRetries + 1; attempt++) {
      final StringBuffer body = StringBuffer();
      final String tailAtStart = tail; // 重试时从同一前文重新起笔
      sliceNo = 0;
      while (body.length < kMinChapterChars + 400 && sliceNo < 4) {
        sliceNo++;
        final int need = kMinChapterChars + 400 - body.length;
        final int ask = need < kSliceChars ? need : kSliceChars;
        final String curTail = body.isEmpty
            ? tailAtStart
            : (body.length > 500
                ? body.toString().substring(body.length - 500)
                : body.toString());
        final String tailPart = curTail.isEmpty
            ? '请从本章第一句开始写。'
            : '【前文末尾（仅供衔接上下文，**不要输出这一段**）】\n$curTail\n\n'
                '请紧接上文写下去。只输出**新增**的正文，第一句不得与前文末尾重复。';
        final String user =
            '任务：写《$kBookTitle》第一卷 第$no章 的正文（第 $sliceNo 片）。\n'
            '题材：$kGenre\n背景：$kBackground\n主角：$kProtagonist\n人物：$kCast\n'
            '本章大纲：\n$outline\n'
            '篇幅：本片不少于 $ask 字的成稿正文。这是硬要求。\n'
            '$tailPart';
        final String raw = await generate(
          system: kSystemProse,
          user: user,
          maxTokens: (ask * kSliceBudgetFactor).clamp(1000, 2400).toInt(),
          temperature: kProseTemperature,
        );
        final String piece = cleanChapter(raw);
        if (piece.isEmpty) {
          w('  片$sliceNo：失败（空）');
          break;
        }
        // 回声去重：用项目自带的 `trimSliceEcho`（剥回抄的「前文末尾」与提示词标记）。
        final String trimmed = trimSliceEcho(curTail, piece);
        final String body2 = trimmed.isEmpty ? piece : trimmed;
        // 只有「清洗后仍干净、且够长」的片段才作为示范样本（宁缺勿滥）。
        if (body2.length >= 600 && !RepetitionGuard.isDegenerate(body2)) {
          pairs.add(<String, String>{
            'prompt': '$kSystemProse\n\n$user',
            'completion': body2,
          });
        }
        if (body.isNotEmpty) body.write('\n\n');
        body.write(body2);
        w('  片$sliceNo：${piece.length} 字（累计 ${body.length}）');
      }

      cleaned = cleanChapter(body.toString());
      note = qualityNote(cleaned);
      if (note.isEmpty) break;
      if (attempt <= kChapterRetries) {
        w('  ⚠ 第 $no 章未过闸（$note）→ 整章重写（第 ${attempt + 1} 次）');
      }
    }
    // 本章通过后，把最终正文末尾作为下一章的前文（失败章不污染上下文）。
    tail = cleaned.length > 500 ? cleaned.substring(cleaned.length - 500) : cleaned;

    final double ng = RepetitionGuard.charNgramRepeatRatio(cleaned);
    final double pr = RepetitionGuard.paragraphRepeatRatio(cleaned);
    final bool pass = note.isEmpty;
    rows.add(<String, Object?>{
      'chapter': no,
      'chars': cleaned.length,
      'ngram': double.parse(ng.toStringAsFixed(4)),
      'para': double.parse(pr.toStringAsFixed(4)),
      'pass': pass,
      'note': note,
      'slices': sliceNo,
    });
    File('$outDir/${no.toString().padLeft(2, '0')}_chapter.txt')
        .writeAsStringSync(cleaned);
    w('  第 $no 章：${cleaned.length} 字  ngram=${ng.toStringAsFixed(3)} '
        'para=${pr.toStringAsFixed(3)}  ${pass ? '✅ 过闸' : '❌ $note'}');
    w('');
  }

  // ---- 阶段 3：成书体检 ----
  final int passed = rows.where((Map<String, Object?> r) => r['pass'] == true).length;
  final double avgChars = rows.isEmpty
      ? 0
      : rows
              .map((Map<String, Object?> r) => (r['chars']! as num).toDouble())
              .reduce((a, b) => a + b) /
          rows.length;
  final double avgNg = rows.isEmpty
      ? 0
      : rows
              .map((Map<String, Object?> r) => (r['ngram']! as num).toDouble())
              .reduce((a, b) => a + b) /
          rows.length;
  w('=== 成书报告 ===');
  w('章数：${rows.length}  过闸：$passed/${rows.length}  '
      '平均字数：${avgChars.round()}  平均 ngram：${avgNg.toStringAsFixed(3)}');
  for (final Map<String, Object?> r in rows) {
    w('  第${r['chapter']}章 ${r['chars']}字 ngram=${r['ngram']} '
        '${r['pass'] == true ? 'OK' : 'NG(${r['note']})'}');
  }
  File('$outDir/report.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(rows),
  );
  File('$outDir/report.txt').writeAsStringSync(log.toString());

  // ---- 阶段 4：导出微调示范样本（两种格式，对齐 state_tuning 数据集）----
  final StringBuffer raw = StringBuffer();
  final StringBuffer pc = StringBuffer();
  for (final Map<String, String> p in pairs) {
    raw.writeln(jsonEncode(<String, String>{
      'text': '${p['prompt']}\n\n${p['completion']}',
    }));
    pc.writeln(jsonEncode(<String, String>{
      'prompt': p['prompt']!,
      'completion': p['completion']!,
    }));
  }
  File('$outDir/ft_raw_text.jsonl').writeAsStringSync(raw.toString());
  File('$outDir/ft_prompt_completion.jsonl').writeAsStringSync(pc.toString());
  w('WROTE $outDir/report.json');
  w('示范样本：${pairs.length} 条 → ft_raw_text.jsonl / ft_prompt_completion.jsonl');
}
