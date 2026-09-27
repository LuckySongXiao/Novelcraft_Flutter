// postJson 并发门控下沉的回归测试（交接文档遗留：「effectivePermits 此前
// 没有任何消费方」的补全 —— 非批量路由与批量路径共用同一许可闸）。
//
// 用 MockClient + 假探针（available=2）验证：state 路由的并发 POST
// 在途数不超过许可数，超限者在 finally 释放后才放行。
//
// 运行：flutter test test/postjson_gate_test.dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';

import 'package:novelcraft/ai/rwkv/rwkv_batch_client.dart';
import 'package:novelcraft/ai/rwkv/rwkv_concurrency.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Logger.root.level = Level.OFF;

  test('postJson 门控：在途数受许可限制，释放后放行', () async {
    int inFlight = 0;
    int peakInFlight = 0;
    final gate = Completer<void>();

    final client = MockClient((http.Request req) async {
      inFlight++;
      peakInFlight = peakInFlight > inFlight ? peakInFlight : inFlight;
      // 前 2 个请求挂住直到 gate 放行，制造在途窗口
      if (inFlight <= 2) {
        await gate.future;
      }
      inFlight--;
      return http.Response(
        '{"ok": true, "choices": []}',
        200,
      );
    });

    final concurrency = RwkvConcurrencyController(
      probe: () async => RwkvServerCapacity(
        hardMaxBsz: 4,
        dynamicMaxBsz: 4,
        availableBsz: 2,
        reservedBsz: 0,
        queuedRequests: 0,
        freeVramBytes: 1 << 30,
        totalVramBytes: 1 << 34,
        bytesPerBsz: 52 << 20,
      ),
      clientHardCap: 64,
      logger: Logger('t'),
    );

    final c = RwkvBatchClient(
      client: client,
      baseUrl: () => 'https://x',
      headers: () => <String, String>{},
      logger: Logger('t'),
    );
    c.concurrency = concurrency;

    // 4 路并发 postJson（state 路由），许可只有 2
    final futures = <Future<Map<String, dynamic>>>[
      for (var i = 0; i < 4; i++)
        c.postJson('/state/chat/completions', <String, dynamic>{
          'session_id': 's$i',
          'contents': <String>['x'],
        }),
    ];

    // 等待前 2 个进入在途、后 2 个被门控拦住
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(concurrency.inFlight, 2,
        reason: '许可 2：只有 2 个在途，其余在门控等待');
    expect(peakInFlight, 2, reason: '历史峰值不超过许可数');

    // 放行 → 后 2 个陆续进入并完成
    gate.complete();
    final results = await Future.wait(futures);
    expect(results.length, 4);
    expect(results.every((r) => r['ok'] == true), isTrue);
    expect(concurrency.inFlight, 0, reason: '全部完成后在途归零');
  });
}
