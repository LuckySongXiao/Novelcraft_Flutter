// 前置条件生成 —— 对应 C# `WPF/Services/PrerequisiteGenerationService.cs`。
//
// 职责：新建项目后补齐「可开始写作」的最小数据底座：修炼体系 / 剧情大纲 / 主要角色 /
// 世界设定 / 势力。**只补缺**（达到阈值即跳过），因此可反复调用而不产生重复数据。
//
// 与 C# 的差异（都是有意为之，见各处注释）：
// 1. **不移植 `GenerateWithAIAsync`**：C# 那个方法把几百行结构化 prompt 塞进
//    `parameters["prompt"]`，而下游 `DirectorAgent.GeneratePlot` **根本不读该键**
//    （只做剧情抽取），最终落库的还是模板数据 —— 白烧一次推理。等价语义 = 模板路径。
// 2. **角色模板显式写 `importance = 9`**：C# 模板没设 Importance（实体默认 1），
//    导致"主要角色 Importance>=8 至少 3 个"这条门槛生成后**永远不满足** →
//    反复调用会重复插角色。这是必须修的 C# bug。
// 3. **不引入 `QuantityConfig` / `GetDefault*Templates`**：C# 里全库零调用（死代码）。
// 4. **不调用 `CultivationLevelBackfillService`**：本服务的顺序是「体系 → 角色」，
//    角色创建时已直接写入修为，回填必为 no-op。
//
// 注：模板数据本身（角色名/设定正文等）属于**内容/prompt**，按 C# 原样保留，不参与 UI 本地化。
library;

import 'package:drift/drift.dart' show Value;
import 'package:uuid/uuid.dart';

import '../../ai/prompts/prompt_template.dart';
import '../../ai/providers/rwkv_provider.dart';
import '../../ai/utils/ai_text_fields.dart';
import '../../ai/utils/localized_text.dart';
import '../../data/database.dart';
import '../../data/repositories/character_repository.dart';
import '../../data/repositories/cultivation_level_repository.dart';
import '../../data/repositories/cultivation_system_repository.dart';
import '../../data/repositories/faction_repository.dart';
import '../../data/repositories/plot_repository.dart';
import '../../data/repositories/world_setting_repository.dart';

const Uuid _uuid = Uuid();

/// 生成选项 —— 对应 C# `PrerequisiteGenerationOptions`。
///
/// 只保留模板路径真正生效的 5 个开关；C# 的
/// `UseAIGeneration / AIPrompt / AllowUserEditing / NovelGenre / WorldStyle`
/// 在模板路径下**不生效**，故不提供（避免"看起来能开其实不生效"的假开关）。
class PrerequisiteGenerationOptions {
  const PrerequisiteGenerationOptions({
    this.generatePlotOutlines = true,
    this.generateMainCharacters = true,
    this.generateWorldSettings = true,
    this.generateFactions = true,
    this.generateCultivationSystem = true,
  });

  final bool generatePlotOutlines;
  final bool generateMainCharacters;
  final bool generateWorldSettings;
  final bool generateFactions;
  final bool generateCultivationSystem;
}

/// 生成结果 —— 对应 C# `PrerequisiteGenerationResult`。
class PrerequisiteGenerationResult {
  PrerequisiteGenerationResult(this.projectId);

  final String projectId;

  bool isSuccess = false;
  String message = '';

  /// 已生成条目的展示行（如 `主要角色：林轩（主角）`）。
  final List<String> generatedItems = <String>[];

  /// 实际产出过的分区（`cultivation` / `plots` / `characters` / `world` / `factions`）。
  final Set<String> generatedSections = <String>{};

  int existingPlotsCount = 0;
  int existingMainCharactersCount = 0;
  int existingWorldSettingsCount = 0;
  int existingFactionsCount = 0;
  int existingCultivationSystemsCount = 0;

  int generatedPlotsCount = 0;
  int generatedCharactersCount = 0;
  int generatedWorldSettingsCount = 0;
  int generatedFactionsCount = 0;
  int generatedCultivationSystemsCount = 0;

  bool needsPlotOutlines = false;
  bool needsMainCharacters = false;
  bool needsWorldSettings = false;
  bool needsFactions = false;
  bool needsCultivationSystem = false;

  /// 是否五项都已满足阈值（无需生成）。
  bool get allReady =>
      !needsPlotOutlines &&
      !needsMainCharacters &&
      !needsWorldSettings &&
      !needsFactions &&
      !needsCultivationSystem;

