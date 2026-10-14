// 8 个具体 Agent 的完整实现。
//
// ⚠ +47 重要修正（去硬编码）：本文件此前把**某一本书**（《玄穹剑主》）
// 的书名、题材与 5 个角色名写死在 **system prompt 与回退文本**里。后果：
//   * 任何**其它项目**走这条链路（例如《夜闯寡妇村》）都会被模型写成
//     《玄穹剑主》的人物与设定 —— 属于「会导致模型写作异常的数据」；
//   * 回退文本本身就是别的书的正文片段，一旦被落库就污染项目。
// 现在：**题材/书名/人物一律由调用方通过 parameters 提供**；回退文本改为
// 明确的失败占位（[aiUnavailablePlaceholder]），不再伪造内容。
//
// 对应 C# `Agents/` 下各 Agent 实现。这里按「角色独立、上下游数据结构明确」原则：
//
// 1. 每个 Agent 都覆写 [buildSystemPrompt] + [buildUserPrompt]：
//    - System Prompt：只描述**职责与输出结构**，不绑定具体题材/人名
//    - User Prompt：把 parameters 展开为自然语言指令。
// 2. 每个 Agent 都显式定义 capability 清单（对应 NovelWorkflowEngine 的 task name）。
// 3. [processAIResponse] 把 AI 生成的 Markdown 标题行解析成 Map<String,dynamic> 放入 metadata，
//    方便下游（健康检查/写作工作流）直接消费。
// 4. 执行编排仍走 BaseAgent.executeTaskWithAI，保证 RWKV 本地 / 远程 ModelManager 都可用。
library;

import 'agent.dart';
import '../utils/anti_ai_flavor.dart';

/// AI 不可用时的**失败占位**（替代此前的「其它小说正文片段」回退）。
///
/// 为什么必须换掉：旧回退文本是《玄穹剑主》的设定/正文，调用方无法区分
/// 「这是内容」还是「这是失败」，一旦落库就把**别的书**写进了用户项目。
/// 现在返回一眼可辨的占位串，且 `metadata['Fallback'] = true` 仍可程序化判定。
String aiUnavailablePlaceholder(String taskType, String what) =>
    '（AI 不可用，未生成$what。任务「$taskType」未真正执行 —— '
    '请检查模型/服务配置后重试。此占位内容不可作为项目数据保存。）';

/// 从 AI 返回中抽取 Markdown 标题（## xxx）与下一段内容到 Map。
Map<String, String> parseMarkdownSections(String ai) {
  final out = <String, String>{};
  String? cur;
  final buf = StringBuffer();
  for (final raw in ai.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('## ') || line.startsWith('### ')) {
      if (cur != null && buf.isNotEmpty) out[cur] = buf.toString().trim();
      cur = line.replaceFirst(RegExp(r'^#+\s*'), '').trim();
      buf.clear();
    } else {
      buf.writeln(line);
    }
  }
  if (cur != null && buf.isNotEmpty) out[cur] = buf.toString().trim();
  if (out.isEmpty && ai.isNotEmpty) out['全文'] = ai.trim();
  return out;
}

// ============================================================
// 1. 主编 Agent
// ============================================================

class DirectorAgent extends BaseAgent {
  DirectorAgent({
    required super.logger,
    super.memoryManager,
    super.thinkingChainProcessor,
    super.modelManager,
    super.rwkvService,
  });

  @override
  String get name => 'Director';

  /// 单路请求只有 system + 一条 user（见 `executeTaskWithAI`），
  /// 因此可直接拼成自包含批量 prompt —— 与单路同源。
  @override
  bool get supportsBatchPrompt => true;

  @override
  String get description => '主编，负责统筹小说结构、主题与世界观';

  @override
  List<AgentCapability> supportedCapabilities() => [
        AgentCapability(
          name: 'AnalyzeTheme',
          description: '分析主题：提炼核心/副主题、优先级、结构、情绪曲线',
          priority: 100,
        ),
        AgentCapability(
          name: 'GenerateOutline',
          description: '生成卷宗分卷大纲（开端/发展/高潮/结局）',
          priority: 90,
        ),
        AgentCapability(
          name: 'CreateWorldSetting',
          description: '创建世界设定（地理/修炼/资源/势力）',
          priority: 80,
        ),
        AgentCapability(
          name: 'OptimizeOutline',
          description: '优化已有大纲：节奏/冲突点/伏笔回收',
          priority: 70,
        ),
      ];

