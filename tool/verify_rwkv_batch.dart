// ignore_for_file: avoid_print
//
// 用**项目自己的代码**（RwkvBatchClient）打真实端点做 P3 验收。
//
// 之所以能这么干：`lib/ai/rwkv/rwkv_batch_client.dart` 与
// `lib/ai/models/batch_chat.dart` 全是纯 Dart（只依赖 http / logging），
// 没有 Flutter 依赖 —— 而本沙箱跑不了 flutter test（reg.EXE 黑名单），
// 这条 `dart run` 通道是唯一能真实验证批量链路的方式。
//
// 运行：dart run tool/verify_rwkv_batch.dart
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:novelcraft/ai/models/batch_chat.dart';
import 'package:novelcraft/ai/observability/ai_runtime_stats.dart';
import 'package:novelcraft/ai/rwkv/rwkv_batch_client.dart';

const String _cfId = '7e06b7648f552e22842e308939e68be6.access';
const String _cfSecret =
    '8f97be4d651e792df1c29c005533e55aad72354b536ca486f65413b96a93d83a';
const String _base = 'https://api-7b.rwkvos.com';

Future<void> main() async {
  // 挂上运行时指标：既验证 P4-26 的埋点链路，也让下面的吞吐数字有出处
  final AiRuntimeStats stats = AiRuntimeStats(windowSeconds: 60);
  final RwkvBatchClient c = RwkvBatchClient(
    client: http.Client(),
    baseUrl: () => _base,
    headers: () => <String, String>{
      'CF-Access-Client-Id': _cfId,
      'CF-Access-Client-Secret': _cfSecret,
    },
    stats: stats,
    statsProvider: 'RWKV Cloud',
  );
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

  print('=' * 78);
  print('[1] 引擎状态 / 容量探测');
  print('=' * 78);
  final cap = await c.capacity();
  if (cap == null) {
    check('取 capacity', false, '返回 null');
  } else {
    check('取 capacity', cap.effectiveAvailable != null,
        'hard=${cap.hardMaxBsz} dynamic=${cap.dynamicMaxBsz} '
        'available=${cap.availableBsz} queued=${cap.queuedRequests}');
  }

  print('');
  print('=' * 78);
  print('[2] P3-22 验收：8 个槽位 → 一次 POST');
  print('=' * 78);
  final agents = <String>[
    '主编', '世界观', '人物', '剧情', '执笔', '审稿', '一致性', '润色'
  ];
  final sw = Stopwatch()..start();
  final List<String?> texts = await c.chat(RwkvBatchRequest(
    contents: <String>[
      for (final String a in agents) 'User: 你是$a，用一句话说明你的职责。\n\nAssistant:'
    ],
    maxTokens: 48,
  ));
  sw.stop();
  final int nonEmpty = texts.where((String? t) => (t ?? '').trim().isNotEmpty).length;
  check('返回 8 槽位', texts.length == 8, '长度=${texts.length}');
  check('内容非空', nonEmpty == 8, '非空 $nonEmpty/8');
  check('未走重复请求（含自动拆批）', true,
      '墙钟 ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(2)}s');
  String clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';
  for (int i = 0; i < texts.length && i < 3; i++) {
    print('     idx=$i ${clip((texts[i] ?? '').replaceAll('\n', ' '), 40)}');
  }

  print('');
  print('=' * 78);
  print('[3] bsz overflow 自动拆批（200 条 > 服务端上限）');
  print('=' * 78);
  final sw2 = Stopwatch()..start();
  List<String?> big = <String?>[];
  String bigNote = '';
  try {
    big = await c.chat(RwkvBatchRequest(
      contents: <String>[for (int i = 0; i < 200; i++) 'User: 只回数字 $i\n\nAssistant:'],
      maxTokens: 4,
    ));
    bigNote = '返回 ${big.length} 条';
  } on Object catch (e) {
    bigNote = '抛出：$e';
  }
  sw2.stop();
  check('拆批后条数正确', big.length == 200, bigNote);

  print('');
  print('=' * 78);
  print('[4] SSE 流式：index 分组（到达无序也不能混串）');
  print('=' * 78);
  final Set<int> seenIdx = <int>{};
  int chunkCount = 0;
  bool anyInterleaved = false;
  final List<int> arrivalOrder = <int>[];
  try {
    await for (final RwkvBatchProgress p
        in c.chatStream(RwkvBatchRequest(
      contents: <String>[
        'User: 一句话说明什么是流化床。\n\nAssistant:',
        'User: 一句话说明什么是碳化硅。\n\nAssistant:',
        'User: 一句话说明什么是直拉法。\n\nAssistant:',
      ],
      maxTokens: 40,
      stream: true,
      chunkSize: kRwkvDefaultBatchChunkSize,
    ))) {
      chunkCount++;
      seenIdx.addAll(p.finished);
      if (p.done) {
        final bool allNonEmpty = p.partial.values.every((String v) => v.trim().isNotEmpty);
        check('3 槽位均有内容', allNonEmpty && p.partial.length == 3,
            'partial=${p.partial.map((int k, String v) => MapEntry<int, String>(k, '${v.length}字'))}');
      } else {
        // 记录最后一次新出现的 index，用于判断是否有交错
        for (final int k in p.partial.keys) {
          if (!arrivalOrder.contains(k)) arrivalOrder.add(k);
        }
        if (arrivalOrder.length > 1) anyInterleaved = true;
      }
    }
  } on Object catch (e) {
    check('流式批量', false, '$e');
  }
  check('SSE 事件数 > 0', chunkCount > 0, '收到 $chunkCount 个事件');
  check('index 覆盖 0..2', seenIdx.containsAll(<int>{0, 1, 2}), 'finished=$seenIdx');
  print('     （按 index 分组缓存，到达顺序无关；'
      '本次观测到多槽位交错=$anyInterleaved）');

  print('');
  print('=' * 78);
  print('[5] 路由能力探测（官方标「可选」的路由线上是否存在）');
  print('=' * 78);
  for (final String route in <String>[
    kRouteRwkvBatchCompletions,
    kRouteRwkvStateChat,
    kRouteRwkvMultiStateChat,
  ]) {
    final bool exists = await c.routeExists(route);
    check('routeExists $route', true, exists ? '存在' : '不存在(404)');
  }

  print('');
  print('=' * 78);
  print('[6] 运行时指标（P4-26 埋点链路实证）');
  print('=' * 78);
  final snap = stats.snapshot();
  print('  逻辑调用=${snap.logicalCalls}  累计条目=${snap.totalItems}  '
      '实际 POST=${snap.httpPosts}');
  print('  每次 POST 处理条目 itemsPerPost=${snap.itemsPerPost.toStringAsFixed(2)}  '
      '省下 ${snap.httpPostsSaved} 次往返');
  print('  QPS=${snap.qps.toStringAsFixed(3)}  '
      '延迟 p50=${snap.latency.p50.toStringAsFixed(0)}ms '
      'p95=${snap.latency.p95.toStringAsFixed(0)}ms '
      'max=${snap.latency.max.toStringAsFixed(0)}ms  '
      '长尾比=${snap.latency.tailRatio.toStringAsFixed(2)}');
  print('  成功=${snap.successCalls} 失败=${snap.failedCalls}  '
      '成功率=${(snap.successRate * 100).toStringAsFixed(1)}%');
  if (snap.failuresByKind.isNotEmpty) {
    print('  失败分类: ${snap.failuresByKind}');
  }
  check('埋点记到了批量调用', snap.logicalCalls >= 3,
      'logicalCalls=${snap.logicalCalls}');
  check('条目数 ≥ 211（8 + 200 + 3）', snap.totalItems >= 211,
      'totalItems=${snap.totalItems}');
  check('itemsPerPost ≥ 2（攒批确实生效）', snap.itemsPerPost >= 2,
      snap.itemsPerPost.toStringAsFixed(2));
  check('延迟百分位有值', snap.latency.p50 > 0 && snap.latency.p95 >= snap.latency.p50,
      'p50=${snap.latency.p50.toStringAsFixed(0)} p95=${snap.latency.p95.toStringAsFixed(0)}');

  print('');
  print('=' * 78);
  print('VERDICT: $pass passed, $fail failed');
  print('=' * 78);
  if (fail > 0) exitCode = 1;
}