  /// 本次实际生成的条目总数。
  int get totalGeneratedCount =>
      generatedPlotsCount +
      generatedCharactersCount +
      generatedWorldSettingsCount +
      generatedFactionsCount +
      generatedCultivationSystemsCount;
}

/// 前置条件生成服务。
class PrerequisiteGenerationService {
  PrerequisiteGenerationService({
    required PlotRepository plots,
    required CharacterRepository characters,
    required WorldSettingRepository worldSettings,
    required FactionRepository factions,
    required CultivationSystemRepository cultivationSystems,
    required CultivationLevelRepository cultivationLevels,
    required RwkvProvider Function() rwkv,
    required PromptTemplateRegistry Function() templates,
    required AiTextSource texts,
  })  : _plots = plots,
        _characters = characters,
        _worldSettings = worldSettings,
        _factions = factions,
        _cultivationSystems = cultivationSystems,
        _cultivationLevels = cultivationLevels,
        _rwkv = rwkv,
        _templates = templates,
        _texts = texts;

  /// 阈值（对应 C# `CheckExistingDataAsync`）。
  static const int minPlots = 3;
  static const int minMainCharacters = 3;
  static const int minWorldSettings = 5;
  static const int minFactions = 3;

  /// 主要角色判定阈值（`importance >= 8`）。
  static const int mainCharacterImportance = 8;

  /// 世界设定判定阈值（`importance >= 7`）。
  static const int importantWorldSetting = 7;

  final PlotRepository _plots;
  final CharacterRepository _characters;
  final WorldSettingRepository _worldSettings;
  final FactionRepository _factions;
  final CultivationSystemRepository _cultivationSystems;
  final CultivationLevelRepository _cultivationLevels;
  final RwkvProvider Function() _rwkv;
  final PromptTemplateRegistry Function() _templates;
  final AiTextSource _texts;

  bool get _en => _texts.isEnglish;

  /// 对应 C# `GeneratePrerequisitesAsync`。
  Future<PrerequisiteGenerationResult> generatePrerequisites(
    String projectId, {
    PrerequisiteGenerationOptions? options,
  }) async {
    final PrerequisiteGenerationOptions opts =
        options ?? const PrerequisiteGenerationOptions();
    final PrerequisiteGenerationResult result =
        PrerequisiteGenerationResult(projectId);

    await _checkExistingData(projectId, result);

    // 顺序固定：修炼体系最先生成，供角色修为等级联动（C# 同）
    if (opts.generateCultivationSystem && result.needsCultivationSystem) {
      await ensureCultivationSystem(projectId, result);
    }
    if (opts.generatePlotOutlines && result.needsPlotOutlines) {
      await _generatePlotOutlines(projectId, result);
    }
    if (opts.generateMainCharacters && result.needsMainCharacters) {
      await _generateMainCharacters(projectId, result);
    }
    if (opts.generateWorldSettings && result.needsWorldSettings) {
      await _generateWorldSettings(projectId, result);
    }
    if (opts.generateFactions && result.needsFactions) {
      await _generateFactions(projectId, result);
    }

    // 与 C# 的差异：C# 只要不抛异常就 IsSuccess=true。这里要求至少有一项真正产出，
    // 或五项本就齐备，否则如实报"无需生成"（避免上层把"啥也没干"当成功）。
    result.isSuccess = result.totalGeneratedCount > 0 || result.allReady;
    result.message = result.totalGeneratedCount > 0
        ? _texts.t('PG.Done', '生成完成')
        : _texts.t('PG.NoNeedTitle', '无需生成');
    return result;
  }

  /// 检查现有数据（对应 C# `CheckExistingDataAsync`）。
  Future<void> _checkExistingData(
    String projectId,
    PrerequisiteGenerationResult result,
  ) async {
    final List<PlotRow> plots = await _plots.getByProjectId(projectId);
    result.existingPlotsCount = plots.length;
    result.needsPlotOutlines = plots.length < minPlots;

    final List<CharacterRow> characters =
        await _characters.getByProjectId(projectId);
    final int mainCharacters = characters
        .where((CharacterRow c) => c.importance >= mainCharacterImportance)
        .length;
    result.existingMainCharactersCount = mainCharacters;
    result.needsMainCharacters = mainCharacters < minMainCharacters;

    final List<WorldSettingRow> settings =
        await _worldSettings.getByImportance(projectId, importantWorldSetting);
    result.existingWorldSettingsCount = settings.length;
    result.needsWorldSettings = settings.length < minWorldSettings;

    final List<FactionRow> factions = await _factions.getByProjectId(projectId);
    result.existingFactionsCount = factions.length;
    result.needsFactions = factions.length < minFactions;

    final List<CultivationSystemRow> systems =
        await _cultivationSystems.getByProjectId(projectId);
    result.existingCultivationSystemsCount = systems.length;
    result.needsCultivationSystem = systems.isEmpty;
  }

