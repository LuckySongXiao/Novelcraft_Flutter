// RwkvConcurrencyController 修复项验证：唤醒式许可门控。
//
// 用假探针控制服务端容量，验证：
// - 打满时等待、leaveInFlight 唤醒后立即复评放行（非轮询周期）；
// - 惩罚档回升（noteSuccess ×5）唤醒全部等待者；
// - 许可周期兜底（容量探测升档，无本地事件路径）。
//
// 运行：flutter test test/rwkv_concurrency_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import 'package:novelcraft/ai/rwkv/rwkv_concurrency.dart';

RwkvServerCapacity _cap(int avail) => RwkvServerCapacity(
      hardMaxBsz: 169,
      dynamicMaxBsz: 169,
      availableBsz: avail,
      reservedBsz: 0,
      queuedRequests: 0,
      freeVramBytes: 1 << 30,
      totalVramBytes: 1 << 35,
      bytesPerBsz: 52 << 20,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Logger.root.level = Level.OFF;

  group('RwkvConcurrencyController 唤醒式门控', () {
    test('leaveInFlight 唤醒等待者（非轮询周期）', () async {
      var permits = 2;
      final c = RwkvConcurrencyController(
        probe: () async => _cap(permits),
        clientHardCap: 8,
        logger: Logger('t'),
      );

      // 占满 2 个许可
      c.enterInFlight();
      c.enterInFlight();
      var entered = false;
      final waiter = c.waitForPermit().then((_) => entered = true);

      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(entered, isFalse, reason: '打满时应等待');

      // 释放一个许可 → 应在远小于 1s 兜底周期内放行
      final sw = Stopwatch()..start();
      c.leaveInFlight();
      await waiter;
      sw.stop();
      expect(entered, isTrue);
      expect(sw.elapsedMilliseconds, lessThan(800),
          reason: '唤醒应即时（1s 是兜底而非主路径）');
    });

    test('惩罚档回升唤醒全部等待者', () async {
      final c = RwkvConcurrencyController(
        probe: () async => _cap(64),
        clientHardCap: 8,
        logger: Logger('t'),
      );
      // 触发惩罚：bsz 4 > max 2 → 建议 = min(2, 4~/2=2) = 2（非 1）
      c.noteBszOverflow(4, 2);
      expect(await c.effectivePermits(), 2);

      // 占满 2 个许可，两个等待者
      c.enterInFlight();
      c.enterInFlight();
      var a = false, b = false;
      final wa = c.waitForPermit().then((_) => a = true);
      final wb = c.waitForPermit().then((_) => b = true);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(a, isFalse);
      expect(b, isFalse);

      // 连续 5 次成功 → 惩罚 2→3 → 唤醒全部 → 两个等待者都放行
      for (var i = 0; i < 5; i++) {
        c.noteSuccess();
      }
      await Future.wait(<Future<void>>[wa, wb]);
      expect(a, isTrue);
      expect(b, isTrue, reason: '惩罚回升唤醒全部等待者后容量足够双双放行');
    });

    test('周期兜底：容量升档（TTL 过期重探）后放行', () async {
      var permits = 1;
      final c = RwkvConcurrencyController(
        probe: () async => _cap(permits),
        clientHardCap: 8,
        // 测试用短 TTL：容量缓存 300ms 过期重探，模拟真实 15s TTL 的
        // 「服务端扩容 → 下一次探测看到新容量」路径
        capacityTtl: const Duration(milliseconds: 300),
        logger: Logger('t'),
      );
      c.enterInFlight();
      var entered = false;
      final waiter = c.waitForPermit().then((_) => entered = true);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(entered, isFalse);
      // 服务端扩容；旧缓存 300ms 后过期，兜底周期醒来重探即见新容量
      permits = 8;
      await waiter.timeout(const Duration(seconds: 3));
      expect(entered, isTrue, reason: '容量升档 + TTL 过期后兜底周期应放行');
    });
  });
}
