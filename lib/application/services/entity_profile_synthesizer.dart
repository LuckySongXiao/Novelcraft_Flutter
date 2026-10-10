// 实体档案归纳 —— 把逐章累积的流水账收敛成「读得懂的档案」。
//
// 为什么需要它
// ------------
// `ModuleStateService` 每章把设定变化**追加**成一行
// `[<chapterId>:<version> <章节标题>] <变化内容>`，写进实体的 `history` 列
// （部分类型还会同时写 `status`/`description` 等列）。这让「变更可追溯」，
// 代价是写到第 30 章时，人物档案就是 30 行流水账 —— 用户点开「人物管理」
// 看到的是流水线日志，而不是「这个角色是谁」。
//
// 本服务在**每卷写完时**（以及用户手动点「归纳本卷档案」时）把**本卷**的流水
// 归纳为三样东西：
//   1. 稳定属性 —— 人物 `personality`/`background`/`appearance`/`abilities`，
//      势力 `description`/`resources`/`specialAbilities`/`headquarters`/`territory`，
//      世界观 `description`/`content`/`rules`/`relatedSettings`；
//   2. `keyEvents` —— 关键事件按卷累积成 `【第N卷】事件A；事件B`（仅人物表）；
//   3. 一句话小传 —— 汇总成可读报告，交调用方写进写作档案。
//
// 安全边界（**刻意保守，改之前先想清楚**）
// --------------------------------------
//   1. 稳定属性**默认只在字段为空时写入**，绝不覆盖作者手写或前卷已有的内容。
//      归纳是「模型意见」，不该抹掉人工成果。确要覆盖式重写时传
//      `overwriteExisting: true`。
//   2. `history` 列**一字不动** —— 它是可追溯的证据链，也是下次归纳的输入。
//      若把归纳结果写回 `history`，下一卷归纳就会把「归纳的归纳」再归纳一遍，
//      信息在两三轮内衰减成空话。
//   3. `status` 列**不动** —— 该列由 `ModuleStateService` 按章维护，粒度比卷更细，
//      用卷级归纳去覆盖它是降级。
//   4. 归纳文本一律过长度上限与 `FictionQuality` 闸，且必须能在本卷流水里找到
//      依据词（见 [ProfileSynthesisText.isGrounded]），防小模型编造设定。
import 'package:drift/drift.dart';

import '../../ai/models/chat.dart';
import '../../ai/models/provider.dart';
import '../../ai/utils/fiction_quality.dart';
import '../../ai/utils/localized_text.dart';
import '../../ai/utils/profile_synthesis_text.dart';
import '../../data/database.dart';
import 'module_state_service.dart';
import 'writing_prompt_templates.dart';

/// 一次分卷档案归纳的结果。
class EntityProfileResult {
  const EntityProfileResult({
    required this.isSuccess,
    required this.message,
    this.entitiesScanned = 0,
    this.entitiesUpdated = 0,
    this.fieldsFilled = 0,
    this.keyEventsAdded = 0,
    this.summaries = const <String>[],
    this.notes = const <String>[],
  });

  /// 是否跑到底（「本卷无候选实体」也算成功 —— 那是正常结论，不是失败）。
  final bool isSuccess;

  /// 人类可读结论，UI 直接显示。
  final String message;

  /// 本卷有流水的候选实体数。
  final int entitiesScanned;

  /// 实际写入了至少一个字段的实体数。
  final int entitiesUpdated;

  /// 填写的稳定属性字段总数。
  final int fieldsFilled;

  /// 累积/替换的关键事件段数量。
  final int keyEventsAdded;

  /// 各实体的一句话小传（`名称：小传`），供写入写作档案。
  final List<String> summaries;

  /// 需要人工注意的问题（模型返回不可用、字段全空等）。
  final List<String> notes;

  bool get hasChanges => entitiesUpdated > 0;
}

/// 单个候选实体（本卷有流水的实体）。
class _Candidate {
  _Candidate({
    required this.type,
    required this.table,
    required this.nameColumn,
    required this.historyColumn,
    required this.columns,
    required this.rowId,
    required this.name,
    required this.data,
    required this.entries,
  });

  final String type;
  final TableInfo table;
  final String nameColumn;
  final String historyColumn;

  /// 目标表真实存在的列名集合（drift `$name`，即 Dart 属性名）。
  final Set<String> columns;
  final String rowId;
  final String name;
  final Map<String, dynamic> data;

