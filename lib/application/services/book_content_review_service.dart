import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import '../../ai/models/chat.dart';
import '../../ai/models/provider.dart';
import '../../ai/utils/json_scan.dart';
import '../../ai/utils/output_sanitizer.dart';
import '../../ai/utils/fiction_quality.dart';
import '../../data/database.dart';
import '../../data/repositories/chapter_repository.dart';
import '../../data/storage/key_value_store.dart';
import 'book_review_settings.dart';
import 'chapter_post_process_service.dart';
import 'chapter_sync_service.dart';
import 'writing_prompt_templates.dart';

class BookReviewComment {
  const BookReviewComment({
    required this.severity,
    required this.problem,
    required this.suggestion,
    required this.quote,
    this.author = '7B审查员',
  });

  final String severity;
  final String problem;
  final String suggestion;
  final String quote;
  final String author;

  Map<String, String> toJson() => <String, String>{
        'severity': severity,
        'problem': problem,
        'suggestion': suggestion,
        'quote': quote,
        'author': author,
      };

  factory BookReviewComment.fromJson(Map<String, Object?> json) => BookReviewComment(
        severity: (json['severity'] as String?) ?? 'info',
        problem: (json['problem'] as String?) ?? '',
        suggestion: (json['suggestion'] as String?) ?? '',
        quote: (json['quote'] as String?) ?? '',
        author: (json['author'] as String?) ?? '7B审查员',
      );
}

class BookReviewReport {
  const BookReviewReport({
    required this.chapterId,
    required this.reviewerModel,
    required this.comments,
    required this.raw,
    this.applied = false,
    this.revisedContent = '',
    this.seniorAdvice = '',
    this.seniorApproved = false,
  });

  final String chapterId;
  final String reviewerModel;
  final List<BookReviewComment> comments;
  final String raw;
  final bool applied;
  final String revisedContent;
  final String seniorAdvice;
  final bool seniorApproved;

  bool get hasAnomalies => comments.any((BookReviewComment c) =>
      c.severity.toLowerCase() == 'error' ||
      c.severity.toLowerCase() == 'critical' ||
      c.severity.toLowerCase() == 'warning');
}

/// 7B reviewer → 3B writer loop.
///
/// The reviewer receives the chapter, outline and a bounded context window,
/// then emits comments rather than prose. The writer only receives validated
/// comments and is allowed to replace the chapter after a final prose gate.
class BookContentReviewService {
  BookContentReviewService({
    required ChapterRepository chapters,
    required Future<KeyValueStore> Function() store,
    required IModelProvider? Function() reviewer,
    required IModelProvider? Function() seniorReviewer,
    required IModelProvider? Function() writer,
    IModelProvider? Function(GuestReaderProfile profile)? guestProvider,
    this.guestReaders = _emptyGuests,
    this.outline = _emptyOutline,
    this.promptTemplates,
    this.postProcess,
  })  : _chapters = chapters,
        _store = store,
        _reviewer = reviewer,
        _seniorReviewer = seniorReviewer,
        _writer = writer,
        _guestProvider = guestProvider;

  final ChapterRepository _chapters;
  final WritingPromptTemplates? promptTemplates;
  String _prompt(String id, Map<String, String> values) =>
      (promptTemplates ?? WritingPromptTemplates.defaults()).render(id, values);
  final Future<KeyValueStore> Function() _store;
  final IModelProvider? Function() _reviewer;
  final IModelProvider? Function() _seniorReviewer;
  final IModelProvider? Function() _writer;
  final IModelProvider? Function(GuestReaderProfile profile)? _guestProvider;
  final List<GuestReaderProfile> Function() guestReaders;
  final Future<String> Function(String projectId, ChapterRow chapter) outline;

  /// 审查 / 审核通过后的自动同步（功能 C：规则同步 + AI 设定抽取）。
  ///
  /// 可空 —— 未装配时跳过同步（离线测试 / 纯审查模式）。
  final ChapterPostProcessService? postProcess;

  static Future<String> _emptyOutline(String projectId, ChapterRow chapter) async => '';
  static List<GuestReaderProfile> _emptyGuests() => const <GuestReaderProfile>[];

  static String _key(String projectId, String chapterId) =>
      '$projectId:$chapterId';