  /// 对应 C# `EnsureCultivationSystemAsync`。
  ///
  /// 唯一「真 AI」路径：直连 RWKV 生成自定义体系；AI 不可用或解析失败 →
  /// 回退通用九阶模板。
  Future<void> ensureCultivationSystem(
    String projectId,
    PrerequisiteGenerationResult result,
  ) async {
    try {
      final List<CultivationSystemRow> existing =
          await _cultivationSystems.getByProjectId(projectId);
      if (existing.isNotEmpty) {
        result.needsCultivationSystem = false;
        return;
      }

      final RwkvProvider rwkv = _rwkv();
      if (rwkv.isAvailable) {
        final String? raw = await rwkv.completeRawPrompt(
          _buildCultivationPrompt(),
          maxTokens: 2048,
          temperature: 0.9,
          topP: 0.85,
        );
        if (raw != null && raw.trim().isNotEmpty) {
          // 解析必须在**未清洗的原始输出**上做：清洗会剥掉行首「N.」编号，
          // 而等级块切分依赖编号行。
          final ParsedCultivationSection parsed =
              AiTextFields.parseCultivationSection(raw, isEnglish: _en);
          if (parsed.isValid) {
            await _createCultivationSystem(
              projectId: projectId,
              name: parsed.name,
              type: parsed.type,
              description: null,
              method: parsed.method,
              levels: parsed.levels,
            );
            result.generatedCultivationSystemsCount++;
            result.generatedSections.add('cultivation');
            result.generatedItems.add(_texts.tf(
              'PG.Item.CultivationSystem',
              '修炼体系：{0}（{1} 级）',
              <Object>[parsed.name, parsed.levels.length],
            ));
            result.needsCultivationSystem = false;
            return;
          }
        }
      }

      // AI 不可用 / 解析失败 → 通用九阶模板
      await _createGenericCultivationSystem(projectId, result);
    } on Object {
      // 体系生成失败不阻断整体流程；置 false 表示"已尝试过"
      result.needsCultivationSystem = false;
    }
  }

  /// 取项目第一个修炼体系的等级名（由低到高）—— 对应 C# `GetProjectCultivationLevelNamesAsync`。
  Future<List<String>> getProjectCultivationLevelNames(String projectId) async {
    final List<CultivationSystemRow> systems =
        await _cultivationSystems.getByProjectId(projectId);
    if (systems.isEmpty) return const <String>[];
    final List<CultivationLevelRow> levels =
        await _cultivationLevels.getBySystemId(systems.first.id);
    levels.sort((CultivationLevelRow a, CultivationLevelRow b) =>
        a.orderIndex.compareTo(b.orderIndex));
    return levels.map((CultivationLevelRow l) => l.name).toList();
  }

  // ------------------------------------------------------------ 修炼体系生成

  /// 硬拼原始 prompt —— 对应 C#
  /// `"User: " + system + "\n" + user + "\n\nAssistant:  thinking</think\n"`。
  String _buildCultivationPrompt() {
    final PromptTemplateRegistry reg = _templates();
    final String systemPrompt = reg.get('Prerequisite/Cultivation.System',
            isEnglish: _en) ??
        (_en
            ? 'You are a senior fiction worldbuilding architect. Design original power/progression systems top-down and output plain text strictly in the required structure.'
            : '你是资深网文世界观架构师，擅长自上而下原创设计力量/修炼等级体系，严格按要求的纯文本结构输出。');
    final String userPrompt =
        reg.get('Prerequisite/Cultivation.User', isEnglish: _en) ??
            (_en ? _cultivationUserPromptEn : _cultivationUserPromptZh);
    return 'User: $systemPrompt\n$userPrompt\n\nAssistant:  thinking</think\n';
  }

