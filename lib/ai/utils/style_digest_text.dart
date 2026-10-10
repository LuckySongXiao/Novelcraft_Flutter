// 拆书（文风研读）的**纯文本规则**。
//
// 这一层的职责：把「一本 10MB 的小说 txt」变成「若干段能塞进上下文窗口的样本」，
// 再把模型返回的零散观察合成一份规则。全是字符串处理，与模型/数据库无关。
//
// 为什么独立成文件：这些规则决定了拆书质量的上限（采样偏了 → 结论偏了；
// 合并错了 → 技法列表里全是重复项），必须能被离线自检覆盖。
// 与 `profile_synthesis_text.dart` / `json_scan.dart` 同级，保持纯 Dart。
library;

import 'json_scan.dart' as json_scan;

/// 固定 schema 的**文本维度**（键 → 中文名）。
///
/// 键名同时是提示词里的 JSON 字段名与规则模型的字段名，改键要三处一起改。
const Map<String, String> kStyleAspectLabels = <String, String>{
  'perspective': '叙事视角与人称',
  'sentence': '句式与段落长度',
  'dialogue': '对话与叙述配比',
  'imagery': '常用意象与修辞',
  'rhythm': '节奏与场景切换',
  'opening': '开篇与钩子技法',
  'taboo': '禁忌表达（AI 味与套路词）',
};

/// 技法大类。
///
/// 分节方式是照着用户既有的拆书产物（`E:\书籍拆分\...\作家技能库.md`）
/// 定的 —— 那份文件就是「可复用的写作技能」的标准形态，本功能产出的
/// `techniques` 与它同构（大类 → 技能名 → 可复用写法）。
const List<String> kStyleTechniqueCategories = <String>[
  '叙事技法',
  '人物塑造',
  '对话与语言',
  '战斗与冲突',
  '节奏与结构',
  '情绪与幽默',
  '主题与立意',
];

/// 文本维度单个字段的合并上限（字）。
///
/// 合并多块观察时若不设上限，字段会变成一串半重复的句子，注入提示词后
/// 只会稀释指令密度。
const int kStyleAspectMaxChars = 600;

/// 单个技法条目的描述上限。
const int kStyleTechniqueMaxChars = 300;

/// 一次拆书最多产出多少条技法。
const int kStyleMaxTechniques = 40;

abstract final class StyleDigestText {
  /// 广告 / 站点水印行（只对**短行**判定，正文里出现网址不算）。
  static final RegExp _noiseLine = RegExp(
    r'(https?://|www\.|\.com|加群|加微信|公众号|最新章节|手机阅读|无弹窗|txt下载|请记住本站)',
    caseSensitive: false,
  );

  /// 段落切分。
  ///
  /// 小说 txt 有两种常见排版：① 空行分段（网文导出）；② 每行一段、没有空行
  /// （手工整理稿）。空行切不出足够段落时退化为按行切 —— 否则整本书会被当成
  /// **一个**巨型段落，后面的分块只能硬切，章节边界全丢。
  static List<String> paragraphs(String text) {
    final String t = text.trim();
    if (t.isEmpty) return const <String>[];
    List<String> parts = t
        .split(RegExp(r'\n\s*\n'))
        .map((String e) => e.trim())
        .where((String e) => e.isNotEmpty)
        .toList();
    if (parts.length < 4) {
      parts = t
          .split('\n')
          .map((String e) => e.trim())
          .where((String e) => e.isNotEmpty)
          .toList();
    }
    return parts;
  }

  /// 样本清洗：去 BOM、压空行、丢掉短行里的站点水印。
  ///
  /// 不清洗的代价很直接 —— 广告行会被当作「正文风格」参与统计，
  /// 「请记住本站」「最新章节请访问…」这类模板句会污染句式结论。
  static String cleanSample(String text) {
    final String t = text.replaceFirst('\uFEFF', '');
    final List<String> out = <String>[];
    for (final String line in t.split('\n')) {
      final String s = line.trim();
      if (s.isEmpty) {
        // 折叠连续空行为一个，且不保留开头空行
        if (out.isNotEmpty && out.last.isNotEmpty) out.add('');
        continue;
      }
      if (s.length <= 60 && _noiseLine.hasMatch(s)) continue;
      out.add(s);
    }
    return out.join('\n').trim();
  }

  /// 把长文本切成若干样本块，并**均匀采样**出至多 [maxChunks] 块。
  ///
  /// 为什么不取开头若干块：网文的开头是「黄金三章」（全是作者最用力的部分），
  /// 只取开头会得出「节奏紧凑、冲突密集」这类**系统性偏差**的结论。这里首尾
  /// 必留（尾块代表作者成熟期的写法），中间均匀取样，兼顾全书面貌。
  static List<String> sampleChunks(
    String text, {
    int chunkChars = 4000,
    int maxChunks = 6,
  }) {
    final String t = text.trim();
    if (t.isEmpty) return const <String>[];
    if (chunkChars <= 0 || maxChunks <= 0) return <String>[t];
    if (t.length <= chunkChars) return <String>[t];

    final List<String> chunks = <String>[];
    final StringBuffer buf = StringBuffer();
    void flush() {
      if (buf.isNotEmpty) {
        chunks.add(buf.toString());
        buf.clear();
      }
    }

    for (final String para in paragraphs(t)) {
      if (para.length > chunkChars) {
        // 单段超长（整本没有分段）→ 硬切，否则这一块永远塞不进上下文。
        flush();
        for (int i = 0; i < para.length; i += chunkChars) {
          chunks.add(para.substring(i, (i + chunkChars).clamp(0, para.length)));
        }
        continue;
      }
      if (buf.length + para.length + 2 > chunkChars) flush();
      if (buf.isNotEmpty) buf.write('\n\n');
      buf.write(para);
    }
    flush();

    if (chunks.isEmpty) return <String>[t];
    if (chunks.length <= maxChunks) return chunks;

    final Set<int> picked = <int>{0, chunks.length - 1};
    for (int i = 1; i <= maxChunks - 2; i++) {
      picked.add(((i * (chunks.length - 1)) / (maxChunks - 1)).round());
    }
    final List<int> sorted = picked.toList()..sort();
    return <String>[for (final int i in sorted) chunks[i]];
  }

