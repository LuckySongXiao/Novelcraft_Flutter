// 最大令牌数滑动档位测试：16K/32K/64K/128K/256K/512K/1M。
//
// 运行：flutter test test/max_tokens_slider_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:novelcraft/ui/pages/ai_configuration_page.dart';

void main() {
  group('最大令牌数滑动档位', () {
    test('档位节点与标签一一对应', () {
      expect(kMaxTokensSteps, <int>[
        512, 1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144,
        524288, 1048576,
      ]);
      expect(kMaxTokensStepLabels, <String>[
        '512', '1K', '2K', '4K', '8K', '16K', '32K', '64K', '128K', '256K',
        '512K', '1M',
      ]);
      expect(kMaxTokensSteps.length, kMaxTokensStepLabels.length);
      // 12 档且单调递增
      for (var i = 1; i < kMaxTokensSteps.length; i++) {
        expect(kMaxTokensSteps[i], greaterThan(kMaxTokensSteps[i - 1]));
      }
    });

    test('档位值 → 标签', () {
      expect(maxTokensLabel(512), '512');
      expect(maxTokensLabel(1024), '1K');
      expect(maxTokensLabel(2048), '2K');
      expect(maxTokensLabel(4096), '4K');
      expect(maxTokensLabel(8192), '8K');
      expect(maxTokensLabel(16384), '16K');
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
      expect(maxTokensSliderIndex(400), 0, reason: '400 → 512');
      expect(maxTokensSliderIndex(3000), 2, reason: '3000 距 2048 更近');
      expect(maxTokensSliderIndex(4000), 3, reason: '4K 档命中');
      expect(maxTokensSliderIndex(5000), 3, reason: '5000 距 4096 更近');
      expect(maxTokensSliderIndex(6000), 3,
          reason: '6000 距 4096(1904) 比距 8192(2192) 更近');
      expect(maxTokensSliderIndex(6200), 4, reason: '6200 距 8192(1992) 更近');
      expect(maxTokensSliderIndex(65536), 7);
      expect(maxTokensSliderIndex(70000), 7, reason: '70K 距 64K 更近');
      expect(maxTokensSliderIndex(999999999), 11, reason: '超大值 → 1M');
      expect(maxTokensSliderIndex(0), 0, reason: '0/负界 → 最低档');
    });
  });
}