  /// 本卷的流水行（已剥掉 `[chapterId:version 标题]` 前缀）。
  final List<String> entries;
}

/// 分卷档案归纳服务。
class EntityProfileSynthesizer {
  EntityProfileSynthesizer({
    required this.db,
    required this.provider,
    this.promptTemplates,
    this.texts = const StaticTextSource(),
  });

  final AppDatabase db;

  /// 归纳用的模型。与设定抽取同源（主 Agent / 7.2B）—— 归纳是「规划级」任务。
  final IModelProvider? Function() provider;

  final WritingPromptTemplates? promptTemplates;

  /// 取词接口（领域层不依赖 i18n 表，见 `lib/ai/utils/localized_text.dart`）。
  final AiTextSource texts;

  String _t(String key, String fallback) => texts.t(key, fallback);

  String _tf(String key, String fallback, List<Object> args) =>
      texts.tf(key, fallback, args);

  // 归纳的字段规格（`kProfileSpec`）、类型/字段中文名、关键事件合并、
  // 防幻觉判据、JSON 平衡扫描等**纯文本规则**统一放在
  // `lib/ai/utils/profile_synthesis_text.dart` —— 那里是纯 Dart，
  // `tools/entity_profile_selftest.dart` 可离线直跑；本文件只留需要
  // 模型与数据库的流程逻辑。


  /// 字符串字段长度上限 —— 小模型超长输出通常意味着它开始复述流水。
  static const int maxFieldChars = 200;

  /// 单条关键事件长度上限。
  static const int maxEventChars = 60;

  /// 每个实体最多累积几条本卷关键事件。
  static const int maxEventsPerVolume = 5;