  @override
  String buildSystemPrompt(String taskType) {
    // ⚠ +47 去硬编码：这些 system prompt 此前写死了《玄穹剑主》的题材与人名，
    // 任何其它项目（例如《夜闯寡妇村》）走这条链路都会被注入**错误的书名/角色**。
    // 现在一律「题材/人物由输入决定」，只保留结构性要求。
    if (taskType == 'AnalyzeTheme') {
      return '你是 NovelCraft 主编（Director），负责提炼书籍主题。'
          '请按以下分节输出：## 核心主题（一句话）/ ## 副主题（2~4条）/ ## 剧情结构（分幕分卷）/ ## 节奏建议 / ## 情绪曲线。'
          '题材与风格**以用户提供的设定为准**，不要自行假定；所有输出必须中文，每条分节至少 3 行内容。';
    }
    if (taskType == 'GenerateOutline') {
      return '你是专业主编。请按 ## 第一卷 / ## 第二卷 ... 结构生成分卷大纲：'
          '每卷含「卷名 · 简介（80~150字）· 核心冲突 · 主角阶段目标」；至少 4 卷；'
          '分幕（开端/发展/高潮/结局）清晰，卷间伏笔串联；所有中文。'
          '书名、题材、人物**一律以用户提供的设定为准**，不得替换为其它作品。';
    }
    if (taskType == 'CreateWorldSetting') {
      return '你是世界观设定总监。请按 ## 地理 / ## 力量体系（分级+每级简释） / '
          '## 资源 / ## 势力 / ## 族群 / ## 禁忌历史 输出；'
          '**体系形态以用户提供的题材为准**（修仙/奇幻/科幻/都市等），逻辑自洽、不可混杂无关元素。';
    }
    if (taskType == 'OptimizeOutline') {
      return '你是资深主编。请诊断用户给出的大纲，按 ## 存在问题 / ## 优化后方案 分节输出；'
          '问题点至少指出：节奏拖沓、冲突不足、伏笔悬空、主角动机薄弱；方案给出具体修改段落。';
    }
    return '你是专业主编，请执行任务 $taskType，输出结构化成中文 Markdown。';
  }

  @override
  String buildUserPrompt(String taskType, Map<String, dynamic> parameters) {
    final b = StringBuffer('请执行任务 $taskType。\n');
    parameters.forEach((k, v) => b.writeln('- $k: $v'));
    if (parameters['projectId'] == null || parameters['projectId'].toString().isEmpty) {
      b.writeln('（默认题材：东方修仙 · 剑修 · 重生成长 · 正魔对抗）');
    }
    return b.toString();
  }

  @override
  Future<AgentTaskResult> processAIResponse(
    String taskType,
    String aiResponse,
    Map<String, dynamic> parameters,
  ) async =>
      AgentTaskResult(
        isSuccess: true,
        data: aiResponse,
        metadata: {
          'TaskType': taskType,
          'sections': parseMarkdownSections(aiResponse),
          if (parameters['projectId'] != null) 'projectId': parameters['projectId'],
        },
      );

  @override
  Future<AgentTaskResult> executeTask(
    String taskType,
    Map<String, dynamic> parameters,
  ) async {
    // ⚠ +47：不再返回《玄穹剑主》的设定（那是**别的书**的数据）。
    final String fb = aiUnavailablePlaceholder(
      taskType,
      taskType == 'AnalyzeTheme'
          ? '主题分析'
          : (taskType == 'GenerateOutline' ? '分卷大纲' : '世界观设定'),
    );
    return AgentTaskResult(
      isSuccess: true,
      data: fb,
      metadata: {
        'TaskType': taskType,
        'sections': parseMarkdownSections(fb),
        'Fallback': true,
      },
    );
  }
}

// ============================================================
// 2. 写作 Agent
// ============================================================

class WriterAgent extends BaseAgent {
  WriterAgent({
    required super.logger,
    super.memoryManager,
    super.thinkingChainProcessor,
    super.modelManager,
    super.rwkvService,
  });

  @override
  String get name => 'Writer';

  /// 单路请求只有 system + 一条 user（见 `executeTaskWithAI`），
  /// 因此可直接拼成自包含批量 prompt —— 与单路同源。
  @override
  bool get supportsBatchPrompt => true;

