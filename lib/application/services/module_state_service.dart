import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../../ai/models/chat.dart';
import '../../ai/models/provider.dart';
import '../../ai/utils/entity_update_text.dart';
import '../../ai/utils/fiction_quality.dart';
import '../../data/database.dart';
import 'chapter_sync_service.dart';
import 'writing_prompt_templates.dart';

/// A closed schema, not arbitrary SQL or arbitrary table access.
class ModuleContract {
  const ModuleContract(this.table, {
    this.nameColumn = 'name',
    this.historyColumn = 'notes',
    this.defaults = const {'type': 'AI'},
  });
  final TableInfo table;
  final String nameColumn;
  final String historyColumn;
  final Map<String, Object> defaults;

  Set<String> get columns => table.$columns.map((c) => c.$name).toSet();
  Map<String, String> get fields => {
    if (columns.contains('status')) 'status': 'status',
    if (columns.contains('description')) 'description': 'description',
    if (columns.contains('content')) 'content': 'content',
    if (columns.contains('notes')) 'notes': 'notes',
    'history': historyColumn,
  };
}

class ModuleStateService {
  ModuleStateService({required this.db, required this.provider, this.promptTemplates});
  final WritingPromptTemplates? promptTemplates;
  final AppDatabase db;
  final IModelProvider? Function() provider;

  /// 单段携带的正文字数（见 [extractAndApply] 里的引擎提示词上限说明）。
  ///
  /// 1400 字 + 行式指令（≈1900 字提示词）实测在 3B w8a16 上 prefill 稳定，
  /// 输出 400 tokens 内自然收尾（finish_reason=stop）。
  static const int _chunkChars = 1400;

  /// 相邻分片的步进（留 300 字重叠，避免跨段事实被切断）。
  static const int _chunkStep = 1100;

  /// 12 类分区的契约表。
  ///
  /// 抽成静态是为了让 `EntityProfileSynthesizer`（分卷档案归纳）复用**同一份**
  /// 定义：归纳要扫描的「哪些表、哪个名字列、哪个历史列」必须与抽取落库时的
  /// 完全一致，否则会出现「抽取写进了 A 列、归纳却去 B 列找流水」的静默错位。
  static Map<String, ModuleContract> contractsOf(AppDatabase db) => {
    'character': ModuleContract(db.characters, historyColumn: 'history'),
    'world': ModuleContract(db.worldSettings, historyColumn: 'history'),
    'faction': ModuleContract(db.factions, historyColumn: 'history'),
    'plot': ModuleContract(db.plots, nameColumn: 'title'),
    'race': ModuleContract(db.races),
    'resource': ModuleContract(db.resources),
    'realm': ModuleContract(db.secretRealms),
    'cultivation': ModuleContract(db.cultivationSystems),
    'political': ModuleContract(db.politicalSystems),
    'currency': ModuleContract(db.currencySystems, defaults: {'monetary_system': 'AI'}),
    'relationship': ModuleContract(db.relationshipNetworks, historyColumn: 'development_history'),
    'timeline': ModuleContract(db.timelineEvents, nameColumn: 'title',
      historyColumn: 'description', defaults: {}),
  };

  Map<String, ModuleContract> get contracts => contractsOf(db);

  String get template => jsonEncode({
    'input': {'chapterId': 'source chapter id', 'content': 'final prose',
      'existing': 'module -> exact entity names'},
    'output': {'updates': [
      {'target': 'character', 'action': 'create', 'name': 'exact name from prose',
        'field': 'history', 'content': 'observed change', 'evidence': 'exact quote from prose'}
    ]},
    'modules': {
      for (final e in contracts.entries)
        e.key: {'actions': ['create', 'update'], 'fields': e.value.fields.keys.toList()}
    },
  });

