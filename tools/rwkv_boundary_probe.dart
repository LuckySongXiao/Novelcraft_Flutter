// RWKV **模型边界能力**探针（真机）。
//
// 用途：用真实端点测出「这台模型到底能做到什么」，为「后训练数据集该覆盖哪些
// 能力区间」提供事实依据。与 `rwkv_writing_bench.dart` 的分工：
//   * writing_bench  → 比较**参数组合**（哪套采样更抗复读）
//   * boundary_probe → 测**能力边界**（最长能写多少 / JSON 多长会崩 / 上下文多大）
//
// 用法（必须带 --disable-dart-dev）：
//   dart --disable-dart-dev tools/rwkv_boundary_probe.dart [suite] [outDir]
//     suite  ∈ all | length | json | context | sampling | instruct | slice | attention
//              （默认 all）
//     attention = 长前文暗号复述：验证模型是否**真的**读到第 N 字处的内容
//                  （context 套件只验证「服务端不报错」，不验证 Attention）
//     outDir 产物目录（默认 _boundary_out）
//
// 环境变量：
//   RWKV_BASE_URL  默认 https://api-7b.rwkvos.com/v1/chat/completions
//   RWKV_MODEL     默认 rwkv7-g1k-7.2b-20260930-ctx25600
//   RWKV_NO_PROXY  置 1 绕过 HTTP_PROXY（本地代理常对 RWKV 端点 502）
//   RWKV_MAX_CALLS 单次运行的最大调用数（安全阀，默认 60）
//
// 产物：outDir/rows.jsonl（逐次明细，追加写）+ 控制台汇总。
//
// ⚠ 真实调用，产生费用与耗时。不要放进 CI。
library;

import 'dart:convert';
import 'dart:io';

import '../lib/ai/utils/repetition_guard.dart';

final String kBase = Platform.environment['RWKV_BASE_URL'] ??
    'https://api-7b.rwkvos.com/v1/chat/completions';
final String kModel = Platform.environment['RWKV_MODEL'] ??
    'rwkv7-g1k-7.2b-20260930-ctx25600';
final bool kNoProxy = Platform.environment['RWKV_NO_PROXY'] == '1';
final int kMaxCalls =
    int.tryParse(Platform.environment['RWKV_MAX_CALLS'] ?? '') ?? 60;

/// 官方默认停止 token（整数 ID）。
const List<int> kStop = <int>[0, 261, 24281];

/// 正文类最严防重复采样参数（+48 实测结论）。
const Map<String, Object?> kProseParams = <String, Object?>{
  'alpha_presence': 2.0,
  'alpha_frequency': 0.2,
  'alpha_decay': 0.999,
  'dry_multiplier': 0.8,
  'dry_base': 1.75,
  'dry_allowed_length': 2,
  'dry_penalty_last_n': 2048,
  'top_p': 0.6,
  'top_k': 20,
};

int _calls = 0;
final List<String> _warnings = <String>[];

