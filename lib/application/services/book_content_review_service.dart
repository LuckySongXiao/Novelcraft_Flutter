import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import '../../ai/models/chat.dart';
import '../../ai/models/provider.dart';
import '../../ai/utils/output_sanitizer.dart';
import '../../ai/utils/fiction_quality.dart';
import '../../data/database.dart';
import '../../data/repositories/chapter_repository.dart';
import '../../data/storage/key_value_store.dart';
import 'book_review_settings.dart';
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
    return report;
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

  static Map<String, dynamic>? _parseSenior(String raw, String source) {
    Object? decoded;
    for (final RegExpMatch match in RegExp(r'\{[\s\S]*\}').allMatches(raw)) {
      try {
        decoded = jsonDecode(match.group(0)!);
        break;
      } on FormatException {
        continue;
      }
    }
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

  static List<BookReviewComment>? _parseComments(
    String raw,
    String source, {
    String author = '7B审查员',
  }) {
    Object? decoded;
    for (final RegExpMatch match in RegExp(r'\{[\s\S]*\}').allMatches(raw)) {
      try {
        decoded = jsonDecode(match.group(0)!);
        break;
      } on FormatException {
        continue;
      }
    }
    if (decoded is! Map || decoded['comments'] is! List) return null;
    final List<BookReviewComment> out = <BookReviewComment>[];
    for (final Object? item in decoded['comments'] as List) {
      if (item is! Map) {
        return null;
      }
      final Map<String, Object?> map = item.map(
        (Object? k, Object? v) => MapEntry<String, Object?>('$k', v),
      );
      final BookReviewComment c = BookReviewComment.fromJson(
        <String, Object?>{...map, 'author': author},
      );
      if (c.problem.trim().isEmpty || c.suggestion.trim().isEmpty) return null;
      if (c.quote.trim().isNotEmpty && !source.contains(c.quote.trim())) return null;
      out.add(c);
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
