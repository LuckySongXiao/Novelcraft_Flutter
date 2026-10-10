import '../../ai/models/provider.dart';
import '../../ai/runtime_settings.dart';
import '../../ai/rwkv/rwkv_sampling.dart';
import '../../ai/utils/fiction_quality.dart';

enum ChapterAiAction { polish, dedupePolish, expand, continueWrite, rewrite }

abstract final class SelectionEditService {
  /// 各动作的**字数纪律**（2026-10-10 用户实测「续写的字数依然未达标」后补上
  /// —— 此前续写提示词没有任何字数要求，模型随手给一两百字就交差）。
  ///
  /// * `continueWrite`：目标约 1200 字、下限 600 字 —— 选节级续写要能接出
  ///   一个完整场面，而不是补一句话；
  /// * `expand`：目标 ≈ 选区 ×2（扩写本来就是要「变大」）；
  /// * 其余动作不设字数目标（润色/去重润色长度应与原文相当，重写按选区体量）。
  /// 「作者要求（优先于默认操作）」里写了字数时以作者要求为准 —— 提示词顺序
  /// 已保证这一点。
  static int wordTarget(ChapterAiAction action, int selectedLength) =>
      switch (action) {
        ChapterAiAction.continueWrite => 1200,
        ChapterAiAction.expand =>
          (selectedLength * 2).clamp(400, 2000),
        _ => 0,
      };

  /// 按动作给足输出预算：字数目标 ≈ tokens × 0.55，缺省沿用
  /// `FictionQuality.generate` 的 1800。
  static int maxTokens(ChapterAiAction action, int selectedLength) =>
      switch (action) {
        ChapterAiAction.continueWrite => 2400,
        ChapterAiAction.expand =>
          (wordTarget(action, selectedLength) * 2).clamp(1200, 3200),
        _ => 1800,
      };

  static String buildPrompt({
    required ChapterAiAction action,
    required String selected,
    required String fullContent,
    String instruction = '',
    String chapterOutline = '',
    String volumeOutline = '',
    String prevChapterTail = '',
  }) {
    final index = fullContent.indexOf(selected);
    if (index < 0) throw StateError('Selection no longer belongs to chapter');
    if (fullContent.indexOf(selected, index + selected.length) >= 0) {
      throw StateError('Selection is ambiguous; include surrounding text');
    }
    final before = fullContent.substring((index - 900).clamp(0, index), index);
    final end = index + selected.length;
    final after = fullContent.substring(end, (end + 900).clamp(end, fullContent.length));
    final rewrite = action == ChapterAiAction.rewrite ||
        RegExp(r'重写|无效|重新写|rewrite|invalid', caseSensitive: false)
            .hasMatch(instruction);
    final operation = rewrite
        ? '选区是无效稿。丢弃其中的噪音和问答，依据前后文与大纲重新创作衔接片段，'
            '不要翻译、复述或保留无效内容。'
        : switch (action) {
            ChapterAiAction.polish => '润色选区，保留有效情节和人物事实。',
            ChapterAiAction.dedupePolish => '删除重复和无效表述，再润色选区，不为凑字数扩写。',
            ChapterAiAction.expand => '依据大纲扩写选区的动作和细节，不改变既定事实。',
            ChapterAiAction.continueWrite => '仅输出紧接选区的新增正文，不重复选区，不复述后文。',
            ChapterAiAction.rewrite => '',
          };
    // 字数纪律：写进提示词的硬要求（作者要求在它之前，写了字数时以作者为准）。
    final int target = wordTarget(action, selected.length);
    final String lengthRule = target <= 0
        ? ''
        : (action == ChapterAiAction.continueWrite
            ? '\n篇幅要求：本次续写目标约 $target 字（下限 ${target ~/ 2} 字），'
                '要写出一个完整的场面，不要一两句话就收。'
            : '\n篇幅要求：本次扩写目标约 $target 字。');
    return '任务：$operation\n作者要求（优先于默认操作）：$instruction\n'
        '卷大纲：$volumeOutline\n章大纲：$chapterOutline\n'
        '上一章结尾：$prevChapterTail\n'
        '<before>$before</before>\n<selection>$selected</selection>\n<after>$after</after>\n'
        '只输出本次处理的片段，不输出 before/after、标题、标签、解释或原文对照。'
        '$lengthRule';
  }

  static Future<String> edit({
    required IModelProvider provider,
    required ChapterAiAction action,
    required String selected,
    required String fullContent,
    String model = '',
    String instruction = '',
    String chapterOutline = '',
    String volumeOutline = '',
    String prevChapterTail = '',
  }) => FictionQuality.generate(
    chat: provider.chat,
    model: model,
    maxTokens: maxTokens(action, selected.length),
    prompt: buildPrompt(
      action: action, selected: selected, fullContent: fullContent,
      instruction: instruction, chapterOutline: chapterOutline,
      volumeOutline: volumeOutline, prevChapterTail: prevChapterTail,
    ),
    parameters: isRwkvFamilyProvider(provider.providerName)
        ? aiRuntimeSettings.longFormSamplingParams() : {},
    validate: (text) {
      if (text == selected.trim()) return 'unchanged_selection';
      if (action != ChapterAiAction.dedupePolish &&
          action != ChapterAiAction.rewrite &&
          !RegExp(r'重写|无效|精简|缩短|rewrite|shorten', caseSensitive: false).hasMatch(instruction) &&
          text.length < selected.length * .6) {
        return 'truncated_selection';
      }
      // 续写下限：目标 1200 字的 50%（600 字）—— 两次尝试都不足即如实报错，
      // 让用户看到「续写太短」而不是默默收下一段尾巴。
      if (action == ChapterAiAction.continueWrite &&
          !RegExp(r'精简|缩短|shorten', caseSensitive: false).hasMatch(instruction) &&
          text.length < wordTarget(action, selected.length) ~/ 2) {
        return 'continuation_too_short (${text.length} chars)';
      }
      return null;
    },
  );
}