/// 逐条追加落盘（而不是等整个 suite 跑完）——
/// 这样中途崩溃/被中断也不会丢掉已经测到的数据。
File? _rowsFile;
void _emit(Map<String, Object?> row) {
  _rowsFile?.writeAsStringSync('${jsonEncode(row)}\n', mode: FileMode.append);
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

/// 单次调用结果。
class ProbeResult {
  ProbeResult({
    required this.ok,
    required this.content,
    required this.finishReason,
    required this.ms,
    required this.promptChars,
    required this.usage,
    this.error = '',
  });

  final bool ok;
  final String content;
  final String finishReason;
  final int ms;
  final int promptChars;
  final Map<String, Object?> usage;
  final String error;
}

Future<ProbeResult> probe(Map<String, Object?> body, {int maxRetry = 3}) async {
  final String promptText = () {
    final Object? m = body['messages'];
    if (m is List) {
      final StringBuffer b = StringBuffer();
      for (final Object? x in m) {
        if (x is Map) b.write((x['content'] ?? '').toString());
      }
      return b.toString();
    }
    return '';
  }();

  for (int attempt = 1; attempt <= maxRetry; attempt++) {
    _calls++;
    final Stopwatch sw = Stopwatch()..start();
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    if (kNoProxy) client.findProxy = ((Uri uri) => 'DIRECT');
    try {
      final HttpClientRequest req = await client.postUrl(Uri.parse(kBase));
      req.headers.contentType =
          ContentType('application', 'json', charset: 'utf-8');
      req.add(utf8.encode(jsonEncode(body)));
      final HttpClientResponse resp =
          await req.close().timeout(const Duration(seconds: 420));
      final String text = await resp.transform(utf8.decoder).join();
      sw.stop();
      if (resp.statusCode != 200) {
        final String err = 'HTTP ${resp.statusCode}';
        if ((resp.statusCode == 429 || resp.statusCode >= 500) &&
            attempt < maxRetry) {
          await Future<void>.delayed(Duration(seconds: 4 * attempt));
          continue;
        }
        return ProbeResult(
          ok: false,
          content: '',
          finishReason: '',
          ms: sw.elapsedMilliseconds,
          promptChars: promptText.length,
          usage: const <String, Object?>{},
          error: err,
        );
      }
      final dynamic d = jsonDecode(text);
      if (d is! Map || d['choices'] is! List || (d['choices'] as List).isEmpty) {
        return ProbeResult(
          ok: false,
          content: '',
          finishReason: '',
          ms: sw.elapsedMilliseconds,
          promptChars: promptText.length,
          usage: const <String, Object?>{},
          error: 'shape',
        );
      }
      final dynamic m = (d['choices'] as List).first;
      final dynamic msg = (m is Map) ? m['message'] : null;
      final String content =
          (msg is Map ? msg['content'] : null)?.toString() ?? '';
      final String fr =
          (m is Map ? m['finish_reason'] : null)?.toString() ?? '';
      final Map<String, Object?> usage =
          (d['usage'] is Map) ? Map<String, Object?>.from(d['usage'] as Map) : const <String, Object?>{};
      return ProbeResult(
        ok: true,
        content: content,
        finishReason: fr,
        ms: sw.elapsedMilliseconds,
        promptChars: promptText.length,
        usage: usage,
      );
    } on Object catch (e) {
      sw.stop();
      if (attempt < maxRetry) {
        await Future<void>.delayed(Duration(seconds: 4 * attempt));
        continue;
      }
      return ProbeResult(
        ok: false,
        content: '',
        finishReason: '',
        ms: sw.elapsedMilliseconds,
        promptChars: promptText.length,
        usage: const <String, Object?>{},
        error: '$e',
      );
    } finally {
      client.close(force: true);
    }
  }
  return ProbeResult(
    ok: false,
    content: '',
    finishReason: '',
    ms: 0,
    promptChars: promptText.length,
    usage: const <String, Object?>{},
    error: 'unreachable',
  );
}

// ---------------------------------------------------------------------------
// 指标
// ---------------------------------------------------------------------------

double _ngram(String s) {
  if (s.trim().length < 60) return 0;
  try {
    return RepetitionGuard.charNgramRepeatRatio(s);
  } on Object catch (_) {
    return -1;
  }
}

bool _degenerate(String s) {
  try {
    return RepetitionGuard.isDegenerate(s);
  } on Object catch (_) {
    return false;
  }
}

/// 去掉 <think> 块后的正文（本部署 /state 会吐思考，这里也兜一下）。
String _stripThink(String raw) {
  String t = raw.replaceAll(
      RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false), '');
  t = t.replaceFirst(
      RegExp(r'^\s*<think(?:ing)?>[\s\S]*$', caseSensitive: false), '');
  return t.replaceAll(RegExp(r'</?(?:think|thinking)>', caseSensitive: false), '').trim();
}

/// 是否像「没写完」（结尾停在半句 / 逗号 / 引号未闭合）。
bool _looksTruncated(String s) {
  final String t = s.trim();
  if (t.isEmpty) return true;
  if (t.endsWith('，') || t.endsWith('、') || t.endsWith('：') || t.endsWith('“') ||
      t.endsWith('（')) {
    return true;
  }
  const List<String> ends = <String>['。', '！', '？', '”', '）', '…', '.', '!', '?'];
  return !ends.any(t.endsWith);
}