  Future<BookReviewReport?> reviewChapter({
    required String projectId,
    required String chapterId,
    bool apply = false,
  }) async {
    final ChapterRow? chapter = await _chapters.getById(chapterId);
    if (chapter == null) {
      return null;
    }
    final IModelProvider? reviewer = _reviewer();
    if (reviewer == null || !reviewer.isAvailable) {
      return null;
    }
    final String text = (chapter.content ?? '').trim();
    if (text.isEmpty) {
      return BookReviewReport(
        chapterId: chapterId,
        reviewerModel: '',
        comments: const <BookReviewComment>[],
        raw: '',
      );
    }
    final String context = text.length > 9000 ? text.substring(text.length - 9000) : text;
    final String synopsis = await outline(projectId, chapter);
    final List<BookReviewComment> guestComments = await _collectGuestComments(
      chapter: chapter,
      synopsis: synopsis,
      text: text,
    );
    final String guestAdvice = jsonEncode(<Object?>[
      for (final BookReviewComment comment in guestComments) comment.toJson(),
    ]);
    final ChatResponse response = await reviewer.chat(ChatRequest(
      systemPrompt: _prompt('Review/reviewerSystem', {}),
      messages: <ChatMessage>[ChatMessage.user(
        _prompt('Review/reviewer', {'title': chapter.title, 'synopsis': synopsis, 'context': context, 'guestAdvice': guestAdvice}),
      )],
      temperature: .5,
      maxTokens: 1600,
    ));
    if (!response.isSuccess) return null;
    final String raw = AIOutputSanitizer.extractCleanOutput(response.content);
    final List<BookReviewComment>? comments =
        _parseComments(raw, text, author: '7B审查员');
    if (comments == null) return null;
    final List<BookReviewComment> allComments = <BookReviewComment>[
      ...guestComments,
      ...comments,
    ];
    String seniorAdvice = '';
    bool seniorApproved = false;
    final IModelProvider? senior = _seniorReviewer();
    if (senior != null && senior.isAvailable) {
      final ChatResponse seniorResponse = await senior.chat(ChatRequest(
        systemPrompt: _prompt('Review/seniorSystem', {}),
        messages: <ChatMessage>[ChatMessage.user(
          _prompt('Review/senior', {'title': chapter.title, 'synopsis': synopsis, 'context': context, 'comments': jsonEncode(<Object?>[for (final BookReviewComment comment in allComments) comment.toJson()])}),
        )],
        temperature: .35,
        maxTokens: 1400,
      ));
      if (seniorResponse.isSuccess) {
        final Map<String, dynamic>? verdict =
            _parseSenior(seniorResponse.content, text);
        if (verdict != null) {
          seniorAdvice = verdict['advice'] as String;
          seniorApproved = verdict['decision'] == 'approve';
          if (seniorAdvice.isNotEmpty) {
            allComments.add(BookReviewComment(
              severity: seniorApproved ? 'info' : 'warning',
              problem: seniorApproved ? '13B 已认可 7B 方案' : '13B 要求进一步修订',
              suggestion: seniorAdvice,
              quote: '',
              author: '13B首席审查员',
            ));
          }
          allComments.addAll(
            _parseComments(jsonEncode(<String, Object?>{
              'comments': verdict['comments'],
            }), text, author: '13B首席审查员') ?? const <BookReviewComment>[],
          );
        }
      }
    }
    await _saveComments(projectId, chapterId, allComments);
    BookReviewReport report = BookReviewReport(
      chapterId: chapterId,
      reviewerModel: response.model,
      comments: allComments,
      raw: raw,
      seniorAdvice: seniorAdvice,
      seniorApproved: seniorApproved,
    );
    if (apply && comments.isNotEmpty) {
      report = await applyComments(
        projectId: projectId,
        chapterId: chapterId,
        report: report,
        outlineText: synopsis,
      );
    }
    // ---- 审核通过后的自动同步（功能 C）----
    //
    // 此前这条路径**完全没有接后处理**：7B 审查、13B 复核、3B 改写全部跑完，
    // 正文也回写了，但「人物管理中的角色信息与角色履历」「世界观各子项的
    // 内容信息与状态履历」不会有任何更新 —— 这正是用户实测反馈的核心 BUG。
    // 现在审查落库即触发规则同步 + AI 设定抽取（开关见 AI 配置页）。
    if (apply) {
      await _syncAfterReview(chapterId, report);
    }
    return report;
  }