  static Map<String, dynamic>? parse(String raw) {
    // Scan balanced JSON objects without destroying quotes inside story text.
    for (var start = 0; start < raw.length; start++) {
      if (raw[start] != '{') continue;
      var depth = 0;
      var quoted = false;
      var escaped = false;
      for (var i = start; i < raw.length; i++) {
        final ch = raw[i];
        if (escaped) { escaped = false; continue; }
        if (ch == '\\' && quoted) { escaped = true; continue; }
        if (ch == '"') quoted = !quoted;
        if (quoted) continue;
        if (ch == '{') depth++;
        if (ch == '}') depth--;
        if (depth != 0) continue;
        try {
          final value = jsonDecode(raw.substring(start, i + 1));
          if (value is Map<String, dynamic> && value['updates'] is List) return value;
        } on FormatException { /* Try another balanced object. */ }
        break;
      }
    }
    return null;
  }

  /// 统一失败出口：写调试日志，并把原因带回调用方展示。
  String _fail(String reason) {
    debugPrint('[state-extract] 失败：$reason');
    return '$kAiExtractionFailurePrefix$reason';
  }

  Future<String?> extractAndApply(ChapterSyncInput input) async {
    final prompts = promptTemplates ?? WritingPromptTemplates.defaults();
    if (input.projectId.isEmpty) return null;
    final String whole = input.content.trim();
    // ⚠ 前置条件从「必须 status == 'Completed'」放宽为「正文非空且质量合格」。
    //
    // 用户实测（2026-10-09）：3 卷 30 章里有 3 章未通过质量闸、被存成 Draft，
    // 而旧判据让这 3 章**连尝试都没有** —— 它们的正文其实已经写出来了
    // （2395 / 2435 字），里面的设定变化完全应当登记。同时确认：
    // 正文为空（生成彻底失败）或质量不合格（复读/大纲污染）时抽取不可信，
    // 那时才跳过。
    if (whole.isEmpty) {
      return _fail('正文为空');
    }
    final String? quality = FictionQuality.issue(whole);
    if (quality != null) {
      // 如实回报原因：旧实现直接 return null，调用方只能写「AI 抽取失败已跳过」，
      // 看不出是质量闸还是模型/配置问题（用户实测的「设定抽取未完成」看不出所以然）。
      return _fail('正文未通过质量闸（$quality）');
    }
    final p = provider();
    if (p == null) {
      return _fail('未解析到主智能体写作模型（请检查双代理配置）');
    }
    if (!p.isAvailable) {
      return _fail('主智能体写作模型不可用（端点未就绪）');
    }
    final existing = <String, List<String>>{};
    for (final e in contracts.entries) {
      final rows = await db.customSelect(
        'SELECT "${e.value.nameColumn}" FROM "${e.value.table.actualTableName}" '
        'WHERE project_id = ? AND is_deleted = 0',
        variables: [Variable(input.projectId)],
      ).get();
      existing[e.key] = rows.map((r) => r.read<String>(e.value.nameColumn)).toList();
    }
    final items = <Map<String, dynamic>>[];
    // 分段抽取失败**只跳过错块**，不再整章放弃。
    //
    // 旧实现是 `if (valid == null) return null;` —— 只要章内**任意**一个分段
    // 两次都没能把模型输出纠正成合法的 updates JSON（小模型长文下很常见），
    // 整章就一个设定也抽不到。用户观测到的「审核通过后人物/世界观毫无变化」
    // 有相当一部分就来自这里：失败是静默的，看起来像「Agent 没做这件事」。
    int failedChunks = 0;
    int okChunks = 0;
    int rejectedRows = 0;
    String? lastError;
    // Cover the entire chapter, including state transitions at the ending.
    //
    // ⚠ 分片必须短：本机 rwkv_lightning（3B w8a16，8GB）在**单请求提示词超过
    // 约 3000 字**时会在 prefill 阶段直接断开连接（无响应、无错误码）。
    // 1400 字/片 + 行式指令稳定落在引擎能力内。
    for (var start = 0; start < whole.length; start += _chunkStep) {
      final chunk =
          whole.substring(start, (start + _chunkChars).clamp(0, whole.length));

      // ① 首选「行式登记表」。2026-11-17 真机实测（3B w8a16 / 热降频）：
      //    同一段 1100 字按 `updates` JSON 问，模型吐的是
      //    `{"entities":[...]}`（字段名不是 updates）→ parse 返回 null →
      //    三次重试各烧 4 分钟还闭合不了 JSON；而「类别|名称|字段|一句话」
      //    99 秒就稳定给出 4~6 行（含 Markdown 表格外壳，[pipeRowCells] 已兼容）。
      //    所以行式是**主路径**，JSON 只是兼容自定义模板的次选。
      final (List<Map<String, dynamic>>? lines, int rejected) =
          await _extractChunkLines(p, input.title, chunk, whole);
      if (lines != null) {
        // null = 请求/格式失败；[] = 模型按登记表答了但没有可落库条目，
        // 两者必须分开：后者是「成功且零更新」，不能计失败，更不能触发 JSON 重试。
        okChunks++;
        rejectedRows += rejected;
        items.addAll(lines);
        continue;
      }
      // ② 次选：结构化 JSON（给自定义 State/extract 模板或更强的云端模型）。
      final json = await _extractChunkJson(
        p,
        input,
        prompts,
        existing,
        chunk,
        whole,
      );
      if (json == null) {
        failedChunks++;
        lastError = '行式与 JSON 均未产出（分段起点 $start）';
        continue;
      }
      okChunks++;
      items.addAll(json);
    }
    // ⚠ 判据是「**没有任何一个分段成功**」，不能是 `items.isEmpty` ——
    // 模型合法地回答「无」（本章没有新设定）时 items 同样是空的，
    // 那是**成功且零更新**，必须照常回报「更新 0 项」，不能当成抽取失败。
    if (okChunks == 0) {
      return _fail(
        '$failedChunks 个分段均未产出有效条目（章节《${input.title}》）'
        '${lastError == null ? '' : '；最后错误：$lastError'}',
      );
    }
    // 同一实体同字段的多条更新先合并，避免档案被写成一串流水账
    final List<Map<String, dynamic>> merged = _mergeDuplicateItems(items);
    // 逐条校验已在收集阶段完成，这里仍走事务：任一条非法则整批回滚，
    // 绝不留下半成品（与原设计一致）。
    final count = await apply(input, merged);
    debugPrint(
      '[state-extract] 成功：章=《${input.title}》 段=$okChunks/$failedChunks 更新=$count',
    );
    final String suffix = <String>[
      if (failedChunks > 0) '$failedChunks 个分段未产出，其余照常写入',
      if (rejectedRows > 0) '$rejectedRows 条候选未通过防幻觉校验（名称未在正文原样出现）',
    ].join('；');
    return 'AI 设定同步：已核验 ${contracts.length} 类分区，更新 $count 项。'
        '${suffix.isEmpty ? '' : '（$suffix）'}';
  }