  @override
  String get description => '写作，负责章节正文生成与润色';

  @override
  List<AgentCapability> supportedCapabilities() => [
        AgentCapability(
          name: 'GenerateChapterContent',
          description: '按给定章节标题与剧情节点，生成2000-4000字章节正文',
          priority: 100,
        ),
        AgentCapability(
          name: 'ContinueChapter',
          description: '根据上文续写，字数1500-2500字，结尾留钩子',
          priority: 90,
        ),
        AgentCapability(
          name: 'PolishText',
          description: '润色：修复语病/人物语言统一/修辞提升',
          priority: 80,
        ),
      ];

  @override
  String buildSystemPrompt(String taskType) {
    // ⚠ +47 去硬编码：此前这里写死了《玄穹剑主》书名与 5 个角色的人设语气
    //（叶知秋/谢青山/苏曼莎/冷无霜/血无极），任何其它项目都会写出**错误的人名与语气**。
    // 现在改为「人物与语气一律取自用户提供的章大纲 / 项目设定」。
    if (taskType == 'GenerateChapterContent') {
      // 反 AI 味五戒：StoryScope（arXiv:2604.03136）实证的 5 大话语层
      // AI 写作倾向，作为负向约束注入（见 anti_ai_flavor.dart 头注）
      return withAntiAiFlavorGuidelines(
        '你是专业中文小说主笔作家（WriterAgent）。'
        '要求：严格中文、第三人称、只用用户给定的人物与设定（不得引入其它作品的人物/名词）；'
        '只输出章节正文，不要输出标题、解释、字数统计或大纲；'
        '开头抓眼球，结尾留钩子；若用户给出了目标字数，必须写满。',
      );
    }
    if (taskType == 'ContinueChapter') {
      return withAntiAiFlavorGuidelines(
        '你是专业中文小说续写手。请根据上下文延续：人物不崩、设定不乱、节奏不停，'
        '只输出**新增**正文（不要重复已给的上文），结尾留强钩子；若给出了目标字数必须写满。',
      );
    }
    if (taskType == 'PolishText') {
      // 润色同样是 AI 味重灾区：选节润色最容易把松散线索「顺」成整洁单线
      return withAntiAiFlavorGuidelines(
        '你是专业文字润色编辑。请从语病修复、人物语气统一、场景生动化、术语一致、节奏紧凑化五方面'
        '润色用户提供的正文，直接输出润色后的完整文本。'
        '润色时保留原文的时间线结构与结局歧义，不要把留白解释清楚。',
      );
    }
    return '你是专业小说作家，请执行任务 $taskType。';
  }

  @override
  String buildUserPrompt(String taskType, Map<String, dynamic> parameters) {
    final b = StringBuffer('请执行任务 $taskType。\n');
    parameters.forEach((k, v) => b.writeln('$k: $v'));
    // ⚠ +47 去硬编码：此前缺省塞入《玄穹剑主》的角色名，会把错误人名写进别的书。
    // 现在只提示「按给定设定」，不注入任何具体人名。
    if (taskType == 'GenerateChapterContent' && !parameters.containsKey('chapterTitle')) {
      b.writeln('（未提供章节标题与人物表：请严格按上方给出的项目设定与大纲写作，'
          '不得引入设定之外的人物或名词。）');
    }
    return b.toString();
  }

  @override
  Future<AgentTaskResult> processAIResponse(
    String taskType,
    String aiResponse,
    Map<String, dynamic> parameters,
  ) async =>
      AgentTaskResult(
        isSuccess: true,
        data: aiResponse,
        metadata: {
          'TaskType': taskType,
          'sections': parseMarkdownSections(aiResponse),
          'chineseChars': RegExp(r'[\u4e00-\u9fff]').allMatches(aiResponse).length,
          if (parameters['chapterId'] != null) 'chapterId': parameters['chapterId'],
        },
      );