/// 末尾是否自然收束。
bool _endsClean(String s) {
  final String t = s.trim();
  if (t.isEmpty) return false;
  const List<String> ends = <String>['。', '！', '？', '”', '）', '…'];
  return ends.any(t.endsWith);
}

// ---------------------------------------------------------------------------
// 固定素材
// ---------------------------------------------------------------------------

const String kSysProse = '你是一位中文小说作家。只输出正文，不要解释、标题、字数统计。';

const String kChapterPrompt = '任务：写一章小说的正文片段。\n'
    '设定：临海小城「潮尾镇」。镇东海岬的旧灯塔下，有一座只在退潮时露出水面的图书馆，'
    '馆内每本书都记录着一件尚未发生的事，按人名编目。主角沈砚，28 岁，'
    '市立图书馆夜班管理员，有轻度面孔失认症，只能靠声音和步态认人。\n'
    '本章目标：沈砚第一次在退潮的四十分钟里走进那座图书馆。\n'
    '核心冲突：他必须在潮水回来之前决定要不要翻开写着自己名字的那一本。\n'
    '关键转折：他翻开了，第一页只有一句话。\n'
    '章末钩子：门外的水声变了。\n';

// ---------------------------------------------------------------------------
// 套件
// ---------------------------------------------------------------------------

Future<List<Map<String, Object?>>> suiteLength() async {
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
  for (final int cap in <int>[512, 1024, 2048, 4096, 6144, 8192]) {
    final ProbeResult r = await probe(<String, Object?>{
      'model': kModel,
      'messages': <Map<String, String>>[
        <String, String>{'role': 'system', 'content': kSysProse},
        <String, String>{
          'role': 'user',
          'content': '$kChapterPrompt\n请写尽可能长的完整章节正文，直到这一章自然结束。'
        },
      ],
      'stream': false,
      'max_tokens': cap,
      'temperature': 1.0,
      'stop_tokens': kStop,
      ...kProseParams,
    });
    final String body = _stripThink(r.content);
    final Map<String, Object?> row = <String, Object?>{
      'suite': 'length',
      'maxTokens': cap,
      'ok': r.ok,
      'error': r.error,
      'finishReason': r.finishReason,
      'chars': body.length,
      'ngram': double.parse(_ngram(body).toStringAsFixed(4)),
      'degenerate': _degenerate(body),
      'endsClean': _endsClean(body),
      'truncated': _looksTruncated(body),
      'ms': r.ms,
      'usage': r.usage,
      // 保留首尾样本：判断「为什么 endsClean=false」必须看真实收尾形态
      'head': body.length > 200 ? body.substring(0, 200) : body,
      'tail': body.length > 200 ? body.substring(body.length - 200) : body,
    };
    rows.add(row);
    _emit(row);
    stdout.writeln('[length] cap=$cap → ${body.length} 字 '
        'finish=${r.finishReason} ng=${row['ngram']} '
        'end=${row['endsClean']} trunc=${row['truncated']} ${r.ms}ms'
        '${r.ok ? '' : ' ERR=${r.error}'}');
  }
  return rows;
}

