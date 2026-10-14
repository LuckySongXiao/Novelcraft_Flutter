// RWKV 写作参数 / 提示策略**基准测试台**（真机对照实验）。
//
// 用途：对真实 RWKV 端点跑「同提示词、多参数组、多次重复」的对照实验，
// 用 `RepetitionGuard` 量化每组配置的**复读率 / 退化率 / 达标率**，
// 从而让「写作参数该取什么值」有据可依，而不是靠感觉调。
//
// 用法（必须带 --disable-dart-dev）：
//   dart --disable-dart-dev tools/rwkv_writing_bench.dart [suite] [repeats]
//     suite   ∈ params | prompt | decay | strict | strict2 | strict3   （默认 params）
//     repeats 每组重复次数（默认 3）
//
// 环境变量（可选）：
//   RWKV_BASE_URL   默认 https://api-7b.rwkvos.com/v1/chat/completions
//   RWKV_MODEL      默认 rwkv7-g1k-7.2b-20260930-ctx25600
//   RWKV_NO_PROXY   置 1 时绕过环境里的 HTTP_PROXY（本地代理常对 RWKV 端点 502）
//
// 产物：控制台汇总 + `_bench_<suite>_rows.json`（逐次明细，便于二次分析）。
//
// ⚠ 本工具会真实调用模型（产生费用/耗时）。不适合放进 CI。
library;

import 'dart:convert';
import 'dart:io';

import '../lib/ai/utils/repetition_guard.dart';

final String kBase = Platform.environment['RWKV_BASE_URL'] ??
    'https://api-7b.rwkvos.com/v1/chat/completions';
final String kModel = Platform.environment['RWKV_MODEL'] ??
    'rwkv7-g1k-7.2b-20260930-ctx25600';
final bool kNoProxy = Platform.environment['RWKV_NO_PROXY'] == '1';

/// 官方默认停止 token（整数 ID）。
const List<int> kStop = <int>[0, 261, 24281];

// ---------------------------------------------------------------------------
// 固定提示词（各臂完全一致，保证只变被测变量）
// ---------------------------------------------------------------------------

const String kSystem = '你是一位中文网络小说作家。只输出可直接入库的小说正文，'
    '不要输出解释、标题、字数统计或原文对照。';
const String kOutline = '本章目标：陈九在祭祀当夜潜入祠堂，发现牌位后面的夹层里藏着一封血书。\n'
    '承接上文：上一章结尾陈九把供桌上的香灰扫落在地，被三叔公看见。\n'
    '核心冲突：族规与真相的撕扯。\n'
    '关键转折：血书上的字迹指向陈九自己的父亲。\n'
    '章末钩子：祠堂的门在身后闩上了。\n'
    '出场人物：陈九、三叔公。\n'
    '故事时间节点：祭祀当夜。';
const String kTail = '三叔公把那盏油灯往供桌上一放，火苗晃了晃，照出他半张沟壑纵横的脸。'
    '“九儿，”他说，“有些门，进去了就出不来了。”陈九没有答话，只是把手里的香灰又捻了捻，'
    '任那些细白的粉末从指缝里漏下去。他抬起头，正对上祠堂深处那排牌位——黑漆漆的，'
    '像一排沉默的眼睛。';
const String kHead = '任务：续写本章正文。\n章大纲：\n$kOutline\n'
    '篇幅：不少于 1600 字的成稿正文。这是硬要求。\n';

/// 目标字数（用于「达标率」统计）。
const int kTargetChars = 1600;

/// 一个实验臂。
class BenchArm {
  const BenchArm({
    required this.name,
    required this.note,
    required this.params,
    this.temperature = 1.0,
    this.user,
    this.thinkType,
  });

  final String name;
  final String note;
  final Map<String, Object?> params;
  final double temperature;
  final String? user;
  final String? thinkType;
}

/// App「官方档原值」（= `kRwkvAntiRepeatSampling`，未经长文夹区间）。
const Map<String, Object?> _unbanded = <String, Object?>{
  'top_k': 50, 'top_p': 0.6, 'alpha_presence': 2.0, 'alpha_frequency': 0.2,
  'alpha_decay': 0.999, 'dry_multiplier': 0.8, 'dry_base': 1.75,
  'dry_allowed_length': 2, 'dry_penalty_last_n': 2048, 'stop_tokens': kStop,
};

