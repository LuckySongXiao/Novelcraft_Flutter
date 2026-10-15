// 数据集格式范式 · **可执行校验器**。
//
// 这个文件把 `docs/RWKV后训练数据集格式范式-v1.0.md` 的「质量闸 G1~G8」与
// 「逐任务校验器 V-x-x」从文字变成可运行代码 —— 造数据集时直接调用
// `DatasetSpecValidator.validate(...)`，不满足就拒绝该样本。
//
// 设计原则（与范式一致）：
//   1. **全确定性**，不调用任何模型；
//   2. **复用本仓库已有的纯规则实现**（`BriefPatch` / `MilestoneCodec` /
//      `RepetitionGuard` / `ForeshadowLedgerBuilder` / `ChapterTitleParser`），
//      不另写一套判据 —— 否则训练侧与运行时会漂移；
//   3. 每个闸失败都给出**可读的原因**（写进 `DatasetVerdict.failedChecks`），
//      便于拒绝采样时把原因回灌给教师模型。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'chapter_title.dart';
import 'foreshadow_ledger.dart';
import 'layered_pipeline_plan.dart'; // kChapterBriefFields / BriefPatch
import 'repetition_guard.dart';

/// 样本的格式种类（与范式 `format.kind` 一致）。
enum DatasetFormatKind {
  /// `[{"index":1,"label":…,"endState":…}, …]` —— 里程碑类。
  jsonArray,

  /// `{"names":[…]}` / `{"paragraphs":[…]}` 等 JSON 对象。
  jsonObject,

  /// `标题：…\n本章目标：…` 等字段行。
  textLines,

  /// 小说正文。
  prose,
}

/// 一条待校验的样本。
class DatasetSample {
  const DatasetSample({
    required this.task,
    required this.format,
    required this.completion,
    this.totalChapters = 0,
    this.globalOrder = 0,
    this.askChars = 0,
    this.milestoneCount = 0,
    this.requireLanguageGate = true,
  });

  /// 任务族 ID，取值见范式 §10（如 `T04_chapter_brief`）。
  final String task;

  final DatasetFormatKind format;

  /// 模型应答（必须已被 `cleanStructured` 清洗过）。
  final String completion;

  /// 全书章数（G5 越界校验用；0 = 不校验章号）。
  final int totalChapters;

  /// 本章是全书第几章（G5「末章禁埋」用）。
  final int globalOrder;

  /// 本篇的目标字数（G4 长度闸用；0 = 不校验下限）。
  final int askChars;

  /// 期望的里程碑条数（G2 用；0 = 不校验条数）。
  final int milestoneCount;

  /// 是否启用 G7（中文），界面/工具类样本可关掉。
  final bool requireLanguageGate;
}

/// 校验结论。
class DatasetVerdict {
  const DatasetVerdict({
    required this.ok,
    required this.failedGates,
    required this.failedChecks,
    required this.metrics,
  });

  final bool ok;

  /// 未通过的闸（`G1`~`G8`）。
  final List<String> failedGates;

  /// 未通过的具体检查（可读原因）。
  final List<String> failedChecks;

  /// 度量值（便于统计，不参与判定）。
  final Map<String, Object?> metrics;
}

/// 去重索引（G6）。
///
/// 用 **13-gram 的哈希集合**做 Jaccard 相似度。13 是经验值：
/// 短于 13 会误判（中文常见搭配大量重合），长于 13 会漏判「整句照抄」。
class DatasetDedup {
  DatasetDedup({this.threshold = 0.7, this.n = 13});

  final double threshold;
  final int n;

  final List<Set<int>> _index = <Set<int>>[];

  int get size => _index.length;

  /// 抽 n-gram 哈希集合（空白一律忽略）。
  static Set<int> grams(String text, int n) {
    final String s = text.replaceAll(RegExp(r'\s+'), '');
    final Set<int> out = <int>{};
    if (s.length < n) {
      if (s.isNotEmpty) out.add(s.hashCode);
      return out;
    }
    for (int i = 0; i + n <= s.length; i++) {
      out.add(s.substring(i, i + n).hashCode);
    }
    return out;
  }