Future<List<Map<String, Object?>>> suiteJson() async {
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
  for (final int n in <int>[5, 10, 20, 40]) {
    final ProbeResult r = await probe(<String, Object?>{
      'model': kModel,
      'messages': <Map<String, String>>[
        <String, String>{
          'role': 'system',
          'content': '你是长篇小说总编剧。只输出要求的 JSON 数组，'
              '不要解释、不要 Markdown 围栏。'
        },
        <String, String>{
          'role': 'user',
          'content': '请为一部 20 卷的长篇小说输出 $n 条卷级里程碑。'
              '每卷一个对象，字段：index(整数,从1起)、label(卷名,8~14字)、'
              'endState(本卷结束时主角所处状态,40~80字)。\n'
              '严格输出 JSON 对象数组，第一个字符必须是 [，最后一个必须是 ]。'
        },
      ],
      'stream': false,
      'max_tokens': (n * 120 + 200).clamp(600, 6000),
      'temperature': 0.6,
      'stop_tokens': kStop,
    });
    final String body = _stripThink(r.content);
    Object? parsed;
    bool jsonOk = false;
    int itemCount = 0;
    int schemaOk = 0;
    final String t = body.trim();
    final int s = t.indexOf('[');
    final int e = t.lastIndexOf(']');
    if (s >= 0 && e > s) {
      try {
        parsed = jsonDecode(t.substring(s, e + 1));
        if (parsed is List) {
          jsonOk = true;
          itemCount = parsed.length;
          for (final Object? it in parsed) {
            if (it is Map &&
                it['index'] != null &&
                (it['label'] ?? '').toString().trim().isNotEmpty &&
                (it['endState'] ?? '').toString().trim().isNotEmpty) {
              schemaOk++;
            }
          }
        }
      } on Object catch (_) {
        jsonOk = false;
      }
    }
    final Map<String, Object?> row = <String, Object?>{
      'suite': 'json',
      'requested': n,
      'ok': r.ok,
      'error': r.error,
      'jsonOk': jsonOk,
      'itemCount': itemCount,
      'schemaOk': schemaOk,
      'schemaRate':
          itemCount == 0 ? 0.0 : double.parse((schemaOk / itemCount).toStringAsFixed(3)),
      'chars': body.length,
      'finishReason': r.finishReason,
      'ms': r.ms,
      'head': t.length > 160 ? t.substring(0, 160) : t,
    };
    rows.add(row);
    _emit(row);
    stdout.writeln('[json] 要 $n 条 → jsonOk=$jsonOk 实得 $itemCount 条 '
        'schema=$schemaOk/$itemCount finish=${r.finishReason} ${r.ms}ms'
        '${r.ok ? '' : ' ERR=${r.error}'}');
  }
  return rows;
}

Future<List<Map<String, Object?>>> suiteContext() async {
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
  // 用重复的「前文」构造不同长度的上下文（约 1.6 字/token 的中文经验值）
  const String filler =
      '沈砚沿着防波堤往东走，脚下的青石被海水浸得发亮。灯塔的影子斜斜地压在滩涂上，'
      '像一根插进泥里的旧针。他数着步子，一步、两步，直到水线退到那块露出铁环的礁石旁。'
      '风里有盐的味道，也有一种更旧的、纸张受潮的味道。';
  for (final int targetChars in <int>[2000, 8000, 16000, 30000, 48000]) {
    final StringBuffer ctx = StringBuffer();
    while (ctx.length < targetChars) {
      ctx.write(filler);
    }
    final String context = ctx.toString().substring(0, targetChars);
    final ProbeResult r = await probe(<String, Object?>{
      'model': kModel,
      'messages': <Map<String, String>>[
        <String, String>{'role': 'system', 'content': kSysProse},
        <String, String>{
          'role': 'user',
          'content': '【前文（仅供衔接，不要复述）】\n$context\n\n'
              '请紧接上文写下一段（约 200 字），只输出新增内容。'
        },
      ],
      'stream': false,
      'max_tokens': 400,
      'temperature': 1.0,
      'stop_tokens': kStop,
      ...kProseParams,
    });
    final String body = _stripThink(r.content);
    final Map<String, Object?> row = <String, Object?>{
      'suite': 'context',
      'promptChars': context.length,
      'ok': r.ok,
      'error': r.error,
      'outChars': body.length,
      'ngram': double.parse(_ngram(body).toStringAsFixed(4)),
      'ms': r.ms,
      'usage': r.usage,
      'head': body.length > 120 ? body.substring(0, 120) : body,
    };
    rows.add(row);
    _emit(row);
    stdout.writeln('[context] 前文 ${context.length} 字 → 产出 ${body.length} 字 '
        'ng=${row['ngram']} ${r.ms}ms usage=${jsonEncode(r.usage)}'
        '${r.ok ? '' : ' ERR=${r.error}'}');
  }
  return rows;
}