  @override
  Future<AgentTaskResult> executeTask(
    String taskType,
    Map<String, dynamic> parameters,
  ) async {
    // ⚠ +47：旧回退是《玄穹剑主》的**正文片段**（含 4 个角色名）——
    // 一旦被当成章节内容落库，就把别的书写进了用户项目。改为失败占位。
    final String fb = aiUnavailablePlaceholder(
      taskType,
      taskType == 'GenerateChapterContent'
          ? '章节正文'
          : (taskType == 'ContinueChapter' ? '续写正文' : '润色结果'),
    );
    return AgentTaskResult(
      isSuccess: true,
      data: fb,
      metadata: {
        'TaskType': taskType,
        'sections': parseMarkdownSections(fb),
        'Fallback': true,
      },
    );
  }
}

// ============================================================
// 3. 角色 Agent
// ============================================================

class CharacterAgent extends BaseAgent {
  CharacterAgent({
    required super.logger,
    super.memoryManager,
    super.thinkingChainProcessor,
    super.modelManager,
    super.rwkvService,
  });

  @override
  String get name => 'Character';

  /// 单路请求只有 system + 一条 user（见 `executeTaskWithAI`），
  /// 因此可直接拼成自包含批量 prompt —— 与单路同源。
  @override
  bool get supportsBatchPrompt => true;

  @override
  String get description => '角色设计，负责人物设定与关系梳理';

  @override
  List<AgentCapability> supportedCapabilities() => [
        AgentCapability(
          name: 'GenerateCharacter',
          description: '生成完整角色档案（外貌/性格/身世/动机/冲突/弱点/修为/标签/关系）',
          priority: 100,
        ),
        AgentCapability(
          name: 'OptimizeCharacter',
          description: '优化角色：动机/弧光/弱点补足/矛盾更立体',
          priority: 90,
        ),
        AgentCapability(
          name: 'DesignRelationship',
          description: '生成角色关系网及关键事件',
          priority: 80,
        ),
      ];

  @override
  String buildSystemPrompt(String taskType) {
    if (taskType == 'GenerateCharacter') {
      return '你是 NovelCraft 角色设计师。按以下分节输出完整档案：'
          '## 基本信息 / ## 外貌描写（至少50字）/ ## 性格 / ## 身世背景（至少100字）/ '
          '## 动机（短期/长期）/ ## 核心冲突（内在/外在）/ ## 优势 / ## 弱点 / '
          '## 修为境界 / ## 标签 / ## 与其他角色关系（至少3条）。严格中文。';
    }
    if (taskType == 'OptimizeCharacter') {
      return '你是角色塑造师。请诊断用户提供的角色，按 ## 问题点 / ## 优化建议 输出；'
          '从说服力、人物弧光、性格矛盾、立体度、前后一致性五方面入手。';
    }
    if (taskType == 'DesignRelationship') {
      return '你是关系网络专家。对用户提供的一组角色生成：'
          '## 关系有向图（每条含源/目标/类型/强度/关键事件）/ ## 可演进的关系变化 / ## 潜在冲突点 / ## 反转伏笔。';
    }
    return '你是角色设计师。';
  }

  @override
  String buildUserPrompt(String taskType, Map<String, dynamic> parameters) {
    final b = StringBuffer('执行任务 $taskType。\n');
    parameters.forEach((k, v) => b.writeln('$k：$v'));
    return b.toString();
  }

  @override
  Future<AgentTaskResult> processAIResponse(
    String taskType,
    String aiResponse,
    Map<String, dynamic> parameters,
  ) async =>
      AgentTaskResult(
        isSuccess: true,
        data: aiResponse,
        metadata: {
          'TaskType': taskType,
          'sections': parseMarkdownSections(aiResponse),
        },
      );

  @override
  Future<AgentTaskResult> executeTask(
    String taskType,
    Map<String, dynamic> parameters,
  ) async {
    // ⚠ +47：旧回退是某本书的角色档案（含青云宗/谢青山/冷无霜等），
    // 会被当成「角色设定」写进用户项目。改为失败占位。
    final String fb = aiUnavailablePlaceholder(taskType, '角色档案');
    return AgentTaskResult(
      isSuccess: true,
      data: fb,
      metadata: {
        'TaskType': taskType,
        'sections': parseMarkdownSections(fb),
        'Fallback': true,
      },
    );
  }
}

// ============================================================
// 4. 剧情 Agent
// ============================================================

class PlotAgent extends BaseAgent {
  PlotAgent({
    required super.logger,
    super.memoryManager,
    super.thinkingChainProcessor,
    super.modelManager,
    super.rwkvService,
  });

  @override
  String get name => 'Plot';

