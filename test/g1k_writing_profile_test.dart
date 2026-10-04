import 'package:flutter_test/flutter_test.dart';
import 'package:novelcraft/ai/rwkv/g1k_writing_profile.dart';

void main() {
  test('G1K temperatures stay within the revised T<=1.0 range', () {
    expect(G1kWritingProfile.temperature(1.2), 1.0);
    expect(G1kWritingProfile.temperature(0.7), 0.88);
    expect(G1kWritingProfile.temperature(0.96), 0.96);
    expect(G1kWritingProfile.draftMaxTokens, 1200);
  });

  test('a repeated dialogue loop is cut before it enters the next anchor', () {
    const String first = '林凡推开石门，发现地面留着昨夜的剑痕。';
    const String second = '师姐拾起玉佩，问他是否听到了洞中的回声。';
    final String healthy = '$first$second';
    final String output = '$healthy$healthy$healthy';
    expect(G1kWritingProfile.repeatedSentenceOnset(output), healthy.length);
    expect(G1kWritingProfile.safeDraft(output), healthy);
  });

  test('short common phrases and two natural repetitions are retained', () {
    const String sentence = '师姐拾起玉佩，问他是否听到了洞中的回声。';
    expect(
      G1kWritingProfile.safeDraft('$sentence$sentence'),
      '$sentence$sentence',
    );
    expect(G1kWritingProfile.safeDraft('走吧。走吧。走吧。'), '走吧。走吧。走吧。');
  });

  test('prose is capped at a complete sentence under 1200 characters', () {
    final String output =
        '${List<String>.generate(70, (int i) => '第 $i 次转弯后，他沿山路继续前行，记下了每一道岔口。').join()}末尾';
    final String safe = G1kWritingProfile.safeDraft(output);
    expect(safe.length, lessThanOrEqualTo(1200));
    expect(safe.endsWith('。'), isTrue);
  });
}