  static const String _cultivationUserPromptEn =
      '''Design a cultivation / power progression system for this novel project. Requirements:
1. Define the system name, type and core cultivation method first (must fit the project genre and worldview; names are fully custom).
2. Then define 8-12 ranks from lowest to highest; each rank needs a description, a breakthrough condition and ability features. The advancement logic must be progressive and self-consistent.
3. Do NOT copy common templates such as Qi Refining / Foundation Building / Golden Core.

Output ONLY the plain-text structure below. No markdown code blocks, no explanations, no preamble. Write every value in ENGLISH and keep the field labels EXACTLY as shown:

【Cultivation System】
System Name:
System Type:
Cultivation Method:
1.
Rank Name:
Description:
Breakthrough Condition:
Ability Features:

2.
Rank Name:
Description:
Breakthrough Condition:
Ability Features:

(list all ranks from lowest to highest)''';

  static const String _cultivationUserPromptZh = '''请为书籍项目设计一套修炼/力量等级体系，要求自上而下原创设计：
1. 先确定体系名称、类型与核心修炼方法（须贴合项目题材与世界观，命名可完全自定义）
2. 再从低到高划分 8-12 个等级，每级给出描述、突破条件、能力特点，进阶逻辑要递进自洽
3. 除传统修仙题材外，禁止照搬「练气/筑基/金丹/元婴」等常见模板

请严格按以下纯文本结构输出，不要输出 Markdown 代码块、解释或前言：
【修炼体系】
体系名称：
体系类型：
修炼方法：
1.
等级名：
描述：
突破条件：
能力特点：

2.
等级名：
描述：
突破条件：
能力特点：

（按从低到高顺序列出全部等级）''';

  /// 回退：通用九阶模板（中性命名，不预设修仙体系）。
  Future<void> _createGenericCultivationSystem(
    String projectId,
    PrerequisiteGenerationResult result,
  ) async {
    final List<String> genericLevels;
    final String genericName;
    final String genericType;
    final String genericDesc;
    final String genericMethod;
    if (_en) {
      genericLevels = const <String>[
        'First Steps',
        'Steady Hands',
        'Practiced',
        'Integration',
        'Mastery',
        'Refinement',
        'Pinnacle',
        'Simplicity Returned',
        'Beyond Mortal',
      ];
      genericName = 'General Progression System';
      genericType = 'General';
      genericDesc =
          'A path of progress forged by craft and state of mind; every rank is a leap from quantitative to qualitative change.';
      genericMethod =
          "Refine one's inner source through insight and discipline; each advancement transforms both mind and body.";
    } else {
      genericLevels = const <String>[
        '初窥门径',
        '登堂入室',
        '驾轻就熟',
        '融会贯通',
        '炉火纯青',
        '出神入化',
        '登峰造极',
        '返璞归真',
        '超凡入圣',
      ];
      genericName = '通用进阶体系';
      genericType = '通用';
      genericDesc = '以技艺与心境共同打磨的进阶之路，每一阶都是从量变到质变的跃迁。';
      genericMethod = '以自身领悟淬炼本源之力，境界提升伴随神魂与体魄的双重蜕变。';
    }

    final List<ParsedCultivationLevel> levels = <ParsedCultivationLevel>[
      for (final String n in genericLevels)
        ParsedCultivationLevel(
          name: n,
          breakthrough: _en
              ? 'The key to advancing to $n is solidifying the foundation of the previous rank and completing a transformation of one\'s inner source.'
              : '进阶至$n的关键在于打牢前一级根基，完成一次本源蜕变。',
        ),
    ];

    await _createCultivationSystem(
      projectId: projectId,
      name: genericName,
      type: genericType,
      description: genericDesc,
      method: genericMethod,
      levels: levels,
    );
    result.generatedCultivationSystemsCount++;
    result.generatedSections.add('cultivation');
    result.generatedItems.add(_texts.tf(
      'PG.Item.CultivationSystemFallback',
      '修炼体系：{0}（默认模板，可在修炼体系管理中调整）',
      <Object>[genericName],
    ));
    result.needsCultivationSystem = false;
  }