Future<List<Map<String, Object?>>> suiteSampling() async {
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
  for (final double temp in <double>[0.3, 0.6, 0.8, 1.0, 1.2, 1.5]) {
    final ProbeResult r = await probe(<String, Object?>{
      'model': kModel,
      'messages': <Map<String, String>>[
        <String, String>{'role': 'system', 'content': kSysProse},
        <String, String>{
          'role': 'user',
          'content': '$kChapterPrompt\n请写本章正文，不少于 1200 字。'
        },
      ],
      'stream': false,
      'max_tokens': 2400,
      'temperature': temp,
      'stop_tokens': kStop,
      ...kProseParams,
    });
    final String body = _stripThink(r.content);
    final Map<String, Object?> row = <String, Object?>{
      'suite': 'sampling',
      'temperature': temp,
      'ok': r.ok,
      'error': r.error,
      'chars': body.length,
      'ngram': double.parse(_ngram(body).toStringAsFixed(4)),
      'degenerate': _degenerate(body),
      'endsClean': _endsClean(body),
      'finishReason': r.finishReason,
      'ms': r.ms,
    };
    rows.add(row);
    _emit(row);
    stdout.writeln('[sampling] temp=$temp → ${body.length} 字 ng=${row['ngram']} '
        'deg=${row['degenerate']} end=${row['endsClean']} ${r.ms}ms'
        '${r.ok ? '' : ' ERR=${r.error}'}');
  }
  return rows;
}

Future<List<Map<String, Object?>>> suiteInstruct() async {
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[];

  Future<void> one(
    String id,
    String user, {
    required bool Function(String) check,
    int maxTokens = 400,
    String note = '',
  }) async {
    final ProbeResult r = await probe(<String, Object?>{
      'model': kModel,
      'messages': <Map<String, String>>[
        <String, String>{
          'role': 'system',
          'content': '你是严谨的助手，严格按指令格式输出。'
        },
        <String, String>{'role': 'user', 'content': user},
      ],
      'stream': false,
      'max_tokens': maxTokens,
      'temperature': 0.3,
      'stop_tokens': kStop,
    });
    final String body = _stripThink(r.content);
    final bool ok = r.ok && check(body);
    final Map<String, Object?> row = <String, Object?>{
      'suite': 'instruct',
      'id': id,
      'ok': r.ok,
      'error': r.error,
      'pass': ok,
      'chars': body.length,
      'out': body.length > 200 ? body.substring(0, 200) : body,
      'note': note,
    };
    rows.add(row);
    _emit(row);
    stdout.writeln('[instruct] $id → pass=$ok (${body.length} 字)'
        '${r.ok ? '' : ' ERR=${r.error}'}');
  }

  await one(
    'I1 恰好3行且以"- "开头',
    '请只输出 3 行内容，每行以「- 」开头，每行一个词，不要任何其它文字。',
    check: (String s) {
      final List<String> ls = s
          .trim()
          .split(RegExp(r'\r\n|\r|\n'))
          .where((String x) => x.trim().isNotEmpty)
          .toList();
      return ls.length == 3 && ls.every((String x) => x.trim().startsWith('- '));
    },
  );

  await one(
    'I2 输出JSON对象且只有a和b两个键',
    '请输出一个 JSON 对象，只有两个键：a 和 b，值都是字符串。不要任何解释。',
    check: (String s) {
      final String t = s.trim();
      final int i = t.indexOf('{');
      final int j = t.lastIndexOf('}');
      if (i < 0 || j <= i) return false;
      try {
        final dynamic d = jsonDecode(t.substring(i, j + 1));
        return d is Map && d.length == 2 && d.containsKey('a') && d.containsKey('b');
      } on Object catch (_) {
        return false;
      }
    },
  );

  await one(
    'I3 禁止出现某字',
    '请写一句描写黄昏的话（20~40 字）。整句里绝对不能出现「的」这个字。',
    check: (String s) => s.trim().isNotEmpty && !s.contains('的'),
  );

  await one(
    'I4 首句固定',
    '请写一段话，第一个句子必须完全等于「潮水退去了。」，然后接着写两句描写。',
    check: (String s) => s.trim().startsWith('潮水退去了。'),
  );

  await one(
    'I5 恰好5个汉字',
    '请只输出 5 个汉字，不要标点、不要解释、不要换行。',
    check: (String s) {
      final String t = s.replaceAll(RegExp(r'\s'), '');
      return t.length == 5 && RegExp(r'^[\u4e00-\u9fa5]{5}$').hasMatch(t);
    },
  );

  await one(
    'I6 用①②③编号列3条',
    '请用「①」「②」「③」三个符号各起一行，列出 3 条写作建议。不要用别的编号形式。',
    check: (String s) =>
        s.contains('①') && s.contains('②') && s.contains('③'),
  );

  await one(
    'I7 输出纯JSON数组无围栏',
    '请输出一个 JSON 字符串数组，包含 3 个中文词。第一个字符必须是 [，'
        '最后一个必须是 ]，不要 Markdown 围栏、不要解释。',
    check: (String s) {
      final String t = s.trim();
      if (!t.startsWith('[') || !t.endsWith(']')) return false;
      try {
        final dynamic d = jsonDecode(t);
        return d is List && d.length == 3;
      } on Object catch (_) {
        return false;
      }
    },
  );

  await one(
    'I8 不得回抄提示词',
    '请写一句关于灯塔的话（15~30 字）。不要复述我的指令文字。',
    check: (String s) =>
        s.trim().isNotEmpty && !s.contains('不要复述') && !s.contains('请写一句'),
  );

  return rows;
}

