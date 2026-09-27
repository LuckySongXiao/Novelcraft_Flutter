// RWKV 超级并发压测（真端点，桌面端运行）。
//
// ⚠ 与 rwkv_cloud_live_test.dart 同级：打真实 `api-7b.rwkvos.com`，依赖外网 +
//   CF Access 凭证 + GPU 在线，不进 CI。运行：
//
//   flutter test integration_test/rwkv_concurrency_stress_test.dart -d windows -r expanded
//
// 压测矩阵（PITFALLS §31.3：服务端自带 FIFO admission queue，单路吞吐峰值 N≈16）：
//   ① 容量探测        —— hard/dynamic/available/queued，决定后续压测档位
//   ② 串行基线        —— 8 条提示词逐个跑，作为吞吐对照
//   ③ 8 槽单 POST     —— 同 8 条一次批量，验证批量加速比
//   ④ 48 路并行       —— 6 个 batchChat × 8 槽同时打（服务端排队兜底）
//   ⑤ 16 路有状态并发 —— 16 个独立 session 并行续跑 + 清理
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:novelcraft/ai/models/batch_chat.dart';
import 'package:novelcraft/ai/providers/rwkv_cloud_provider.dart';

const String _cfId = String.fromEnvironment('RWKV_CF_ID');
const String _cfSecret = String.fromEnvironment('RWKV_CF_SECRET');

/// 48 个彼此不同的主题：既是内容源，也用于肉眼核查槽位没有混串。
const List<String> _topics = <String>[
  '流化床', '碳化硅', '直拉法', '区域熔炼', '布里奇曼法', '泡生法', '热交换法', '焰熔法',
  '提拉速率', '晶种', '位错', '晶圆抛光', '坩埚', '石英砂', '单晶硅', '多晶硅',
  '蓝宝石衬底', '氮化镓', '碳化钽', '热场', '保温筒', '石墨件', '籽晶轴', '坩埚轴',
  '真空泵', '氩气', '冷却水', '热电偶', '欧姆定律', '傅里叶变换', '偏导数', '矩阵秩',
  '卷积', '注意力机制', '递归', '动态规划', '红黑树', '哈希表', 'TCP握手', 'DNS解析',
  '修仙炼气', '金丹雷劫', '元婴出窍', '门派大比', '灵石经济', '宗门政务', '秘境探宝', '灵宠养成',
];

String _prompt(String topic) => 'User: 用一句话解释「$topic」。\n\nAssistant:';