  /// 审查/审核通过后触发世界观、剧情、人物与时间线的自动同步。
  ///
  /// 两条要点：
  ///  1. 同步前先重读章节 —— [applyComments] 可能刚改写了正文并自增了版本；
  ///  2. 13B 首席审查员**认可**（`seniorApproved`）即视为「审核通过」，把仍处
  ///     草稿态的章节推进为「已完成」。状态本身应当如实反映审核结论；顺带也
  ///     让后续「按 Completed 过滤」的统计口径保持一致。
  ///     （注：AI 设定抽取 `ModuleStateService.extractAndApply` 的前置条件已
  ///     从 `status == 'Completed'` 放宽为「正文非空且通过质量闸」——草稿章
  ///     只要正文写出来了，设定照样登记，详见该方法的注释。）
  Future<void> _syncAfterReview(
    String chapterId,
    BookReviewReport report,
  ) async {
    final ChapterPostProcessService? post = postProcess;
    if (post == null) return;
    try {
      ChapterRow? row = await _chapters.getById(chapterId);
      if (row == null) return;
      String status = row.status;
      if (report.seniorApproved && status != 'Completed') {
        await _chapters.updateById(
          chapterId,
          ChaptersCompanion(status: const Value('Completed')),
        );
        status = 'Completed';
        row = await _chapters.getById(chapterId) ?? row;
      }
      await post.runForChapter(
        ChapterSyncInput(
          chapterId: row.id,
          volumeId: row.volumeId,
          projectId: row.projectId ?? '',
          title: row.title,
          orderIndex: row.orderIndex,
          content: (row.content ?? '').trim(),
          summary: row.summary,
          tags: row.tags,
          notes: row.notes,
          status: status,
          versionNumber: row.versionNumber,
          eventDate: DateTime.now(),
        ),
      );
    } on Object {
      // 后处理绝不阻塞审查流程；失败静默，可在「从已完成章节补同步」重试。
    }
  }

  Future<BookReviewReport> applyComments({
    required String projectId,
    required String chapterId,
    required BookReviewReport report,
    String outlineText = '',
  }) async {
    final ChapterRow? chapter = await _chapters.getById(chapterId);
    final IModelProvider? writer = _writer();
    if (chapter == null || writer == null || !writer.isAvailable || !report.hasAnomalies) {
      return report;
    }
    final String original = chapter.content ?? '';
    final String comments = jsonEncode(<Object?>[
      for (final BookReviewComment c in report.comments) c.toJson(),
    ]);
    final ChatResponse response = await writer.chat(ChatRequest(
      systemPrompt: _prompt('Review/writerSystem', {}),
      messages: <ChatMessage>[ChatMessage.user(
        _prompt('Review/writer', {'outline': outlineText, 'comments': comments, 'original': original}),
      )],
      temperature: .88,
      maxTokens: 1400,
    ));
    if (!response.isSuccess) return report;
    final String revised = AIOutputSanitizer.extractCleanOutput(response.content).trim();
    if (revised.isEmpty || FictionQuality.issue(revised) != null) return report;
    final bool updated = await _chapters.updateById(
      chapterId,
      ChaptersCompanion(
        content: Value(revised),
        wordCount: Value(revised.length),
        versionNumber: Value(chapter.versionNumber + 1),
        lastEditedAt: Value(DateTime.now()),
      ),
    );
    if (!updated) return report;
    return BookReviewReport(
      chapterId: chapterId,
      reviewerModel: report.reviewerModel,
      comments: report.comments,
      raw: report.raw,
      applied: true,
      revisedContent: revised,
      seniorAdvice: report.seniorAdvice,
      seniorApproved: report.seniorApproved,
    );
  }

  Future<List<BookReviewComment>> commentsFor(
    String projectId,
    String chapterId,
  ) async {
    try {
      final String? raw = await (await _store()).readJson(
        'book_review',
        _key(projectId, chapterId),
      );
      if (raw == null || raw.isEmpty) return const <BookReviewComment>[];
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return const <BookReviewComment>[];
      return <BookReviewComment>[
        for (final Object? item in decoded)
          if (item is Map)
            BookReviewComment.fromJson(item.map(
              (Object? k, Object? v) => MapEntry<String, Object?>('$k', v),
            )),
      ];
    } on Object {
      return const <BookReviewComment>[];
    }
  }

  Future<List<BookReviewComment>> _collectGuestComments({
    required ChapterRow chapter,
    required String synopsis,
    required String text,
  }) async {
    final List<GuestReaderProfile> profiles = guestReaders()
        .where((GuestReaderProfile profile) =>
            profile.enabled && profile.provider.trim().isNotEmpty)
        .toList(growable: false);
    final List<Future<List<BookReviewComment>>> jobs = <Future<List<BookReviewComment>>>[];
    for (final GuestReaderProfile profile in profiles) {
      jobs.add(() async {
        final IModelProvider? guest = _guestProvider?.call(profile) ?? _reviewer();
        if (guest == null || !guest.isAvailable) return const <BookReviewComment>[];
        final ChatResponse response = await guest.chat(ChatRequest(
          model: profile.model,
          systemPrompt: _prompt('Review/guestSystem', {'name': profile.name, 'taste': profile.taste}),
          messages: <ChatMessage>[ChatMessage.user(
            _prompt('Review/guest', {'title': chapter.title, 'synopsis': synopsis, 'text': text}),
          )],
          temperature: .8,
          maxTokens: 900,
        ));
        if (!response.isSuccess) return const <BookReviewComment>[];
        return _parseComments(
              AIOutputSanitizer.extractCleanOutput(response.content),
              text,
              author: profile.name,
            ) ??
            const <BookReviewComment>[];
      }());
    }
    if (jobs.isEmpty) return const <BookReviewComment>[];
    final List<List<BookReviewComment>> batches = await Future.wait(jobs);
    return <BookReviewComment>[for (final List<BookReviewComment> batch in batches) ...batch];
  }