/// `params` 套件：官方推荐 vs App 现状（+47 结论的原始依据）。
final List<BenchArm> _paramsSuite = <BenchArm>[
  BenchArm(
    name: 'APP_CURRENT',
    note: 'App 现状（strong 夹区间后的实发值）',
    temperature: 0.88,
    params: <String, Object?>{
      'top_k': 40, 'top_p': 0.5, 'alpha_presence': 0.5, 'alpha_frequency': 0.6,
      'alpha_decay': 0.997, 'dry_multiplier': 0.9, 'dry_base': 1.75,
      'dry_allowed_length': 2, 'dry_penalty_last_n': 4096, 'stop_tokens': kStop,
    },
  ),
  BenchArm(
    name: 'OFFICIAL_CREATIVE_CN',
    note: '官方 G1 创意写作（rwkv.cn 模型卡）',
    temperature: 0.6,
    params: <String, Object?>{
      'top_p': 0.7, 'alpha_presence': 2.0, 'alpha_frequency': 0.2,
      'alpha_decay': 0.99, 'stop_tokens': kStop,
    },
  ),
  BenchArm(
    name: 'OFFICIAL_STORY_EN',
    note: '官方 Story Creation（wiki.rwkv.com）',
    temperature: 1.3,
    params: <String, Object?>{
      'top_p': 0.8, 'alpha_presence': 0.4, 'alpha_frequency': 0.5,
      'alpha_decay': 0.99, 'stop_tokens': kStop,
    },
  ),
  BenchArm(
    name: 'APP_OFFICIAL_UNBANDED',
    note: 'App 官方档原值（不夹区间）',
    params: _unbanded,
  ),
  BenchArm(
    name: 'APP_CURRENT_TEMP1',
    note: 'App 现状 + 温度 1.0',
    params: <String, Object?>{
      'top_k': 40, 'top_p': 0.5, 'alpha_presence': 0.5, 'alpha_frequency': 0.6,
      'alpha_decay': 0.997, 'dry_multiplier': 0.9, 'dry_base': 1.75,
      'dry_allowed_length': 2, 'dry_penalty_last_n': 4096, 'stop_tokens': kStop,
    },
  ),
];

/// `decay` 套件：隔离 `alpha_decay` / 温度 / `top_p` 三个旋钮。
final List<BenchArm> _decaySuite = <BenchArm>[
  BenchArm(name: 'D990_T10', note: 'decay 0.99（官方创意档值）+ 温度 1.0',
      params: <String, Object?>{..._unbanded, 'alpha_decay': 0.99}),
  BenchArm(name: 'D999_T10', note: 'decay 0.999 + 温度 1.0',
      params: <String, Object?>{..._unbanded, 'alpha_decay': 0.999}),
  BenchArm(name: 'D999_T12', note: 'decay 0.999 + 温度 1.2',
      params: <String, Object?>{..._unbanded, 'alpha_decay': 0.999},
      temperature: 1.2),
  BenchArm(name: 'TOP05_T10', note: 'top_p 0.5（隔离 Top_P）',
      params: <String, Object?>{..._unbanded, 'top_p': 0.5}),
];

/// `strict` 套件（+48 第一轮）：候选「最严防重复」组合。
///
/// ⚠ 结论（见 +48 交接记录）：复读确实 0/3，但**字数崩了**（均值 481，
/// 达标 0/3）—— 把 freq/dry/last_n 三处同时顶严会「被罚得不敢写」。
/// 因此本套件只作为**负面结论**的留档，实际取值由 `strict2` / `strict3` 决定。
final List<BenchArm> _strictSuite = <BenchArm>[
  BenchArm(
    name: 'UNBANDED_BASE',
    note: '对照：+47 实测 0/3 退化、字数最高的官方档原值',
    params: _unbanded,
  ),
  BenchArm(
    name: 'STRICT_V48',
    note: '+48 第一版「最严」：presence 2.0 / freq 0.5 / decay 0.999 / dry 0.85 / last_n 4096',
    params: <String, Object?>{
      'top_k': 50, 'top_p': 0.6, 'alpha_presence': 2.0,
      'alpha_frequency': 0.5, 'alpha_decay': 0.999,
      'dry_multiplier': 0.85, 'dry_base': 1.75,
      'dry_allowed_length': 2, 'dry_penalty_last_n': 4096,
      'stop_tokens': kStop,
    },
  ),
  BenchArm(
    name: 'STRICT_V48_TOP05',
    note: '最严 + top_p 0.5（夹区间下限）',
    params: <String, Object?>{
      'top_k': 50, 'top_p': 0.5, 'alpha_presence': 2.0,
      'alpha_frequency': 0.5, 'alpha_decay': 0.999,
      'dry_multiplier': 0.85, 'dry_base': 1.75,
      'dry_allowed_length': 2, 'dry_penalty_last_n': 4096,
      'stop_tokens': kStop,
    },
  ),
];