  /// 对应 C# `CreateCultivationSystemAsync`。
  Future<CultivationSystemRow> _createCultivationSystem({
    required String projectId,
    required String name,
    required String type,
    required String? description,
    required String? method,
    required List<ParsedCultivationLevel> levels,
  }) async {
    final List<ParsedCultivationLevel> levelList = levels
        .where((ParsedCultivationLevel l) => l.name.trim().isNotEmpty)
        .toList(growable: false);

    final CultivationSystemRow created =
        await _cultivationSystems.create(CultivationSystemsCompanion.insert(
      id: _uuid.v4(),
      name: AiTextFields.limitLength(name, 100),
      type: AiTextFields.limitLength(type, 50),
      projectId: projectId,
      description: Value(AiTextFields.nullIfEmpty(description)),
      cultivationMethod: Value(AiTextFields.nullIfEmpty(method)),
      realmDivision:
          Value(levelList.map((ParsedCultivationLevel l) => l.name).join('→')),
      importance: const Value(9),
    ));

    int order = 1;
    for (final ParsedCultivationLevel l in levelList) {
      await _cultivationLevels.create(CultivationLevelsCompanion.insert(
        id: _uuid.v4(),
        name: AiTextFields.limitLength(l.name, 100),
        cultivationSystemId: created.id,
        orderIndex: Value(order),
        description: Value(AiTextFields.nullIfEmpty(l.description)),
        breakthroughCondition: Value(AiTextFields.nullIfEmpty(l.breakthrough)),
        abilities: Value(AiTextFields.nullIfEmpty(l.abilities)),
      ));
      order++;
    }
    return created;
  }

  // ------------------------------------------------------------ 四项模板数据

  /// 对应 C# `GeneratePlotOutlinesAsync`（3 条固定剧情大纲）。
  Future<void> _generatePlotOutlines(
    String projectId,
    PrerequisiteGenerationResult result,
  ) async {
    final List<_PlotTemplate> templates = _en
        ? const <_PlotTemplate>[
            _PlotTemplate(
              title: 'Main plot: the road of growth',
              type: '主线',
              description:
                  'The protagonist starts from obscurity and grows into someone formidable through effort, opportunity, and hard choices',
            ),
            _PlotTemplate(
              title: 'Emotional line: bonds that matter',
              type: '情感线',
              description:
                  "The protagonist's evolving relationships — friendship, love, mentorship, and rivalry",
            ),
            _PlotTemplate(
              title: 'Subplot: a web of powers',
              type: '支线',
              description:
                  'Shifting alliances and conflicting interests between factions reveal a diverse world',
            ),
          ]
        : const <_PlotTemplate>[
            _PlotTemplate(
              title: '主线剧情：成长之路',
              type: '主线',
              description: '主角从平凡开始，通过不断努力和机遇，逐步成长为强者的主线故事',
            ),
            _PlotTemplate(
              title: '情感线：人际关系',
              type: '情感线',
              description: '主角与重要人物之间的情感发展，包括友情、爱情、师徒情等',
            ),
            _PlotTemplate(
              title: '支线剧情：势力纷争',
              type: '支线',
              description: '各方势力之间的复杂关系和利益纠葛，展现世界的多元化',
            ),
          ];

    for (final _PlotTemplate t in templates) {
      await _plots.create(PlotsCompanion.insert(
        id: _uuid.v4(),
        title: t.title,
        type: t.type,
        projectId: projectId,
        description: Value(t.description),
        status: const Value('计划中'),
      ));
      result.generatedItems.add(_texts.tf(
        'PG.Item.Plot',
        '剧情大纲：{0}',
        <Object>[t.title],
      ));
    }
    result.generatedPlotsCount = templates.length;
    result.generatedSections.add('plots');
    result.needsPlotOutlines = false;
  }

