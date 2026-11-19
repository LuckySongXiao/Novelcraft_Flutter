// 最大令牌数滑动档位测试：512 → 1M（含 24K/25K 两个非 2 的幂档位）。
//
// 运行：flutter test test/max_tokens_slider_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:novelcraft/ui/pages/ai_configuration_page.dart';

void main() {
  group('最大令牌数滑动档位', () {
    test('档位表：严格递增、标签数量一致且不重复', () {
      expect(kMaxTokensSteps.length, kMaxTokensStepLabels.length);
      expect(kMaxTokensSteps.length, greaterThanOrEqualTo(12));
      for (var i = 1; i < kMaxTokensSteps.length; i++) {
        expect(
          kMaxTokensSteps[i],
          greaterThan(kMaxTokensSteps[i - 1]),
          reason: '第 $i 档必须大于前一档',
        );
      }
      expect(
        kMaxTokensStepLabels.toSet().length,
        kMaxTokensStepLabels.length,
        reason: '标签必须两两不同',
      );
      // 下限/上限是给用户的承诺；中间档位允许增删。
      expect(kMaxTokensSteps.first, 512);
      expect(kMaxTokensSteps.last, 1048576);
      // 24K / 25K 是为 RWKV G1K 云端 `ctx25600` 专门插入的（见页面注释），
      // 若被删掉，用户将永远选不出模型真实支持的 25K。
      expect(
        kMaxTokensSteps,
        containsAll(<int>[24576, 25600]),
        reason: '必须保留 24K / 25K 档位',
      );
    });

    test('档位值 → 标签', () {
      expect(maxTokensLabel(512), '512');
      expect(maxTokensLabel(1024), '1K');
      expect(maxTokensLabel(2048), '2K');
      expect(maxTokensLabel(4096), '4K');
      expect(maxTokensLabel(8192), '8K');
      expect(maxTokensLabel(16384), '16K');
      expect(maxTokensLabel(24576), '24K');
      expect(maxTokensLabel(25600), '25K');
      expect(maxTokensLabel(32768), '32K');
      expect(maxTokensLabel(65536), '64K');
      expect(maxTokensLabel(131072), '128K');
      expect(maxTokensLabel(262144), '256K');
      expect(maxTokensLabel(524288), '512K');
      expect(maxTokensLabel(1048576), '1M');
    });

    test('非档位值显示原始数值（如存量配置 3000）', () {
      expect(maxTokensLabel(3000), '3000');
      expect(maxTokensLabel(1), '1');
    });

    test('存量自定义值吸附最近档位', () {
      // 断言「吸附到哪一档」而不是写死索引：中间档位增删不会让测试变脆。
      int snapped(int v) => kMaxTokensSteps[maxTokensSliderIndex(v)];

      expect(snapped(400), 512, reason: '400 → 最低档');
      expect(snapped(3000), 2048, reason: '3000 距 2048 更近');
      expect(snapped(4000), 4096, reason: '4K 档命中');
      expect(snapped(5000), 4096);
      expect(snapped(6000), 4096, reason: '6000 距 4096(1904) 比距 8192(2192) 更近');
      expect(snapped(6200), 8192, reason: '6200 距 8192(1992) 更近');
      expect(snapped(24576), 24576, reason: '24K 档命中');
      expect(snapped(25600), 25600, reason: '25K 档命中');
      expect(snapped(65536), 65536);
      expect(snapped(70000), 65536, reason: '70K 距 64K 更近');
      expect(snapped(999999999), 1048576, reason: '超大值 → 1M');
      expect(snapped(0), 512, reason: '0/负界 → 最低档');
    });
  });
}
