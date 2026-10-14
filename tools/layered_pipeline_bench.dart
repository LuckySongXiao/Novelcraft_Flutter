// 分层写书管线 —— **命令行跑案例**（真实 RWKV 端点）。
//
// 用法（必须带 --disable-dart-dev）：
//   dart --disable-dart-dev tools/layered_pipeline_bench.dart [chapters] [outDir] [volumes]
//     chapters 每卷章数（默认 5）
//     outDir   输出目录（默认 _layered_out）
//     volumes  卷数（默认 1）
//
// 环境变量：RWKV_BASE_URL / RWKV_MODEL / RWKV_NO_PROXY（同其它 bench 工具）
//
// 传输策略（+50 实测结论，见 HANDOFF）：
//   * **正文（prose=true）走有状态路由** `/state/chat/completions`：
//     同一章的多片共享一条 state 链，后续片**只发增量**（RWKV 的 O(1) 上下文接续）。
//   * **结构化任务走无状态路由** `/v1/chat/completions`：输出干净（不夹思考前缀）。
//   * ⚠ 实测：`/state/*` 无视 `think_type: none`，每轮先吐 `<think>`；
//     由 `LayeredBookGenerationService._stripThink` 剥离。
//
// ⚠ 会真实调用模型（付费 + 耗时）。不适合放进 CI。
library;

import 'dart:convert';
import 'dart:io';

import '../lib/ai/utils/chapter_plan_text.dart' show trimSliceEcho;
import '../lib/ai/utils/foreshadow_ledger.dart';
import '../lib/ai/utils/layered_pipeline_plan.dart';
import '../lib/ai/utils/output_sanitizer.dart';
import '../lib/ai/utils/repetition_guard.dart';
import '../lib/ai/utils/repetition_repair_text.dart';
import '../lib/application/services/layered_book_generation_service.dart';

final String kBase = Platform.environment['RWKV_BASE_URL'] ??
    'https://api-7b.rwkvos.com/v1/chat/completions';
final String kModel = Platform.environment['RWKV_MODEL'] ??
    'rwkv7-g1k-7.2b-20260930-ctx25600';
final bool kNoProxy = Platform.environment['RWKV_NO_PROXY'] == '1';

/// state 路由（注意：**不带 `/v1`**，见 PITFALLS §32.1）。
final String kStateUrl = Platform.environment['RWKV_STATE_URL'] ??
    'https://api-7b.rwkvos.com/state/chat/completions';

const List<int> kStop = <int>[0, 261, 24281];

/// 正文采样参数（+48 实测最严防重复档）。
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

// ---------------------------------------------------------------------------
// 书籍设定（与基线 `book_craft_smoketest.dart` **逐字一致**，保证可比）
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

/// 全书起点 → 终点（L1 的锚）。
const PipelineAnchor kBookAnchor = PipelineAnchor(
  start: '沈砚刚接手市立图书馆夜班，镇上流传「东岬退潮时别去」的说法，'
      '他对低潮图书馆一无所知，与周晓棠只是点头之交。',
  end: '百年大潮退去，低潮图书馆被永久淹没；沈砚知道了「编目员」是谁、'
      '也明白了改写的代价由谁承担，并做出最终选择后承担后果。'
      '镇上的生活恢复平静，但沈砚与周晓棠的关系已不可逆地改变。',
  startLabel: '全书起点',
  endLabel: '全书终点',
);

/// 每卷章数（第一卷）。第二、三卷的推进方向由锚点给出。
const int kChaptersPerVolume = 5;

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

final HttpClient _client = HttpClient()
  ..connectionTimeout = const Duration(seconds: 30);

Future<Map<String, Object?>> _post(String url, Map<String, Object?> body) async {
  if (kNoProxy) _client.findProxy = ((Uri uri) => 'DIRECT');
  final HttpClientRequest req = await _client.postUrl(Uri.parse(url));
  req.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
  req.add(utf8.encode(jsonEncode(body)));
  final HttpClientResponse resp =
      await req.close().timeout(const Duration(seconds: 300));
  final String text = await resp.transform(utf8.decoder).join();
  if (resp.statusCode != 200) {
    return <String, Object?>{'err': 'HTTP ${resp.statusCode}'};
  }
  final Object? d = jsonDecode(text);
  if (d is Map && d['choices'] is List && (d['choices'] as List).isNotEmpty) {
    final Object? m = (d['choices'] as List).first;
    final Object? c =
        (m is Map && m['message'] is Map) ? (m['message'] as Map)['content'] : null;
    return <String, Object?>{'content': c?.toString() ?? ''};
  }
  return <String, Object?>{'err': 'shape'};
}