  /// 单路请求只有 system + 一条 user（见 `executeTaskWithAI`），
  /// 因此可直接拼成自包含批量 prompt —— 与单路同源。
  @override
  bool get supportsBatchPrompt => true;

  @override
  String get description => '剧情设计，负责情节推进与冲突安排';

  @override
  List<AgentCapability> supportedCapabilities() => [
        AgentCapability(
          name: 'GeneratePlot',
          description: '按开端/上升/转进/高潮/结局生成至少5节点剧情链',
          priority: 100,
        ),
        AgentCapability(
          name: 'OptimizePlot',
          description: '诊断并优化现有剧情：节奏/冲突/伏笔/反派压迫感',
          priority: 90,
        ),
        AgentCapability(
          name: 'GetPlotSuggestions',
          description: '基于当前上下文给3-5条下一章剧情走向',
          priority: 80,
        ),
      ];

  @override
  String buildSystemPrompt(String taskType) {
    if (taskType == 'GeneratePlot') {
      return '你是剧情策划。按 ## 开端 / ## 上升情节 / ## 中盘转进 / ## 高潮 / ## 结局 分节；'
          '每节点：标题（≤12字） + 详细描述（≥100字）；主角动机清晰、冲突持续升级、伏笔+回收+反转钩子+章末钩子俱全。';
    }
    if (taskType == 'OptimizePlot') {
      return '你是剧情医生。诊断用户剧情：节奏拖沓 / 冲突不足 / 伏笔悬空 / 反派压迫感不强；'
          '按 ## 问题 / ## 修改方案 输出。';
    }
    if (taskType == 'GetPlotSuggestions') {
      return '你是剧情顾问。请基于上下文给出至少 4 条剧情方向：每条含 [路径X-情绪] - 标题（≤12字）- 简述（≥80字）。';
    }
    return '你是剧情策划。';
  }

  @override
  String buildUserPrompt(String taskType, Map<String, dynamic> parameters) {
    final b = StringBuffer('执行任务 $taskType。\n');
    parameters.forEach((k, v) => b.writeln('$k: $v'));
    return b.toString();
  }

  @override
  Future<AgentTaskResult> processAIResponse(
    String taskType,
    String aiResponse,
    Map<String, dynamic> parameters,
  ) async =>
      AgentTaskResult(
        isSuccess: true,
        data: aiResponse,
        metadata: {
          'TaskType': taskType,
          'sections': parseMarkdownSections(aiResponse),
        },
      );

  @override
  Future<AgentTaskResult> executeTask(
    String taskType,
    Map<String, dynamic> parameters,
  ) async {
    // ⚠ +47：旧回退是某本书的剧情结构（含叶知秋/血煞门等）。改为失败占位。
    final String fb = aiUnavailablePlaceholder(taskType, '剧情结构');
    return AgentTaskResult(
      isSuccess: true,
      data: fb,
      metadata: {
        'TaskType': taskType,
        'sections': parseMarkdownSections(fb),
        'Fallback': true,
      },
    );
  }
}

// ============================================================
// 5. 世界设定 Agent
// ============================================================

class WorldAgent extends BaseAgent {
  WorldAgent({
    required super.logger,
    super.memoryManager,
    super.thinkingChainProcessor,
    super.modelManager,
    super.rwkvService,
  });

  @override
  String get name => 'World';

  /// 单路请求只有 system + 一条 user（见 `executeTaskWithAI`），
  /// 因此可直接拼成自包含批量 prompt —— 与单路同源。
  @override
  bool get supportsBatchPrompt => true;

  @override
  String get description => '世界设定，负责规则体系与背景构建';

  @override
  List<AgentCapability> supportedCapabilities() => [
        AgentCapability(
          name: 'CreateWorldSetting',
          description: '构建完整世界观（地理/修炼/货币/势力/禁忌/历史）',
          priority: 100,
        ),
        AgentCapability(
          name: 'OptimizeWorldSetting',
          description: '优化设定：逻辑/战力平衡/经济体系/地域特色',
          priority: 90,
        ),
      ];

