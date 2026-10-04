import '../../ai/models/provider.dart';
import '../../ai/runtime_settings.dart';
import '../../ai/rwkv/rwkv_sampling.dart';
import '../../ai/utils/fiction_quality.dart';

enum ChapterAiAction { polish, dedupePolish, expand, continueWrite, rewrite }

abstract final class SelectionEditService {
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
    return '任务：$operation\n作者要求（优先于默认操作）：$instruction\n'
        '卷大纲：$volumeOutline\n章大纲：$chapterOutline\n'
        '上一章结尾：$prevChapterTail\n'
        '<before>$before</before>\n<selection>$selected</selection>\n<after>$after</after>\n'
        '只输出本次处理的片段，不输出 before/after、标题、标签、解释或原文对照。';
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
      return null;
    },
  );
}