void main() {
  late RwkvCloudProvider provider;

  setUp(() async {
    provider = RwkvCloudProvider(client: http.Client());
    await provider.initialize(RwkvCloudConfiguration(
      cfAccessClientId: _cfId,
      cfAccessClientSecret: _cfSecret,
    ));
  });

  tearDown(() => provider.dispose());

  test('① 容量探测：hard/dynamic/available/queued', () async {
    final c = await provider.capacity();
    expect(c, isNotNull, reason: '端点未响应 /state 或 /v1/server/status');
    // ignore: avoid_print
    print('容量: hard=${c!.hardMaxBsz} dynamic=${c.dynamicMaxBsz} '
        'available=${c.availableBsz} queued=${c.queuedRequests} '
        'bytesPerBsz=${c.bytesPerBsz} effective=${c.effectiveAvailable}');
    expect(c.effectiveAvailable ?? 0, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('② 串行基线：8 条逐个跑（吞吐对照）', () async {
    final prompts = _topics.take(8).map(_prompt).toList();
    final sw = Stopwatch()..start();
    for (final p in prompts) {
      final out = await provider.batchChat(
        RwkvBatchRequest(contents: <String>[p], maxTokens: 48),
      );
      expect(out.single?.trim() ?? '', isNotEmpty);
    }
    sw.stop();
    // ignore: avoid_print
    print('串行 8 条: ${sw.elapsedMilliseconds} ms，'
        '吞吐 ${(8 / sw.elapsedMilliseconds * 1000).toStringAsFixed(2)} req/s');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('③ 8 槽单 POST：同 8 条一次批量（对照加速比）', () async {
    final prompts = _topics.take(8).map(_prompt).toList();
    final sw = Stopwatch()..start();
    final out = await provider.batchChat(
      RwkvBatchRequest(contents: prompts, maxTokens: 48),
    );
    sw.stop();
    expect(out.length, 8);
    for (int i = 0; i < 8; i++) {
      expect(out[i]?.trim() ?? '', isNotEmpty, reason: '槽位 $i 为空');
    }
    // ignore: avoid_print
    print('8 槽单 POST: ${sw.elapsedMilliseconds} ms，'
        '吞吐 ${(8 / sw.elapsedMilliseconds * 1000).toStringAsFixed(2)} req/s');
    // 服务端批量必快于逐条往返（跨境 RTT 是大头，批量把 8 次 RTT 折成 1 次）
    expect(sw.elapsedMilliseconds, lessThan(8 * 4500),
        reason: '批量 8 槽应当显著快于串行 8 次单槽（串行实测见②的输出）');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('④ 超级并发：6 路批量 × 8 槽 = 48 条同时打', () async {
    final sw = Stopwatch()..start();
    final batches = List.generate(6, (int b) {
      final topics = _topics.skip(b * 8).take(8).map(_prompt).toList();
      return provider.batchChat(
        RwkvBatchRequest(contents: topics, maxTokens: 48),
      );
    });
    final results = await Future.wait(batches);
    sw.stop();

    final all = <String?>[];
    for (final r in results) {
      expect(r.length, 8, reason: '每个批量必须返回 8 个对齐槽位');
      all.addAll(r);
    }
    expect(all.length, 48);
    for (int i = 0; i < all.length; i++) {
      expect(all[i]?.trim() ?? '', isNotEmpty, reason: '槽位 $i 为空');
    }
    final distinct = all.map((String? t) => t!.trim()).toSet().length;
    final double tps = all.length / sw.elapsedMilliseconds * 1000;
    // ignore: avoid_print
    print('48 路并行: ${sw.elapsedMilliseconds} ms，吞吐 ${tps.toStringAsFixed(2)} req/s，'
        '去重内容 $distinct/48（不足 48 时人工看下是否相邻槽位混串）');
    final c = await provider.capacity();
    // ignore: avoid_print
    print('压测后服务端状态: queued=${c?.queuedRequests} '
        'available=${c?.availableBsz}（应回落，无残留堆积）');
  }, timeout: const Timeout(Duration(minutes: 8)));

  test('⑤ 16 路有状态会话并发（/state O(1) 增量）+ 清理', () async {
    final String ts = DateTime.now().millisecondsSinceEpoch.toString();
    final sessions = List.generate(16, (int i) => 'nc-stress-$ts-$i');

    final sw = Stopwatch()..start();
    final answers = await Future.wait(<Future<String>>[
      for (int i = 0; i < 16; i++)
        provider.statefulChat(
          sessionId: sessions[i],
          // ⚠ 别加「只回复：好的」这类指令——小模型第二轮会复读自己的
          // 上一句（上轮实测把「暗号是什么」也答成「好的」），并非串号
          prompt: 'User: 请记住暗号是「琉璃$i号」。\n\nAssistant:',
          maxTokens: 32,
        ),
    ]);
    sw.stop();

    for (final a in answers) {
      expect(a.trim(), isNotEmpty, reason: '有状态会话返回空');
    }
    // ignore: avoid_print
    print('16 路有状态并发: ${sw.elapsedMilliseconds} ms，'
        '吞吐 ${(16 / sw.elapsedMilliseconds * 1000).toStringAsFixed(2)} req/s');

    // 抽查 2 个会话的 state 复用（不重发历史，直接问暗号）。
    // 断言各自的暗号 + 不混入别的暗号 → 并发下既不丢 state 也不串号。
    for (final int i in <int>[7, 12]) {
      final probe = await provider.statefulChat(
        sessionId: sessions[i],
        prompt: 'User: 我刚才让你记的暗号是什么？只答暗号本身。\n\nAssistant:',
        maxTokens: 32,
      );
      expect(probe.contains('琉璃$i号'), isTrue,
          reason: '会话 $i 的 state 丢失或被复读污染。实际回答：$probe');
      final cross = RegExp(r'琉璃\d+号').allMatches(probe).map((RegExpMatch m) => m.group(0)).toSet();
      expect(cross, <String>{'琉璃$i号'},
          reason: '会话 $i 混入了别的会话暗号 → state 串号。回答：$probe');
    }

    // 收尾：清掉全部压测会话，别把 state 字节差留在服务端
    for (final sid in sessions) {
      await provider.stateDelete(sessionId: sid, deletePrefix: true);
    }
    // ignore: avoid_print
    print('已清理 ${sessions.length} 个压测会话');
  }, timeout: const Timeout(Duration(minutes: 6)));
}