  @override
  String buildSystemPrompt(String taskType) {
    // ⚠ +47 去硬编码：此前写死「东方奇幻 / 修炼体系 / 正道魔道妖族」，
    // 非该题材的项目会被强行塞进修仙世界观。现在体系形态由输入决定。
    if (taskType == 'CreateWorldSetting') {
      return '你是世界观设定总监。按 ## 地理 / ## 力量或规则体系（分级+描述）/ ## 货币与资源 / '
          '## 势力格局 / ## 禁忌 / ## 近百年大事年表（≥20条） 分节，逻辑自洽。'
          '**体系形态与题材以用户提供的设定为准**（修仙/奇幻/科幻/都市/历史等），不得自行假定。';
    }
    if (taskType == 'OptimizeWorldSetting') {
      return '你是设定医生。按 ## 逻辑漏洞 / ## 战力平衡修正 / ## 经济体系自洽 / ## 地域特色 给出优化方案。';
    }
    return '你是世界构建师。';
  }

  @override
  String buildUserPrompt(String taskType, Map<String, dynamic> parameters) {
    final b = StringBuffer('执行任务 $taskType。\n');
    parameters.forEach((k, v) => b.writeln('$k: $v'));
    return b.toString();
  }

  @override
  Future<AgentTaskResult> processAIResponse(
    String taskType,
    String aiResponse,
    Map<String, dynamic> parameters,
  ) async =>
      AgentTaskResult(
        isSuccess: true,
        data: aiResponse,
        metadata: {
          'TaskType': taskType,
          'sections': parseMarkdownSections(aiResponse),
        },
      );

  @override
  Future<AgentTaskResult> executeTask(
    String taskType,
    Map<String, dynamic> parameters,
  ) async {
    // ⚠ +47：旧回退是某本书的修仙世界观（青冥山脉/血煞门/炼气→飞升）。
    final String fb = aiUnavailablePlaceholder(taskType, '世界观设定');
    return AgentTaskResult(
      isSuccess: true,
      data: fb,
      metadata: {
        'TaskType': taskType,
        'sections': parseMarkdownSections(fb),
        'Fallback': true,
      },
    );
  }
}

// ============================================================
// 6. 读者 Agent
// ============================================================

class ReaderAgent extends BaseAgent {
  ReaderAgent({
    required super.logger,
    super.memoryManager,
    super.thinkingChainProcessor,
    super.modelManager,
    super.rwkvService,
  });

  @override
  String get name => 'Reader';

  /// 单路请求只有 system + 一条 user（见 `executeTaskWithAI`），
  /// 因此可直接拼成自包含批量 prompt —— 与单路同源。
  @override
  bool get supportsBatchPrompt => true;

  @override
  String get description => '读者视角，负责章节评价与可读性反馈';

  @override
  List<AgentCapability> supportedCapabilities() => [
        AgentCapability(
          name: 'EvaluateChapter',
          description: '5维评分（爽点/节奏/人物/场景/逻辑）+ 总分100 + 亮点/槽点',
          priority: 100,
        ),
        AgentCapability(
          name: 'SuggestImprovements',
          description: '给出≥8条按严重度分级的修改建议',
          priority: 90,
        ),
      ];

  @override
  String buildSystemPrompt(String taskType) {
    if (taskType == 'EvaluateChapter') {
      return '你是资深网文十年读者。按以下分节输出评分：'
          '## 评分表（爽点0-10 / 节奏0-10 / 人物0-10 / 场景0-10 / 逻辑0-10 / 总分0-100）/ '
          '## 亮点（至少3条）/ ## 槽点（至少3条）/ ## 修改建议（至少3条）。每条要具体到情节或段落。';
    }
    if (taskType == 'SuggestImprovements') {
      return '你是编辑顾问。请对章节给出至少 8 条修改建议：每条 [严重度·高/中/低] · 位置 · 建议方案。';
    }
    return '你是读者评论员。';
  }

  @override
  String buildUserPrompt(String taskType, Map<String, dynamic> parameters) {
    final b = StringBuffer('执行任务 $taskType。\n');
    parameters.forEach((k, v) => b.writeln('$k: $v'));
    return b.toString();
  }

  @override
  Future<AgentTaskResult> processAIResponse(
    String taskType,
    String aiResponse,
    Map<String, dynamic> parameters,
  ) async {
    final scoreMatch =
        RegExp(r'总分.{0,6}(\d{1,3})\s*\/\s*100|(\d{1,3})\s*\/\s*100').firstMatch(aiResponse);
    return AgentTaskResult(
      isSuccess: true,
      data: aiResponse,
      metadata: {
        'TaskType': taskType,
        'sections': parseMarkdownSections(aiResponse),
        'score': scoreMatch?.group(1) ?? scoreMatch?.group(2) ?? '未解析',
      },
    );
  }