  /// 行式登记表抽取（主路径）。
  ///
  /// 返回 `(null, n)` = 这一段没拿到可用结果（请求失败 / 输出是一坨解释），
  /// 需要落到 JSON 次选；返回 `(列表, n)` = 模型按登记表答了（列表可能为空，
  /// 表示「没有可登记的变化」或条目全被防幻觉闸门挡下），**不应**再重试；
  /// `n` 是被闸门挡下的候选条数，用于如实回报。
  /// 行式登记表的类别词表（键 = 模型可能写出的类别词）。
  static const Map<String, String> _targetLabels = <String, String>{
    '人物': 'character',
    '角色': 'character',
    '势力': 'faction',
    '组织': 'faction',
    '门派': 'faction',
    '宗门': 'faction',
    '家族': 'faction',
    '世界观': 'world',
    '设定': 'world',
    '地点': 'world',
    '场景': 'world',
    '地理': 'world',
    '剧情': 'plot',
    '情节': 'plot',
    '事件': 'timeline',
    '时间线': 'timeline',
    '物品': 'resource',
    '道具': 'resource',
    '资源': 'resource',
    '种族': 'race',
    '境界': 'realm',
    '秘境': 'realm',
    '功法': 'cultivation',
    '体系': 'cultivation',
    '政治': 'political',
    '制度': 'political',
    '货币': 'currency',
    '关系': 'relationship',
  };