  /// 对应 C# `GenerateMainCharactersAsync`（3 个固定主要角色）。
  Future<void> _generateMainCharacters(
    String projectId,
    PrerequisiteGenerationResult result,
  ) async {
    final List<_CharacterTemplate> templates = _en
        ? const <_CharacterTemplate>[
            _CharacterTemplate(
              name: 'Ethan Cross',
              type: '主角',
              gender: '男',
              age: 18,
              appearance: 'Tall and lean, with steady eyes and an unbroken will',
              personality:
                  'Resilient, principled, fiercely loyal to those he trusts',
              background:
                  'Of humble birth, he stumbles upon a legacy that changes his fate',
            ),
            _CharacterTemplate(
              name: 'Iris Vale',
              type: '女主角',
              gender: '女',
              age: 17,
              appearance:
                  'Striking and otherworldly, with an air of quiet grace',
              personality:
                  'Brilliant and kind, gentle on the surface yet unyielding at the core',
              background:
                  'Born into a renowned family, a prodigy of rare talent',
            ),
            _CharacterTemplate(
              name: 'Alden the Elder',
              type: '师父',
              gender: '男',
              age: 800,
              appearance:
                  'White-haired and serene, his depth impossible to fathom',
              personality:
                  'Wise and reserved, kind yet exacting, perceptive of the world',
              background:
                  'A recluse of legend, once the most celebrated figure of his era',
            ),
          ]
        : const <_CharacterTemplate>[
            _CharacterTemplate(
              name: '林轩',
              type: '主角',
              gender: '男',
              age: 18,
              appearance: '相貌英俊，身材修长，眼神坚毅',
              personality: '坚韧不拔，正义感强，重情重义',
              background: '出身平凡，因机缘巧合获得修仙传承',
            ),
            _CharacterTemplate(
              name: '苏雨薇',
              type: '女主角',
              gender: '女',
              age: 17,
              appearance: '倾国倾城，气质出尘，如仙子下凡',
              personality: '聪慧善良，外柔内刚，冰雪聪明',
              background: '名门世家出身，天赋卓绝的修仙天才',
            ),
            _CharacterTemplate(
              name: '玄天老祖',
              type: '师父',
              gender: '男',
              age: 800,
              appearance: '仙风道骨，白发飘逸，深不可测',
              personality: '睿智深沉，慈祥严厉，洞察世事',
              background: '隐世高人，曾经的修仙界传奇人物',
            ),
          ];

    // 修为等级从项目自定义修炼体系里按定位取值（主角低阶、师父高阶；C# 同）
    final List<String> levelNames =
        await getProjectCultivationLevelNames(projectId);
    String? levelFor(int index) {
      if (levelNames.isEmpty) return null;
      final int last = levelNames.length - 1;
      switch (index) {
        case 0:
          return levelNames[0];
        case 1:
          return levelNames[1 < last ? 1 : last];
        default:
          return levelNames[last - 1 < 0 ? 0 : last - 1];
      }
    }

    int created = 0;
    for (int i = 0; i < templates.length; i++) {
      final _CharacterTemplate t = templates[i];
      await _characters.create(CharactersCompanion.insert(
        id: _uuid.v4(),
        name: t.name,
        type: t.type,
        projectId: projectId,
        gender: Value(t.gender),
        age: Value(t.age),
        appearance: Value(t.appearance),
        personality: Value(t.personality),
        background: Value(t.background),
        cultivationLevel: Value(levelFor(i)),
        // ⚠ 显式写 9：C# 模板漏设 Importance（默认 1），会让「主要角色 >= 8」
        // 这条门槛永远不满足 → 反复调用重复插角色。必须修。
        importance: const Value(9),
      ));
      created++;
      result.generatedItems.add(_texts.tf(
        'PG.Item.Character',
        '主要角色：{0}（{1}）',
        <Object>[t.name, t.type],
      ));
    }
    result.generatedCharactersCount = created;
    result.generatedSections.add('characters');
    result.needsMainCharacters = false;
  }