  @override
  Future<AgentTaskResult> executeTask(
    String taskType,
    Map<String, dynamic> parameters,
  ) async {
    const fb = '## 评分表\n爽点：7/10；节奏：6/10；人物：8/10；场景：7/10；逻辑：8/10；总分：72/100\n'
        '## 亮点\n1. 人物互动自然；2. 剑招描写有画面感；3. 章末钩子有效。\n'
        '## 槽点\n1. 中段对话偏多、节奏略慢；2. 反派手段稍显套路。\n'
        '## 修改建议\n1. 中段插入长老会内斗的小冲突；2. 给反派增加苦衷使其更立体。';
    return AgentTaskResult(
      isSuccess: true,
      data: fb,
      metadata: {
        'TaskType': taskType,
        'sections': parseMarkdownSections(fb),
        'Fallback': true,
      },
    );
  }
}

// ============================================================
// 7. 摘要 Agent
// ============================================================

class SummarizerAgent extends BaseAgent {
  SummarizerAgent({
    required super.logger,
    super.memoryManager,
    super.thinkingChainProcessor,
    super.modelManager,
    super.rwkvService,
  });

  @override
  String get name => 'Summarizer';

  /// 单路请求只有 system + 一条 user（见 `executeTaskWithAI`），
  /// 因此可直接拼成自包含批量 prompt —— 与单路同源。
  @override
  bool get supportsBatchPrompt => true;

  @override
  String get description => '摘要，负责章节与卷宗的压缩总结';

  @override
  List<AgentCapability> supportedCapabilities() => [
        AgentCapability(
          name: 'SummarizeChapter',
          description: '章节摘要（一句话标题/人物/事件/基调/伏笔）',
          priority: 100,
        ),
        AgentCapability(
          name: 'SummarizeVolume',
          description: '卷宗摘要（总体概览/节点/主角成长/伏笔回收）',
          priority: 90,
        ),
      ];

  @override
  String buildSystemPrompt(String taskType) {
    if (taskType == 'SummarizeChapter') {
      return '你是章节摘要专家。按 ## 一句话剧情 / ## 出场人物 / ## 关键事件 / '
          '## 情绪基调 / ## 埋下伏笔 / ## 后续可回收 分节。';
    }
    if (taskType == 'SummarizeVolume') {
      return '你是卷宗摘要专家。按 ## 总体概览 / ## 分章节点 / ## 主角成长（境界+心理）/ ## 伏笔回收 分节。';
    }
    return '你是摘要员。';
  }

  @override
  String buildUserPrompt(String taskType, Map<String, dynamic> parameters) {
    final b = StringBuffer('执行任务 $taskType。\n');
    parameters.forEach((k, v) => b.writeln('$k: $v'));
    return b.toString();
  }

  @override
  Future<AgentTaskResult> processAIResponse(
    String taskType,
    String aiResponse,
    Map<String, dynamic> parameters,
  ) async =>
      AgentTaskResult(
        isSuccess: true,
        data: aiResponse,
        metadata: {
          'TaskType': taskType,
          'sections': parseMarkdownSections(aiResponse),
          'chars': aiResponse.length,
        },
      );

  @override
  Future<AgentTaskResult> executeTask(
    String taskType,
    Map<String, dynamic> parameters,
  ) async {
    // ⚠ +47：旧回退是某本书的章节摘要（含叶知秋等）。改为失败占位。
    final String fb = aiUnavailablePlaceholder(taskType, '章节摘要');
    return AgentTaskResult(
      isSuccess: true,
      data: fb,
      metadata: {
        'TaskType': taskType,
        'sections': parseMarkdownSections(fb),
        'Fallback': true,
      },
    );
  }
}

// ============================================================
// 8. 编辑 Agent
// ============================================================

class EditorAgent extends BaseAgent {
  EditorAgent({
    required super.logger,
    super.memoryManager,
    super.thinkingChainProcessor,
    super.modelManager,
    super.rwkvService,
  });

  @override
  String get name => 'Editor';