  /// 行式登记表的字段词表。
  static const Map<String, String> _fieldLabels = <String, String>{
    '状态': 'status',
    '履历': 'history',
    '简介': 'description',
    '备注': 'notes',
    '内容': 'content',
  };

  /// 每个「类别 + 竖线」的起始位置。
  static final RegExp _rowBreaks = RegExp(
    '(?=(?:${_targetLabels.keys.join('|')})\\s*[|｜])',
  );

  /// 把被压平的登记表重新按行切开。
  ///
  /// ⚠ 必需：流式链路对**每个 delta** 调 `AIOutputSanitizer.extractVisibleContent`，
  /// 而它内部会 `trim()`。当模型把换行单独当一个 token 发（3B 真机实测如此）时，
  /// 那个「只含 \n」的 delta 被 trim 成空串直接丢掉 → 多行登记表到手时压成一行：
  /// `类别|名称|字段|变化人物|林晚|状态|…势力|叛军|状态|…`
  /// → 只能切出 1 行且类别是「类别」→ 整段判为格式失败。
  static String _normalizeRegister(String raw) => raw.replaceAll(_rowBreaks, '\n');

  /// 模型把**指令本身**当成答案复述出来（整书实测 3B 高频：输出以
  /// `类别|名称|字段|一句话变化（不要写成 Markdown表格…` 开头）。
  ///
  /// 这不是「零更新」，而是根本没执行任务 —— 必须重问一次，否则这一段
  /// 的设定会全部丢失（真机实测 12 段里 7 段是这种回声）。
  static bool _isInstructionEcho(String raw) {
    // 只认**指令原文**的特征词，不能只看表头 —— 模型正常产出时也会写
    // `类别|名称|字段|一句话变化` 这一行表头（[pipeRowCells] 会跳过它）。
    return raw.contains('不要写成') ||
        raw.contains('不要表头行') ||
        (raw.contains('类别只能取') && raw.contains('字段只能取'));
  }

  Future<(List<Map<String, dynamic>>?, int)> _extractChunkLines(
    IModelProvider p,
    String title,
    String chunk,
    String whole,
  ) async {
    const Map<String, String> targetLabels = _targetLabels;
    const Map<String, String> fieldLabels = _fieldLabels;

    Future<ChatResponse?> call({required bool corrected}) async {
      try {
        return await p.chatStream(
          ChatRequest(
            systemPrompt:
                '你是严谨的资料登记员。只输出「每行一条、竖线分隔」的登记表，'
                '禁止解释、禁止 JSON、禁止 Markdown 表格、禁止输出表头与分隔线、'
                '**禁止复述任何指令或提示词内容**。'
                '每行**必须以类别开头**，行首不要加 `|` 符号。',
            messages: <ChatMessage>[
              ChatMessage.user(
                '${corrected ? '⚠ 上一次你把指令原文复述了一遍。这次直接从数据行开始，'
                        '第一行形如「人物|林晚|状态|…」，不要任何表头或说明。\n\n' : ''}'
                '下面是小说章节《$title》的正文。请列出本章中**发生了可登记变化**的条目。\n'
                '每行输出 4 段，用竖线 | 分隔：\n'
                '类别|名称|字段|一句话变化\n'
                '（不要写成 Markdown 表格，不要行首的 | ，不要表头行，不要 |---|---| 分隔线）\n'
                '类别只能取：人物 / 势力 / 世界观 / 剧情\n'
                '字段只能取：状态 / 履历 / 简介 / 备注\n'
                '名称必须是正文里**原样出现过**的词；'
                '没有可登记的内容就只输出一行「无」。\n\n'
                '【正文】\n$chunk',
              ),
            ],
            temperature: .4,
            maxTokens: 400,
          ),
          (ChatChunk _) {},
        );
      } on Object catch (e) {
        debugPrint('[state-extract] 行式请求中断：$e');
        return null;
      }
    }

