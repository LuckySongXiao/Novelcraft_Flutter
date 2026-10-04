/// G1K v1.1 + T<=1.0: keep requests short and reject repeated prose loops.
class G1kWritingProfile {
  const G1kWritingProfile._();

  static const int draftMaxTokens = 1200;
  static const int draftTargetChars = 1100;
  static const int draftMinChars = 800;
  static const int draftMaxChars = 1200;
  static const double topP = 0.7;
  static const double presencePenalty = 2.0;

  static double temperature(double requested) =>
      requested.clamp(0.88, 1.0).toDouble();

  /// Return the start of the second occurrence once a sentence appears 3 times.
  /// Keeping the first occurrence avoids propagating a looping anchor.
  static int? repeatedSentenceOnset(String text) {
    final Map<String, List<int>> positions = <String, List<int>>{};
    final RegExp sentences = RegExp(r'[^。！？!?；;\n]+[。！？!?；;]');
    for (final RegExpMatch match in sentences.allMatches(text)) {
      final String sentence = match.group(0)!.replaceAll(RegExp(r'\s+'), '');
      if (sentence.length < 16) continue;
      final List<int> found = positions.putIfAbsent(sentence, () => <int>[]);
      found.add(match.start);
      if (found.length == 3) return found[1];
    }
    return null;
  }

  static String safeDraft(String text) {
    final int? repeatAt = repeatedSentenceOnset(text);
    String result = repeatAt == null ? text : text.substring(0, repeatAt);
    if (result.length > draftMaxChars) {
      final int lastSentence = result.lastIndexOf('。', draftMaxChars);
      result = lastSentence >= draftMinChars
          ? result.substring(0, lastSentence + 1)
          : result.substring(0, draftMaxChars);
    }
    return result.trim();
  }
}