  /// 对应 C# `GenerateWorldSettingsAsync`（5 条固定世界设定）。
  Future<void> _generateWorldSettings(
    String projectId,
    PrerequisiteGenerationResult result,
  ) async {
    final String cultivationSummary = await _buildCultivationSummary(projectId);

    final List<_WorldSettingTemplate> templates = _en
        ? <_WorldSettingTemplate>[
            _WorldSettingTemplate(
              name: 'Progression System',
              type: 'System Setting',
              content: cultivationSummary,
              importance: 10,
              order: 1,
            ),
            const _WorldSettingTemplate(
              name: 'World Geography',
              type: 'Geography Setting',
              content:
                  "The known world spans four great regions, each with distinct terrain, cultures, and resources that shape their people's ways of life.",
              importance: 9,
              order: 2,
            ),
            const _WorldSettingTemplate(
              name: 'Energy System',
              type: 'Energy Setting',
              content:
                  "The world's energy flows in five elemental currents (metal, wood, water, fire, earth) plus rare variants such as lightning, ice, and wind. Practitioners attune to affinities matching their nature.",
              importance: 8,
              order: 3,
            ),
            const _WorldSettingTemplate(
              name: 'Artifact Ranks',
              type: 'Item Setting',
              content:
                  'Artifacts are ranked: Mortal → Spirit → Treasure → Law → Immortal → Divine. Each rank divides into lower, middle, upper, and peak quality.',
              importance: 7,
              order: 4,
            ),
            const _WorldSettingTemplate(
              name: 'Time & Lifespan',
              type: 'Time Setting',
              content:
                  'Time flows as it does in the mortal world, yet practitioners live far longer — roughly two centuries at the early ranks, five at the middle, a thousand at the high, and beyond.',
              importance: 7,
              order: 5,
            ),
          ]
        : <_WorldSettingTemplate>[
            _WorldSettingTemplate(
              name: '修炼体系',
              type: '体系设定',
              content: cultivationSummary,
              importance: 10,
              order: 1,
            ),
            const _WorldSettingTemplate(
              name: '世界地理',
              type: '地理设定',
              content: '九天仙域分为四大洲：东胜神洲、西牛贺洲、南赡部洲、北俱芦洲。每洲都有独特的地理环境和修炼资源。',
              importance: 9,
              order: 2,
            ),
            const _WorldSettingTemplate(
              name: '灵气体系',
              type: '能量设定',
              content: '天地灵气分为五行灵气（金木水火土）和特殊灵气（雷、冰、风等）。修炼者根据体质吸收不同属性的灵气。',
              importance: 8,
              order: 3,
            ),
            const _WorldSettingTemplate(
              name: '法宝等级',
              type: '物品设定',
              content: '法宝等级：凡器→灵器→宝器→法器→仙器→神器。每个等级又分为下品、中品、上品、极品四个品质。',
              importance: 7,
              order: 4,
            ),
            const _WorldSettingTemplate(
              name: '时间设定',
              type: '时间设定',
              content: '修仙界时间流速与凡间相同，但修炼者寿命大幅延长。练气期寿命200年，筑基期500年，金丹期1000年，以此类推。',
              importance: 7,
              order: 5,
            ),
          ];

    for (final _WorldSettingTemplate t in templates) {
      await _worldSettings.create(WorldSettingsCompanion.insert(
        id: _uuid.v4(),
        name: t.name,
        type: t.type,
        projectId: projectId,
        content: Value(t.content),
        importance: Value(t.importance),
        orderIndex: Value(t.order),
      ));
      result.generatedItems.add(_texts.tf(
        'PG.Item.WorldSetting',
        '世界设定：{0}',
        <Object>[t.name],
      ));
    }
    result.generatedWorldSettingsCount = templates.length;
    result.generatedSections.add('world');
    result.needsWorldSettings = false;
  }