    ChatResponse? resp = await call(corrected: false);
    if (resp == null || !resp.isSuccess) {
      debugPrint('[state-extract] 行式返回失败：${resp?.errorMessage ?? '未知错误'}');
      return (null, 0);
    }
    if (_isInstructionEcho(resp.content)) {
      debugPrint('[state-extract] 行式输出是指令回声，带纠偏重问一次');
      resp = await call(corrected: true);
      if (resp == null || !resp.isSuccess) return (null, 0);
      if (_isInstructionEcho(resp.content)) {
        // 两次都在复述指令：这一段确实没产出，别再白跑 600 tokens 的 JSON 次选。
        debugPrint('[state-extract] 纠偏后仍是指令回声，跳过该段');
        return (const <Map<String, dynamic>>[], 0);
      }
    }
    final ChatResponse ok = resp;
    final (List<Map<String, dynamic>> rows, int rejected) =
        _parseLooseLines(ok.content, whole, targetLabels, fieldLabels);
    // 「模型按格式答了，只是条目被闸门挡下」不能当格式失败 —— 3B 的 JSON 次选
    // 必失败（它从来不吐 `{"updates":[...]}`），重试纯属白烧 2×600 tokens
    // （真机实测单段多花 5~6 分钟，整章直接跑成 25 分钟超时）。
    if (rows.isEmpty &&
        !_answeredNone(ok.content) &&
        !_looksLikeRegister(ok.content)) {
      debugPrint(
        '[state-extract] 行式未产出，原文开头：'
        '${ok.content.length > 120 ? ok.content.substring(0, 120) : ok.content}',
      );
      return (null, rejected);
    }
    return (rows, rejected);
  }

  /// 输出里是否已经有「类别|名称|字段|内容」形状的行（表格外壳不算）。
  ///
  /// 只按**形状**判断，不按类别白名单：3B 常写出「场景」「物品」这类词表外的
  /// 类别，若要求认得出类别就会把它误判成格式失败，再白跑 2×600 tokens 的
  /// JSON 次选（真机实测单段 +5 分钟）。词表外的类别会在 [validate] 里被拒。
  static bool _looksLikeRegister(String raw) => _normalizeRegister(raw)
      .split(RegExp(r'\r?\n'))
      .map(pipeRowCells)
      .whereType<List<String>>()
      .any((List<String> c) {
        final String head = c.length < 4 ? '' : c[0].trim();
        return c.length >= 4 &&
            head.isNotEmpty &&
            head.length <= 6 &&
            head != '类别' &&
            head != '名称' &&
            c[1].trim().isNotEmpty;
      });

  /// 模型是否明确表示「本章没有可登记的内容」。
  ///
  /// 小模型很少规规矩矩只回一个「无」，更多是「本章没有可登记的变化。」
  /// 这类一句话否定 —— 只认「无」的话会把它当格式失败，再白跑一遍 600 tokens
  /// 的 JSON 次选（真机实测多花 2~3 分钟）。所以：短句 + 含「无」+ 含
  /// 登记/变化/更新 之一，即视为「零更新」。
  static bool _answeredNone(String raw) {
    final List<String> lines = raw
        .split(RegExp(r'\r?\n'))
        .map((String l) => l.trim())
        .where((String l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty || lines.length > 3) return false;
    final String joined =
        lines.join().replaceAll(RegExp(r'[。．.！!、|`\s]'), '');
    if (joined == '无') return true;
    return joined.length <= 24 &&
        joined.contains('无') &&
        (joined.contains('登记') ||
            joined.contains('变化') ||
            joined.contains('更新'));
  }

  /// 结构化 JSON 抽取（次选）。
  ///
  /// 保留给自定义 `State/extract` 模板或更强的云端模型：小模型产出
  /// `{"entities":[...]}` 而不是 `{"updates":[...]}` 时这里会失败，
  /// 但失败只影响这一段，不再拖垮整章。
  Future<List<Map<String, dynamic>>?> _extractChunkJson(
    IModelProvider p,
    ChapterSyncInput input,
    WritingPromptTemplates prompts,
    Map<String, List<String>> existing,
    String chunk,
    String whole,
  ) async {
    String? error;
    for (var attempt = 0; attempt < 2; attempt++) {
      ChatResponse response;
      try {
        response = await p.chatStream(
          ChatRequest(
            systemPrompt: prompts.render('State/system', {}),
            messages: [
              ChatMessage.user(prompts.render('State/extract', {
                'schema': template,
                'existing': jsonEncode(existing),
                'title': input.title,
                'chunk': chunk,
                'correction': error == null
                    ? ''
                    : '上次格式失败：$error。请重新按 updates JSON 模板输出，不要解释。',
              })),
            ],
            temperature: .88,
            maxTokens: 600,
          ),
          (ChatChunk _) {},
        );
      } on Object catch (e) {
        error = '请求中断：$e';
        debugPrint('[state-extract] JSON 请求中断：$e');
        continue;
      }
      if (!response.isSuccess) {
        error = '模型返回失败：${response.errorMessage ?? '未知错误'}';
        continue;
      }
      final parsed = parse(response.content);
      if (parsed == null) {
        error = 'missing updates array';
        continue;
      }
      final raw = parsed['updates'] as List;
      if (raw.length > 30) {
        error = 'at most 30 updates per part';
        continue;
      }
      final valid = <Map<String, dynamic>>[];
      var broken = false;
      for (final item in raw) {
        if (item is! Map<String, dynamic>) {
          error = 'invalid target/field/name/evidence';
          broken = true;
          break;
        }
        // 先收敛长度与 evidence 形态再校验 —— 见 [_normalizeItem]。
        _normalizeItem(item);
        if (validate(item, whole) != null) {
          error = 'invalid target/field/name/evidence';
          broken = true;
          break;
        }
        valid.add(item);
      }
      if (!broken) return valid;
    }
    debugPrint('[state-extract] JSON 次选失败：$error');
    return null;
  }

  /// 解析行式登记表 → `updates` 条目（仍然过 [validate] 防幻觉）。
  ///
  /// 返回（条目, 被闸门挡下的候选条数）：后者用于如实告诉用户「模型给了 N 条
  /// 但名称在正文里找不到」，而不是静默吞掉。
  (List<Map<String, dynamic>>, int) _parseLooseLines(
    String raw,
    String whole,
    Map<String, String> targetLabels,
    Map<String, String> fieldLabels,
  ) {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    var rejected = 0;
    for (final String lineRaw in _normalizeRegister(raw).split(RegExp(r'\r?\n'))) {
      // ⚠ 用 [pipeRowCells] 而不是裸 `split('|')`：7B 几乎总会加 Markdown 表格
      // 外壳，行首那个 `|` 会切出空段 → `类别 = ''` → 整行被丢弃 → 兜底等于没跑。
      final List<String>? cells = pipeRowCells(lineRaw);
      if (cells == null || cells.length < 4) continue;
      final String? target = targetLabels[cells[0].trim()];
      String name = cells[1].trim();
      if (target == null || name.isEmpty) continue;
      // 名称必须原样出现在正文里 —— 这条是防幻觉的关键闸门。
      // 「皇帝（秦昭元）」这类合成写法在本机 3B 上很常见：括号里/括号外总有一半
      // 是真名，取括号前的本体再验一次，避免整条真设定被丢掉。
      if (!whole.contains(name)) {
        name = name.replaceAll(RegExp(r'[（(][^）)]*[）)]'), '').trim();
      }
      if (name.isEmpty || name.length > 100 || !whole.contains(name)) {
        rejected++;
        continue;
      }
      String value = cells.sublist(3).join('|').trim();
      if (value.isEmpty) continue;
      final ModuleContract contract = contracts[target]!;
      final String rawField = fieldLabels[cells[2].trim()] ?? 'history';
      final String field = contract.fields.containsKey(rawField)
          ? rawField
          : (contract.fields.containsKey('history') ? 'history' : 'notes');
      // status 列有 50 字上限（见 [validate]）。
      if (field == 'status' && value.length > 50) {
        value = value.substring(0, 50);
      }
      if (value.length > 1000) value = value.substring(0, 1000);
      // evidence：取名称在正文中的一段真实窗口（既是证据也满足 validate 的
      // 「evidence 含 name 且是正文子串」）。
      final int at = whole.indexOf(name);
      final String evidence = whole.substring(
        at,
        (at + 24).clamp(0, whole.length),
      );
      final Map<String, dynamic> item = <String, dynamic>{
        // 用 create：实体已存在时 [apply] 会走更新分支，不存在时新建，
        // 语义与「登记」一致。
        'target': target,
        'action': 'create',
        'name': name,
        'field': field,
        'content': value,
        'evidence': evidence,
      };
      if (validate(item, whole) != null) {
        rejected++;
        continue;
      }
      out.add(item);
      if (out.length >= 60) break;
    }
    return (out, rejected);
  }

  /// 合并「同 target + 同 name + 同 field」的多条更新。
  ///
  /// `status` 不合并（列宽上限 50，拼接必然超限，且状态取**最后一次**才有意义）；
  /// 其余文本字段用「；」连接后截到 1000 字。
  static List<Map<String, dynamic>> _mergeDuplicateItems(
    List<Map<String, dynamic>> items,
  ) {
    final Map<String, Map<String, dynamic>> byKey =
        <String, Map<String, dynamic>>{};
    final List<String> order = <String>[];
    for (final Map<String, dynamic> it in items) {
      final String name = (it['name'] as String).trim();
      final String field = (it['field'] as String).trim();
      final String key =
          '${it['target']}|${name.toLowerCase()}|$field';
      final Map<String, dynamic>? existing = byKey[key];
      if (existing == null) {
        byKey[key] = Map<String, dynamic>.of(it);
        order.add(key);
        continue;
      }
      if (field == 'status') {
        existing['content'] = it['content'];
        existing['evidence'] = it['evidence'];
        continue;
      }
      final String joined =
          '${existing['content']}；${it['content']}';
      existing['content'] =
          joined.length > 1000 ? joined.substring(0, 1000) : joined;
      if ((existing['evidence'] as String).length <
          (it['evidence'] as String).length) {
        existing['evidence'] = it['evidence'];
      }
    }
    return <Map<String, dynamic>>[for (final String k in order) byKey[k]!];
  }

  String? validate(Map<String, dynamic> item, String source) {
    final contract = contracts[item['target']];
    if (contract == null || !contract.fields.containsKey(item['field'])) return 'field';
    if (!['create', 'update'].contains(item['action'])) return 'action';
    for (final key in ['name', 'content', 'evidence']) {
      if (item[key] is! String || (item[key] as String).trim().isEmpty) return key;
    }
    final name = (item['name'] as String).trim();
    final evidence = stripEvidencePrefix(item['evidence'] as String);
    // ⚠ evidence 判据从 `source.contains(evidence)`（必须是**连续子串**）放宽为
    // 「分段有据」（见 [evidenceSharesText]）。7B 实测会把 evidence 写成拼接引用
    // 并带 `正文：` 前缀 → 旧判据条条必败 → 整章 0 条设定。
    // 防幻觉的真正闸门是 `source.contains(name)`：**实体名必须原样出现在正文**。
    if (name.length > 100 || !source.contains(name) || evidence.length < 4 ||
        !evidenceSharesText(evidence, source)) {
      return 'evidence';
    }
    if ((item['content'] as String).length > (item['field'] == 'status' ? 50 : 1000)) return 'length';
    if (FictionQuality.issue(item['content'] as String) != null) return 'content';
    return null;
  }

  /// 收敛模型给的 `content` / `evidence` —— 在 [validate] **之前**调用。
  ///
  /// * `content` 超列宽时**截断**而不是判非法：`status` 列宽 50，而 7B 对状态
  ///   几乎必给一整句话 —— 旧实现「超长即拒绝」意味着 status 更新**永远**
  ///   落不下来；状态本来就是「取最后一次」的短标记，截断更贴近预期。
  /// * `evidence` 脱掉 `正文：` 这类字段名前缀，再交给 [evidenceSharesText]。
  static void _normalizeItem(Map<String, dynamic> item) {
    final String field = (item['field'] ?? '').toString().trim();
    final Object? rawContent = item['content'];
    if (rawContent is String) {
      final int max = field == 'status' ? 50 : 1000;
      final String v = rawContent.trim();
      item['content'] = v.length > max ? v.substring(0, max) : v;
    }
    final Object? rawEvidence = item['evidence'];
    if (rawEvidence is String) {
      item['evidence'] = stripEvidencePrefix(rawEvidence);
    }
  }

  Future<int> apply(ChapterSyncInput input, List<Map<String, dynamic>> items) =>
      db.transaction(() async {
        var count = 0;
        for (final item in items) {
          final problem = validate(item, input.content);
          if (problem != null) throw FormatException('Invalid module update: $problem');
          final c = contracts[item['target']]!;
          final table = c.table.actualTableName;
          final name = (item['name'] as String).trim();
          final rows = await db.customSelect(
            'SELECT * FROM "$table" WHERE project_id = ? AND "${c.nameColumn}" = ? AND is_deleted = 0',
            variables: [Variable(input.projectId), Variable(name)],
          ).get();
          if (rows.length > 1) throw StateError('Ambiguous entity: $name');
          final field = c.fields[item['field']]!;
          final value = (item['content'] as String).trim();
          final entry = '[${input.chapterId}:${input.versionNumber} ${input.title}] $value';
          if (rows.isEmpty) {
            if (item['action'] != 'create') throw StateError('Missing entity: $name');
            final values = <String, Object>{
              'id': const Uuid().v4(), 'project_id': input.projectId,
              c.nameColumn: name, ...c.defaults,
              if (item['target'] == 'timeline') 'event_date': (input.eventDate ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000,
              field: value,
              c.historyColumn: entry,
            };
            await db.customInsert(
              'INSERT INTO "$table" (${values.keys.map((k) => '"$k"').join(',')}) '
              'VALUES (${List.filled(values.length, '?').join(',')})',
              variables: values.values.map((v) => Variable(v)).toList(),
              updates: {c.table},
            );
          } else {
            final row = rows.single;
            final history = (row.data[c.historyColumn] as String?) ?? '';
            if (history.split('\n').contains(entry)) continue;
            final values = <String, Object>{
              field: (item['field'] == 'history' || item['field'] == 'notes')
                  ? '${row.data[field] ?? ''}\n$entry'.trim() : value,
              c.historyColumn: '$history\n$entry'.trim(),
            };
            await db.customUpdate(
              'UPDATE "$table" SET ${values.keys.map((k) => '"$k" = ?').join(',')}, '
              'updated_at = unixepoch(), version = version + 1 WHERE id = ? AND project_id = ?',
              variables: [
                ...values.values.map((v) => Variable(v)),
                Variable(row.read<String>('id')), Variable(input.projectId),
              ],
              updates: {c.table},
            );
          }
          count++;
        }
        return count;
      });
}