/// `strict2` 套件（+48 第二轮）：逐个旋钮隔离，找出「既压住复读又不掉字数」。
final List<BenchArm> _strict2Suite = <BenchArm>[
  BenchArm(
    name: 'FREQ05_ONLY',
    note: '只把 freq 0.2→0.5（其余 = 官方档原值）',
    params: <String, Object?>{..._unbanded, 'alpha_frequency': 0.5},
  ),
  BenchArm(
    name: 'DRY085_ONLY',
    note: '只把 dry_multiplier 0.8→0.85',
    params: <String, Object?>{..._unbanded, 'dry_multiplier': 0.85},
  ),
  BenchArm(
    name: 'LASTN4096_ONLY',
    note: '只把 dry_penalty_last_n 2048→4096',
    params: <String, Object?>{..._unbanded, 'dry_penalty_last_n': 4096},
  ),
  BenchArm(
    name: 'FREQ05_DRY085',
    note: 'freq 0.5 + dry 0.85（窗口仍 2048）',
    params: <String, Object?>{
      ..._unbanded, 'alpha_frequency': 0.5, 'dry_multiplier': 0.85,
    },
  ),
  BenchArm(
    name: 'FREQ03_DRY085_LASTN4096',
    note: 'freq 0.3 + dry 0.85 + last_n 4096',
    params: <String, Object?>{
      ..._unbanded, 'alpha_frequency': 0.3, 'dry_multiplier': 0.85,
      'dry_penalty_last_n': 4096,
    },
  ),
  BenchArm(
    name: 'FREQ05_LASTN3072',
    note: 'freq 0.5 + last_n 3072（折中窗口）',
    params: <String, Object?>{
      ..._unbanded, 'alpha_frequency': 0.5, 'dry_penalty_last_n': 3072,
    },
  ),
];

/// `strict3` 套件（+48 第三轮）：对第一轮疑似负面结论做确认 ——
/// STRICT_V48 的短输出是「系统性变短」还是当次服务端抖动。
final List<BenchArm> _strict3Suite = <BenchArm>[
  BenchArm(name: 'STRICT_V48', note: '复测第一轮 481 字的组合',
      params: <String, Object?>{
        'top_k': 50, 'top_p': 0.6, 'alpha_presence': 2.0,
        'alpha_frequency': 0.5, 'alpha_decay': 0.999,
        'dry_multiplier': 0.85, 'dry_base': 1.75,
        'dry_allowed_length': 2, 'dry_penalty_last_n': 4096,
        'stop_tokens': kStop,
      }),
  BenchArm(name: 'UNBANDED_BASE', note: '对照：官方档原值',
      params: _unbanded),
  BenchArm(
    name: 'FREQ05_DRY085',
    note: '候选终值：只在 freq / dry 两处更严（窗口不动）',
    params: <String, Object?>{
      ..._unbanded, 'alpha_frequency': 0.5, 'dry_multiplier': 0.85,
    },
  ),
];

/// `prompt` 套件：提示结构（标记 / 纯续写 / 无前文 / think_type）。
final List<BenchArm> _promptSuite = <BenchArm>[
  BenchArm(
    name: 'MARKED_TAIL',
    note: 'App 现状：标记 + 前文末尾 + 双重约束',
    params: _unbanded,
    user: '$kHead【前文末尾（仅供衔接上下文，**不要输出这一段**）】\n$kTail\n\n'
        '请紧接上文写下去。只输出**新增**的正文，第一句不得与前文末尾重复；'
        '若前文末尾停在半句，请先把那半句补完再往下写。',
  ),
  BenchArm(
    name: 'PLAIN_TAIL',
    note: '纯续写：把前文末尾当小说文本接着写（无标记、无指令）',
    params: _unbanded,
    user: '$kHead$kTail\n',
  ),
  BenchArm(
    name: 'INLINE_HINT',
    note: '前文末尾 + 一句话内联提示（无标记块）',
    params: _unbanded,
    user: '$kHead$kTail\n\n（继续往下写，不要重复以上内容。）',
  ),
  BenchArm(
    name: 'NO_TAIL',
    note: '不给前文末尾（只给大纲）',
    params: _unbanded,
    user: '${kHead}请从本章第一句开始写。',
  ),
  BenchArm(
    name: 'MARKED_TAIL_THINK_NONE',
    note: 'App 现状 + think_type=none',
    params: _unbanded,
    thinkType: 'none',
    user: '$kHead【前文末尾（仅供衔接上下文，**不要输出这一段**）】\n$kTail\n\n'
        '请紧接上文写下去。只输出**新增**的正文，第一句不得与前文末尾重复；'
        '若前文末尾停在半句，请先把那半句补完再往下写。',
  ),
];