  /// 与库中已有样本的最高 Jaccard 相似度。
  double maxSimilarity(String text) {
    final Set<int> g = grams(text, n);
    if (g.isEmpty || _index.isEmpty) return 0;
    double best = 0;
    for (final Set<int> h in _index) {
      if (h.isEmpty) continue;
      int inter = 0;
      for (final int x in g) {
        if (h.contains(x)) inter++;
      }
      final int union = g.length + h.length - inter;
      if (union == 0) continue;
      final double j = inter / union;
      if (j > best) best = j;
    }
    return best;
  }

  bool isDuplicate(String text) => maxSimilarity(text) >= threshold;

  void add(String text) => _index.add(grams(text, n));
}

/// 范式校验器（纯静态，无状态）。
abstract final class DatasetSpecValidator {
  // -------------------------------------------------------------------------
  // 指标
  // -------------------------------------------------------------------------

  /// 中文字符比例（G7）。
  ///
  /// ⚠ **必须把中文标点算进去** —— 首轮只数 0x4E00~0x9FFF，结果真实正文的中文比例
  /// 只有 0.83~0.84（`,。：；、！？「」《》——…` 全被判成「非中文」），
  /// 把合格中文全卡在 0.85 以下。中文排版里这些标点就是中文，必须计入：
  ///   0x3000~0x303F  CJK 符号和标点
  ///   0xFF00~0xFFEF  半角及全角形式（全角冒号/逗号/句号/括号）
  ///   0x2010~0x2027  连接号、引号、省略号（中文排版常用）
  static double cjkRatio(String text) {
    if (text.trim().isEmpty) return 0;
    int cjk = 0;
    int all = 0;
    for (final int r in text.runes) {
      if (r == 0x20 || r == 0x09 || r == 0x0a || r == 0x0d) continue;
      all++;
      if ((r >= 0x4E00 && r <= 0x9FFF) ||
          (r >= 0x3400 && r <= 0x4DBF) ||
          (r >= 0xF900 && r <= 0xFAFF) ||
          (r >= 0x3000 && r <= 0x303F) ||
          (r >= 0xFF00 && r <= 0xFFEF) ||
          (r >= 0x2010 && r <= 0x2027)) {
        cjk++;
      }
    }
    return all == 0 ? 0 : cjk / all;
  }

  /// G7 的中文比例下限，**按格式种类区分**。
  ///
  /// - `prose`：0.85 —— 正文就该是中文。
  /// - `textLines`：0.30 —— 细纲带 8 个字段名 + 冒号 + 书括号，结构性字符占比高。
  /// - `jsonArray` / `jsonObject`：0.02 —— JSON 里 `{}[]",` 已占掉大半字符，
  ///   只要求「确实含中文」，用来挡纯英文输出（E12 的极端形态）。
  static double minCjkRatioFor(DatasetFormatKind f) {
    switch (f) {
      case DatasetFormatKind.prose:
        return 0.85;
      case DatasetFormatKind.textLines:
        return 0.30;
      case DatasetFormatKind.jsonArray:
      case DatasetFormatKind.jsonObject:
        return 0.02;
    }
  }

  // -------------------------------------------------------------------------
  // 主入口
  // -------------------------------------------------------------------------

