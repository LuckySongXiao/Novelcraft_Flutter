// AIOutputSanitizer 聊天模板 token 泻漏清理验证（对应 C# 版 RwkvThinkingStripper
// 同款修复：rwkv-g1k 等 chat 模板模型在 state 端点偶发输出原始模板标记）。
//
// 运行：flutter test test/output_sanitizer_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:novelcraft/ai/utils/output_sanitizer.dart';

void main() {
  group('AIOutputSanitizer 聊天模板 token 泄漏清理', () {
    test('孤立 im_start（带 role）被剥除', () {
      const raw = '<|im_start|>assistant\n正文第一段。';
      expect(AIOutputSanitizer.extractCleanOutput(raw), '正文第一段。');
    });

    test('endoftext 标记被剥除', () {
      const raw = '前文后文';
      expect(AIOutputSanitizer.extractCleanOutput(raw), '前文后文');
    });

    test('中段孤立 im_end 清理且保留前后正文', () {
      const raw = '前文。\n<|im_end|>\n后文继续。';
      final out = AIOutputSanitizer.extractCleanOutput(raw);
      expect(out, contains('前文'));
      expect(out, contains('后文继续'));
      expect(out, isNot(contains('im_end')));
    });

    test('模板续写（im_end 紧跟 im_start）整体截断', () {
      // 真机实测样本形态：模型开始续写对话模板，其后全是其他回合的模板文本
      const raw = '正文A。\n<|im_end|>\n<|im_start|>user （扮演玩家角色）\n夜色渐深。';
      expect(AIOutputSanitizer.extractCleanOutput(raw), '正文A。');
    });

    test('开头即模板续写 → 空输出', () {
      const raw = '<|im_end|> <|im_start|>user 全是模板垃圾内容';
      expect(AIOutputSanitizer.extractCleanOutput(raw), '');
    });

    test('大小写与空格变体同样命中', () {
      const raw = '<| IM_START |>assistant\n正文。';
      expect(AIOutputSanitizer.extractCleanOutput(raw), '正文。');
    });

    test('连续模板标记全部剥除', () {
      const raw = 'A<|im_end|><|im_end|><|im_start|>user x';
      expect(AIOutputSanitizer.extractCleanOutput(raw), 'A');
    });

    test('正常中文正文不受影响', () {
      const prose = '夜色如墨，林晚推开书店的木门，风铃轻响。';
      expect(AIOutputSanitizer.extractCleanOutput(prose), prose);
    });

    test('思维链 + 模板混合：模板先清，思维链再剥', () {
      const raw = 'We need to write.\n<|im_end|>\n真正的正文在这里。';
      expect(AIOutputSanitizer.extractCleanOutput(raw), contains('真正的正文在这里'));
    });
  });
}