String _defaultUser() =>
    '$kHead【前文末尾（仅供衔接上下文，**不要输出这一段**）】\n$kTail\n\n'
    '请紧接上文写下去。只输出**新增**的正文，第一句不得与前文末尾重复；'
    '若前文末尾停在半句，请先把那半句补完再往下写。';

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
    if (resp.statusCode != 200) return <String, Object?>{'err': 'HTTP ${resp.statusCode}'};
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

/// 输出开头是否回抄了前文末尾。
bool _echoesTail(String out) {
  final String s = out.trim().replaceAll(RegExp(r'\s+'), '');
  if (s.isEmpty) return false;
  final String t = kTail.replaceAll(RegExp(r'\s+'), '');
  for (int len = 12; len <= 60 && len <= s.length; len++) {
    if (t.endsWith(s.substring(0, len))) return true;
  }
  return false;
}

Future<void> main(List<String> args) async {
  final String suite = args.isNotEmpty ? args[0] : 'params';
  final int repeats = args.length > 1 ? (int.tryParse(args[1]) ?? 3) : 3;
  final List<BenchArm> arms = switch (suite) {
    'decay' => _decaySuite,
    'strict' => _strictSuite,
    'strict2' => _strict2Suite,
    'strict3' => _strict3Suite,
    'prompt' => _promptSuite,
    _ => _paramsSuite,
  };

  stdout.writeln('endpoint=$kBase model=$kModel suite=$suite repeats=$repeats '
      'noProxy=$kNoProxy');
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[];

  for (final BenchArm arm in arms) {
    for (int rep = 1; rep <= repeats; rep++) {
      final Stopwatch sw = Stopwatch()..start();
      String content = '';
      String err = '';
      try {
        final Map<String, Object?> r = await post(<String, Object?>{
          'model': kModel,
          'messages': <Map<String, String>>[
            <String, String>{'role': 'system', 'content': kSystem},
            <String, String>{'role': 'user', 'content': arm.user ?? _defaultUser()},
          ],
          'stream': false,
          'max_tokens': 2200,
          'temperature': arm.temperature,
          ...arm.params,
          if (arm.thinkType != null) 'think_type': arm.thinkType!,
        });
        sw.stop();
        err = (r['err'] ?? '').toString();
        content = (r['content'] ?? '').toString();
      } catch (e) {
        sw.stop();
        err = '$e';
      }
      final String s = content.trim();
      final double ng = RepetitionGuard.charNgramRepeatRatio(s);
      final double pr = RepetitionGuard.paragraphRepeatRatio(s);
      final bool deg = RepetitionGuard.isDegenerate(s);
      rows.add(<String, Object?>{
        'arm': arm.name, 'rep': rep, 'sec': sw.elapsed.inSeconds,
        'len': s.length, 'ngram': double.parse(ng.toStringAsFixed(4)),
        'para': double.parse(pr.toStringAsFixed(4)), 'deg': deg,
        'hitTarget': s.length >= kTargetChars, 'echo': _echoesTail(s), 'err': err,
      });
      stdout.writeln('[${arm.name} #$rep] ${sw.elapsed.inSeconds}s len=${s.length} '
          'ngram=${ng.toStringAsFixed(3)} para=${pr.toStringAsFixed(3)} deg=$deg '
          '${err.isEmpty ? '' : 'ERR=$err'}');
    }
    stdout.writeln('');
  }

  stdout.writeln('=== 汇总 ===');
  for (final BenchArm arm in arms) {
    final List<Map<String, Object?>> rs =
        rows.where((Map<String, Object?> r) => r['arm'] == arm.name).toList();
    if (rs.isEmpty) continue;
    double avg(String k) => rs
        .map((Map<String, Object?> r) => (r[k]! as num).toDouble())
        .reduce((a, b) => a + b) / rs.length;
    double maxOf(String k) => rs
        .map((Map<String, Object?> r) => (r[k]! as num).toDouble())
        .reduce((a, b) => a > b ? a : b);
    int cnt(String k) => rs.where((Map<String, Object?> r) => r[k] == true).length;
    stdout.writeln('${arm.name}: len均值=${avg('len').round()} '
        'ngram均值=${avg('ngram').toStringAsFixed(3)} '
        'ngram最差=${maxOf('ngram').toStringAsFixed(3)} '
        '退化=${cnt('deg')}/${rs.length} 达标=${cnt('hitTarget')}/${rs.length} '
        '| ${arm.note}');
  }

  File('_bench_${suite}_rows.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(rows),
  );
  stdout.writeln('WROTE _bench_${suite}_rows.json');
}