  /// 取出审查结果里的 JSON 载荷：对象 `{...}` 或裸数组 `[...]` 都接受。
  ///
  /// 用 `lib/ai/utils/json_scan.dart` 的 [parseJsonPayload]（纯 Dart、已被离线
  /// 自检覆盖）—— 它**按文本里最先出现的结构字符**决定解析成对象还是数组。
  /// 这一点是关键：若改用「先试对象」的写法，裸数组 `[{…}]` 会被解析成内层
  /// 对象（`decoded['comments']` 取不到）→ 整章留言被判为「审查未产出」。
  ///
  /// 旧实现用贪婪正则 `\{[\s\S]*\}` 取「第一个 `{` 到最后一个 `}`」，
  /// 正文里只要再出现一对花括号就会整段截歪。
  static Object? _decodeReviewPayload(String raw) => parseJsonPayload(raw);

  static Map<String, dynamic>? _parseSenior(String raw, String source) {
    final Object? decoded = _decodeReviewPayload(raw);
    if (decoded is! Map || decoded['decision'] is! String || decoded['advice'] is! String) {
      return null;
    }
    final String decision = decoded['decision'] as String;
    if (decision != 'approve' && decision != 'revise') return null;
    final Object? comments = decoded['comments'];
    return <String, dynamic>{
      'decision': decision,
      'advice': (decoded['advice'] as String).trim(),
      'comments': comments is List ? comments : const <Object?>[],
    };
  }

  /// 解析审查留言 —— **逐条容错**，坏条目跳过而不是整章作废。
  ///
  /// 旧实现只要**任意一条**评论缺 problem/suggestion、或 quote 不是正文原文
  /// 子串，就 `return null` 把整章留言**全部丢弃** —— 现象正是用户报的
  /// 「审查功能没生效」：跑完一圈一条留言都看不到。
  ///
  /// 现在的取舍：
  ///   * 拿不到留言数组（JSON 结构不可用）才返回 null；
  ///   * 单条缺 problem / suggestion → 跳过该条；
  ///   * quote 不在正文里 → **清空 quote 保留该条**（留言的价值在
  ///     problem + suggestion，quote 只是佐证；小模型引用时爱加省略号、
  ///     改标点，逐字比对必然误伤）。
  static List<BookReviewComment>? _parseComments(
    String raw,
    String source, {
    String author = '7B审查员',
  }) {
    final Object? decoded = _decodeReviewPayload(raw);
    final Object? list = decoded is List
        ? decoded
        : (decoded is Map ? decoded['comments'] : null);
    if (list is! List) return null;
    final List<BookReviewComment> out = <BookReviewComment>[];
    for (final Object? item in list) {
      if (item is! Map) continue;
      final Map<String, Object?> map = item.map(
        (Object? k, Object? v) => MapEntry<String, Object?>('$k', v),
      );
      final BookReviewComment c = BookReviewComment.fromJson(
        <String, Object?>{...map, 'author': author},
      );
      if (c.problem.trim().isEmpty || c.suggestion.trim().isEmpty) continue;
      final String quote = c.quote.trim();
      if (quote.isEmpty || source.contains(quote)) {
        out.add(c);
        continue;
      }
      out.add(BookReviewComment(
        severity: c.severity,
        problem: c.problem,
        suggestion: c.suggestion,
        quote: '',
        author: c.author,
      ));
    }
    return out;
  }

  Future<void> _saveComments(
    String projectId,
    String chapterId,
    List<BookReviewComment> comments,
  ) async {
    try {
      await (await _store()).writeJson(
        'book_review',
        _key(projectId, chapterId),
        jsonEncode(<Object?>[for (final BookReviewComment c in comments) c.toJson()]),
      );
    } on Object {
      // Review persistence is supplementary; it must never block reading.
    }
  }
}