Future<List<Map<String, Object?>>> suiteSlice() async {
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
  // 3 片串行续写：测跨片复读（模型最容易在续写时回抄上一片）
  final StringBuffer acc = StringBuffer();
  String prevTail = '';
  for (int slice = 1; slice <= 3; slice++) {
    final ProbeResult r = await probe(<String, Object?>{
      'model': kModel,
      'messages': <Map<String, String>>[
        <String, String>{'role': 'system', 'content': kSysProse},
        <String, String>{
          'role': 'user',
          'content': '$kChapterPrompt\n'
              '${prevTail.isEmpty ? '' : '【已写部分末尾（不要复述）】\n$prevTail\n\n'}'
              '请接着写第 $slice/3 段，约 700 字。只输出新增内容，'
              '第一句不得与已写部分末尾重复。'
        },
      ],
      'stream': false,
      'max_tokens': 1400,
      'temperature': 1.0,
      'stop_tokens': kStop,
      ...kProseParams,
    });
    final String body = _stripThink(r.content);
    // 跨片复读：新片与已写全文的 ngram 重叠
    final double cross = acc.isEmpty ? 0 : _ngram('${acc.toString()}\n$body');
    final Map<String, Object?> row = <String, Object?>{
      'suite': 'slice',
      'slice': slice,
      'ok': r.ok,
      'error': r.error,
      'chars': body.length,
      'selfNgram': double.parse(_ngram(body).toStringAsFixed(4)),
      'crossNgram': double.parse(cross.toStringAsFixed(4)),
      'echoesTail': prevTail.trim().replaceAll(RegExp(r'\s+'), '').length >= 12 &&
          body.trim().replaceAll(RegExp(r'\s+'), '').isNotEmpty &&
          body.trim().replaceAll(RegExp(r'\s+'), '').startsWith(
              prevTail.trim().replaceAll(RegExp(r'\s+'), '').substring(0, 12)),
      'endsClean': _endsClean(body),
      'ms': r.ms,
    };
    rows.add(row);
    _emit(row);
    stdout.writeln('[slice] 第 $slice 片 → ${body.length} 字 '
        'self=${row['selfNgram']} cross=${row['crossNgram']} '
        '${r.ms}ms${r.ok ? '' : ' ERR=${r.error}'}');
    acc.writeln(body);
    prevTail = body.length > 200 ? body.substring(body.length - 200) : body;
  }
  return rows;
}

// ---------------------------------------------------------------------------
// 套件：上下文 Attention（补齐 context 套件「只验证不报错」的缺口）
// ---------------------------------------------------------------------------