  /// 归纳**某一卷**的实体档案。
  ///
  /// [maxEntities] 默认 15，是**延迟与覆盖面的折中**：归纳挂在整书生成的
  /// 收尾阶段，每个实体一次模型调用，40 个实体 × 3 卷就是 120 次调用，
  /// 会把主流程拖长十分钟以上。候选已按「本卷流水条数」降序排序，
  /// 流水最多的必然是主角与核心势力 —— 优先保这批的档案质量。
  ///
  /// [volumeNo] 为 0 时自动按 `volumes.order_index` 推断；[volumeTitle] 为空时
  /// 自动查库。两者都取不到也不影响归纳，只影响提示词与关键事件段的标题。
  /// 自动查库。两者都取不到也不影响归纳，只影响提示词与关键事件段的标题。
  Future<EntityProfileResult> synthesizeVolume({
    required String volumeId,
    String projectId = '',
    String volumeTitle = '',
    int volumeNo = 0,
    bool overwriteExisting = false,
    int maxEntities = 15,
    int concurrency = 4,
    void Function(String step)? onProgress,
  }) async {
    if (volumeId.isEmpty) {
      return EntityProfileResult(
        isSuccess: false,
        message: _t('PRF.NoTarget', '缺少卷宗标识，无法归纳档案。'),
      );
    }
    final IModelProvider? p = provider();
    if (p == null || !p.isAvailable) {
      return EntityProfileResult(
        isSuccess: false,
        message: _t('PRF.NoProvider', '归纳所需的模型不可用（请在 AI 配置中检查主 Agent）。'),
      );
    }

    // ---- 1. 卷信息（标题 / 卷号 / 所属项目）与本卷章节 ----
    //
    // `projectId` 允许调用方不传：卷 → 项目是确定的（`volumes.project_id`），
    // 从卷宗列表的行按钮进来时只拿得到卷 id，没必要逼 UI 再反查一次项目。
    final QueryRow? vol = await db
        .customSelect(
          'SELECT title, order_index, project_id FROM volumes WHERE id = ?',
          variables: <Variable<Object>>[Variable<String>(volumeId)],
        )
        .getSingleOrNull();
    if (vol == null) {
      return EntityProfileResult(
        isSuccess: false,
        message: _t('PRF.NoVolume', '卷宗不存在，无法归纳档案。'),
      );
    }
    if (projectId.isEmpty) projectId = vol.read<String>('project_id');
    if (projectId.isEmpty) {
      return EntityProfileResult(
        isSuccess: false,
        message: _t('PRF.NoTarget', '该卷宗未关联项目，无法归纳档案。'),
      );
    }
    final String title = volumeTitle.isEmpty
        ? vol.read<String>('title')
        : volumeTitle;
    final int no = volumeNo > 0 ? volumeNo : vol.read<int>('order_index');
    final String volLabel = title.isEmpty
        ? '第$no卷'
        : '第$no卷《$title》';

    final List<QueryRow> chapterRows = await db
        .customSelect(
          'SELECT id FROM chapters WHERE volume_id = ? AND is_deleted = 0 '
          'ORDER BY order_index',
          variables: <Variable<Object>>[Variable<String>(volumeId)],
        )
        .get();
    final Set<String> chapterIds = <String>{
      for (final QueryRow r in chapterRows) r.read<String>('id'),
    };
    if (chapterIds.isEmpty) {
      return EntityProfileResult(
        isSuccess: true,
        message: _tf('PRF.NoChaptersFmt', '{0} 下没有章节，无需归纳。', <Object>[volLabel]),
      );
    }

    // ---- 2. 扫描本卷有流水的候选实体 ----
    onProgress?.call(
      _tf('PRF.ScanFmt', '正在扫描 {0} 的设定流水…', <Object>[volLabel]),
    );
    final Map<String, ModuleContract> contracts = ModuleStateService
        .contractsOf(db);
    final List<_Candidate> candidates = <_Candidate>[];
    for (final String type in kProfileSpec.keys) {
      final ModuleContract? c = contracts[type];
      if (c == null) continue;
      final String table = c.table.actualTableName;
      final List<QueryRow> rows = await db
          .customSelect(
            'SELECT * FROM "$table" WHERE project_id = ? AND is_deleted = 0',
            variables: <Variable<Object>>[Variable<String>(projectId)],
          )
          .get();
      for (final QueryRow row in rows) {
        final List<String> entries = ProfileSynthesisText.volumeEntries(
          row.data[c.historyColumn] as String?,
          chapterIds,
        );
        if (entries.isEmpty) continue;
        final String name = (row.data[c.nameColumn] as String?) ?? '';
        if (name.trim().isEmpty) continue;
        candidates.add(
          _Candidate(
            type: type,
            table: c.table,
            nameColumn: c.nameColumn,
            historyColumn: c.historyColumn,
            columns: c.columns,
            rowId: row.read<String>('id'),
            name: name.trim(),
            data: row.data,
            entries: entries,
          ),
        );
      }
    }
    if (candidates.isEmpty) {
      return EntityProfileResult(
        isSuccess: true,
        message: _tf(
          'PRF.NoEntitiesFmt',
          '{0} 内没有登记过设定变化的实体，无需归纳。',
          <Object>[volLabel],
        ),
      );
    }
    // 流水多的先归纳，实体过多时优先保证主角团/核心势力拿到档案。
    candidates.sort(
      (_Candidate a, _Candidate b) => b.entries.length.compareTo(a.entries.length),
    );
    final List<_Candidate> targets = candidates.length > maxEntities
        ? candidates.sublist(0, maxEntities)
        : candidates;

    // ---- 3. 逐实体归纳（有界并发）----
    final WritingPromptTemplates prompts =
        promptTemplates ?? WritingPromptTemplates.defaults();
    final List<String> summaries = <String>[];
    final List<String> notes = <String>[];
    int updated = 0;
    int fieldsFilled = 0;
    int eventsAdded = 0;
    int done = 0;
    await _runPool<_Candidate, void>(
      concurrency,
      targets,
      (_Candidate cand) async {
        try {
          final _Applied? applied = await _profileOne(
            p,
            prompts,
            cand,
            volumeNo: no,
            volumeTitle: title,
            overwriteExisting: overwriteExisting,
          );
          if (applied == null) {
            notes.add(
              _tf('PRF.EntityNoOutputFmt', '{0}（{1}）：模型未产出可用档案', <Object>[
                cand.name,
                kProfileTypeLabels[cand.type] ?? cand.type,
              ]),
            );
            return;
          }
          updated++;
          fieldsFilled += applied.fields;
          if (applied.keyEventsReplaced) eventsAdded++;
          if (applied.summary.isNotEmpty) {
            summaries.add('${cand.name}：${applied.summary}');
          }
        } on Object catch (e) {
          notes.add(
            _tf('PRF.EntityFailFmt', '{0}（{1}）：归纳失败 {2}', <Object>[
              cand.name,
              kProfileTypeLabels[cand.type] ?? cand.type,
              e,
            ]),
          );
        } finally {
          done++;
          onProgress?.call(
            _tf('PRF.ProgressFmt', '正在归纳档案（{0}/{1}）…', <Object>[
              done,
              targets.length,
            ]),
          );
        }
      },
    );

    final StringBuffer msg = StringBuffer()
      ..write(
        _tf(
          'PRF.ResultFmt',
          '{0} 档案归纳：扫描 {1} 个有设定变化的实体，已更新 {2} 个。',
          <Object>[volLabel, candidates.length, updated],
        ),
      );
    if (fieldsFilled > 0 || eventsAdded > 0) {
      msg.write(
        _tf(
          'PRF.ResultDetailFmt',
          '（补充属性 {0} 项、关键事件 {1} 段）',
          <Object>[fieldsFilled, eventsAdded],
        ),
      );
    }
    if (candidates.length > targets.length) {
      msg.write(
        _tf(
          'PRF.ResultTruncFmt',
          ' 实体较多，本卷优先归纳了流水最多的 {0} 个。',
          <Object>[targets.length],
        ),
      );
    }
    return EntityProfileResult(
      isSuccess: true,
      message: msg.toString(),
      entitiesScanned: candidates.length,
      entitiesUpdated: updated,
      fieldsFilled: fieldsFilled,
      keyEventsAdded: eventsAdded,
      summaries: summaries,
      notes: notes,
    );
  }