  /// 对应 C# `GenerateFactionsAsync`（3 个固定势力）。
  Future<void> _generateFactions(
    String projectId,
    PrerequisiteGenerationResult result,
  ) async {
    final List<_FactionTemplate> templates = _en
        ? const <_FactionTemplate>[
            _FactionTemplate(
              name: 'Skyhaven Order',
              type: '修仙宗门',
              powerLevel: 95,
              description:
                  'An ancient and powerful order with deep foundations, strict rules, and a proud tradition of inheritance',
              territory: 'Skyhaven Mountains',
              memberCount: 50000,
              powerRating: 95,
              influence: 90,
              importance: 95,
              tags: 'order,tradition,discipline,formidable',
            ),
            _FactionTemplate(
              name: 'Crimson Moon Sect',
              type: '修仙宗门',
              powerLevel: 85,
              description:
                  'A sect known for its blood-attribute arts and unorthodox methods, holding a singular place in the world',
              territory: 'Crimson Moon Gorge',
              memberCount: 30000,
              powerRating: 85,
              influence: 70,
              importance: 80,
              tags: 'sect,blood arts,unorthodox,mysterious',
            ),
            _FactionTemplate(
              name: 'Myriad Treasures Guild',
              type: '商业组织',
              powerLevel: 70,
              description:
                  "The world's largest merchant guild, controlling the flow of most cultivation resources while staying strictly neutral",
              territory: 'Major trade cities',
              memberCount: 20000,
              powerRating: 70,
              influence: 80,
              importance: 65,
              tags: 'commerce,wealth,trade,neutral',
            ),
          ]
        : const <_FactionTemplate>[
            _FactionTemplate(
              name: '玄天宗',
              type: '修仙宗门',
              powerLevel: 95,
              description: '修仙界历史悠久的大型宗门，拥有强大实力和深厚底蕴，门规严明，注重传承',
              territory: '玄天山脉',
              memberCount: 50000,
              powerRating: 95,
              influence: 90,
              importance: 95,
              tags: '宗门,修仙,传承,强大',
            ),
            _FactionTemplate(
              name: '血月宗',
              type: '修仙宗门',
              powerLevel: 85,
              description: '以血系功法闻名的修仙宗门，修炼方式独特，在修仙界有着特殊地位',
              territory: '血月峡谷',
              memberCount: 30000,
              powerRating: 85,
              influence: 70,
              importance: 80,
              tags: '宗门,血系功法,独特修炼,神秘',
            ),
            _FactionTemplate(
              name: '万宝商会',
              type: '商业组织',
              powerLevel: 70,
              description: '修仙界最大的商业组织，掌控着大部分修炼资源的流通，保持中立立场',
              territory: '各大商城',
              memberCount: 20000,
              powerRating: 70,
              influence: 80,
              importance: 65,
              tags: '商业,财富,贸易,中立',
            ),
          ];

    for (final _FactionTemplate t in templates) {
      await _factions.create(FactionsCompanion.insert(
        id: _uuid.v4(),
        name: t.name,
        type: t.type,
        projectId: projectId,
        powerLevel: Value(t.powerLevel),
        description: Value(t.description),
        territory: Value(t.territory),
        memberCount: Value(t.memberCount),
        powerRating: Value(t.powerRating),
        influence: Value(t.influence),
        importance: Value(t.importance),
        tags: Value(t.tags),
        status: const Value('Active'),
      ));
      result.generatedItems.add(_texts.tf(
        'PG.Item.Faction',
        '势力：{0}（{1}）',
        <Object>[t.name, t.type],
      ));
    }
    result.generatedFactionsCount = templates.length;
    result.generatedSections.add('factions');
    result.needsFactions = false;
  }

  /// 对应 C# `BuildCultivationSummaryAsync`（世界设定首条的正文）。
  Future<String> _buildCultivationSummary(String projectId) async {
    final List<String> levelNames =
        await getProjectCultivationLevelNames(projectId);
    if (levelNames.isNotEmpty) {
      return _en
          ? 'Progression ranks: ${levelNames.join(' → ')}. Ranks ascend step by step; each breakthrough requires meeting its condition and yields a qualitative leap.'
          : '修炼等级：${levelNames.join('→')}。等级由低到高递进，每次突破均需满足对应条件并获得质的飞跃。';
    }
    return _en
        ? 'Progression ranks: Novice → Adept → Adept Master → Core Formation → Spirit Refinement → Union → Ascendant → Sovereign → Tribulation → Immortal. Each great realm divides into early, middle, late, and peak stages.'
        : '修炼等级：练气→筑基→金丹→元婴→化神→炼虚→合体→大乘→渡劫→仙人。每个大境界分为初期、中期、后期、巅峰四个小境界。';
  }
}

// ---------------------------------------------------------------- 模板数据载体
// 用私有类而不是 Record：C# 的模板条目是具名对象，具名类比 6~10 字段的
// Record 类型注解可读性好得多，也便于后续加字段。

class _PlotTemplate {
  const _PlotTemplate({
    required this.title,
    required this.type,
    required this.description,
  });

  final String title;
  final String type;
  final String description;
}

class _CharacterTemplate {
  const _CharacterTemplate({
    required this.name,
    required this.type,
    required this.gender,
    required this.age,
    required this.appearance,
    required this.personality,
    required this.background,
  });

  final String name;
  final String type;
  final String gender;
  final int age;
  final String appearance;
  final String personality;
  final String background;
}

class _WorldSettingTemplate {
  const _WorldSettingTemplate({
    required this.name,
    required this.type,
    required this.content,
    required this.importance,
    required this.order,
  });

  final String name;
  final String type;
  final String content;
  final int importance;
  final int order;
}

class _FactionTemplate {
  const _FactionTemplate({
    required this.name,
    required this.type,
    required this.powerLevel,
    required this.description,
    required this.territory,
    required this.memberCount,
    required this.powerRating,
    required this.influence,
    required this.importance,
    required this.tags,
  });

  final String name;
  final String type;
  final int powerLevel;
  final String description;
  final String territory;
  final int memberCount;
  final int powerRating;
  final int influence;
  final int importance;
  final String tags;
}