/// 剥掉全部 `<think>` 内容（含未闭合），用于判断「本轮是否只产出了思考」。
String _stripAllThink(String raw) {
  String t = raw.replaceAll(
      RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false), '');
  t = t.replaceFirst(
      RegExp(r'^\s*<think(?:ing)?>[\s\S]*$', caseSensitive: false), '');
  return t.replaceAll(RegExp(r'</?(?:think|thinking)>', caseSensitive: false), '').trim();
}

/// 有状态会话是否已建（首轮发完整 prompt，之后只发增量）。
final Set<String> _freshSessions = <String>{};

/// 一次调用（带重试；按 prose 选择传输）。
Future<String> _chat(LayeredChatRequest r) async {
  final bool useState = r.stateful && r.sessionKey.isNotEmpty;
  for (int attempt = 0; attempt <= 2; attempt++) {
    try {
      final Map<String, Object?> body;
      final String url;
      if (useState) {
        final bool first = !_freshSessions.contains(r.sessionKey);
        final String prompt = first
            ? 'System: ${r.system}\n\nUser: ${r.user}\n\nAssistant:'
            : 'User: ${r.user}\n\nAssistant:';
        _freshSessions.add(r.sessionKey);
        url = kStateUrl;
        body = <String, Object?>{
          'session_id': r.sessionKey,
          'contents': <String>[prompt],
          'stream': false,
          'max_tokens': r.maxTokens,
          'stop_tokens': kStop,
          // 实测本部署的 /state/* 无视该字段（仍会思考），保留仅为向前兼容
          'think_type': 'none',
          ...kProseParams,
        };
      } else {
        url = kBase;
        body = <String, Object?>{
          'model': kModel,
          'messages': <Map<String, String>>[
            <String, String>{'role': 'system', 'content': r.system},
            <String, String>{'role': 'user', 'content': r.user},
          ],
          'stream': false,
          'max_tokens': r.maxTokens,
          'temperature': r.temperature,
          'think_type': 'none',
        };
      }
      final Map<String, Object?> res = await _post(url, body);
      final String c = (res['content'] ?? '').toString().trim();
      if (c.isNotEmpty) {
        // 自愈：本轮只产出了思考（剥离后为空）→ 同一会话再发一轮「直接输出」。
        // 实测：`/state/*` 首轮必思考，思考若吃满 max_tokens 就会正文为空。
        if (useState && _stripAllThink(c).isEmpty) {
          final Map<String, Object?> again = await _post(kStateUrl, <String, Object?>{
            'session_id': r.sessionKey,
            'contents': <String>['User: 请直接输出结果，不要再思考，不要重复上面的内容。\n\nAssistant:'],
            'stream': false,
            'max_tokens': r.maxTokens,
            'stop_tokens': kStop,
            'think_type': 'none',
            ...kProseParams,
          });
          final String c2 = (again['content'] ?? '').toString().trim();
          if (_stripAllThink(c2).isNotEmpty) return c2;
        }
        return c;
      }
    } on Object {
      // 网络抖动 / 524 → 重试
    }
  }
  return '';
}

// ---------------------------------------------------------------------------
// 清洗 / 质量闸 / 回声（与基线 `book_craft_smoketest.dart` 同口径）
// ---------------------------------------------------------------------------

String cleanProse(String raw) {
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
  final List<String> paras =
      t.split(RegExp(r'\n\s*\n')).map((String p) => p.trim()).toList();
  final List<String> out = <String>[];
  for (final String p in paras) {
    if (p.isEmpty) continue;
    if (out.isNotEmpty && out.last == p) continue;
    out.add(p);
  }
  String joined = out.join('\n\n');
  // 尾部退化截断（与 App 同策）
  final int cut = RepetitionRepair.degenerationOnset(joined);
  if (cut > 0) joined = joined.substring(0, cut).trim();
  return joined.trim();
}

String qualityNote(String prose, int minChars) {
  final int n = prose.trim().length;
  if (n < minChars) return '字数不足（$n < $minChars）';
  if (RepetitionGuard.isDegenerate(prose)) {
    final double ng = RepetitionGuard.charNgramRepeatRatio(prose);
    final double pr = RepetitionGuard.paragraphRepeatRatio(prose);
    return '复读率过高（ngram=${ng.toStringAsFixed(3)} '
        'para=${pr.toStringAsFixed(3)}）';
  }
  return '';
}

// ---------------------------------------------------------------------------
// 文件 sink
// ---------------------------------------------------------------------------

class FileSink implements LayeredArtifactSink {
  FileSink(this.root);
  final String root;

  @override
  Future<void> write(String kind, String key, String content) async {
    final Directory dir = Directory('$root/$kind');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final String safe = key.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    File('${dir.path}/$safe.txt').writeAsStringSync(content);
  }
}