  /// 单路请求只有 system + 一条 user（见 `executeTaskWithAI`），
  /// 因此可直接拼成自包含批量 prompt —— 与单路同源。
  @override
  bool get supportsBatchPrompt => true;

  @override
  String get description => '编辑，负责一致性与内容审查';

  @override
  List<AgentCapability> supportedCapabilities() => [
        AgentCapability(
          name: 'ContentReview',
          description: '合规审查（政治/色情/暴力/未成年）：通过/存疑/不通过 + 条目',
          priority: 100,
        ),
        AgentCapability(
          name: 'ConsistencyCheck',
          description: '设定一致性（人设/战力/时间线/地理/伏笔）：列表形式输出问题',
          priority: 100,
        ),
        AgentCapability(
          name: 'AiFlavorCheck',
          description: '叙事结构「AI 味」审查（主题显式/因果线性/时间线性/感官超写/和解模板）',
          priority: 70,
        ),
      ];

  @override
  String buildSystemPrompt(String taskType) {
    if (taskType == 'ContentReview') {
      return '你是出版社合规编辑。按 ## 结论（通过/存疑/不通过）/ ## 风险条目（高/中/低，含位置+理由）/ ## 修改建议 输出。';
    }
    if (taskType == 'ConsistencyCheck') {
      return '你是专业总编。按角色档案 / 境界战力 / 时间线 / 地理设定 / 伏笔回收 五大维度，'
          '## 问题清单 分节列出每条：位置 + 问题描述 + 修改建议。';
    }
    if (taskType == 'AiFlavorCheck') {
      // StoryScope 五维自检：把「检测 AI」的研究结论反转为创作自检工具
      return '你是叙事结构审读员。对给定章节按五维逐项评分（0-2：0=无 AI 味，1=轻度，2=明显）：'
          '①主题显式（叙述者直接点题/说教/对话变哲理辩论）'
          '②因果过整洁（无支线或松散线索全被收束、冲突全由主角解决）'
          '③时间过线性（无闪回/时间跳跃/非线性）'
          '④感官超写（身体/环境感官细节密度过高）'
          '⑤和解模板（以主角内心释怀收束、拒绝歧义）。'
          '按 ## 五维评分（每维：分数+一句话证据）/ ## 总评（AI 味 0-10 分）/ ## 去味建议 输出。';
    }
    return '你是总编辑。';
  }

  @override
  String buildUserPrompt(String taskType, Map<String, dynamic> parameters) {
    final b = StringBuffer('执行任务 $taskType。\n');
    parameters.forEach((k, v) => b.writeln('$k: $v'));
    return b.toString();
  }

  @override
  Future<AgentTaskResult> processAIResponse(
    String taskType,
    String aiResponse,
    Map<String, dynamic> parameters,
  ) async =>
      AgentTaskResult(
        isSuccess: true,
        data: aiResponse,
        metadata: {
          'TaskType': taskType,
          'sections': parseMarkdownSections(aiResponse),
          'headingCount': RegExp(r'^##\s+', multiLine: true).allMatches(aiResponse).length,
        },
      );

  @override
  Future<AgentTaskResult> executeTask(
    String taskType,
    Map<String, dynamic> parameters,
  ) async {
    if (taskType == 'AiFlavorCheck') {
      // 本地回退：无 AI 服务时给出全 0 分占位（如实标注回退）
      const fb = '## 五维评分\n'
          '①主题显式：0\n②因果过整洁：0\n③时间过线性：0\n④感官超写：0\n⑤和解模板：0\n'
          '## 总评\n0（本地回退：未执行 AI 叙事审查）\n'
          '## 去味建议\n（需配置 AI 服务后执行）';
      return AgentTaskResult(
        isSuccess: true,
        data: fb,
        metadata: {
          'TaskType': taskType,
          'sections': parseMarkdownSections(fb),
          'Fallback': true,
        },
      );
    }
    const fb = '## 结论\n通过\n'
        '## 问题清单\n（本地回退：未检出风险或矛盾）\n'
        '## 修改建议\n1. 可在剑招描写中加入剑光特效；2. 反派独白可再增加性格层次。';
    return AgentTaskResult(
      isSuccess: true,
      data: fb,
      metadata: {
        'TaskType': taskType,
        'sections': parseMarkdownSections(fb),
        'Fallback': true,
      },
    );
  }
}