  // -------------------------------------------------------------------------
  // 单个实体
  // -------------------------------------------------------------------------

  Future<_Applied?> _profileOne(
    IModelProvider p,
    WritingPromptTemplates prompts,
    _Candidate c, {
    required int volumeNo,
    required String volumeTitle,
    required bool overwriteExisting,
  }) async {
    // 只保留目标表**真实存在**的列 —— 同类实体共用一份规格表，
    // 个别表可能没有某个列（例如某些表没有 `related_settings`）。
    final List<String> spec = <String>[
      for (final String col in kProfileSpec[c.type]!)
        if (c.columns.contains(col)) col,
    ];
    // 人物表的关键事件列单独处理（累积而非填空）。
    final bool hasKeyEvents =
        c.type == 'character' && c.columns.contains(kKeyEventsColumn);
    if (spec.isEmpty && !hasKeyEvents) return null;

    final StringBuffer fieldLines = StringBuffer();
    for (final String col in spec) {
      fieldLines.writeln(
        '- $col（${kProfileFieldLabels[col] ?? col}）：一句话描述，不超过 $maxFieldChars 字',
      );
    }
    if (hasKeyEvents) {
      fieldLines.writeln(
        '- $kKeyEventsColumn（${kProfileFieldLabels[kKeyEventsColumn]}）：字符串数组，'
        '最多 $maxEventsPerVolume 条，每条不超过 $maxEventChars 字，按发生顺序',
      );
    }
    final StringBuffer jsonShape = StringBuffer('{');
    final List<String> jsonKeys = <String>[
      for (final String col in spec) '"$col":""',
      if (hasKeyEvents) '"$kKeyEventsColumn":["事件1","事件2"]',
      '"summary":"一句话小传，不超过 80 字"',
    ];
    jsonShape
      ..write(jsonKeys.join(', '))
      ..write('}');

    String currentOf(String col) {
      final String v = ((c.data[col] as String?) ?? '').trim();
      return v.isEmpty ? '（空）' : v;
    }

    // 现有档案值 —— 既让模型知道「已经有什么」（避免同一字段来回摇摆），
    // 也是「只填空」策略的依据。
    final List<String> currentLines = <String>[
      for (final String col in spec) '${kProfileFieldLabels[col] ?? col}：${currentOf(col)}',
      if (hasKeyEvents) '关键事件：${currentOf(kKeyEventsColumn)}',
    ];

    final ChatResponse resp = await p.chat(
      ChatRequest(
        systemPrompt: prompts.render('Profile/system', const <String, String>{}),
        messages: <ChatMessage>[
          ChatMessage.user(
            prompts.render('Profile/synthesize', <String, String>{
              'typeLabel': kProfileTypeLabels[c.type] ?? c.type,
              'name': c.name,
              'volumeLabel': volumeTitle.isEmpty
                  ? '第$volumeNo卷'
                  : '第$volumeNo卷《$volumeTitle》',
              'history': c.entries.map((String e) => '- $e').join('\n'),
              'current': currentLines.join('\n'),
              'fields': fieldLines.toString().trimRight(),
              'json': jsonShape.toString(),
              'maxChars': '$maxFieldChars',
            }),
          ),
        ],
        temperature: 0.5,
        maxTokens: 1400,
      ),
    );
    if (!resp.isSuccess) return null;
    final Map<String, dynamic>? obj = ProfileSynthesisText.parseJsonObject(
      resp.content,
    );
    if (obj == null) return null;

    // 用来做「有据可依」校验的语料：本卷流水 + 现有档案。
    final String grounded = <String>[
      ...c.entries,
      for (final String col in spec) ((c.data[col] as String?) ?? ''),
    ].join('\n');

    final Map<String, Object> values = <String, Object>{};
    int filled = 0;
    for (final String col in spec) {
      final Object? raw = obj[col];
      if (raw is! String) continue;
      final String v = raw.trim();
      if (v.isEmpty) continue;
      if (v.length > maxFieldChars) continue;
      if (FictionQuality.issue(v) != null) continue;
      if (!ProfileSynthesisText.isGrounded(v, grounded)) continue;
      final String existing = ((c.data[col] as String?) ?? '').trim();
      if (existing.isNotEmpty && !overwriteExisting) continue; // 只填空，不覆盖
      if (existing == v) continue;
      values[col] = v;
      filled++;
    }

    bool keyEventsReplaced = false;
    if (hasKeyEvents) {
      final List<String> items = <String>[];
      final Object? rawList = obj[kKeyEventsColumn];
      if (rawList is List) {
        for (final Object? e in rawList) {
          if (e is! String) continue;
          final String t = e.trim();
          if (t.isEmpty || t.length > maxEventChars) continue;
          if (FictionQuality.issue(t) != null) continue;
          if (!ProfileSynthesisText.isGrounded(t, grounded)) continue;
          items.add(t);
          if (items.length >= maxEventsPerVolume) break;
        }
      }
      if (items.isNotEmpty) {
        final String existing = ((c.data[kKeyEventsColumn] as String?) ?? '');
        final String merged = ProfileSynthesisText.mergeVolumeKeyEvents(existing, volumeNo, items);
        if (merged != existing) {
          values[kKeyEventsColumn] = merged;
          keyEventsReplaced = true;
        }
      }
    }

    if (values.isEmpty) return null;

    await db.customUpdate(
      'UPDATE "${c.table.actualTableName}" '
      'SET ${values.keys.map((String k) => '"$k" = ?').join(', ')}, '
      'updated_at = unixepoch(), version = version + 1 '
      'WHERE id = ?',
      variables: <Variable<Object>>[
        ...values.values.map((Object v) => Variable<String>(v as String)),
        Variable<String>(c.rowId),
      ],
      updates: <TableInfo>{c.table},
    );

    final String summary = (obj['summary'] as String? ?? '').trim();
    return _Applied(
      fields: filled,
      summary: (ProfileSynthesisText.isGrounded(summary, grounded) && summary.length <= 200)
          ? summary
          : '',
      keyEventsReplaced: keyEventsReplaced,
    );
  }

  /// 简单并发池（与 `MultiAgentBookGenerationService._runPool` 同构，
  /// 那边是私有方法，此处不跨类复用）。
  static Future<List<B>> _runPool<A, B>(
    int limit,
    List<A> items,
    Future<B> Function(A item) task,
  ) async {
    if (items.isEmpty) return <B>[];
    final List<B?> results = List<B?>.filled(items.length, null);
    int next = 0;
    Future<void> worker() async {
      while (true) {
        final int i = next++;
        if (i >= items.length) return;
        results[i] = await task(items[i]);
      }
    }

    final int workers = limit.clamp(1, items.length);
    await Future.wait(<Future<void>>[
      for (int w = 0; w < workers; w++) worker(),
    ]);
    return <B>[for (final B? r in results) r as B];
  }
}

/// 单个实体的落库结果。
class _Applied {
  const _Applied({
    required this.fields,
    required this.summary,
    required this.keyEventsReplaced,
  });

  final int fields;
  final String summary;
  final bool keyEventsReplaced;
}