  static DatasetVerdict validate(DatasetSample s) {
    final List<String> gates = <String>[];
    final List<String> checks = <String>[];
    final Map<String, Object?> metrics = <String, Object?>{
      'task': s.task,
      'format': s.format.name,
      'chars': s.completion.length,
    };

    final String raw = s.completion;

    // ---- 样本级硬前提 ----
    if (raw.trim().isEmpty) {
      return DatasetVerdict(
        ok: false,
        failedGates: <String>['G1', 'G4'],
        failedChecks: <String>['样本为空'],
        metrics: metrics,
      );
    }

    // ---- G1 格式闸 ----
    Object? parsed;
    switch (s.format) {
      case DatasetFormatKind.jsonArray:
        parsed = _tryDecodeArray(raw);
        if (parsed == null) {
          gates.add('G1');
          checks.add('G1: 不是可解析的 JSON 对象数组（首字符须为 `[`、末字符须为 `]`、'
              '元素须为对象而非字符串）');
        }
      case DatasetFormatKind.jsonObject:
        parsed = _tryDecodeObject(raw);
        if (parsed == null) {
          gates.add('G1');
          checks.add('G1: 不是可解析的 JSON 对象');
        }
      case DatasetFormatKind.textLines:
      case DatasetFormatKind.prose:
        parsed = raw;
    }
    metrics['parsed'] = parsed == null ? null : 'ok';

    // ---- E17：服务端 `>` 前缀（G1 的伴生检查）----
    if (RegExp(r'^\s*>').hasMatch(raw)) {
      gates.add('G1');
      checks.add('E17: 仍带服务端 `>` 前缀 —— 必须在流水线阶段 2 剥掉');
    }

    // ---- G2 契约闸（按任务族）----
    final List<String> contract = _contractChecks(s, parsed, metrics);
    if (contract.isNotEmpty) {
      gates.add('G2');
      checks.addAll(contract);
    }

    // ---- G3 复读闸（仅正文）----
    if (s.format == DatasetFormatKind.prose) {
      final double ng = RepetitionGuard.charNgramRepeatRatio(raw);
      final bool deg = RepetitionGuard.isDegenerate(raw);
      metrics['ngram'] = double.parse(ng.toStringAsFixed(4));
      metrics['degenerate'] = deg;
      if (ng > 0.05) {
        gates.add('G3');
        checks.add('G3: ngram=${ng.toStringAsFixed(4)} > 0.05');
      }
      if (deg) {
        gates.add('G3');
        checks.add('G3: RepetitionGuard.isDegenerate 判定为退化');
      }
      // 收尾污染（E10 / E9）
      if (RegExp(r'（全文完）|（完）|全文完|THE END').hasMatch(raw)) {
        gates.add('G3');
        checks.add('E10: 出现收尾语');
      }
      final String t = raw.trimRight();
      const List<String> goodEnds = <String>['。', '！', '？', '”', '）', '…'];
      if (t.isNotEmpty && !goodEnds.any(t.endsWith)) {
        gates.add('G3');
        checks.add('E9: 末尾不是完整句（停在半句）');
      }
      // 大纲回抄 / 标题污染 / 角色标记泄漏
      if (RegExp(r'^(标题|本章目标|承接上文|核心冲突|关键转折|章末钩子)：', multiLine: true)
          .hasMatch(raw)) {
        gates.add('G3');
        checks.add('E6: 复述了细纲字段');
      }
      if (RegExp(r'^#{1,3}\s', multiLine: true).hasMatch(raw)) {
        gates.add('G3');
        checks.add('E5: 出现 Markdown 标题');
      }
      if (raw.contains('User:') || raw.contains('Assistant:')) {
        gates.add('G3');
        checks.add('E15: 角色标记泄漏');
      }
    }

    // ---- G4 长度闸 ----
    if (s.format == DatasetFormatKind.prose && s.askChars > 0) {
      // 单片可用上限 2400 字（+52 实测：再长就词级复读崩壞）
      if (raw.trim().length > 2400) {
        gates.add('G4');
        checks.add('G4: 单片 ${raw.trim().length} 字 > 2400 上限'
            '（整章必须分片构造）');
      }
      if (raw.trim().length < s.askChars * 0.9) {
        gates.add('G4');
        checks.add('G4: ${raw.trim().length} 字 < askChars*0.9'
            '（${(s.askChars * 0.9).round()}）');
      }
    }

    // ---- G5 一致性闸（伏笔章号 / 跨度 / 末章禁埋）----
    final List<String> consistency = _consistencyChecks(s, metrics);
    if (consistency.isNotEmpty) {
      gates.add('G5');
      checks.addAll(consistency);
    }

    // ---- G7 语言闸 ----
    if (s.requireLanguageGate) {
      final double ratio = cjkRatio(raw);
      metrics['cjkRatio'] = double.parse(ratio.toStringAsFixed(4));
      // ⚠ 阈值**按格式种类区分**：结构化样本天然含大量分隔符（`{}[]",` 与字段名
      // 「标题：」「本章目标：」），用正文的 0.85 去卡会把合格 JSON 全毙掉
      //（首轮实测：一份完全合格的里程碑中文比例只有 0.40）。
      // 这里的目标是抓 E12「中英混杂」，不是惩罚结构符号。
      final double minRatio = minCjkRatioFor(s.format);
      metrics['cjkMinRatio'] = minRatio;
      if (ratio < minRatio) {
        gates.add('G7');
        checks.add('G7: 中文比例 ${ratio.toStringAsFixed(3)} < '
            '${minRatio.toStringAsFixed(2)}）');
      }
    }

    // G6（去重）与 G8（教师一致性）需要跨样本，单独提供 API。

    gates.sort();
    return DatasetVerdict(
      ok: gates.isEmpty,
      failedGates: gates,
      failedChecks: checks,
      metrics: metrics,
    );
  }

