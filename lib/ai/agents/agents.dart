// 8 个具体 Agent 的完整实现（精修版，修仙题材专业 system prompt）。
//
// 对应 C# `Agents/` 下各 Agent 实现。这里按「角色独立、上下游数据结构明确」原则：
//
// 1. 每个 Agent 都覆写 [buildSystemPrompt] + [buildUserPrompt]：
//    - System Prompt：贴合《玄穹剑主》风格（修仙/东方奇幻），明确任务（职责明确、用词一致），并要求结构化输出（分节）
//    - User Prompt：把 parameters 展开为自然语言指令。
// 2. 每个 Agent 都显式定义 capability 清单（对应 NovelWorkflowEngine 的 task name）。
// 3. [processAIResponse] 把 AI 生成的 Markdown 标题行解析成 Map<String,dynamic> 放入 metadata，
//    方便下游（健康检查/写作工作流）直接消费。
// 4. 执行编排仍走 BaseAgent.executeTaskWithAI，保证 RWKV 本地 / 远程 ModelManager 都可用。
library;

import 'agent.dart';

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
    if (taskType == 'AnalyzeTheme') {
      return '你是 NovelCraft 主编（Director），专精东方奇幻/修仙题材主题提炼。'
          '请按以下分节输出：## 核心主题（一句话）/ ## 副主题（2~4条）/ ## 剧情结构（分幕分卷）/ ## 节奏建议 / ## 情绪曲线。'
          '所有输出必须中文，每条分节至少 3 行内容。';
    }
    if (taskType == 'GenerateOutline') {
      return '你是《玄穹剑主》专业主编。请按 ## 第一卷 / ## 第二卷 ... 结构生成分卷大纲：'
          '每卷含「卷名 · 简介（80~150字）· 核心冲突 · 主角阶段目标」；至少 4 卷；'
          '分幕（开端/发展/高潮/结局）清晰，卷间伏笔串联；所有中文。';
    }
    if (taskType == 'CreateWorldSetting') {
      return '你是东方奇幻设定总监。请按 ## 地理 / ## 修炼体系（境界9级+每级简释） / '
          '## 资源（灵石丹药法宝分级） / ## 势力（正道/魔道/妖族） / ## 族群（人族/妖族关系） / ## 禁忌历史 输出；'
          '逻辑自洽，东方修仙风格，不可混杂现代或西方元素。';
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
    String fb;
    if (taskType == 'AnalyzeTheme') {
      fb = '## 核心主题\n凡人逆天改命，打破天道桎梏\n'
          '## 副主题\n1. 兄弟情义（叶知秋 x 谢青山）\n'
          '2. 正魔之辨（非黑即白的反思）\n3. 救赎（苏曼莎摆脱妖族宿命）\n'
          '## 剧情结构\n四幕：入门青云 → 秘境争锋 → 宗门之变 → 飞升证道\n'
          '## 节奏建议\n前期紧凑（每卷15-25章），第3卷宗门大战达高潮\n'
          '## 情绪曲线\n压抑（灭门）-温情（入门）-燃（秘境）-悲（宗门之变）-喜（飞升）';
    } else if (taskType == 'GenerateOutline') {
      fb = '## 第一卷 · 青云少年行\n简介：叶知秋从秋风镇登青云，入门大试觉醒上古剑脉，拜入师门。\n核心冲突：血煞门外门追杀案；主角阶段目标：通过入门大试。\n'
          '## 第二卷 · 青冥秘境\n简介：秘境开启，与苏曼莎首次相遇组队夺机缘。\n核心冲突：五大洲年轻一代争锋；目标：夺秘境榜首。\n'
          '## 第三卷 · 青云之变\n简介：血无极率血煞门攻上青云，灭门真相揭露。\n核心冲突：青云存亡；目标：突破元婴，守护宗门。\n'
          '## 第四卷 · 玄穹飞升\n简介：平定乱世，叶知秋证玄穹剑主真身飞升。\n核心冲突：天道桎梏；目标：携众人飞升。';
    } else if (taskType == 'CreateWorldSetting') {
      fb = '## 地理\n青冥山脉三千里 / 血泽魔渊十二州 / 中州皇朝 / 极北冰原 / 东荒妖族\n'
          '## 修炼体系\n炼气→筑基→金丹→元婴→化神→炼虚→合体→大乘→渡劫→飞升（10级，每级分初/中/后/圆满）\n'
          '## 资源\n下品/中品/上品/极品灵石（兑换1:100）；一至九品丹药；法器→灵器→仙器→神器\n'
          '## 势力\n正道（青云/紫霄/瑶池）；魔道（血煞/合欢/幽冥）；妖族（月影狐族/金鹏/龙族）\n'
          '## 族群\n人族、妖族互有往来但不信任，魔族为上古遗留禁忌血脉\n'
          '## 禁忌历史\n万年前天道崩塌一战，玄穹剑主陨落后剑脉四散，此后飞升之路半锁。';
    } else {
      fb = 'Director 本地回退：$taskType';
    }
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
    if (taskType == 'GenerateChapterContent') {
      return '你是《玄穹剑主》的网文主笔作家（WriterAgent）。'
          '要求：严格中文、第三人称、无现代用语、修仙术语统一；'
          '分节：## 章节标题 / ## 正文；字数：至少1500字。'
          '人物语气必须匹配：叶知秋=冷静外冷内热；谢青山=憨厚正直；苏曼莎=清冷隐忍；'
          '冷无霜=冷艳毒舌；血无极=阴毒深沉。开头抓眼球，结尾留钩子。';
    }
    if (taskType == 'ContinueChapter') {
      return '你是东方奇幻续写手。请根据上下文延续，人物不崩、节奏不停、字数1500-2500，结尾必须留强钩子。';
    }
    if (taskType == 'PolishText') {
      return '你是专业文字润色编辑。请从语病修复、人物语气统一、场景生动化、修仙术语一致、节奏紧凑化五方面润色用户提供的正文，直接输出润色后的完整文本。';
    }
    return '你是专业小说作家，请执行任务 $taskType。';
  }

  @override
  String buildUserPrompt(String taskType, Map<String, dynamic> parameters) {
    final b = StringBuffer('请执行任务 $taskType。\n');
    parameters.forEach((k, v) => b.writeln('$k: $v'));
    if (taskType == 'GenerateChapterContent' && !parameters.containsKey('chapterTitle')) {
      b.writeln('默认标题：未命名章节；默认角色：叶知秋、谢青山、冷无霜');
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
    const fb = '【本地回退章节示例】\n\n'
        '叶知秋背负玄铁古剑，立在青云山外的云海边缘，剑眉微蹙。\n\n'
        '谢青山拍了拍他的肩膀：「小师弟，你今日是第一次登青云主峰，不必紧张。」\n'
        '话音未落，远处一道剑光破云而来，冷无霜一袭雪白狐裘落于二人身前，冷冷道：「大师兄，长老会召你议事。」\n\n'
        '叶知秋低头抱拳，却察觉冷无霜的目光在他腰间古剑上停留了一瞬。\n';
    return AgentTaskResult(
      isSuccess: true,
      data: taskType == 'GenerateChapterContent'
          ? '${parameters['chapterTitle'] ?? '未命名章节'}\n\n$fb'
          : (taskType == 'ContinueChapter' ? fb : '润色结果（本地回退：$taskType）'),
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
    const fb = '## 基本信息\n姓名：示例 / 化名：示 / 性别：男 / 种族：人族 / 宗门：青云宗 / 身份：内门弟子\n'
        '## 外貌\n面容清俊，身形修长，腰间悬一柄短剑，右虎口常年有厚茧。\n'
        '## 性格\n沉稳内敛，重情义，对敌人绝不手软。\n'
        '## 身世背景\n自小失祜，由宗门药堂抚养长大，少年时便立誓要护身后之人。\n'
        '## 动机\n短期：通过内门大比；长期：守护青云宗。\n'
        '## 核心冲突\n内在：怕自己太弱护不住人；外在：魔道势大。\n'
        '## 优势\n悟性极高 / 意志力坚韧\n'
        '## 弱点\n过于在意他人眼光，重压时会冲动。\n'
        '## 修为境界\n炼气九层\n'
        '## 标签\n内门弟子、剑修、护短\n'
        '## 与其他角色关系\n1. 视大师兄谢青山为兄长；2. 对冷无霜有好感但不敢言；3. 与血煞门弟子天生敌对。';
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
    const fb = '## 开端\n秋风吹叶，灭门旧事起\n叶知秋父母被血煞门所害，被谢青山救上青云山。\n'
        '## 上升情节\n入门试剑\n入门大试中叶知秋体内上古剑脉觉醒，震动九峰长老。\n'
        '## 中盘转进\n秘境相逢\n青冥秘境中与苏曼莎联手御敌，情愫暗生；同时察觉宗门内有内鬼。\n'
        '## 高潮\n青云大战\n血无极率血煞门攻上青云，叶知秋得知灭门真相，剑脉完全觉醒，突破元婴。\n'
        '## 结局\n玄穹飞升\n平定乱世，叶知秋证玄穹剑主真身，与众人同登飞升之路。';
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
    if (taskType == 'CreateWorldSetting') {
      return '你是东方奇幻设定总监。按 ## 地理 / ## 修炼体系（10级境界+描述）/ ## 货币与资源 / '
          '## 势力（正道/魔道/妖族 三足）/ ## 禁忌 / ## 近百年大事年表（≥20条） 分节，逻辑自洽，不可混杂现代或西方元素。';
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
    const fb = '## 地理\n青冥山脉 / 血泽魔渊 / 中州皇朝 / 极北冰原 / 东荒妖族\n'
        '## 修炼体系\n炼气→筑基→金丹→元婴→化神→炼虚→合体→大乘→渡劫→飞升，每级分初/中/后/圆满。\n'
        '## 货币与资源\n灵石四级；丹药九品；法器→灵器→仙器→神器；仙晶仅上界流通。\n'
        '## 势力\n正道（青云/紫霄/瑶池），魔道（血煞/合欢/幽冥），妖族八部。\n'
        '## 禁忌\n修炼中不可提及他人名讳夺其气运；不可擅入上古战场；不可与魔族缔结盟约。\n'
        '## 近百年大事年表\n100年前·青冥秘境首次开启；50年前·血煞门崛起；30年前·天道封印松动。';
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
    const fb = '## 一句话剧情\n叶知秋初登青云山，拜入师门\n'
        '## 出场人物\n叶知秋 / 谢青山 / 冷无霜\n'
        '## 关键事件\n拜师大典；入门剑脉初觉；冷无霜留意叶知秋腰间古剑。\n'
        '## 情绪基调\n温馨中带一丝隐忧\n'
        '## 埋下伏笔\n上古剑脉觉醒、宗门内鬼线索。\n'
        '## 后续可回收\n冷无霜与上古剑主可能存在前世渊源。';
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