/// 暗号：四字词。用于验证模型是否**真的在利用**长前文。
///
/// `context` 套件只验证「服务端接受多长的输入」，不验证模型是否真的读到了。
/// 本套件用「在前文第 N 字处埋一个四字暗号，然后要求原样复述」来度量真实可用深度。
const String kAttentionSecret = '青柏归舟';

const String kSysRecall = '你是严谨的助手。按问题简短回答，不要解释、不要客套。';

/// 构造一份 length 字的前文，并在 offset 处插入一句含暗号的话。
String _attentionContext(int length, int offset) {
  const String filler =
      '潮尾镇的夜晚总是来得比别处早些。他沿着防波堤往东走，脚下的青石被海水浸得发亮，'
      '灯塔的影子斜斜地压在滩涂上，像一根插进泥里的旧针。';
  final StringBuffer ctx = StringBuffer();
  while (ctx.length < length) {
    ctx.write(filler);
  }
  final String base = ctx.toString().substring(0, length);
  final int at = offset.clamp(0, base.length);
  return '${base.substring(0, at)}'
      '\n守塔人老岑压低声音念了四个字：「$kAttentionSecret」。\n'
      '${base.substring(at)}';
}

Future<List<Map<String, Object?>>> suiteAttention() async {
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[];

  Future<void> ask({
    required String id,
    required String context,
    required String question,
    String? expect,
  }) async {
    final ProbeResult r = await probe(<String, Object?>{
      'model': kModel,
      'messages': <Map<String, String>>[
        <String, String>{'role': 'system', 'content': kSysRecall},
        <String, String>{
          'role': 'user',
          'content': '【前文】\n$context\n\n$question'
        },
      ],
      'stream': false,
      'max_tokens': 80,
      'temperature': 0.3,
      'stop_tokens': kStop,
    });
    final String body = _stripThink(r.content);
    final bool hit = expect != null && body.contains(expect);
    final Map<String, Object?> row = <String, Object?>{
      'suite': 'attention',
      'id': id,
      'promptChars': r.promptChars,
      'ok': r.ok,
      'error': r.error,
      'hit': hit,
      'out': body.length > 80 ? body.substring(0, 80) : body,
      'ms': r.ms,
    };
    rows.add(row);
    _emit(row);
    stdout.writeln('[attention] $id → 命中=$hit '
        '输出="${row['out']}" ${r.ms}ms${r.ok ? '' : ' ERR=${r.error}'}');
  }

  // (前文总长, 暗号插入位置) —— 覆盖前段 / 中段 / 后段 / 超长
  for (final List<int> c in <List<int>>[
    <int>[20000, 500],
    <int>[20000, 10000],
    <int>[30000, 25000],
    <int>[40000, 20000],
  ]) {
    final String ctx = _attentionContext(c[0], c[1]);
    await ask(
      id: 'R${c[0] ~/ 1000}k@${c[1]}',
      context: ctx,
      question: '请回答：前文里守塔人老岑压低声音念出的那四个字是什么？'
          '只写出这四个字。',
      expect: kAttentionSecret,
    );
  }

  // 对照组：问一个前文里**没有**的问题。
  // 若模型老实回答「未提及」，说明上面的「未命中」是真没读到而不是随口编。
  final String ctrl = _attentionContext(40000, 20000);
  await ask(
    id: 'control(未提及项)',
    context: ctrl,
    question: '请回答：前文里那座灯塔是哪一年建成的？如果前文没有说，'
        '就只回答「未提及」。',
    expect: null,
  );

  return rows;
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

Future<void> main(List<String> args) async {
  try {
    await _main(args);
  } on Object catch (e, st) {
    // 绝不静默退出：把异常与栈打出来（否则后台运行只会看到 exit 1）。
    stderr.writeln('FATAL: $e');
    stderr.writeln(st);
    exitCode = 1;
  } finally {
    await stdout.flush();
    await stderr.flush();
  }
}

Future<void> _main(List<String> args) async {
  final String suite = args.isNotEmpty ? args[0] : 'all';
  final String outDir = args.length > 1 ? args[1] : '_boundary_out';
  Directory(outDir).createSync(recursive: true);
  final File rowsFile = File('$outDir/rows.jsonl');
  if (!rowsFile.existsSync()) rowsFile.writeAsStringSync('');
  _rowsFile = rowsFile;

  stdout.writeln('endpoint=$kBase');
  stdout.writeln('model=$kModel suite=$suite outDir=$outDir '
      'noProxy=$kNoProxy maxCalls=$kMaxCalls');

  final List<Map<String, Object?>> all = <Map<String, Object?>>[];

  Future<void> run(String name, Future<List<Map<String, Object?>>> Function() fn) async {
    if (suite != 'all' && suite != name) return;
    if (_calls >= kMaxCalls) {
      _warnings.add('跳过 $name：已达调用上限 $kMaxCalls');
      stdout.writeln('--- 跳过 $name（调用上限）---');
      return;
    }
    stdout.writeln('--- $name ---');
    try {
      final List<Map<String, Object?>> rows = await fn();
      all.addAll(rows);
    } on Object catch (e) {
      _warnings.add('$name 失败：$e');
      stdout.writeln('!! $name 失败：$e');
    }
  }

  await run('length', suiteLength);
  await run('json', suiteJson);
  await run('context', suiteContext);
  await run('sampling', suiteSampling);
  await run('instruct', suiteInstruct);
  await run('slice', suiteSlice);
  await run('attention', suiteAttention);

  // ---- 汇总 ----
  stdout.writeln('');
  stdout.writeln('================ 汇总 ================');
  stdout.writeln('总调用次数=$_calls');

  final List<Map<String, Object?>> len =
      all.where((Map<String, Object?> r) => r['suite'] == 'length').toList();
  if (len.isNotEmpty) {
    int maxClean = 0;
    for (final Map<String, Object?> r in len) {
      if (r['ok'] == true && r['endsClean'] == true) {
        final int c = (r['chars'] as int?) ?? 0;
        if (c > maxClean) maxClean = c;
      }
    }
    stdout.writeln('【长度】自然收束的最长产出 = $maxClean 字');
    for (final Map<String, Object?> r in len) {
      stdout.writeln('  cap=${r['maxTokens']} chars=${r['chars']} '
          'finish=${r['finishReason']} endsClean=${r['endsClean']} '
          'ngram=${r['ngram']}');
    }
  }

  final List<Map<String, Object?>> js =
      all.where((Map<String, Object?> r) => r['suite'] == 'json').toList();
  if (js.isNotEmpty) {
    int maxN = 0;
    for (final Map<String, Object?> r in js) {
      if (r['jsonOk'] == true && (r['schemaRate'] as double? ?? 0) >= 0.95) {
        final int n = (r['itemCount'] as int?) ?? 0;
        if (n > maxN) maxN = n;
      }
    }
    stdout.writeln('【结构化】schema 完整可用的最大条数 = $maxN');
  }

  final List<Map<String, Object?>> ctx =
      all.where((Map<String, Object?> r) => r['suite'] == 'context').toList();
  if (ctx.isNotEmpty) {
    int maxOk = 0;
    for (final Map<String, Object?> r in ctx) {
      if (r['ok'] == true) {
        final int c = (r['promptChars'] as int?) ?? 0;
        if (c > maxOk) maxOk = c;
      }
    }
    stdout.writeln('【上下文】成功接受的最大前文字数 = $maxOk');
  }

  final List<Map<String, Object?>> ins =
      all.where((Map<String, Object?> r) => r['suite'] == 'instruct').toList();
  if (ins.isNotEmpty) {
    final int pass = ins.where((Map<String, Object?> r) => r['pass'] == true).length;
    stdout.writeln('【指令遵循】$pass/${ins.length} 通过');
    for (final Map<String, Object?> r in ins) {
      stdout.writeln('  ${r['id']} → ${r['pass']}');
    }
  }

  if (_warnings.isNotEmpty) {
    stdout.writeln('--- 警告 ---');
    for (final String w in _warnings) {
      stdout.writeln('  · $w');
    }
  }
  stdout.writeln('rows.jsonl: ${rowsFile.absolute.path}');
}
