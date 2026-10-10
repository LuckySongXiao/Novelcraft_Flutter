// 分卷档案归纳的**纯文本规则**。
//
// 为什么单独一个文件：这些规则的输入输出都是字符串，与 drift / 模型 / Flutter
// 毫无关系，而它们恰好是最需要回归测试的部分 ——
//   * [volumeEntries] 错 → 归纳到别卷的剧情，档案串味；
//   * [mergeVolumeKeyEvents] 不幂等 → 反复归纳让字段无限膨胀；
//   * [isGrounded] 失效 → 小模型编造的设定被写进正式档案。
// 放在 `lib/ai/utils/` 与 `output_sanitizer.dart` / `chapter_title.dart` 同级，
// 保持纯 Dart，`dart --disable-dart-dev tools/entity_profile_selftest.dart` 可直跑。
//
// ⚠ 所有列名常量都是 **SQL 列名（snake_case）**，不是 Dart 属性名。
// `QueryRow.data` 的键、drift `GeneratedColumn.$name` 用的都是 SQL 名
// （drift 源码该字段的注释即 "The sql name of this column"）。写成
// `specialAbilities` 会**静默取不到值**：读成 null、写回时列不存在而报错。
library;

import 'json_scan.dart' as json_scan;

/// 归纳目标实体类型 → 可归纳的**档案性列**。
///
/// 刻意不含两个列：
///   * `history` —— 证据链，归纳的输入；把归纳结果写回去会让下一卷
///     「归纳的归纳」，信息两三卷内衰减成空话；
///   * `status` —— 由设定抽取按**章**维护，粒度比卷更细，用卷级归纳覆盖它是降级。
const Map<String, List<String>> kProfileSpec = <String, List<String>>{
  'character': <String>['personality', 'background', 'appearance', 'abilities'],
  'faction': <String>[
    'description',
    'resources',
    'special_abilities',
    'headquarters',
    'territory',
  ],
  'world': <String>['description', 'content', 'rules', 'related_settings'],
};

/// 实体类型的中文名（进提示词）。
const Map<String, String> kProfileTypeLabels = <String, String>{
  'character': '人物',
  'faction': '势力组织',
  'world': '世界观设定',
};

/// 字段的中文说明（进提示词）。键是 SQL 列名。
const Map<String, String> kProfileFieldLabels = <String, String>{
  'personality': '性格特点',
  'background': '出身背景',
  'appearance': '外貌特征',
  'abilities': '能力专长',
  'description': '情况概述',
  'resources': '掌握资源',
  'special_abilities': '特殊手段',
  'headquarters': '据点所在地',
  'territory': '势力范围',
  'content': '详细说明',
  'rules': '运转规则',
  'related_settings': '关联设定',
  'key_events': '关键事件',
};

/// 人物表的关键事件列（累积式，与「只填空」策略不同）。
const String kKeyEventsColumn = 'key_events';

/// 纯文本规则集合。
abstract final class ProfileSynthesisText {
  /// 流水账条目正则：`[<chapterId>:<version> <章节标题>] <内容>`。
  ///
  /// `chapterId` 是 UUID（不含冒号），紧随其后是 `:` + 版本号，因此
  /// `[^\]:\s]+` 不会把标题里的字符吞进来。
  static final RegExp entryRegex = RegExp(r'^\s*\[([^\]:\s]+):(\d+)[^\]]*\]\s*(.*)$');

  /// 从 `[<chapterId>:<version> <标题>] <内容>` 形式的流水账里，抽出属于
  /// [chapterIds] 的那些行的**内容部分**。
  ///
  /// 不属于本卷的行直接丢弃 —— 它们会在自己那一卷的归纳里被处理。
  /// 无章节标记的行（人工笔记）同样丢弃：归纳只处理机器可追溯的变更。
  static List<String> volumeEntries(String? history, Set<String> chapterIds) {
    final String raw = (history ?? '').trim();
    if (raw.isEmpty || chapterIds.isEmpty) return const <String>[];
    final List<String> out = <String>[];
    for (final String line in raw.split('\n')) {
      final String t = line.trim();
      if (t.isEmpty) continue;
      final RegExpMatch? m = entryRegex.firstMatch(t);
      if (m == null) continue;
      if (!chapterIds.contains(m.group(1))) continue;
      final String body = (m.group(3) ?? '').trim();
      if (body.isEmpty) continue;
      out.add(body);
    }
    return out;
  }

  /// 把本卷的关键事件段合并进已有的 `key_events` 文本。
  ///
  /// **幂等**：同卷重复归纳时旧的 `【第N卷】…` 段被**替换**而不是追加 ——
  /// 否则每归纳一次字段就长一段，跑几轮就变成另一个流水账，归纳的意义归零。
  static String mergeVolumeKeyEvents(
    String current,
    int volumeNo,
    List<String> items,
  ) {
    final String marker = '【第$volumeNo卷】';
    final List<String> kept = <String>[];
    for (final String line in current.split('\n')) {
      final String t = line.trim();
      if (t.isEmpty) continue;
      if (t.startsWith(marker)) continue;
      kept.add(t);
    }
    kept.add('$marker${items.join('；')}');
    return kept.join('\n');
  }

  /// 归纳出的文本必须**能在本卷流水或现有档案里找到依据**。
  ///
  /// 中文没有空格分词，所以这里用 **n-gram 重叠**而不是「取一个词组」：
  /// 从长到短取文本里的连续内容片段（4→2 字），只要有一个出现在语料里
  /// 就认为有据可依。
  ///
  /// ⚠ 不要退回到「用一个正则抓连续汉字段再整体比对」—— 中文里整句话就是
  /// 一个连续汉字段，那样每次都会拿整句去 contains，**永远不命中**，
  /// 结果是所有字段都被判为幻觉、档案一个字都填不上。
  ///
  /// 判据刻意宽松，只用来拦住「整句都是模型自创设定」这类明显幻觉。
  /// 宁可放过，不可误杀：误判为幻觉会让档案永远空白，比偶发漏网更难排查。
  static bool isGrounded(String text, String corpus) {
    final String t = text.trim();
    if (t.isEmpty) return false;
    // 没有语料可比对时不误杀（新实体尚无档案、本卷流水又极短的情况）。
    if (corpus.isEmpty) return true;
    for (int n = 4; n >= 2; n--) {
      for (int i = 0; i + n <= t.length; i++) {
        final String gram = t.substring(i, i + n);
        // 含标点 / 空白 / 换行的窗口不算依据（"。「" 这种匹配没有意义）。
        if (_contentGram.hasMatch(gram) && corpus.contains(gram)) return true;
      }
    }
    return false;
  }

  /// 「内容片段」判据：整段都是汉字 / 字母 / 数字，不含标点与空白。
  static final RegExp _contentGram = RegExp(r'^[\u4e00-\u9fa5A-Za-z0-9]+$');

  /// 平衡扫描出第一个合法 JSON 对象（实现见 `json_scan.dart`，三处共用）。
  ///
  /// 与 `ModuleStateService.parse` 同思路，但**不限定** `updates` 字段 ——
  /// 归纳的产出形状与设定抽取不同（前者是档案字段，后者是变更条目）。
  static Map<String, dynamic>? parseJsonObject(String raw) =>
      json_scan.parseJsonObject(raw);
}