// ---------------------------------------------------------------------------

Future<void> main(List<String> args) async {
  final int chaptersPerVolume =
      args.isNotEmpty ? (int.tryParse(args[0]) ?? kChaptersPerVolume) : kChaptersPerVolume;
  final String outDir = args.length > 1 ? args[1] : '_layered_out';
  final int volumes = args.length > 2 ? (int.tryParse(args[2]) ?? 1) : 1;
  /// 是否启用 RWKV 有状态路由（`RWKV_USE_STATE=1`）。
  ///
  /// ⚠ 默认**关闭**：本部署 `/state/*` 无视 `think_type: none`，思考长度不稳定，
  /// 实测过闸率 1/5 → 4/5 → 2/5（出现 0 字章）。无状态路由稳定（基线 5/5）。
  final bool useState = Platform.environment['RWKV_USE_STATE'] == '1';

  Directory(outDir).createSync(recursive: true);
  final StringBuffer log = StringBuffer();
  void w(String s) {
    log.writeln(s);
    stdout.writeln(s);
  }

  w('=== 分层写书管线（L1 主线 → L2 分卷 → L3 细纲 → L4 正文）===');
  w('书：《$kBookTitle》 [$kGenre]  卷数：$volumes  每卷章数：$chaptersPerVolume');
  w('模型：$kModel');
  w('传输：结构化=/v1（无状态）　正文='
      '${useState ? '/state（有状态，O(1) 增量续跑）' : '/v1（无状态，稳定优先）'}');
  w('输出：$outDir');
  w('');

  final LayeredBookConfig cfg = LayeredBookConfig(
    bookTitle: kBookTitle,
    genre: kGenre,
    theme: kTheme,
    background: kBackground,
    protagonist: kProtagonist,
    cast: kCast,
    volumeCount: volumes,
    chaptersPerVolume: chaptersPerVolume,
    bookAnchor: kBookAnchor,
    concurrency: 2,
    minChapterChars: 1600,
    sliceChars: 1400,
    sliceBudgetFactor: 1.5,
    maxSlicesPerChapter: 4,
    chapterRetries: 1,
    briefSelfCheck: true,
    proseParams: kProseParams,
    proseStateful: useState,
  );

  final Stopwatch total = Stopwatch()..start();
  final LayeredBookGenerationService svc = LayeredBookGenerationService(
    chat: _chat,
    sink: FileSink(outDir),
    onProgress: (String s) => w('  · $s'),
    cleanProse: cleanProse,
    qualityNote: qualityNote,
    trimEcho: trimSliceEcho,
  );
  final LayeredBookResult r = await svc.generate(cfg);
  total.stop();

  w('');
  w('=== 阶段耗时 ===');
  for (final MapEntry<String, double> e in r.stageSeconds.entries) {
    w('  ${e.key}：${e.value.toStringAsFixed(1)}s');
  }
  w('  合计：${total.elapsed.inSeconds}s');
  w('=== 调用次数 ===');
  for (final MapEntry<String, int> e in r.calls.entries) {
    w('  ${e.key}：${e.value}');
  }
  w('');
  w('=== 成书报告 ===');
  w('章数：${r.chapters.length}  过闸：${r.passed}/${r.chapters.length}  '
      '平均字数：${r.avgChars.round()}  平均 ngram：${r.avgNgram.toStringAsFixed(3)}');
  for (final LayeredChapterResult c in r.chapters) {
    w('  ${c.label} ${c.chars}字 ngram=${c.ngram.toStringAsFixed(3)} '
        'para=${c.paragraphRepeat.toStringAsFixed(3)} 片=${c.slices} '
        '${c.pass ? 'OK' : 'NG(${c.note})'}');
  }
  w('');
  w('=== 伏笔经纬 ===');
  w('  条目：${r.ledger.entries.length}  未回收：${r.ledger.openCount}  '
      '结构错误：${r.ledger.errors.length}  提醒：${r.ledger.density.reminderCount}');
  for (final ForeshadowIssue i in r.ledger.errors) {
    w('  ⚠ ${i.message}');
  }
  if (r.failures.isNotEmpty) {
    w('');
    w('=== 管线问题 ===');
    for (final String f in r.failures) {
      w('  · $f');
    }
  }

  File('$outDir/report.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(r.toJson()),
  );
  File('$outDir/report.txt').writeAsStringSync(log.toString());
  File('$outDir/00_volume_milestones.txt').writeAsStringSync(
    <String>[
      for (final PipelineMilestone m in r.volumeMilestones)
        '第${m.index}卷（${m.ratioLabel}）｜${m.label}｜${m.endState}',
    ].join('\n'),
  );
  w('');
  w('WROTE $outDir/report.json');
  _client.close(force: true);
}