  /// 「无需修改」的各种等价写法。
  static bool isNoChange(String text) {
    final String t = text.replaceAll(RegExp(r'[\s。．.,，、:：]'), '');
    if (t.isEmpty) return true;
    return const <String>[
      '无需修改',
      '无',
      '合格',
      '全部合格',
      '无需改动',
      '没有需要修改的字段',
    ].contains(t);
  }

  // -------------------------------------------------------------------------
  // G2 契约检查
  // -------------------------------------------------------------------------

  static List<String> _contractChecks(
    DatasetSample s,
    Object? parsed,
    Map<String, Object?> metrics,
  ) {
    final List<String> out = <String>[];
    switch (s.task) {
      case 'T01_volume_milestone':
      case 'T02_chapter_milestone':
        if (parsed is! List) return out;
        final List<Object?> items = parsed;
        metrics['itemCount'] = items.length;
        if (!items.every((Object? x) => x is Map)) {
          out.add('G2: 数组元素必须是对象（E11 schema 降级）');
        }
        if (s.milestoneCount > 0 && items.length != s.milestoneCount) {
          out.add('G2: 条数 ${items.length} != 期望 ${s.milestoneCount}');
        }
        for (int i = 0; i < items.length; i++) {
          final Object? it = items[i];
          if (it is! Map) continue;
          final int idx = int.tryParse('${it['index']}') ?? -1;
          if (idx != i + 1) {
            out.add('G2: 第 $i 项 index=$idx，应为 ${i + 1}');
          }
          if ((it['label'] ?? '').toString().trim().isEmpty) {
            out.add('G2: 第 ${i + 1} 项 label 为空');
          }
          final String es = (it['endState'] ?? '').toString().trim();
          if (es.isEmpty) {
            out.add('G2: 第 ${i + 1} 项 endState 为空');
          } else if (es.length < 20) {
            out.add('G2: 第 ${i + 1} 项 endState 仅 ${es.length} 字（需 40~80 字）');
          }
        }
        // 状态必须互不相同（否则弧线没推进）
        final Set<String> states = <String>{
          for (final Object? it in items)
            if (it is Map) (it['endState'] ?? '').toString().trim(),
        }..remove('');
        if (items.length > 1 && states.length <= 1) {
          out.add('G2: 所有 endState 相同 —— 弧线没有推进');
        }

      case 'T03_chapter_names':
        if (parsed is! Map) return out;
        final Object? names = parsed['names'];
        if (names is! List) {
          out.add('G2: 缺少 names 数组');
          return out;
        }
        metrics['nameCount'] = names.length;
        for (final Object? n in names) {
          if (n is! Map || n['name'] == null) {
            out.add('G2: names 元素必须是 {"i":…,"name":…}');
            continue;
          }
          final String nm = n['name'].toString().trim();
          if (nm.isEmpty) {
            out.add('G2: 存在空章名');
          } else if (nm.length < 4 || nm.length > 20) {
            out.add('G2: 章名「$nm」长度 ${nm.length} 不在 4~20');
          } else {
            final ChapterNameResult r = ChapterTitleParser.extractName(nm);
            if (!r.reliable) {
              out.add('E14: 章名「$nm」含元信息字段词，不可靠');
            }
          }
          if (RegExp(r'第\s*\d+\s*章|《|「', caseSensitive: false).hasMatch(nm)) {
            out.add('G2: 章名「$nm」含章号/书名号/引号');
          }
        }

      case 'T04_chapter_brief':
        if (!BriefPatch.looksLikeBrief(s.completion)) {
          out.add('G2: 不是合格细纲（命中字段 < 4）');
        }
        final Map<String, String> f = BriefPatch.parseFields(s.completion);
        metrics['fieldCount'] = f.length;
        if (f.length != 8) {
          out.add('G2: 解析到 ${f.length} 个字段，应为 8');
        }
        final List<String> dup = BriefPatch.duplicatedFields(s.completion);
        metrics['fieldDuplication'] = dup;
        if (dup.isNotEmpty) {
          out.add('E5: 字段复制 ${dup.join('、')}');
        }
        // 标题必须是 `标题：《章名》`
        final String? title = f['标题'];
        if (title == null || !RegExp(r'^《.{2,}$').hasMatch(title)) {
          out.add('G2: 标题字段缺失或不是 `标题：《章名》` 形态');
        }
        // 禁止输出示例占位行
        if (RegExp(r'Txxx|TXX|第[A-Za-z]章|：…$', multiLine: true)
            .hasMatch(s.completion)) {
          out.add('E3: 回抄了模板占位行');
        }

      case 'T05_brief_patch':
        if (isNoChange(s.completion)) {
          metrics['patchKind'] = 'no-change';
          return out;
        }
        metrics['patchKind'] = 'patch';
        final Map<String, String> pf = BriefPatch.parseFields(s.completion);
        metrics['patchFields'] = pf.keys.toList();
        if (pf.isEmpty) {
          out.add('G2: 补丁里没有任何 `字段名：新值` 行');
        }
        for (final String k in pf.keys) {
          if (!kChapterBriefFields.contains(k)) {
            out.add('G2: 补丁字段「$k」不在契约内');
          }
        }
        if (RegExp(r'请核验|请自查|①|②|③|④|如果全部合格|以上就是', multiLine: true)
            .hasMatch(s.completion)) {
          out.add('E4: 补丁里复述了核验清单');
        }

      default:
        // 其余任务族：至少非空 + 无 `>` 前缀（已在 G1 查）
        break;
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // G5 一致性检查（伏笔）
  // -------------------------------------------------------------------------

  static List<String> _consistencyChecks(
    DatasetSample s,
    Map<String, Object?> metrics,
  ) {
    final List<String> out = <String>[];
    if (s.task != 'T04_chapter_brief') return out;
    if (s.totalChapters <= 0) return out;

    // 用账本解析器重新解析整份细纲（与运行时同一条代码路径）。
    //
    // ⚠ 必须给账本**完整的全书章数**，不能只喂一章：`build()` 把「输入的章数」
    // 当成 `chapterCount`，只喂一章会让 `第6章 → …` 被判成「超出全书 1 章」
    //（首轮实测就是这个假阳性）。所以造 totalChapters 个源，只有本章带 outline。
    final int bookSize = s.totalChapters > 0 ? s.totalChapters : 1;
    final int myOrder = s.globalOrder > 0 ? s.globalOrder : 1;
    final List<ForeshadowChapterSource> sources =
        <ForeshadowChapterSource>[
      for (int o = 1; o <= (bookSize < myOrder ? myOrder : bookSize); o++)
        ForeshadowChapterSource(
          order: o,
          outline: o == myOrder ? s.completion : '',
          title: '',
          hasContent: false,
        ),
    ];
    final ForeshadowLedger ledger = ForeshadowLedgerBuilder.build(sources);
    metrics['foreshadowEntries'] = ledger.entries.length;
    metrics['foreshadowErrors'] = ledger.errors.length;
    if (ledger.errors.isNotEmpty) {
      for (final ForeshadowIssue e in ledger.errors) {
        out.add('G5: 伏笔结构错误 ${e.message}');
      }
    }

    // 末章禁埋：本书结尾不足 2 章时不得出现伏笔小节
    final bool canPlant = s.globalOrder > 0 &&
        s.globalOrder + 2 <= s.totalChapters;
    final bool hasSection = BriefPatch.foreshadowSection(s.completion) != null;
    if (!canPlant && hasSection) {
      out.add('G5: 第 $s.globalOrder 章距结尾不足 2 章，却仍输出了伏笔小节'
          '（末章禁埋）');
    }

    // 越界与跨度（账本不一定全查，这里兜一道显式检查）
    final RegExp hint =
        RegExp(r'-?\s*T?\s*\d{0,4}\s*[（(]\s*第?\s*(\d+)\s*章?\s*→\s*第?\s*(\d+)\s*章?');
    for (final RegExpMatch m in hint.allMatches(s.completion)) {
      final int a = int.parse(m.group(1)!);
      final int b = int.parse(m.group(2)!);
      if (a < 1 || a > s.totalChapters || b < 1 || b > s.totalChapters) {
        out.add('E6: 伏笔章号 $a→$b 超出本书 1~${s.totalChapters}');
      } else if (b - a < 2) {
        out.add('G5: 伏笔跨度 $a→$b 仅 ${b - a} 章（需 ≥2）');
      }
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // JSON 解码
  // -------------------------------------------------------------------------

  static List<Object?>? _tryDecodeArray(String text) {
    final String t = text.trim();
    final int s = t.indexOf('[');
    final int e = t.lastIndexOf(']');
    if (s != 0 || e != t.length - 1 || e <= s) return null;
    try {
      final dynamic d = jsonDecode(t);
      return d is List ? d : null;
    } on Object catch (_) {
      return null;
    }
  }

  static Map<String, Object?>? _tryDecodeObject(String text) {
    final String t = text.trim();
    final int s = t.indexOf('{');
    final int e = t.lastIndexOf('}');
    if (s != 0 || e != t.length - 1 || e <= s) return null;
    try {
      final dynamic d = jsonDecode(t);
      return d is Map ? Map<String, Object?>.from(d) : null;
    } on Object catch (_) {
      return null;
    }
  }
}


// ===========================================================================
// Part II · State Tuning 专项闸位
// ===========================================================================

/// State Tuning 的 state 目标（与 Part II §S2 一一对应）。
///
/// ⚠ 每个 state **单独一份数据集、单独训练、单独一个 `.pth`**。
/// state 是「整个数据集共享的一份全局偏置」，所以同质性要求远比 SFT 严格
/// —— 这就是下面这些闸存在的原因。
enum StateTarget {
  /// ST-1 正文写手。
  novelistProse('ST-1', 'novelist_prose', DatasetFormatKind.prose),

  /// ST-2 结构化规划（里程碑 / 大纲）。
  outlinerStruct('ST-2', 'outliner_struct', DatasetFormatKind.jsonArray),

  /// ST-3 细纲 8 字段契约。
  briefContract('ST-3', 'brief_contract', DatasetFormatKind.textLines),

  /// ST-4 自查补丁。
  copyeditorPatch('ST-4', 'copyeditor_patch', DatasetFormatKind.textLines),

  /// ST-5 单本书的世界观与文风。
  bookWorld('ST-5', 'book_world', DatasetFormatKind.prose),

  /// ST-6 跨章续写 + 伏笔义务。
  chapterLinker('ST-6', 'chapter_linker', DatasetFormatKind.prose);

  const StateTarget(this.id, this.name, this.format);

  final String id;
  final String name;

  /// 该 state **唯一允许**的输出形状。
  final DatasetFormatKind format;

  static StateTarget? byName(String name) {
    for (final StateTarget t in StateTarget.values) {
      if (t.name == name || t.id == name) return t;
    }
    return null;
  }
}

/// 一条 State Tuning 样本（Part II §S3 的可校验子集）。
class StateTuningSample {
  const StateTuningSample({
    required this.stateTarget,
    required this.completion,
    this.persona = '',
    this.pov = '',
    this.tense = '',
  });

  final StateTarget stateTarget;
  final String completion;

  /// 人格标签（如「分卷编剧」）。
  final String persona;

  /// 叙事人称（如「第三人称限知」）。
  final String pov;

  /// 时态（如「过去时」）。
  final String tense;
}

/// State Tuning 闸位结论。
class StateGateVerdict {
  const StateGateVerdict({
    required this.ok,
    required this.failedGates,
    required this.reasons,
    required this.metrics,
  });

  final bool ok;
  final List<String> failedGates;
  final List<String> reasons;
  final Map<String, Object?> metrics;
}

/// State Tuning 的数据阶段闸位（**ST-G9 同质性闸 / ST-G12 单轮闸**）。
///
/// ST-G10（反塌缩）与 ST-G11（基底保留）必须训练后才能执行，不在这里。
abstract final class StateTuningGates {
  /// `cjk_ratio` 允许的极差（Part II §S4.1）。
  static const double kCjkRangeMax = 0.10;

  /// 长度合格区间：中位数 ±30%（Part II §S4.1）。
  static const double kLengthBandRatio = 0.30;

  /// 区间外样本允许占比（Part II §S4.1）。
  static const double kOutlierRatioMax = 0.05;

  /// 单轮闸：出现成对角色标记即判失败。
  static final RegExp _turnPair = RegExp(
    r'(User\s*:|Assistant\s*:|System\s*:)',
    caseSensitive: false,
  );

  /// ST-G12：是否是严格单轮样本。
  static bool isSingleTurn(String completion) =>
      !_turnPair.hasMatch(completion);

  /// ST-G9e 用的长度度量。
  ///
  /// - `jsonArray`：**单元素平均长度**（总长 / 元素个数），绕开「元素个数
  ///   本来就该不同」的合法变动；
  /// - 其它：总字符数。
  static int _lengthMetric(StateTuningSample s, StateTarget target) {
    final int total = s.completion.trim().length;
    if (target.format != DatasetFormatKind.jsonArray) return total;
    final int open = s.completion.indexOf('[');
    final int close = s.completion.lastIndexOf(']');
    if (open < 0 || close <= open) return total;
    try {
      final dynamic d = jsonDecode(s.completion.substring(open, close + 1));
      if (d is List && d.isNotEmpty) return total ~/ d.length;
    } on Object catch (_) {
      // 解析失败：退回总长度（G1 会另外报错）
    }
    return total;
  }

  /// 对**一个 state 的一组样本**执行 ST-G9 + ST-G12。
  static StateGateVerdict checkGroup(List<StateTuningSample> samples) {
    final List<String> gates = <String>[];
    final List<String> reasons = <String>[];
    final Map<String, Object?> metrics = <String, Object?>{
      'count': samples.length,
    };

    if (samples.isEmpty) {
      return const StateGateVerdict(
        ok: false,
        failedGates: <String>['ST-G9'],
        reasons: <String>['ST-G9: state 组为空'],
        metrics: <String, Object?>{'count': 0},
      );
    }

    // ---- ST-G12 单轮闸 ----
    int multiTurn = 0;
    for (final StateTuningSample s in samples) {
      if (!isSingleTurn(s.completion)) multiTurn++;
    }
    metrics['multiTurn'] = multiTurn;
    if (multiTurn > 0) {
      gates.add('ST-G12');
      reasons.add('ST-G12: $multiTurn 条样本含 User:/Assistant:/System: 角色标记'
          '（state tuning 炼的是单轮）');
    }

    // ---- ST-G9a：state 目标必须单一 ----
    final StateTarget target = samples.first.stateTarget;
    final int mixed =
        samples.where((StateTuningSample s) => s.stateTarget != target).length;
    metrics['stateTarget'] = target.name;
    if (mixed > 0) {
      gates.add('ST-G9');
      reasons.add('ST-G9: 组内混了 $mixed 条其它 state 的样本'
          ' —— 一个 state 只能有一种输出形状/人格');
    }

    // ---- ST-G9b：每条样本都要过该 state 声明形状的 G1 ----
    int shapeBad = 0;
    for (final StateTuningSample s in samples) {
      if (DatasetSpecValidator.validate(DatasetSample(
            task: 'ST-${target.id}',
            format: target.format,
            completion: s.completion,
            requireLanguageGate: s.stateTarget == StateTarget.novelistProse ||
                s.stateTarget == StateTarget.bookWorld ||
                s.stateTarget == StateTarget.chapterLinker,
          )).failedGates.isNotEmpty) {
        shapeBad++;
      }
    }
    metrics['shapeBad'] = shapeBad;
    if (shapeBad > 0) {
      gates.add('ST-G9');
      reasons.add('ST-G9: $shapeBad 条样本不满足 ${target.format.name} 的格式契约');
    }

    // ---- ST-G9c：字段数一致（仅 textLines 类有意义）----
    if (target.format == DatasetFormatKind.textLines) {
      final Set<int> fieldCounts = <int>{
        for (final StateTuningSample s in samples)
          BriefPatch.parseFields(s.completion).length,
      };
      metrics['fieldCounts'] = fieldCounts.toList()..sort();
      if (fieldCounts.length > 1) {
        gates.add('ST-G9');
        reasons.add('ST-G9: 字段数不统一（出现 ${fieldCounts.toList()..sort()}）'
            ' —— state 只能偏一个形状');
      }
    }

    // ---- ST-G9d：cjk_ratio 极差 ----
    final List<double> ratios = <double>[
      for (final StateTuningSample s in samples)
        DatasetSpecValidator.cjkRatio(s.completion),
    ];
    final double rMin = ratios.reduce(math.min);
    final double rMax = ratios.reduce(math.max);
    metrics['cjkRatioRange'] =
        double.parse((rMax - rMin).toStringAsFixed(4));
    if (rMax - rMin > kCjkRangeMax) {
      gates.add('ST-G9');
      reasons.add('ST-G9: cjk_ratio 极差 ${(rMax - rMin).toStringAsFixed(3)}'
          ' > ${kCjkRangeMax.toStringAsFixed(2)}');
    }

    // ---- ST-G9e：长度必须落在中位数 ±30% 内（超窗占比 ≤5%）----
    //
    // ⚠ jsonArray 的**总字符数**会随元素个数合法变动（一本书 3 卷、另一本书
    // 40 章，本来就该不一样），拿总长度去卡会把合格的结构化数据全毙掉
    //（首轮实测：3/4/5/6 条里程碑就有 25% 样本超窗）。所以结构化类改用
    // **单元素平均长度** 作度量；prose / textLines 才用总长度。
    final List<int> lens = <int>[
      for (final StateTuningSample s in samples) _lengthMetric(s, target),
    ]..sort();
    final int med = lens[lens.length ~/ 2];
    final int lo = (med * (1 - kLengthBandRatio)).round();
    final int hi = (med * (1 + kLengthBandRatio)).round();
    final int outCount = lens.where((int l) => l < lo || l > hi).length;
    final double outRatio = outCount / lens.length;
    metrics['medianLength'] = med;
    metrics['lengthBand'] = <int>[lo, hi];
    metrics['outlierRatio'] = double.parse(outRatio.toStringAsFixed(4));
    if (outRatio > kOutlierRatioMax) {
      gates.add('ST-G9');
      reasons.add('ST-G9: 长度落在中位数 ±30%（$lo~$hi）外的样本占 '
          '${(outRatio * 100).toStringAsFixed(1)}%'
          ' > ${(kOutlierRatioMax * 100).toStringAsFixed(0)}%'
          ' —— state 只能偏一个长度，混太多档会全塌到中位数');
    }

    // ---- ST-G9f：人格 / 人称 / 时态零分歧 ----
    for (final MapEntry<String, List<String>> e
        in <String, List<String>>{
      'persona': <String>[for (final StateTuningSample s in samples) s.persona],
      'pov': <String>[for (final StateTuningSample s in samples) s.pov],
      'tense': <String>[for (final StateTuningSample s in samples) s.tense],
    }.entries) {
      final Set<String> distinct =
          e.value.where((String v) => v.trim().isNotEmpty).toSet();
      if (distinct.length > 1) {
        gates.add('ST-G9');
        reasons.add('ST-G9: ${e.key} 有分歧（${distinct.join(' / ')}）');
      }
    }

    gates.sort();
    return StateGateVerdict(
      ok: gates.isEmpty,
      failedGates: gates,
      reasons: reasons,
      metrics: metrics,
    );
  }
}