  /// 合并同一份样本内多块的观察结果。
  ///
  /// 文本维度：去重后「；」连接并截断（保留先出现、信息量更靠前的表述）。
  /// 技法列表：按标题去重累积，标题相同的只留第一条 —— 不同块看到同一个
  /// 技法时，重复条目会让最终规则显得冗长而难用。
  static Map<String, dynamic> mergeObservations(
    List<Map<String, dynamic>> observations, {
    int maxTechniques = kStyleMaxTechniques,
  }) {
    final Map<String, dynamic> out = <String, dynamic>{};
    for (final String key in kStyleAspectLabels.keys) {
      final List<String> values = <String>[];
      for (final Map<String, dynamic> o in observations) {
        final Object? v = o[key];
        if (v is String && v.trim().isNotEmpty) values.add(v.trim());
      }
      out[key] = _dedupeJoin(values, maxChars: kStyleAspectMaxChars);
    }

    final List<Map<String, dynamic>> techniques = <Map<String, dynamic>>[];
    final Set<String> seen = <String>{};
    for (final Map<String, dynamic> o in observations) {
      final Object? raw = o['techniques'];
      if (raw is! List) continue;
      for (final Object? item in raw) {
        if (item is! Map) continue;
        final String title = '${item['title'] ?? ''}'.trim();
        if (title.isEmpty) continue;
        final String key = title.toLowerCase();
        if (seen.contains(key)) continue;
        seen.add(key);
        String detail = '${item['detail'] ?? ''}'.trim();
        if (detail.length > kStyleTechniqueMaxChars) {
          detail = detail.substring(0, kStyleTechniqueMaxChars);
        }
        String category = '${item['category'] ?? ''}'.trim();
        if (!kStyleTechniqueCategories.contains(category)) {
          // 模型偶尔自造分类（如「其他」「写作技巧」）→ 归到最接近的大类，
          // 否则 UI 上会出现一堆只含一条技法的一级标题。
          category = nearestCategory('$title$detail');
        }
        techniques.add(<String, dynamic>{
          'category': category,
          'title': title,
          'detail': detail,
        });
        if (techniques.length >= maxTechniques) break;
      }
      if (techniques.length >= maxTechniques) break;
    }
    out['techniques'] = techniques;
    return out;
  }

  /// 按关键词把自造分类归到既有大类。
  ///
  /// 公开：`StyleDigestService` 在**汇总阶段**单独解析模型返回的技法时也要用
  /// 同一套归一规则，两处若各写一份，UI 上就会出现「同一类技法分到两个标题下」。
  static String nearestCategory(String text) {
    const Map<String, List<String>> hints = <String, List<String>>{
      '叙事技法': <String>['叙事', '视角', '人称', '线', '时空', '悬念', '伏笔', '信息差', '结构'],
      '人物塑造': <String>['人物', '角色', '性格', '配角', '女主', '男主', '反派', '群像', '动机'],
      '对话与语言': <String>['对话', '语言', '句式', '词', '描写', '比喻', '修辞', '口吻'],
      '战斗与冲突': <String>['战斗', '打斗', '冲突', '对决', '招式', '领域', '功法', '升级'],
      '节奏与结构': <String>['节奏', '结构', '章节', '转场', '场景', '铺垫', '高潮', '收尾'],
      '情绪与幽默': <String>['幽默', '笑', '情绪', '爽', '燃', '虐', '情感', '共鸣'],
      '主题与立意': <String>['主题', '立意', '思想', '价值', '内核'],
    };
    for (final MapEntry<String, List<String>> e in hints.entries) {
      for (final String h in e.value) {
        if (text.contains(h)) return e.key;
      }
    }
    return '叙事技法';
  }

  /// 去重后用「；」连接，并截到 [maxChars]。
  ///
  /// 三种情况：
  ///   * 完全相同的 → 丢掉后来的；
  ///   * 已有的是新值的**超集** → 丢掉新值（信息没增加）；
  ///   * 新值是已有的**超集** → **用新值替换**已有的。
  ///
  /// ⚠ 第三种必须替换而不是「跳过」。只判 `kept.contains(v)` 会让**先到的短句
  /// 把后到的长句挤掉** —— 观察是按块顺序来的，早的块不一定更完整，
  /// 结果就是越靠后的信息越容易被丢掉。
  static String _dedupeJoin(List<String> values, {required int maxChars}) {
    final List<String> kept = <String>[];
    for (final String v in values) {
      bool handled = false;
      for (int i = 0; i < kept.length; i++) {
        final String k = kept[i];
        if (k == v || k.contains(v)) {
          handled = true;
          break;
        }
        if (v.contains(k)) {
          kept[i] = v; // 新值更完整 → 替换，而不是跳过
          handled = true;
          break;
        }
      }
      if (!handled) kept.add(v);
    }
    String joined = kept.join('；');
    if (joined.length > maxChars) joined = joined.substring(0, maxChars);
    return joined;
  }

  /// 平衡扫描 JSON 对象（实现见 `json_scan.dart`，三处共用）。
  static Map<String, dynamic>? parseJsonObject(String raw) =>
      json_scan.parseJsonObject(raw);
}
