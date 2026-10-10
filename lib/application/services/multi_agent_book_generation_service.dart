// 多智能体协同写书 —— 用户填定向向导（书名/作者/分卷数/每卷章数/并发），
// 按三级大纲 + 固定编制章节写作团队编排：
//
//   ① 主智能体（规划组组长）规划【主线大纲】
//   ② 规划组写手按主线大纲并行规划各【分卷大纲】（空结果自动重试，杜绝空卷）
//   ③ 规划组写手继续并行规划各【章节大纲】
//   ④ 每一章由固定编制团队完成：1 名组长 + 9 名偏向写手（强制 10 人，用户不可改）：
//        · 组长结合主线/分卷/本章大纲，把本章切分为前后衔接的段落任务，
//          按 9 位写手的偏向参数派活（打斗/聊天/搭讪/耍流氓/安抚人心/
//          环境景物/心理刻画/悬疑伏笔/诙谐幽默）；
//        · 写手并行成稿（各自独享 state，互不串号）；
//        · 组长逐段验收：不合格段打回对应写手返工一轮，仍不合格由组长补写；
//        · 组长拼接全部段落 → 润色去重 → 统一排版 → 产出整章正文落库；
//        · 验收通过后生成章节档案（时间范围+主题任务+得失总结+规避措施），
//          并按固定模板接口把待更新项分派给 9 位写手更新人物/世界观。
//
// 并发语义：并发 N = N 个章节团队并行写 N 章（每队固定 1 组长 + 9 写手）；
// 模型调用受全局在途闸（32）保护，超时尊重 AI 配置页的 timeoutSeconds。
//
// 所有编排只依赖可注入的 [AgentChatExecutor]（生产环境由 writingProvider 构建，
// 测试注入假执行器）；纯解析逻辑（parseSectionPlan / parseAcceptanceReport /
// fallbackPlan）独立成静态方法便于单测。
library;

import 'dart:async';
import 'writing_prompt_templates.dart';
import 'dart:convert';
import '../../ai/utils/chapter_title.dart';
import '../../ai/utils/fiction_quality.dart';

import 'package:drift/drift.dart' show Value;
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../../ai/agents/writer_personas.dart';
import '../../ai/models/chat.dart';
import '../../ai/models/provider.dart';
import '../../ai/providers/openai_compatible_provider.dart'
    show OpenAICompatibleProvider;
import '../../ai/providers/rwkv_cloud_provider.dart'
    show
        RwkvCloudConfiguration,
        RwkvCloudProvider,
        kHeaderCfAccessClientId,
        kHeaderCfAccessClientSecret;
import '../../ai/rwkv/g1k_model_preset.dart';
import '../../ai/rwkv/g1k_writing_profile.dart';
import '../../ai/rwkv/rwkv_sampling.dart' show isRwkvFamilyProvider;
import '../../ai/runtime_settings.dart';
import '../../ai/utils/output_sanitizer.dart';
import '../../ai/utils/semaphore.dart';
import '../../ai/workflow/agent_state_manager.dart';
import '../../data/database.dart';
import '../../data/repositories/chapter_repository.dart';
import '../../data/repositories/plot_repository.dart';
import '../../data/repositories/project_repository.dart';
import '../../data/repositories/volume_repository.dart';
import 'chapter_dedup_guard.dart';
import 'chapter_export_service.dart';
import 'chapter_post_process_service.dart';
import 'chapter_rewrite_service.dart';
import 'chapter_sync_service.dart';
import 'entity_profile_synthesizer.dart';
import 'style_rule.dart';
import 'writing_archive_service.dart' show ArchiveDescription;
import '../models/stats.dart';

const Uuid _uuid = Uuid();

/// 单个智能体的聊天执行器：system prompt + 累积消息 → 清洗后的输出文本。
///
/// 生产环境由 [MultiAgentBookGenerationService.writingProvider] 构建
/// （provider.chat + AIOutputSanitizer + RWKV 防复读采样参数）；
/// 测试注入脚本化假执行器即可驱动全链路。
typedef AgentChatExecutor =
    Future<String> Function(
      String systemPrompt,
      List<ChatMessage> messages, {
      required int maxTokens,
      double temperature,
      /// 客户端 state 会话标识（`<项目或大纲分组>::<智能体角色>`）。
      ///
      /// 仅当底层 provider 是开启客户端 state 管理的 RWKV 云端 provider 时
      /// 才有意义：它让「组长 / 写手 1..9」各自拥有一条**由客户端持有**的
      /// state 链（RWKV 的 O(1) 上下文接续），而不是每轮重发全部历史。
      /// 其它 provider / 未开启时该参数被忽略。
      String? sessionKey,
    });

/// 写作档案钩子：level = `project` / `volume` / `chapter`。
///
/// metadata 携带档案四段描述（timeRange/themeTask/gainsLosses/safeguards）
/// 与归属 id（volumeId/chapterId）；实现方落 KVStore project_archive。
typedef TeamArchiveHook =
    Future<void> Function({
      required String level,
      required String? projectId,
      required String title,
      required String content,
      required Map<String, String> metadata,
    });

/// 验收后更新分派回调：组长罗列的待更新项按固定模板接口分派给 9 位写手
/// 产出最终条目并防幻觉应用（由 TeamUpdateDispatchService 提供）。
typedef TeamUpdatesDispatcher =
    Future<List<String>> Function({
      required String projectId,
      required List<Map<String, Object?>> items,
      required Future<String> Function(int writerSlot, String prompt)
      writerChat,
    });

/// 章节写作阶段（矩阵化实时进度展示用）。
enum MultiAgentChapterPhase {
  queued, // 排队等待团队
  planning, // 组长偏向派活中
  writing, // 写手并行成稿中
  accepting, // 组长逐段验收中
  rework, // 不合格段打回返工中
  leaderFix, // 组长亲自补写中
  polishing, // 拼接润色定稿中
  outlineRepair, // 收尾自动修复：按前后章节调大纲 + 重写（2026-10-10 新增）
  done,
  failed,
}

/// 章节级实时进度事件（每章状态/进度变化即上报）。
class MultiAgentChapterEvent {
  const MultiAgentChapterEvent({
    required this.chapterId,
    required this.chapterTitle,
    required this.volumeTitle,
    required this.phase,
    required this.progress,
    this.detail = '',
  });

  final String chapterId;
  final String chapterTitle;
  final String volumeTitle;
  final MultiAgentChapterPhase phase;

  /// 章内进度 0..1。
  final double progress;
  final String detail;
}

/// 章节事件监听器（全局写作动态面板消费）。
typedef MultiAgentChapterListener = void Function(MultiAgentChapterEvent event);

/// 单段目标字数（**实测甜点**）。
///
/// RWKV7-G1J 云端实测：单次生成在 2000~2800 字区间质量最稳
///（4-gram 去重率 ≥0.98、段落复读率 0）；一旦放飞，同一配置下有约 20%
/// 概率一路写到 1.4 万字，且末千字 4-gram 去重率跌到 0.29、段落复读率 0.72。
const int kSegmentTargetChars = 2200;

/// 单段输出 token 预算：段目标 × 1.45（中文字 ≈1 token/字，留约 45% 余量）。
///
/// ⚠ **必须贴近目标**：实测把 max_tokens 开到 14000 而目标只写 2000 字时，
/// 模型会一路写到 1.4 万字并整段复读 —— 大预算 = 放飞（7/7 轮全部退化）。
/// 2900 ≈ 段目标 2200 × 1.32：实测单段产出 2079~2788 字不触顶；
/// **一旦顶到预算上限，模型就是被迫继续写 → 必然退化**（实测顶到上限的
/// 全部轮次复读率 0.09~0.89，未顶到的全部 ≤0.01）。宁可留 30% 余量。
const int kSegmentBudgetTokens = 2900;

/// 分段串行的最大轮数（按字数驱动的安全上限：4500 字章通常 3~6 轮）。
const int kMaxSerialRounds = 8;

/// 单笔直书（solo）的输出预算与目标上限。
///
/// 实测单次目标 2000 字 → 复读率 0.000；3000 字 → 0.091；5000 字 → 0.556。
/// 故 solo 只适合短章，这里把请求目标硬性钳到 2600 字、预算 3600。
const int kSoloTargetChars = 2600;
const int kSoloBudgetTokens = 3600;

/// 写作工艺（章节正文的产出方式）。
///
/// 2026-09-30 RWKV7-G1J 云端实测结论：
/// - 单次生成的自然收敛长度 ≈ 2000~2800 字，尾部极易进入复读循环；
/// - 旧「1 组长 + 9 写手并行 + 组长拼接」每章 12+ 次调用、约 4.3 万 token，
///   9 段拼缝还会放大风格漂移 —— 与 16K 上下文无关（16K 远够写 5000 字）。
/// 并发候选数（best-of-N）：同一前缀并发续写 N 份再择优。
///
/// 依据：7.2B 单次输出方差极大（实测同提示词 156~2937 字），**择优是
/// 方差问题的标准解**；服务端实测可扛 169 并发（`/v1/server/status`
/// `available_bsz`），App 全局在途闸 32，所以并发几乎不增加墙钟时间。
/// 每轮并发的续写候选数。
///
/// ⚠ 这些候选是 `Future.wait` **并发**发起的，因此一律走**无状态链路**
/// （`_AgentChannel.send(isolated: true)`）—— 共用 lead 的 state 会话会让候选
/// 之间互相污染，并触发台账串行化白给并发。详见 [_writeChapterBeam]。
const int kBeamWidth = 5;

/// 每个候选段的目标字数：**刻意取短**（600~900 字远离退化区），
/// 靠轮数堆出整章长度。
const int kBeamSegmentChars = 800;

/// 候选段输出预算：段目标 × 1.6（短段必须留足空间，避免顶到上限退化）。
const int kBeamSegmentTokens = 1300;

/// 续写优选的最大轮数（800 字/段 × 8 = 6400 字上限）。
const int kMaxBeamRounds = 10;

enum WritingCraft {
  /// 单笔直书：1 次调用写完本章（最快最省，适合短章）。
  solo,

  /// 主笔分段串行：同一主笔按段续写，只携带上一段尾部 300 字。
  duo,

  /// **续写优选（推荐）**：利用 RWKV「完形填空/续写强、指令创作弱」的特性 ——
  /// 每轮以「前文尾部」为前缀**并发发起 N 份续写**，按
  /// 长度达标 / 段落复读 / 大纲污染 / 与前文重复度 打分择优后再续写。
  /// 把「一次赌运气」变成「N 选 1」，直接吃掉单次方差。
  beam,

  /// 组长 + 9 位偏向写手**并行** + 组长验收/拼接（旧工艺，保留兼容）。
  ///
  /// ⚠ 这是**唯一**「章内并行」的工艺：9 位写手各自独享一条（本章）state 链，
  /// 所以并发写同一 session 的风险不存在，但它与「单张章节内容走串行」的编排
  /// 拓扑不一致 —— 新项目建议用 [duo]（默认）或 [beam]。
  team,
}

/// 多智能体写书向导配置（用户在开始前填写）。
class MultiAgentBookConfig {
  /// 书籍名称（用户指定，不再由模型自命名）。
  final String bookTitle;

  /// 作者署名（写进项目设置与主大纲提示词）。
  final String authorName;

  /// 初始目标分卷数。
  final int targetVolumes;

  /// 每卷目标章节数。
  final int chaptersPerVolume;

  /// 固定编制 10（1 组长 + 9 写手），用户不可再配置（历史字段保留兼容）。
  final int subAgentCount;

  /// 并行章节数（N = N 个章节团队并行写 N 章）。
  final int concurrency;

  /// 定稿质量闸：整章正文字数低于该值不得标记「已完成」，按草稿保存。
  final int minFinalWords;

  /// 定稿质量闸：段落级重复率上限（[0,1]）。超过则触发组长删重定稿，
  /// 仍超限则按草稿保存 —— 专治 RWKV7-G1J 长文整段复读。
  final double maxRepeatRatio;

  /// 写作工艺：单笔直书 / 主笔分段串行（推荐）/ 组长+9 写手（旧工艺）。
  final WritingCraft craft;

  /// 本次生成使用的**拆书文风规则集 id**（空 = 不注入文风约束）。
  ///
  /// 为什么挂在 config 上而不是只按项目查：一键生成会**新建**一个项目，
  /// 那时项目还没有「启用规则」可言；「用《众仙俯首》的文风写我这本书」
  /// 必须能在开写前选定，所以规则集是**本次生成**的参数。
  /// 项目级启用映射（`StyleRuleLibrary.active`）只作为界面里的默认值。
  final String styleRuleSetId;

  const MultiAgentBookConfig({
    required this.bookTitle,
    required this.authorName,
    this.targetVolumes = 3,
    this.chaptersPerVolume = 10,
    this.subAgentCount = kChapterTeamSize,
    this.concurrency = 10,
    // 单篇篇幅配套：目标 4200 字，下限放宽到 3200 字。
    // （旧下限 4000 与「清洗后自然损耗」只差一点点，导致大量“差一点”失败；
    //   4200 目标 / 3200 下限后，正文仍是 3000+ 字的完整章节。）
    this.minFinalWords = 3200,
    this.maxRepeatRatio = 0.5,
    this.craft = WritingCraft.beam,
    this.styleRuleSetId = '',
  });

  /// 写手数量（固定 9）。
  int get writerCount => kWriterCount;

  /// 每章目标字数（正文体量基准）。
  ///
  /// **单篇篇幅由本框架定**：结合 7.2B 的稳定区间与可读性取 **4200 字/章**
  ///（≈ 6 段 × 800 字的续写优选轮次）。依据：
  /// - 单次生成超过 ~3000 字即开始退化 ⇒ 必须靠多段拼接，不能一次成型；
  /// - 段目标 800 字落在零复读区间（实测 para_rep 恒为 0.000）；
  /// - 6 段可在 8~10 轮内稳妥收敛，轮数再多成功率反而下降。
  int get chapterWordTarget => 4200;

  /// 校验并钳制非法输入（书名/作者为空返回错误文案，数值越界直接钳制）。
  ({String? error, MultiAgentBookConfig normalized}) normalize() {
    final String title = bookTitle.trim();
    final String author = authorName.trim();
    if (title.isEmpty) {
      return (error: '书籍名称不能为空', normalized: this);
    }
    if (author.isEmpty) {
      return (error: '作者署名不能为空', normalized: this);
    }
    return (
      error: null,
      normalized: MultiAgentBookConfig(
        bookTitle: title,
        authorName: author,
        targetVolumes: targetVolumes.clamp(1, 50),
        chaptersPerVolume: chaptersPerVolume.clamp(1, 200),
        // 固定编制：任何输入都强制 1 组长 + 9 写手（修复「单章节分配超过
        // 十个智能体」——此前允许钳制到 32）。
        subAgentCount: kChapterTeamSize,
        // 并发语义（2026-09-29 用户实测后修订）：并发 N = N 个章节团队并行写
        // N 章（每队固定 1 组长 + 9 写手）。范围 1~9999；实际并行道数还会被
        // 章节数收口，模型调用受全局在途闸（32）保护。
        concurrency: concurrency.clamp(1, 9999),
        minFinalWords: minFinalWords.clamp(200, 20000),
        maxRepeatRatio: maxRepeatRatio.clamp(0.1, 0.95),
        craft: craft,
        styleRuleSetId: styleRuleSetId.trim(),
      ),
    );
  }
}

/// 组长分派给写手的段落任务。
class SectionPlan {
  final int agent;
  final String title;
  final String brief;
  final String boundary;
  final int wordTarget;

  /// 组长指定的写手偏向 id（可空 —— 空时按关键词匹配 / 槽位顺序兜底）。
  final String personaId;

  const SectionPlan({
    required this.agent,
    required this.title,
    required this.brief,
    required this.boundary,
    required this.wordTarget,
    this.personaId = '',
  });
}

/// 组长验收中的单段判定。
class ParagraphVerdict {
  final int agent;
  final bool accepted;
  final String problems;

  const ParagraphVerdict({
    required this.agent,
    required this.accepted,
    this.problems = '',
  });
}

/// 组长验收报告（含章节档案四段描述与待更新项）。
class TeamAcceptance {
  final List<ParagraphVerdict> verdicts;
  final String timeRange;
  final String themeTask;
  final String gainsLosses;
  final String safeguards;
  final List<Map<String, Object?>> updateItems;

  const TeamAcceptance({
    this.verdicts = const <ParagraphVerdict>[],
    this.timeRange = '',
    this.themeTask = '',
    this.gainsLosses = '',
    this.safeguards = '',
    this.updateItems = const <Map<String, Object?>>[],
  });

  bool get allAccepted =>
      verdicts.isEmpty || verdicts.every((ParagraphVerdict v) => v.accepted);
}

/// 多智能体写书结果（结构化成败，不靠 message 猜）。
class MultiAgentBookResult {
  const MultiAgentBookResult({
    required this.isSuccess,
    required this.message,
    required this.bookTitle,
    required this.authorName,
    required this.projectId,
    this.projectCreated = false,
    this.mainOutlineSaved = false,
    this.volumesPlanned = 0,
    this.chapterOutlinesPlanned = 0,
    this.chaptersWritten = 0,
    this.chaptersPlanned = 0,
    this.failureStep,
    this.warnings = const <String>[],
    this.mainOutlineText = '',
  });

  final bool isSuccess;
  final String message;
  final String bookTitle;
  final String authorName;
  final String projectId;
  final bool projectCreated;
  final bool mainOutlineSaved;
  final int volumesPlanned;
  final int chapterOutlinesPlanned;
  final int chaptersPlanned;
  final int chaptersWritten;
  final String? failureStep;
  final List<String> warnings;
  final String mainOutlineText;
}

/// 团队内单个智能体的独享 state 通道。
///
/// 每次发送 = system prompt + 该智能体自己的累积历史 + 新 user 消息；
/// 成功产出后 user/assistant 落回自己的历史（失败不污染 state）。
/// 组长与写手、写手与写手之间互不共享 —— state 独享由结构保证。
///
/// ⚠ 复读修复（RWKV7-G1J 长文实测）：
/// RWKV 是 RNN，**上下文里出现过的 n-gram 会持续抬高自身采样概率**。
/// 旧实现让写手通道累积历史，而一名写手常被派到同一章的多个段落 ——
/// 模型看到自己刚写的上一段，就会把句式/情节整段搬回来，
/// 这是「同一章内段落重复率 85%+」的主要结构性来源。
/// 因此正文类通道（写手）走 [keepHistory] = false：**每段独立生成**
///（提示词本身已自带大纲与段落任务，不依赖历史）；
/// 组长通道保留多轮上下文，但只回灌最近 [_kMaxHistoryMessages] 条，
/// 防止把整章草稿反复塞回上下文。
class _AgentChannel {
  _AgentChannel(
    this.entry,
    this.systemPrompt,
    this._chat, {
    this.keepHistory = true,
    this.sessionKeyPrefix = '',
  });

  final AgentStateEntry entry;
  final String systemPrompt;
  final AgentChatExecutor _chat;

  /// 是否累积/回灌本通道历史。正文写手置 false（每段独立，防自我复读）。
  final bool keepHistory;

  /// 客户端 state 会话前缀（项目 id / 大纲分组名）；空串 = 不启用客户端 state。
  ///
  /// 最终下发的 key = `'$sessionKeyPrefix::${entry.agentId}'` —— 于是
  /// 「组长」「写手 3」在**同一项目**内各自拥有一条由客户端持有的 state 链
  /// （RWKV 的 O(1) 上下文接续），跨章节累积世界观记忆，并发写多章互不串味。
  /// 服务端不再需要猜「哪个 state 对应哪个并发」—— 会话 ID 由客户端生成并持久化。
  final String sessionKeyPrefix;

  String? get _sessionKey {
    final String prefix = sessionKeyPrefix.trim();
    return prefix.isEmpty ? null : '$prefix::${entry.agentId}';
  }

  /// ⚠ 客户端 state 会话的硬约束：**同一个 session 绝不能并发写**。
  /// 凡是「同一通道并发发起多次」的调用点（续写优选的 N 份候选就是典型的），
  /// 必须传 `isolated: true` 走**无状态链路** —— 否则要么候选之间互相污染
  /// （第 1 份的产出被写进 state，第 2 份带着它继续写，「独立候选」名存实亡），
  /// 要么被台账 `runExclusive` 排成串行、白白损失并发。
  ///
  /// 单通道**串行**的调用点（主笔分段续写、单笔直书）不需要隔离，保留 state 会话。

  /// 组长通道回灌的历史条数上限（user+assistant 各算一条）。
  static const int _kMaxHistoryMessages = 8;

  String get agentId => entry.agentId;

  Future<String> send(
    String userPrompt, {
    required int maxTokens,
    double temperature = 0.85,
    bool isolated = false,
  }) async {
    final List<ChatMessage> history = !keepHistory
        ? const <ChatMessage>[]
        : (entry.history.length > _kMaxHistoryMessages
              ? entry.history.sublist(
                  entry.history.length - _kMaxHistoryMessages,
                )
              : entry.history);
    final List<ChatMessage> messages = <ChatMessage>[
      ...history,
      ChatMessage.user(userPrompt),
    ];
    final String out = await _chat(
      systemPrompt,
      messages,
      maxTokens: maxTokens,
      temperature: temperature,
      sessionKey: isolated ? null : _sessionKey,
    );
    if (out.trim().isEmpty) return '';
    if (keepHistory) {
      entry.history
        ..add(ChatMessage.user(userPrompt))
        ..add(ChatMessage.assistant(out));
    }
    entry
      ..turns = entry.turns + 1
      ..lastActivityMs = DateTime.now().millisecondsSinceEpoch
      ..status = AgentStateStatus.active;
    return out;
  }
}

/// 多智能体协同写书服务。
class MultiAgentBookGenerationService {
  MultiAgentBookGenerationService({
    required this.projects,
    required this.plots,
    required this.volumes,
    required this.chapters,
    required this.writingProvider,
    this.planningProvider,
    this.postProcess,
    AgentStateManager? stateManager,
    this.chatExecutor,
    this.planningChatExecutor,
    this.mainModel = '',
    this.subModel = '',
    this.archiveHook,
    this.updateDispatch,
    this.exportService,
    this.profileSynthesizer,
    this.styleRuleResolver,
    this.chapterRewriter,
    this.promptTemplates,
  }) : stateManager = stateManager ?? AgentStateManager();

  final ProjectRepository projects;
  final WritingPromptTemplates? promptTemplates;

  String _renderPrompt(String stage, Map<String, String> values) =>
      (promptTemplates ?? WritingPromptTemplates.defaults()).render(
        stage,
        values,
      );

  /// 按规则集 id 解析出要注入的文风块（解析不到则两个都留空）。
  void _resolveStyleBlocks(String id) {
    _activeStyleBlock = '';
    _activeStyleBlockBrief = '';
    if (id.trim().isEmpty) return;
    final StyleRuleSet? set = styleRuleResolver?.call(id.trim());
    if (set == null || !set.isUsable) return;
    _activeStyleBlock =
        set.toPromptBlock(maxChars: styleBlockMaxChars).trim();
    _activeStyleBlockBrief =
        set.toPromptBlockBrief(maxChars: styleBlockBriefMaxChars).trim();
  }

  /// 注入提示词的「文风要求」整段文本。
  ///
  /// 空规则集时返回**空串**（不是空标题）：`{{styleRules}}` 在提示词正文里
  /// 单独占一行，替换为空串只会留下一个空行，无害。
  ///
  /// [brief] 用精简版（只给「别用什么词 / 句子多长 / 对白多少 / 视角在哪」）——
  /// 专供 [WritingCraft.beam] 的候选提示词，那段提示词**必须保持极简**
  /// （越像一段被截断的小说，产出越像小说）。
  String _styleSection({bool brief = false}) {
    final String block = brief ? _activeStyleBlockBrief : _activeStyleBlock;
    if (block.isEmpty) return '';
    return brief
        ? '【文风要求（摘要）】\n$block'
        : '【文风要求（必须遵守，优先于你个人的表达习惯）】\n$block';
  }
  final PlotRepository plots;
  final VolumeRepository volumes;
  final ChapterRepository chapters;

  /// 写作 provider（双代理配置的 SubAgent provider；本地或云端均可）。
  final IModelProvider? Function() writingProvider;

  /// 主编模型；未配置时兼容旧流程，复用写手模型。
  final IModelProvider? Function()? planningProvider;
  final String mainModel;
  final String subModel;

  /// 每章落库后的联动同步（可空 —— 离线测试不装配）。
  final ChapterPostProcessService? postProcess;

  /// 智能体 state 分组管理（与健康页快照共享同一实例时可在运行期观察）。
  final AgentStateManager stateManager;

  /// 注入式聊天执行器（测试打桩；为空时按 writingProvider 构建）。
  final AgentChatExecutor? chatExecutor;
  final AgentChatExecutor? planningChatExecutor;

  /// 写作档案钩子（项目/分卷/章节三档；失败只记 warning）。
  final TeamArchiveHook? archiveHook;

  /// 验收后更新分派（可空 —— 未装配时跳过更新分派阶段）。
  final TeamUpdatesDispatcher? updateDispatch;

  /// 章节结构化导出（可空 —— 未装配时不落盘；失败折叠为 warning）。
  final ChapterExportService? exportService;

  /// 分卷档案归纳（可空 —— 未装配时跳过；失败只记 warning）。
  ///
  /// 全部章节写完后按卷各跑一次，把逐章累积的设定流水（`ModuleStateService`
  /// 写进实体 `history` 列的流水账）收敛成稳定档案。**必须放在章节池之后**：
  /// 章节是并行写的，池子没结束就不知道哪一卷写完了。
  final EntityProfileSynthesizer? profileSynthesizer;

  /// 章节自动重写（可空 —— 未装配时跳过「失败章补写」阶段）。
  ///
  /// 用户 2026-10-09 明确要求：**所有章节完成后**，对质量校验失败的章节
  /// 自动按上下文（前章结尾 + 本章大纲 + 下章开头）重写一遍。
  ///
  /// 复用 `ChapterRewriteService`（与「章节管理 → 单章重写」同一实现），
  /// 而不是在这里另写一套提示词 —— 两处对「什么叫合格正文」必须只有一套口径。
  final ChapterRewriteService? chapterRewriter;

  /// 拆书文风规则集解析器（按 id 取规则集；可空 —— 未装配时等同于不注入）。
  ///
  /// 由 DI 注入（读全局 `StyleRuleLibrary`）。用「id → 规则集」的回调而不是
  /// 直接持有规则库，是为了让本服务对存储层零依赖（离线测试可以不装配）。
  final StyleRuleSet? Function(String id)? styleRuleResolver;

  /// 本次生成要注入的文风规则块（`generate()` 开始时定好，之后只读）。
  ///
  /// 为什么要用可变字段而不是逐层传参：注入点分布在 5 个提示词构造函数里，
  /// 其中 `_soloChapterPrompt` / `_serialSegmentPrompt` 的签名里没有 `cfg`，
  /// 逐层加参数会改动十余处调用点，收益只是「更函数式」。
  ///
  /// ⚠ 前提是**同一实例同一时刻只跑一次生成**。UI 侧「一键生成书籍 / 开始写作」
  /// 是模态推进的，不满足并发条件时也会各自新建服务实例；如果将来要做
  /// 「多本书同时后台生成」，必须改成逐层传参。
  String _activeStyleBlock = '';

  /// 精简版文风块（供续写优选候选提示词，见 [_styleSection] 的 `brief`）。
  String _activeStyleBlockBrief = '';

  /// 一次生成注入的文风规则块长度上限。
  ///
  /// 这段文本会进**每一章**的写作/大纲提示词，1600 字在 4200 字/章的体量下
  /// 已是可观开销；再长就开始挤压大纲与上文衔接的上下文。
  static const int styleBlockMaxChars = 1600;

  /// 精简版上限 —— 续写优选候选提示词能容忍的额外文本量（约 4 行）。
  static const int styleBlockBriefMaxChars = 700;

  /// 整个流程不抛异常；进度经 [onProgress]（step 文案 + 0..1 进度）；
  /// 章节级实时进度经 [onChapterEvent]（写作动态矩阵面板消费）。
  Future<MultiAgentBookResult> generate({
    required MultiAgentBookConfig config,
    void Function(String step, double? progress)? onProgress,
    MultiAgentChapterListener? onChapterEvent,
  }) async {
    final List<String> warnings = <String>[];
    final ({String? error, MultiAgentBookConfig normalized}) norm = config
        .normalize();
    if (norm.error != null) {
      return MultiAgentBookResult(
        isSuccess: false,
        message: norm.error!,
        bookTitle: config.bookTitle,
        authorName: config.authorName,
        projectId: '',
      );
    }
    final MultiAgentBookConfig cfg = norm.normalized;

    // ---- 文风规则（拆书产物）----
    //
    // 在流程最前面定好，后面所有提示词只读 [_activeStyleBlock]。
    // 解析不到（id 为空 / 规则集已被删 / 规则集为空）时一律留空串 ——
    // 注入一段「【文风要求】」却没有任何内容，比不注入更糟：模型会把空标题
    // 当成约束去猜。
    _resolveStyleBlocks(cfg.styleRuleSetId);

    // ---- 0. 聊天执行器（注入优先；否则按 provider 构建并先探活）----
    onProgress?.call('正在检查写作模型服务…', null);
    final AgentChatExecutor chat;
    final AgentChatExecutor planningChat;
    bool useG1kPair = false;
    RwkvCloudProvider? temporaryWriter;
    String resolvedMainModel = mainModel;
    String resolvedSubModel = subModel;
    if (chatExecutor != null) {
      chat = chatExecutor!;
      planningChat = planningChatExecutor ?? chat;
    } else {
      final IModelProvider? provider = writingProvider();
      if (provider == null) {
        return _fail(
          cfg,
          'provider',
          '没有配置双代理 SubAgent 写作模型，请先在「AI 配置」完成配置并注册。',
        );
      }
      if (!(await provider.testConnection()).isSuccess) {
        return _fail(
          cfg,
          'provider',
          '写作模型服务不可用（testConnection 失败），请检查「AI 配置」。',
        );
      }
      final IModelProvider planner = planningProvider?.call() ?? provider;
      if (!identical(planner, provider) &&
          !(await planner.testConnection()).isSuccess) {
        return _fail(cfg, 'provider', 'MainAgent 大纲模型服务不可用，请检查「AI 配置」。');
      }
      final bool requestedPair =
          identical(planner, provider) &&
          provider is RwkvCloudProvider &&
          RegExp(r'g1k.*7\.2b', caseSensitive: false).hasMatch(mainModel) &&
          RegExp(r'g1k.*2\.9b', caseSensitive: false).hasMatch(subModel);
      if (requestedPair) {
        final RwkvCloudProvider cloud = provider;
        if (Uri.tryParse(cloud.configuration.baseUrl)?.host !=
            'api-7b.rwkvos.com') {
          return _fail(cfg, 'provider', 'MainAgent 必须配置到官方 api-7b 端点。');
        }
        resolvedMainModel =
            resolveG1kModel(
              mainModel,
              (await cloud.getAvailableModels()).map((m) => m.id),
            ) ??
            '';
        if (resolvedMainModel.isEmpty) {
          return _fail(cfg, 'provider', '7B 端点无法唯一匹配 MainAgent 模型 $mainModel。');
        }
        final headers = cloud.configuration.customHeaders;
        // ⚠ 必须**继承** DI 里那个 `cloud` 的台账与开关：
        // 章节正文走的正是这个临时 provider（2.9B 端点），旧代码 `RwkvCloudProvider()`
        // 是裸构造 —— `sessionLedger = null` + `clientStateEnabled = false`，
        // 于是「BUG 2 客户端 state」只在规划链路（7.2B）生效，
        // **真正的写书主链路反而退化成每轮全量重发**。
        // 台账可以安全共用：会话键里带了端点 host（provider 侧兜底）、
        // `::plan` / `::chapter::<章id>` 作用域与角色名，两个端点不会撞到同一条会话。
        temporaryWriter = RwkvCloudProvider(
          sessionLedger: cloud.sessionLedger,
          clientStateEnabled: cloud.clientStateEnabled,
        );
        final bool ready = await temporaryWriter.initialize(
          RwkvCloudConfiguration(
            baseUrl: kG1kWriterBaseUrl,
            defaultModel: subModel,
            cfAccessClientId: headers[kHeaderCfAccessClientId] ?? '',
            cfAccessClientSecret: headers[kHeaderCfAccessClientSecret] ?? '',
            timeoutSeconds: cloud.configuration.timeoutSeconds,
          ),
        );
        if (!ready) {
          temporaryWriter.dispose();
          return _fail(cfg, 'provider', 'SubAgent 2.9B 云端服务不可用，请检查 3B 端点及鉴权。');
        }
        resolvedSubModel =
            resolveG1kModel(
              subModel,
              (await temporaryWriter.getAvailableModels()).map((m) => m.id),
            ) ??
            '';
        if (resolvedSubModel.isEmpty) {
          temporaryWriter.dispose();
          return _fail(cfg, 'provider', '3B 端点未找到 SubAgent 模型 $subModel。');
        }
      }
      final IModelProvider writer = temporaryWriter ?? provider;
      chat = _buildProviderExecutor(writer, model: resolvedSubModel);
      planningChat = _buildProviderExecutor(planner, model: resolvedMainModel);
      useG1kPair =
          writer is RwkvCloudProvider &&
          planner is RwkvCloudProvider &&
          RegExp(r'g1k.*2\.9b', caseSensitive: false).hasMatch(
            subModel.isEmpty ? writer.configuration.defaultModel : subModel,
          ) &&
          RegExp(r'g1k.*7\.2b', caseSensitive: false).hasMatch(
            mainModel.isEmpty ? planner.configuration.defaultModel : mainModel,
          );
    }

    // ---- 1. 规划组 state + 主线大纲（规划组组长）----
    final AgentStateGroup planning = stateManager.activateGroup(
      label: '${cfg.bookTitle}·大纲规划组',
    );
    try {
      // 规划组会话前缀 = 书名 + `plan` 作用域。
      //
      // ⚠ 这里**只能**用 `cfg.bookTitle`：项目是在「主线大纲产出之后」才创建的
      // （见下面第 2 步 `_createProject`），规划阶段拿不到 `projectId`。
      // 用书名是安全的 —— `_createProject` 对同名项目走「复活复用」，
      // 所以同一本书重复生成会命中同一条规划会话，记忆得以延续。
      //
      // 刻意与章节写作组（`$projectId::chapter`）分开：两者都有名为 `leader`
      // 的角色，共用一个前缀会把「大纲规划主智能体」和「章节写作组长」混成
      // 同一条 state 链。
      final String planPrefix = '${cfg.bookTitle}::plan';
      final _AgentChannel mainAgent = _planningLeaderChannel(
        planningChat,
        planning,
        sessionKeyPrefix: planPrefix,
      );
      final List<_AgentChannel> planners = _planningWriterChannels(
        planningChat,
        planning,
        sessionKeyPrefix: planPrefix,
      );

      onProgress?.call('主智能体正在规划主线大纲…', 0.02);
      final String mainOutline = await mainAgent.send(
        _mainOutlinePrompt(cfg),
        maxTokens: 6000,
      );
      if (mainOutline.isEmpty) {
        return _fail(
          cfg,
          'outline',
          '主线大纲生成失败：${lastChatDiagnostic.isEmpty ? '模型返回为空' : lastChatDiagnostic}',
        );
      }

      // ---- 2. 建项目 + 主线大纲落库 + 项目档案 ----
      onProgress?.call('正在创建书籍项目…', 0.08);
      final ({String id, String name, bool adjusted, bool revived}) created =
          await _createProject(cfg);
      final String projectId = created.id;
      final String projectName = created.name;
      if (created.revived) {
        warnings.add(
          '检测到已被删除的同名项目「${created.name}」，已复活复用该条目'
          '（原关联数据在删除时已清理）',
        );
      } else if (created.adjusted) {
        warnings.add('已存在同名项目「${cfg.bookTitle}」，本次创建为「${created.name}」');
      }
      try {
        await plots.create(
          PlotsCompanion.insert(
            id: _uuid.v4(),
            title: '${cfg.bookTitle}·主线大纲',
            type: '主线',
            projectId: projectId,
            status: const Value('进行中'),
            priority: const Value('高'),
            description: Value('作者：${cfg.authorName}'),
            outline: Value(mainOutline),
          ),
        );
      } on Object catch (e) {
        warnings.add('主线大纲落库失败：$e');
      }
      await _emitArchive(
        warnings,
        level: 'project',
        projectId: projectId,
        title: cfg.bookTitle,
        content: mainOutline,
        metadata: <String, String>{
          'timeRange': _fmtDate(DateTime.now()),
          'themeTask':
              '《${cfg.bookTitle}》主线大纲编制'
              '（目标 ${cfg.targetVolumes} 卷 × ${cfg.chaptersPerVolume} 章）',
          'gainsLosses': '主线大纲 ${mainOutline.length} 字定稿，项目与团队编制（1组长+9写手）建立',
          'safeguards': '分卷/章节创作须贴合主线大纲，冲突时以主线为准并在档案中记录取舍',
        },
      );

      // ---- 3. 分卷大纲（写手并行 + 空结果重试，修复「未按预期写入全部大纲」）----
      onProgress?.call(
        '规划组 $kWriterCount 位写手并行规划 ${cfg.targetVolumes} 卷大纲'
        '（空结果自动重试）…',
        0.12,
      );
      // 支线大纲（分卷 / 章节）走**并行**，且**每个并发道固定绑一条写手通道**：
      // `lanes` 个 worker 各自占住 `planners[lane]`，同一时刻任一通道只被一个道
      // 使用 —— 这是「同一 session 绝不并发写」在**排程层**的保证（台账的
      // `runExclusive` 只是兜底）。所以池宽可以就等于规划写手数（9）。
      //
      // ⚠ 不能按「任务序号 % 通道数」轮转：章节大纲的序号是**卷内序号**
      // （每卷都从 1 重新数），池宽 9 时第 10 个任务就会退回通道 0，
      // 与仍在飞行中的第 1 个任务撞同一条会话。
      final int outlineWorkers = AgentStateManager.quantizeConcurrency(
        cfg.concurrency,
      ).clamp(1, planners.length);
      final List<String> volumeOutlines = await _runPoolIndexed<int, String>(
        outlineWorkers,
        [for (int i = 1; i <= cfg.targetVolumes; i++) i],
        (int i, int lane) => _volumeOutlineWithRetry(
          planningChat,
          planners,
          cfg,
          mainOutline,
          i,
          lane,
        ),
      );

      // ---- 4. 分卷落库 + 分卷档案 ----
      onProgress?.call('正在写入分卷与分卷大纲…', 0.3);
      final List<VolumeRow> volumeRows = <VolumeRow>[];
      for (int i = 0; i < volumeOutlines.length; i++) {
        final String outline = volumeOutlines[i];
        final String vid = _uuid.v4();
        await volumes.create(
          VolumesCompanion.insert(
            id: vid,
            title: '第${_cn(i + 1)}卷',
            projectId: projectId,
            orderIndex: Value(i + 1),
            status: const Value('Planning'),
            description: Value(outline.isEmpty ? '' : _truncate(outline, 950)),
          ),
        );
        final VolumeRow? row = await volumes.getById(vid);
        if (row != null) volumeRows.add(row);
        await _emitArchive(
          warnings,
          level: 'volume',
          projectId: projectId,
          title: '第${_cn(i + 1)}卷',
          content: outline,
          metadata: <String, String>{
            'timeRange': '第${_cn(i + 1)}卷（全卷 ${cfg.chaptersPerVolume} 章）',
            'themeTask': outline.isEmpty
                ? '本卷大纲生成失败，待手动补写'
                : _firstLine(outline, 80),
            'gainsLosses': outline.isEmpty
                ? '并行生成 3 次仍未产出，需人工介入'
                : '分卷大纲 ${outline.length} 字已生成并落库',
            'safeguards': outline.isEmpty
                ? '后续章节按主线大纲该卷推进脉络兜底创作，补写大纲后校准'
                : '章节创作不得与本卷卷首/卷末状态冲突',
          },
        );
        if (outline.isEmpty) {
          warnings.add(
            '第 ${i + 1} 卷大纲生成失败（已重试 3 次）：'
            '${lastChatDiagnostic.isEmpty ? '模型返回为空' : lastChatDiagnostic}'
            '；已创建空卷（可手动补写大纲）。',
          );
        }
      }
      if (volumeRows.isEmpty) {
        return _fail(cfg, 'volume', '分卷创建失败。', projectId: projectId);
      }

      // ---- 5. 章节大纲（写手并行池轮转）----
      final int totalChapters = volumeRows.length * cfg.chaptersPerVolume;
      onProgress?.call('规划组写手继续并行规划 $totalChapters 个章节大纲…', 0.34);
      final List<(VolumeRow, int)> chapterSlots = <(VolumeRow, int)>[
        for (final VolumeRow v in volumeRows)
          for (int c = 1; c <= cfg.chaptersPerVolume; c++) (v, c),
      ];
      final List<String> chapterOutlines =
          await _runPoolIndexed<(VolumeRow, int), String>(
            outlineWorkers,
            chapterSlots,
            ((VolumeRow, int) slot, int lane) => _chapterOutlineChat(
              planners,
              cfg,
              mainOutline,
              volumeOutlines[volumeRows.indexOf(slot.$1)],
              slot.$2,
              lane,
            ),
          );

      // ---- 5.2 章名统一整理 ----
      //
      // `Book/chapterOutline` 要求第一行输出「标题：《章名》」，但小模型经常
      // 给成单行无换行的元信息大杂烩（`第4章：地下交易标题：血色契约【本章目标】…`）
      // 或整段散文。旧实现只截首行 20 字，导致全书标题变成碎片（用户实测）。
      // 这里先走纯解析器；解析不出「像章名」的结果时，**一次批量调用**请规划
      // 模型统一命名（1 次调用覆盖全书的坏章名，不是每章一次）。
      final Set<String> forbiddenNames = <String>{
        cfg.bookTitle.trim(),
        for (int i = 0; i < volumeRows.length; i++) '第${_cn(i + 1)}卷',
      };
      final List<ChapterNameResult> resolvedNames = <ChapterNameResult>[
        for (final String outline in chapterOutlines)
          ChapterTitleParser.extractName(
            outline,
            forbidden: forbiddenNames,
          ),
      ];
      final List<int> unnamed = <int>[
        for (int i = 0; i < resolvedNames.length; i++)
          if (resolvedNames[i].isEmpty || !resolvedNames[i].reliable) i,
      ];
      if (unnamed.isNotEmpty) {
        onProgress?.call(
          '${unnamed.length} 个章节名格式不规范，正在统一整理…',
          0.50,
        );
        final Map<int, String> synthesised = await _synthesiseChapterNames(
          chat: planningChat,
          cfg: cfg,
          outlines: chapterOutlines,
          indices: unnamed,
          slots: chapterSlots,
          volumes: volumeRows,
        );
        for (final MapEntry<int, String> e in synthesised.entries) {
          final String cleaned = ChapterTitleParser.cleanFragment(
            e.value,
            maxChars: 14,
          );
          if (cleaned.isEmpty || !ChapterTitleParser.isReliableName(cleaned)) {
            continue;
          }
          resolvedNames[e.key] = ChapterNameResult(cleaned, reliable: true);
        }
      }

      // ---- 6. 章节大纲落库（查重：同卷同序号/同标题复用既有行，不重复创建）----
      onProgress?.call('正在写入章节大纲…', 0.55);
      final List<ChapterRow> outlineRows = <ChapterRow>[];
      for (int i = 0; i < chapterSlots.length; i++) {
        final (VolumeRow vol, int cIdx) = chapterSlots[i];
        final String outline = chapterOutlines[i];
        // 章节名必须自带卷号：各卷都从「第一章」重排编号，只写章号在全书
        // 视图里完全无法区分（用户实测痛点）。章名由上面的解析/整理步骤给出。
        final int vIdx = volumeRows.indexOf(vol);
        final String resolved = resolvedNames[i].name ?? '';
        final String name = resolved.isEmpty ? '第${_cn(cIdx)}章' : resolved;
        final String title = '第${_cn(vIdx + 1)}卷·第${_cn(cIdx)}章·《$name》';
        // 梗概只留一句话 —— 章节记录里不放大纲草稿与过程数据。
        final String brief = _chapterBrief(outline, name);
        final List<ChapterRow> existing = await chapters.getByVolumeId(vol.id);
        final ChapterRow? hit = ChapterDedupGuard.findExisting(
          existing: existing,
          orderIndex: cIdx,
          title: title,
        );
        if (hit != null) {
          if (outline.isNotEmpty) {
            await chapters.updateById(
              hit.id,
              ChaptersCompanion(summary: Value(brief), title: Value(title)),
            );
          }
          outlineRows.add(hit);
          continue;
        }
        final String cid = _uuid.v4();
        await chapters.create(
          ChaptersCompanion.insert(
            id: cid,
            volumeId: vol.id,
            title: title,
            projectId: Value(projectId),
            orderIndex: Value(cIdx),
            status: const Value('Draft'),
            summary: Value(brief),
          ),
        );
        final ChapterRow? row = await chapters.getById(cid);
        if (row != null) outlineRows.add(row);
        if (outline.isEmpty) {
          warnings.add('《$title》（${vol.title}）大纲生成失败，写作团队将依据主线与分卷大纲直接成稿。');
        }
      }

      // ---- 7. 章节写作团队（并发 N = N 个团队并行写 N 章）----
      final Map<String, String> volumeTitleById = <String, String>{
        for (final VolumeRow v in volumeRows) v.id: v.title,
      };
      void emitChapter(
        ChapterRow ch,
        MultiAgentChapterPhase phase,
        double progress,
        String detail,
      ) => onChapterEvent?.call(
        MultiAgentChapterEvent(
          chapterId: ch.id,
          chapterTitle: ch.title,
          volumeTitle: volumeTitleById[ch.volumeId] ?? '',
          phase: phase,
          progress: progress,
          detail: detail,
        ),
      );
      // 矩阵初始态：全部章节入队
      for (final ChapterRow ch in outlineRows) {
        emitChapter(ch, MultiAgentChapterPhase.queued, 0, '排队等待写作团队');
      }
      // 全书编排拓扑（用户 2026-10-07 定的方案，也是最适合 RWKV state 机制的路子）：
      //
      //   主线大纲   ── 串行：规划组 `leader` 单链，一次调用产出全书骨架
      //   支线大纲   ── 并行：规划组 9 位写手通道轮转派活（池宽 ≤ 通道数）
      //   单章内容   ── 串行：每章各自一条 state 链，段与段之间严格串行
      //   全书章节   ── 并行：`lanes` 个写作团队同时开工，章间零依赖
      //
      // `cfg.concurrency` 的语义就是**并行章节团队数**（见 UI：MAG.Concurrency
      // 「并行章节数（每章 1 个写作团队）」/「填章节数即可全部并行」）。
      // 章级并行 + 章内串行 + 章级独立 state 链（[chapterPrefix]）三者合起来，
      // 既吃到了 RWKV 的 O(1) 上下文接续，又不让任一章拖住其他章。
      final int lanes = cfg.concurrency.clamp(
        1,
        outlineRows.isEmpty ? 1 : outlineRows.length,
      );
      // 进度文案要跟着工艺走：`team` 才有「1 组长 + 9 写手」，
      // `duo`/`solo`/`beam` 都是**单主笔**（这正是「单章内容串行」的形态）。
      final String teamShape = switch (cfg.craft) {
        WritingCraft.team => '每章 1 组长 + 9 偏向写手',
        WritingCraft.beam => '每章 1 主笔（续写优选）',
        WritingCraft.duo => '每章 1 主笔（分段串行）',
        WritingCraft.solo => '每章 1 主笔（单笔直书）',
      };
      onProgress?.call(
        '激活 $lanes 个章节流水线并行写作（$teamShape，每章一条 state 链）…',
        0.56,
      );
      int written = 0;
      int teamStarted = 0;
      final List<({int order, String title, String status, int wordCount})>
      exportedChapters =
          <({int order, String title, String status, int wordCount})>[];
      final List<(ChapterRow, int)> teamSlots = <(ChapterRow, int)>[
        for (int i = 0; i < outlineRows.length; i++) (outlineRows[i], i),
      ];
      await _runPool<(ChapterRow, int), void>(lanes, teamSlots, (
        (ChapterRow, int) slot,
      ) async {
        final (ChapterRow ch, int seq) = slot;
        final AgentStateGroup team = stateManager.activateGroup(
          label: '《${ch.title}》写作团队',
        );
        void emit(MultiAgentChapterPhase phase, double p, String detail) =>
            emitChapter(ch, phase, p, detail);
        try {
          teamStarted++;
          final int started = teamStarted;
          onProgress?.call(
            '写作团队《${ch.title}》开工'
            '（${(started / outlineRows.length * 100).round()}% 章节已开队）…',
            0.56 +
                0.42 *
                    ((started - 1) /
                        (outlineRows.isEmpty ? 1 : outlineRows.length)),
          );
          // 章节写作会话前缀 = 项目 + **章** + `chapter` 作用域：
          // `'$chapterPrefix::${entry.agentId}'` → 每章每个角色各一条 state 链。
          //
          // 为什么粒度落到「章」而不是「项目」（用户 2026-10-07 定的编排拓扑：
          // **主线大纲走串行 / 支线大纲走并行 / 单张章节内容走串行 /
          // 所有章节可以同时并行开始**）：
          //   * 本项目是**章级并行**（`lanes` 个写作团队同时开工），而 RWKV 的
          //     state 是**单条可变递归状态**，一个 session 同一时刻只能有一条链；
          //   * 若把粒度放到「项目 × 角色」（一条链贯穿全书），`duo`/`solo`
          //     工艺只有 `leader` 一个角色 → 台账 `runExclusive` 会把所有章节
          //     排成一条队 ——「N 章并行」直接退化成**整书严格串行**，
          //     并发参数彻底失效；
          //   * 落到「章 × 角色」后，每章都是一条独立的连续叙事线：章内严格串行
          //     （单张章节内容走串行），章间互不阻塞（所有章节同时并行开始）。
          //     25K 上下文也全部花在**本章**上，而不是被其他章的turn 稀释。
          //   * 跨章一致性不再依赖 state，而依赖**提示词**：主线/分卷/章节大纲
          //     逐章注入，叠加 BUG 3 修好后的「章节验收通过即回写人物履历与
          //     世界观子项」—— 后续章节读到的是被前文更新过的设定档案。
          final String chapterPrefix = '$projectId::chapter::${ch.id}';
          final ({
            String? content,
            TeamAcceptance? acceptance,
            bool shortfall,
            String qualityNote,
            List<ChapterExportSection> sections,
          })
          outcome = await switch (cfg.craft) {
            WritingCraft.team => _writeChapterWithTeam(
              chat: chat,
              team: team,
              sessionKeyPrefix: chapterPrefix,
              cfg: cfg,
              mainOutline: mainOutline,
              volumeOutline:
                  volumeOutlines[volumeRows.indexWhere(
                    (VolumeRow v) => v.id == ch.volumeId,
                  )],
              chapterOutline: chapterOutlines[seq],
              onStep: (String step) => onProgress?.call(step, null),
              onPhase: emit,
            ),
            WritingCraft.beam => _writeChapterBeam(
              chat: chat,
              polishChat: useG1kPair ? planningChat : null,
              team: team,
              sessionKeyPrefix: chapterPrefix,
              cfg: cfg,
              mainOutline: mainOutline,
              volumeOutline:
                  volumeOutlines[volumeRows.indexWhere(
                    (VolumeRow v) => v.id == ch.volumeId,
                  )],
              chapterOutline: chapterOutlines[seq],
              onStep: (String step) => onProgress?.call(step, null),
              onPhase: emit,
            ),
            WritingCraft.duo => _writeChapterSerial(
              chat: chat,
              team: team,
              sessionKeyPrefix: chapterPrefix,
              cfg: cfg,
              mainOutline: mainOutline,
              volumeOutline:
                  volumeOutlines[volumeRows.indexWhere(
                    (VolumeRow v) => v.id == ch.volumeId,
                  )],
              chapterOutline: chapterOutlines[seq],
              onStep: (String step) => onProgress?.call(step, null),
              onPhase: emit,
            ),
            WritingCraft.solo => _writeChapterSolo(
              chat: chat,
              team: team,
              sessionKeyPrefix: chapterPrefix,
              cfg: cfg,
              mainOutline: mainOutline,
              volumeOutline:
                  volumeOutlines[volumeRows.indexWhere(
                    (VolumeRow v) => v.id == ch.volumeId,
                  )],
              chapterOutline: chapterOutlines[seq],
              onStep: (String step) => onProgress?.call(step, null),
              onPhase: emit,
            ),
          };
          String? content = outcome.content;
          if (content != null && FictionQuality.issue(content) != null) {
            onProgress?.call('《${ch.title}》检测到正文污染，正在按段纠偏…', null);
            final repaired = <String>[];
            for (final part in content.split(RegExp(r'\n\s*\n'))) {
              if (FictionQuality.issue(part) == null) {
                repaired.add(part);
                continue;
              }
              final raw = await chat(
                _renderPrompt('Book/repairSystem', {}),
                [
                  ChatMessage.user(
                    _renderPrompt('Book/repair', {
                      'outline': chapterOutlines[seq],
                      'previous': repaired.isEmpty
                          ? ''
                          : _ref(repaired.last, .3),
                    }),
                  ),
                ],
                maxTokens: 1200,
                temperature: 1.0,
              );
              repaired.add(FictionQuality.clean(raw));
            }
            content = repaired.join('\n\n');
            if (FictionQuality.issue(content) != null) {
              warnings.add('《${ch.title}》纠偏后仍有正文污染，拒绝覆盖原稿或同步设定。');
              emit(MultiAgentChapterPhase.failed, 1, '正文质量校验失败，原稿未修改');
              return;
            }
          }
          if (content == null || content.trim().isEmpty) {
            warnings.add('《${ch.title}》团队写作失败（已保留大纲，可重试）。');
            emit(MultiAgentChapterPhase.failed, 1, '团队写作失败（已保留大纲，可重试）');
            return;
          }
          // —— 定稿质量闸：≥ minFinalWords 字才标「已完成」，否则按草稿保存 ——
          final bool shortfall = _qualityNote(content, cfg).isNotEmpty;
          await chapters.updateById(
            ch.id,
            ChaptersCompanion(
              content: Value(content),
              wordCount: Value(content.trim().length),
              status: Value(shortfall ? 'Draft' : 'Completed'),
              lastEditedAt: Value(DateTime.now()),
              versionNumber: Value(ch.versionNumber + 1),
            ),
          );
          if (shortfall) {
            warnings.add(
              '《${ch.title}》未通过质量闸（'
              '${outcome.qualityNote.isEmpty ? '质量不达标' : outcome.qualityNote}），'
              '已按草稿保存（可对草稿手动润色或重新生成）。',
            );
          } else {
            written++;
          }
          final ChapterPostProcessService? post = postProcess;
          if (post != null && !shortfall) {
            try {
              final sync = await post.runForChapter(
                ChapterSyncInput(
                  chapterId: ch.id,
                  volumeId: ch.volumeId,
                  projectId: projectId,
                  title: ch.title,
                  orderIndex: ch.orderIndex,
                  content: content,
                  summary: ch.summary ?? '',
                  tags: ch.tags,
                  notes: ch.notes,
                  status: shortfall ? 'Draft' : 'Completed',
                  versionNumber: ch.versionNumber + 1,
                  eventDate: DateTime.now(),
                ),
              );
              if (!sync.aiApplied) {
                warnings.add(
                  '《${ch.title}》设定抽取未完成：${sync.aiNote} ${sync.skippedReason ?? ''}',
                );
              }
            } on Object catch (e) {
              warnings.add('《${ch.title}》联动同步未执行：$e');
            }
          }

          // ---- 验收后更新分派（组长罗列待更新项 → 9 写手按模板产出 → 防幻觉应用）----
          //
          // ⚠ 这里**绝不能**再以 `post == null` 作为门控：生产环境的
          // `chapterPostProcessServiceProvider` 恒被注入（见 core/di.dart），
          // 旧条件 `post == null && …` 于是**永久为假** —— 组长罗列在验收报告
          // `updates[]` 里的待更新项一条都不会落地，现象就是用户报的
          // 「章节正文验收通过了，人物管理/世界观却完全没有更新」。
          //
          // 两级同步职责互补、各自幂等，因此两者都跑：
          //   * 规则同步（零模型）：按名匹配追加履历/首末出场/关系/时间线；
          //   * 本分派（组长点名 → 写手成文）：人物 status/history/notes、
          //     世界观 status/history/notes/content/description 等子项内容更新。
          final TeamAcceptance? acceptance = outcome.acceptance;
          final TeamUpdatesDispatcher? dispatcher = updateDispatch;
          if (!shortfall &&
              acceptance != null &&
              acceptance.updateItems.isNotEmpty &&
              dispatcher != null) {
            try {
              final List<String> issues = await dispatcher(
                projectId: projectId,
                items: acceptance.updateItems,
                // 更新分派沿用**本章的写作会话**（同章同角色）——
                // 让「角色/世界观状态更新」这一步也吃到组长/写手已经在本章
                // state 里累积的上下文，而不是从零起一段新会话。
                writerChat: (int writerSlot, String prompt) => _AgentChannel(
                  stateManager.stateOf(team.groupId, 'writer-$writerSlot'),
                  _writerSystemPrompt(writerSlot),
                  chat,
                  sessionKeyPrefix: chapterPrefix,
                ).send(prompt, maxTokens: 1600, temperature: 0.7),
              );
              warnings.addAll(<String>[
                for (final String s in issues)
                  if (s.trim().isNotEmpty) '《${ch.title}》更新分派：$s',
              ]);
            } on Object catch (e) {
              warnings.add('《${ch.title}》更新分派未执行：$e');
            }
          }

          // ---- 章节档案（验收通过即同步生成；四段描述）----
          final TeamAcceptance acc = acceptance ?? const TeamAcceptance();
          await _emitArchive(
            warnings,
            level: 'chapter',
            projectId: projectId,
            title: ch.title,
            content: content,
            metadata: <String, String>{
              'chapterId': ch.id,
              'volumeId': ch.volumeId,
              'timeRange': acc.timeRange.isNotEmpty
                  ? acc.timeRange
                  : '第${ch.orderIndex}章 · ${_fmtDate(DateTime.now())}',
              'themeTask': acc.themeTask.isNotEmpty
                  ? acc.themeTask
                  : _firstLine(chapterOutlines[seq], 80),
              'gainsLosses': acc.gainsLosses.isNotEmpty
                  ? acc.gainsLosses
                  : '团队协作完成，正文 ${content.trim().length} 字定稿'
                        '（验收${acc.allAccepted ? '一次通过' : '经返工后通过'}）',
              'safeguards': acc.safeguards.isNotEmpty
                  ? acc.safeguards
                  : '后续章节保持与本章结尾状态衔接',
            },
          );
          emit(
            shortfall
                ? MultiAgentChapterPhase.failed
                : MultiAgentChapterPhase.done,
            1,
            shortfall
                ? '${outcome.qualityNote.isEmpty ? '质量不达标' : outcome.qualityNote}，已按草稿落库'
                : '定稿落库（${content.trim().length} 字，'
                      '验收${acc.allAccepted ? '一次通过' : '经返工后通过'}）',
          );

          // ---- 结构化导出（Markdown + JSON 落盘，便于离线分析/改良模板）----
          final ChapterExportService? exporter = exportService;
          if (exporter != null) {
            try {
              await exporter.exportChapter(
                ChapterExportInput(
                  projectId: projectId,
                  projectName: projectName,
                  volumeTitle: volumeTitleById[ch.volumeId] ?? '',
                  chapterId: ch.id,
                  title: ch.title,
                  orderIndex: ch.orderIndex,
                  status: shortfall ? '草稿' : '落库定稿',
                  wordCount: content.trim().length,
                  content: content,
                  mainOutline: mainOutline,
                  volumeOutline:
                      volumeOutlines[volumeRows.indexWhere(
                        (VolumeRow v) => v.id == ch.volumeId,
                      )],
                  chapterOutline: chapterOutlines[seq],
                  minFinalWords: cfg.minFinalWords,
                  concurrency: cfg.concurrency,
                  sections: outcome.sections,
                  archive: ArchiveDescription(
                    timeRange: acc.timeRange,
                    themeTask: acc.themeTask,
                    gainsLosses: acc.gainsLosses,
                    safeguards: acc.safeguards,
                  ),
                ),
              );
              exportedChapters.add((
                order: ch.orderIndex,
                title: ch.title,
                status: shortfall ? '草稿' : '落库定稿',
                wordCount: content.trim().length,
              ));
            } on Object catch (e) {
              warnings.add('《${ch.title}》结构化导出失败：$e');
            }
          }
        } finally {
          stateManager.closeGroup(team.groupId);
        }
      });

      // ---- 7.5 失败章自动修复：先调大纲、再重写（用户 2026-10-09/10-10 要求）----
      //
      // 必须放在**章节池之后**：质量失败是「跑完才知道」的，而且重写要靠
      // 「前章结尾 + 本章大纲 + 下章开头」约束 —— 邻居没定稿就无从写起。
      // 也必须放在**档案归纳之前**：补写出来的正文同样要参与设定抽取与归档。
      //
      // 每章修复期间向矩阵上报事件（polishing → done/failed），否则面板上
      // 那些格子停在修复前的红标，作者会以为自动修复没跑。
      // （`volumeTitleById` 复用第 6 步章节落库时已经建好的那张表。）
      written += await _rewriteFailedChapters(
        projectId: projectId,
        cfg: cfg,
        warnings: warnings,
        onProgress: onProgress,
        onChapterEvent: onChapterEvent,
        volumeTitleById: volumeTitleById,
      );

      // ---- 8. 分卷档案归纳（每卷一次）----
      //
      // 放在**章节池之后**：章节是并行写的，池子没结束就无从判断「哪一卷写完了」。
      // 输入是 `ModuleStateService` 逐章写进实体 `history` 列的流水账 ——
      // 不归纳的话，写到第 30 章时点开「人物管理」看到的是一串 30 行变更日志，
      // 而不是「这个角色是谁」。
      //
      // 每卷独立 try/catch，且归纳失败**绝不能**影响已经写好的正文与已落库的设定：
      // 归纳只是「把已有信息整理得更好读」，不是成稿的必要环节。
      final EntityProfileSynthesizer? profiler = profileSynthesizer;
      if (profiler != null) {
        onProgress?.call('正在归纳各卷的设定档案…', 0.985);
        for (final VolumeRow vol in volumeRows) {
          // 该卷正文一个字都没落库时跳过 —— 没有流水可归纳，白调一次模型。
          // 判据看**正文是否非空**而不是 status：未过质量闸的草稿章同样
          // 被抽取过设定（见 ModuleStateService 的前置条件），必须一起归纳。
          final List<ChapterRow> volChapters = await chapters.getByVolumeId(
            vol.id,
          );
          final bool hasContent = volChapters.any(
            (ChapterRow ch) => (ch.content ?? '').trim().isNotEmpty,
          );
          if (!hasContent) continue;
          try {
            final EntityProfileResult res = await profiler.synthesizeVolume(
              projectId: projectId,
              volumeId: vol.id,
              volumeTitle: vol.title,
              volumeNo: volumeRows.indexOf(vol) + 1,
              onProgress: (String step) => onProgress?.call(step, null),
            );
            if (!res.isSuccess) {
              warnings.add('《${vol.title}》档案归纳未完成：${res.message}');
            } else {
              warnings.addAll(<String>[
                for (final String n in res.notes) '《${vol.title}》档案归纳：$n',
              ]);
            }
          } on Object catch (e) {
            warnings.add('《${vol.title}》档案归纳未执行：$e');
          }
        }
      }

      // ---- 项目级导出索引（主线大纲 + 卷大纲 + 章节清单）----
      final ChapterExportService? indexExporter = exportService;
      if (indexExporter != null) {
        try {
          await indexExporter.exportProjectIndex(
            projectId: projectId,
            projectName: projectName,
            mainOutline: mainOutline,
            volumes: <({String title, String outline})>[
              for (int i = 0; i < volumeOutlines.length; i++)
                (title: '第${_cn(i + 1)}卷', outline: volumeOutlines[i]),
            ],
            chapters: exportedChapters,
          );
        } on Object catch (e) {
          warnings.add('项目导出索引失败：$e');
        }
      }

      final bool ok = written > 0;

      // ---- 书籍（项目）收尾档案：全书完成情况总账 ----
      // 大纲阶段已写过一条 `project` 级档案（主线大纲），这里补一条
      // **收尾全书档案**，让「写作档案」页同时具备「大纲」与「成书总账」。
      try {
        // ⚠ 必须**重读数据库**：`outlineRows` 是「章节大纲落库」那一刻取回的行，
        // 那时 `content` 还是 null（正文尚未写）。旧实现直接遍历 `outlineRows`
        // 累加长度 → 全书档案恒写「正文约 0 字」（用户实测）。
        final List<ChapterRow> settledRows = await chapters.getByProjectId(
          projectId,
        );
        int totalWords = 0;
        for (final ChapterRow ch in settledRows) {
          totalWords += (ch.content ?? '').trim().length;
        }
        final String volSummary = volumeRows
            .map((VolumeRow v) => '${v.title}（${cfg.chaptersPerVolume} 章）')
            .join('；');
        await _emitArchive(
          warnings,
          level: 'project',
          projectId: projectId,
          title: '${cfg.bookTitle}·全书成稿总账',
          content:
              '《${cfg.bookTitle}》（作者：${cfg.authorName}）共 ${volumeRows.length} 卷、'
              '$totalChapters 章规划，实际落库 $written 章、正文约 $totalWords 字。\n'
              '分卷：$volSummary。\n'
              '写作工艺：${cfg.craft.name}；目标每章 ${cfg.chapterWordTarget} 字'
              '（下限 ${cfg.minFinalWords} 字）。',
          metadata: <String, String>{
            'timeRange': _fmtDate(DateTime.now()),
            'themeTask': '《${cfg.bookTitle}》全书成稿（${cfg.craft.name} 工艺）',
            'gainsLosses': '落库 $written/$totalChapters 章，正文约 $totalWords 字',
            'safeguards': warnings.isEmpty
                ? '全书各章均通过质量闸，可按卷连读'
                : '存在 ${warnings.length} 条告警，建议按告警定位并重写对应章节',
            'chapterWordTarget': '${cfg.chapterWordTarget}',
            'craft': cfg.craft.name,
          },
        );
      } on Object catch (e) {
        warnings.add('书籍档案写入失败：$e');
      }

      // ---- 项目进度回写（章节完成率口径）----
      await _refreshProgress(projectId);

      return MultiAgentBookResult(
        isSuccess: ok,
        message: ok
            ? '多智能体协同写作完成：$written/$totalChapters 章已落库。'
            : '全部章节写作失败（大纲已保留）。',
        bookTitle: cfg.bookTitle,
        authorName: cfg.authorName,
        projectId: projectId,
        projectCreated: true,
        mainOutlineSaved: true,
        volumesPlanned: volumeRows.length,
        chapterOutlinesPlanned: totalChapters,
        chaptersPlanned: outlineRows.length,
        chaptersWritten: written,
        warnings: warnings
            .where((String w) => w.trim().isNotEmpty)
            .toList(growable: false),
        mainOutlineText: mainOutline,
      );
    } finally {
      stateManager.closeGroup(planning.groupId);
      temporaryWriter?.dispose();
    }
  }

  MultiAgentBookResult _fail(
    MultiAgentBookConfig cfg,
    String step,
    String message, {
    String projectId = '',
  }) => MultiAgentBookResult(
    isSuccess: false,
    message: message,
    bookTitle: cfg.bookTitle,
    authorName: cfg.authorName,
    projectId: projectId,
    failureStep: step,
  );

  // -----------------------------------------------------------------------
  // 聊天执行器 / 规划组通道
  // -----------------------------------------------------------------------

  /// 生产执行器：provider.chat + 输出清洗 + RWKV 防复读采样参数。
  ///
  /// 思考型模型（rwkv7-g1j/g1k）的 `<think>` 块会白吃 max_tokens：预算不足时
  /// 思考未闭合 → AIOutputSanitizer 把通篇当推理剥掉 → 「正文为空」。
  /// 策略：首轮按调用方预算；剥 think 后为空 → 预算放大 2 倍重试一次
  ///（封顶 12000，兼容 ctx16384）；认证/参数类失败（isSuccess=false）不重试。
  ///
  /// ⚠ 超时尊重 AI 配置页的 timeoutSeconds（provider 此前从未把它应用到
  /// chat()，思考型模型 + 大预算下单次调用可无限期运行）。超时不重试。
  ///
  /// 诊断：每次空返回都记录精确原因到 [lastChatDiagnostic] 并打日志
  ///（isSuccess=false 带错误信息 / 原始响应为空带 finishReason / 思考块
  /// 未闭合带原文头部），UI 失败文案直接携带 —— 不再只说「返回为空」。
  static final Logger _logger = Logger('MultiAgentBookGeneration');

  /// 全局在途模型调用闸（跨团队共享）：并行团队 × 9 写手的峰值请求
  /// 钳到 32 在途，超出排队（多队并行时不压垮 CF / 推理端点）。
  static final Semaphore _inFlightGate = Semaphore(32);

  /// 最近一次模型调用产出为空的原因（供失败文案与排查）。
  String lastChatDiagnostic = '';

  int _callTimeoutSeconds(IModelProvider provider) {
    int seconds = 300;
    if (provider is OpenAICompatibleProvider) {
      try {
        final int t = provider.configuration.timeoutSeconds;
        if (t > 0) seconds = t > 3600 ? 3600 : t;
      } on Object {
        // 保持默认 300s
      }
    }
    return seconds;
  }

  AgentChatExecutor _buildProviderExecutor(
    IModelProvider provider, {
    String model = '',
  }) {
    return (
      String systemPrompt,
      List<ChatMessage> messages, {
      required int maxTokens,
      double temperature = 0.85,
      String? sessionKey,
    }) async {
      final int timeoutSec = _callTimeoutSeconds(provider);
      final String effectiveModel = model.isNotEmpty
          ? model
          : provider is OpenAICompatibleProvider
          ? provider.configuration.defaultModel
          : '';
      final bool g1kCloud =
          provider is RwkvCloudProvider &&
          effectiveModel.toLowerCase().contains('g1k');
      final bool g1kDraft =
          g1kCloud && effectiveModel.toLowerCase().contains('2.9b');
      final Map<String, dynamic> sampling = g1kCloud
          ? <String, dynamic>{
              'top_p': G1kWritingProfile.topP,
              'presence_penalty': G1kWritingProfile.presencePenalty,
            }
          : isRwkvFamilyProvider(provider.providerName)
          ? Map<String, dynamic>.of(aiRuntimeSettings.longFormSamplingParams())
          : <String, dynamic>{};
      final double effectiveTemperature = g1kCloud
          ? G1kWritingProfile.temperature(temperature)
          : temperature;
      // —— 上下文保护（2026-09-30 实测修正）——
      // 中文 ≈ 1 token/字（旧代码按 1.6 字/token 估算，低估约 60%）：
      // 用户把「最大令牌数」填成接近窗口值时（如 16000 / ctx16384），
      // 直接下发会「提示词 + max_tokens > 窗口」被服务端截断甚至报错。
      // 这里三重钳制：用户值 → 运行时输出预算 → 窗口剩余空间。
      final int promptChars =
          systemPrompt.length +
          messages.fold<int>(0, (int s, ChatMessage m) => s + m.content.length);
      final int promptTokens =
          (promptChars * AiRuntimeSettings.kTokensPerChineseChar).ceil();
      final int window = g1kCloud
          ? AiRuntimeSettings.parseContextWindow(effectiveModel)
          : aiRuntimeSettings.contextWindowTokens;
      int budget = maxTokens;
      if (g1kCloud &&
          budget > (g1kDraft ? G1kWritingProfile.draftMaxTokens : 1500)) {
        budget = g1kDraft ? G1kWritingProfile.draftMaxTokens : 1500;
      }
      final int runBudget = aiRuntimeSettings.outputBudgetTokens;
      if (budget > runBudget) budget = runBudget;
      if (budget > 12000) budget = 12000;
      final int windowCap =
          window - promptTokens - AiRuntimeSettings.kContextSafetyMargin;
      if (windowCap > 0 && budget > windowCap) {
        budget = windowCap;
      }
      if (budget < 256) budget = 256;
      // ---- 客户端 state（BUG 2）----
      //
      // 带会话标识 + 云端 provider 已开启客户端 state 时，走
      // `/state/chat/completions` **增量续跑**：会话 ID 与转写本由客户端持有并
      // 持久化，服务端只按 id 接着算 —— 这才是 RNN 的 O(1) 上下文接续，
      // 而不是每轮把全部历史重新 prefill 一遍。
      //
      // 代价：该路由只支持非流式（官方契约如此），所以这条分支跳过流式。
      final bool clientState =
          sessionKey != null &&
          sessionKey.isNotEmpty &&
          provider is RwkvCloudProvider &&
          provider.clientStateEnabled &&
          provider.sessionLedger != null;
      final Map<String, dynamic> requestParams = <String, dynamic>{
        ...sampling,
        if (clientState) 'rwkvSessionKey': sessionKey,
      };
      for (int attempt = 1; attempt <= 2; attempt++) {
        final ChatRequest req = ChatRequest(
          model: model,
          systemPrompt: systemPrompt,
          messages: messages,
          temperature: effectiveTemperature,
          maxTokens: budget,
          // 流式优先：CF 对非流式请求有 ~120s 代理读超时（HTTP 524，硬限制
          // 不可配置），思考型模型一次生成 5-20 分钟必撞墙；SSE 字节持续
          // 回流则不会触发。流式不可用时回落非流式。
          // clientState 例外：/state 路由不支持流式。
          stream: !clientState,
          // 防复读采样参数只下发 RWKV 家族（DeepSeek/Zhipu 等严格 API 会 400）
          parameters: requestParams,
        );
        ChatResponse resp;
        try {
          // 全局在途闸：N 队并行时写手阶段峰值 = N×9 个并发请求，
          // 直接压端点会触发 CF 429 / 服务端过载 —— 钳到 32 在途，其余排队。
          await _inFlightGate.acquire();
          try {
            resp = clientState
                ? await provider
                      .chat(req)
                      .timeout(Duration(seconds: timeoutSec))
                : await provider
                      .chatStream(req, (_) {})
                      .timeout(Duration(seconds: timeoutSec));
          } finally {
            _inFlightGate.release();
          }
        } on TimeoutException {
          lastChatDiagnostic = '单次调用超时（${timeoutSec}s，可在「AI 配置」调整超时秒数）';
          _logger.warning('模型调用超时（不重试）：$lastChatDiagnostic');
          return '';
        } on Object catch (e) {
          // 流式失败（provider 不支持 / 网络中断）→ 回落非流式一次
          _logger.warning('流式调用失败，回落非流式：$e');
          try {
            await _inFlightGate.acquire();
            try {
              resp = await provider
                  .chat(
                    ChatRequest(
                      model: model,
                      systemPrompt: systemPrompt,
                      messages: messages,
                      temperature: effectiveTemperature,
                      maxTokens: budget,
                      parameters: requestParams,
                    ),
                  )
                  .timeout(Duration(seconds: timeoutSec));
            } finally {
              _inFlightGate.release();
            }
          } on TimeoutException {
            lastChatDiagnostic = '单次调用超时（${timeoutSec}s，可在「AI 配置」调整超时秒数）';
            return '';
          } on Object catch (e2) {
            lastChatDiagnostic = '调用异常：$e2';
            _logger.warning('模型调用异常（不重试）：$lastChatDiagnostic');
            return '';
          }
        }
        if (!resp.isSuccess) {
          lastChatDiagnostic = '调用失败：${resp.errorMessage ?? '未知错误（未返回错误信息）'}';
          _logger.warning('模型调用失败（不重试）：$lastChatDiagnostic');
          return '';
        }
        final String raw = resp.content;
        final String cleaned = AIOutputSanitizer.extractCleanOutput(raw).trim();
        if (cleaned.isNotEmpty) {
          lastChatDiagnostic = '';
          return cleaned;
        }
        // —— 空产出：精确定位是「原始响应为空」还是「被清洗剥空」——
        final String trimmed = raw.trim();
        final String head = trimmed.isEmpty
            ? ''
            : trimmed.substring(0, trimmed.length > 120 ? 120 : trimmed.length);
        final bool thinkUnclosed = RegExp(
          r'^\s*<(?:think|thinking)>',
          caseSensitive: false,
        ).hasMatch(trimmed);
        lastChatDiagnostic = thinkUnclosed
            ? '思考块未闭合：max_tokens=$budget 在 <think> 阶段耗尽'
                  '（finishReason=${resp.finishReason}），正文被剥空 —— 需更大预算'
            : (trimmed.isEmpty
                  ? '原始响应为空（finishReason=${resp.finishReason}，'
                        'usage=${resp.usage?.totalTokens ?? '-'} tokens）'
                  : '产出被清洗剥空（finishReason=${resp.finishReason}，'
                        '原文前 120 字：$head）');
        _logger.warning(
          '模型调用产出为空（第 $attempt/2 次，预算 $budget，'
          '超时 ${timeoutSec}s）：$lastChatDiagnostic',
        );
        final int retryCap = g1kCloud
            ? (g1kDraft ? G1kWritingProfile.draftMaxTokens : 1500)
            : 12000;
        budget = (budget * 2) > retryCap ? retryCap : budget * 2;
      }
      return '';
    };
  }

  _AgentChannel _planningLeaderChannel(
    AgentChatExecutor chat,
    AgentStateGroup planning, {
    String sessionKeyPrefix = '',
  }) => _AgentChannel(
    stateManager.stateOf(planning.groupId, 'leader'),
    _renderPrompt('Book/planningLeader', {}),
    chat,
    sessionKeyPrefix: sessionKeyPrefix,
  );

  List<_AgentChannel> _planningWriterChannels(
    AgentChatExecutor chat,
    AgentStateGroup planning, {
    String sessionKeyPrefix = '',
  }) => <_AgentChannel>[
    for (int s = 1; s <= kWriterCount; s++)
      _AgentChannel(
        stateManager.stateOf(planning.groupId, 'writer-$s'),
        _renderPrompt('Book/planningWriter', {'slot': '$s'}),
        chat,
        sessionKeyPrefix: sessionKeyPrefix,
      ),
  ];

  /// 规划组写手通道指派：**按并发道固定绑定**（lane → channel），
  /// 于是同一时刻同一个通道只会被一个道使用，从排程层杜绝「同一 session 并发写」。
  _AgentChannel _plannerChannelFor(List<_AgentChannel> planners, int lane) =>
      planners[lane % planners.length];

  /// 分卷大纲：空结果自动重试（最多 3 次尝试），修复「未按预期写入全部大纲内容」。
  Future<String> _volumeOutlineWithRetry(
    AgentChatExecutor chat,
    List<_AgentChannel> planners,
    MultiAgentBookConfig cfg,
    String mainOutline,
    int index,
    int lane,
  ) async {
    final _AgentChannel channel = _plannerChannelFor(planners, lane);
    for (int attempt = 1; attempt <= 3; attempt++) {
      final String text = await channel.send(
        _volumeOutlinePrompt(cfg, mainOutline, index),
        maxTokens: 4000,
        temperature: 0.8,
      );
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  Future<String> _chapterOutlineChat(
    List<_AgentChannel> planners,
    MultiAgentBookConfig cfg,
    String mainOutline,
    String volumeOutline,
    int chapterIndex,
    int lane,
  ) {
    final _AgentChannel channel = _plannerChannelFor(planners, lane);
    return channel.send(
      _chapterOutlinePrompt(cfg, mainOutline, volumeOutline, chapterIndex),
      maxTokens: 2400,
      temperature: 0.8,
    );
  }

  // -----------------------------------------------------------------------
  // ④ 章节写作团队：组长偏向派活 → 写手并行 → 组长验收 → 返工/补写 → 拼接定稿
  // -----------------------------------------------------------------------

  /// 续写优选（beam）：每轮并发 [kBeamWidth] 份续写候选，打分择优后再续写。
  ///
  /// 为什么这是 RWKV 的「专属框架」：
  /// ① 它擅长**给定前文续写**、不擅长**按指令创作** → 提示词极简、
  ///    只给「本章要点 + 前文尾部」，让它做最擅长的事；
  /// ② 单次输出方差极大（实测 156~2937 字）→ **N 选 1 直接吃掉方差**，
  ///    烂轮次（太短 / 复读 / 大纲污染）在打分阶段就被淘汰；
  /// ③ 每段刻意取短（[kBeamSegmentChars]）→ 远离退化区；
  /// ④ 服务端并发充足（实测 169 bsz），N 倍调用几乎不增加墙钟时间。
  Future<
    ({
      String? content,
      TeamAcceptance? acceptance,
      bool shortfall,
      String qualityNote,
      List<ChapterExportSection> sections,
    })
  >
  _writeChapterBeam({
    required AgentChatExecutor chat,
    AgentChatExecutor? polishChat,
    required AgentStateGroup team,
    required MultiAgentBookConfig cfg,
    required String mainOutline,
    required String volumeOutline,
    required String chapterOutline,
    void Function(String step)? onStep,
    void Function(MultiAgentChapterPhase phase, double progress, String detail)?
    onPhase,
    String sessionKeyPrefix = '',
  }) async {
    final bool fastDraft = polishChat != null;
    final int beamWidth = fastDraft ? 1 : kBeamWidth;
    final int segmentChars = fastDraft
        ? G1kWritingProfile.draftTargetChars
        : kBeamSegmentChars;
    final int segmentTokens = fastDraft
        ? G1kWritingProfile.draftMaxTokens
        : kBeamSegmentTokens;
    final String volBrief = volumeOutline.isEmpty
        ? '（见主线大纲）'
        : _ref(volumeOutline, 0.10);
    final String chText = chapterOutline.isEmpty
        ? '（见主线大纲与分卷大纲）'
        : _ref(chapterOutline, 0.25);
    final _AgentChannel lead = _AgentChannel(
      team.leader!,
      _leadWriterSystemPrompt(),
      chat,
      keepHistory: false,
      sessionKeyPrefix: sessionKeyPrefix,
    );

    final int withMargin = (cfg.minFinalWords * 1.2).ceil();
    final int target = cfg.chapterWordTarget > withMargin
        ? cfg.chapterWordTarget
        : withMargin;
    onStep?.call('续写优选：每轮并发 $beamWidth 份候选、择优续写（目标 $target 字）');
    onPhase?.call(
      MultiAgentChapterPhase.planning,
      0.05,
      '续写优选（并发 $beamWidth/轮）',
    );

    final List<ChapterExportSection> sections = <ChapterExportSection>[];
    final StringBuffer sb = StringBuffer();
    String tail = '';
    int round = 0;
    while (round < kMaxBeamRounds) {
      final int produced = sb.toString().trim().length;
      if (produced >= target) break;
      round++;
      final int remaining = target - produced;
      final int ask = remaining < segmentChars ? remaining : segmentChars;
      onStep?.call(
        '续写优选第 $round 轮（已 $produced / 目标 $target 字），'
        '并发 $beamWidth 份候选…',
      );
      onPhase?.call(
        MultiAgentChapterPhase.writing,
        0.10 + 0.85 * (round - 1) / kMaxBeamRounds,
        '续写优选第 $round 轮（已 $produced 字）',
      );

      // 并发发起 N 份候选：同一前缀、不同温度与叙事侧重。
      //
      // ⚠ 候选必须走**无状态链路**（`isolated: true`）—— 见 [_AgentChannel] 的
      //   隔离说明：N 份候选是 `Future.wait` 并发发起的，若共用 lead 的 session，
      //   第 1 份产出会被写进 state、第 2 份就带着它继续生成，「N 份独立候选」
      //   直接退化成「同一段续写 N 次」；台账的 `runExclusive` 还会把它们排成
      //   串行，N 倍并发白给。
      //   候选提示词本身已自带「前文尾部 + 章节要点 + 偏向」，不依赖 state，
      //   隔离后既安全又不掉质量。
      // 候选数 == 1（G1K 双模型快写）时是严格串行，保留 state 会话。
      final bool isolateCandidates = beamWidth > 1;
      final List<String> candidates = await Future.wait(<Future<String>>[
        for (int k = 0; k < beamWidth; k++)
          lead.send(
            _beamCandidatePrompt(
              chText: chText,
              volBrief: volBrief,
              tail: tail,
              targetChars: ask,
              variant: k,
            ),
            maxTokens: segmentTokens,
            // 官方创作类推荐 Temperature ≈ 1；候选按 0.96→1.12 梯度拉开多样性
            temperature: 0.96 + k * 0.04,
            isolated: isolateCandidates,
          ),
      ]);

      String best = '';
      double bestScore = double.negativeInfinity;
      for (final String raw in candidates) {
        final String seg = _cleanFinalChapter(
          fastDraft ? G1kWritingProfile.safeDraft(raw) : raw,
        );
        final double score = _scoreCandidate(seg, ask, tail);
        if (score > bestScore) {
          bestScore = score;
          best = seg;
        }
      }
      final int minSegmentChars = ask < G1kWritingProfile.draftMinChars
          ? (ask * 0.75).ceil()
          : G1kWritingProfile.draftMinChars;
      if (fastDraft && best.length < minSegmentChars) {
        final String retry = _cleanFinalChapter(
          G1kWritingProfile.safeDraft(
            await lead.send(
              '${_beamCandidatePrompt(chText: chText, volBrief: volBrief, tail: tail, targetChars: ask, variant: 0)}'
              '\n至少写满 $ask 字，情节没写完不要收尾；禁止字数统计和写作说明。',
              maxTokens: segmentTokens,
              temperature: 1.0,
              isolated: isolateCandidates,
            ),
          ),
        );
        if (_scoreCandidate(retry, ask, tail) >
            _scoreCandidate(best, ask, tail)) {
          best = retry;
        }
      }
      if (best.isEmpty || (fastDraft && best.length < minSegmentChars)) {
        if (round >= 3) break;
        continue;
      }
      if (polishChat != null) {
        final String polished = await _polishDraft(polishChat, best);
        if (polished.length >= (best.length * 0.9).floor() &&
            _scoreCandidate(polished, ask, tail) >=
                _scoreCandidate(best, ask, tail) - 1) {
          best = polished;
        }
      }
      // 累积时做**跨段去重**：模型常把提示词里的「前文末尾」原样复述一遍
      // 再往下写，直接 write(best) 会让同一段在正文里出现两次（用户实测：
      // 第一卷第一章正文由 3 段拼成，段间逐字复述）。见 [_mergeSegment]。
      final String merged = _mergeSegment(sb.toString(), best);
      sb
        ..clear()
        ..write(merged);
      tail = merged.length > 400
          ? merged.substring(merged.length - 400)
          : merged;
      sections.add(
        ChapterExportSection(
          slot: round,
          personaId: 'lead',
          personaName: '主笔',
          title: '第 $round 段（$beamWidth 选 1）',
          brief: '',
          boundary: '',
          wordTarget: ask,
          draft: best,
          accepted: true,
          problems: '',
          reworked: false,
          leaderFixed: false,
        ),
      );
    }
    final String text = _cleanFinalChapter(sb.toString());
    final String note = _qualityNote(text, cfg);
    onPhase?.call(
      MultiAgentChapterPhase.polishing,
      0.95,
      note.isEmpty ? '定稿 ${text.length} 字，通过质量闸' : '$note，按草稿保存',
    );
    // 本工艺**没有**组长逐段验收环节 → 定稿后补一次「设定/履历抽取」，
    // 否则验收后更新分派永远拿不到 updateItems，人物管理与世界观不会更新
    //（质量闸未过的草稿不抽取：它本来也不会走分派）。
    final TeamAcceptance extracted = note.isNotEmpty
        ? const TeamAcceptance()
        : await _extractAcceptanceFromProse(
            chat: chat,
            team: team,
            chapterText: text,
            chapterOutline: chapterOutline,
          );
    return (
      content: text.isEmpty ? null : text,
      acceptance: extracted.updateItems.isEmpty ? null : extracted,
      shortfall: note.isNotEmpty,
      qualityNote: note,
      sections: sections,
    );
  }

  Future<String> _polishDraft(AgentChatExecutor editor, String draft) async {
    final StringBuffer result = StringBuffer();
    int start = 0;
    while (start < draft.length) {
      int end = (start + 850).clamp(0, draft.length);
      if (end < draft.length) {
        final int sentence = draft.lastIndexOf('。', end);
        if (sentence > start + 450) end = sentence + 1;
      }
      final String chunk = draft.substring(start, end);
      final String polished = _cleanFinalChapter(
        G1kWritingProfile.safeDraft(
          await editor(
            _renderPrompt('Book/polishSystem', {}),
            <ChatMessage>[
              ChatMessage.user(_renderPrompt('Book/polish', {'chunk': chunk})),
            ],
            maxTokens: 1200,
            temperature: 0.88,
          ),
        ),
      );
      if (polished.length < (chunk.length * 0.9).floor()) return draft;
      if (result.isNotEmpty) result.writeln('\n');
      result.write(polished);
      start = end;
    }
    return result.toString();
  }

  /// 续写候选提示词 —— **刻意极简**。
  ///
  /// 实测：提示词越像「一段被截断的小说」，产出越像小说；指令、大纲、
  /// 约束越多，模型越容易跑去「复述大纲 / 输出元信息」。
  String _beamCandidatePrompt({
    required String chText,
    required String volBrief,
    required String tail,
    required int targetChars,
    required int variant,
  }) {
    final String style = switch (variant % 4) {
      0 => '侧重动作与场面。',
      1 => '侧重对白与人物互动。',
      2 => '侧重心理与氛围。',
      _ => '侧重视觉细节与叙事节奏。',
    };
    return _renderPrompt('Book/beamCandidate', <String, String>{
      'chText': (chText).toString(),
      'volBrief': (volBrief).toString(),
      'context3':
          (tail.isEmpty
                  ? '请从本章第一句开始写。'
                  // ⚠ 旧文案是 `【上文结尾】\n$tail\n\n请紧接着上文继续写，不要重复上文。`
                  // —— 标记 + 上文原文一起给出去，小模型的最优延续就是**把两者
                  // 都抄一遍再往下写**，于是章节正文里出现 `【上文结尾】` 与被回灌
                  // 上文的逐字复述（用户实测 BUG）。现在改成：标记用「前文末尾」，
                  // 并明确「不要输出这一段」，同时拼装时还有 [_mergeSegment] 兜底去重。
                  : '【前文末尾（仅供衔接上下文，**不要输出这一段**）】\n$tail\n\n'
                        '请紧接上文写下去。只输出**新增**的正文，第一句不得与前文末尾重复；'
                        '若前文末尾停在半句，请先把那半句补完再往下写。')
              .toString(),
      'targetChars': (targetChars).toString(),
      'style': (style).toString(),
      'styleRules': _styleSection(brief: true),
    });
  }

  /// 候选打分：长度达标 + 段落多样 + 无大纲污染 + 不复读前文。
  static double _scoreCandidate(String seg, int ask, String tail) {
    if (FictionQuality.issue(seg) != null) return double.negativeInfinity;
    if (seg.trim().isEmpty) return double.negativeInfinity;
    final int len = seg.trim().length;
    double s = (len / ask).clamp(0.0, 1.5) * 4.0;
    s -= _repeatRatio(seg) * 8.0;
    if (_looksLikeOutline(seg)) s -= 6.0;
    s -= _tailOverlap(seg, tail) * 6.0;
    return s;
  }

  /// 候选与前文尾部的 4-gram 重合率（[0,1]，越高越像在复读前文）。
  static double _tailOverlap(String text, String tail) {
    if (tail.length < 24 || text.length < 24) return 0;
    final String t = text.length > 2000
        ? text.substring(text.length - 2000)
        : text;
    final Set<String> grams = <String>{
      for (int i = 0; i + 4 <= tail.length; i++) tail.substring(i, i + 4),
    };
    if (grams.isEmpty) return 0;
    int hit = 0;
    int total = 0;
    for (int i = 0; i + 4 <= t.length; i++) {
      total++;
      if (grams.contains(t.substring(i, i + 4))) hit++;
    }
    return total == 0 ? 0 : hit / total;
  }

  Future<
    ({
      String? content,
      TeamAcceptance? acceptance,
      bool shortfall,
      String qualityNote,
      List<ChapterExportSection> sections,
    })
  >
  _writeChapterSolo({
    required AgentChatExecutor chat,
    required AgentStateGroup team,
    required MultiAgentBookConfig cfg,
    required String mainOutline,
    required String volumeOutline,
    required String chapterOutline,
    void Function(String step)? onStep,
    void Function(MultiAgentChapterPhase phase, double progress, String detail)?
    onPhase,
    String sessionKeyPrefix = '',
  }) async {
    onStep?.call('单笔直书：一次调用写出整章…');
    onPhase?.call(MultiAgentChapterPhase.writing, 0.35, '单笔成稿中');
    final _AgentChannel lead = _AgentChannel(
      team.leader!,
      _leadWriterSystemPrompt(),
      chat,
      keepHistory: false,
      sessionKeyPrefix: sessionKeyPrefix,
    );
    final String raw = await lead.send(
      _soloChapterPrompt(
        mainOutline,
        volumeOutline,
        chapterOutline,
        // 实测单次超过 ~3000 字就开始退化，这里把请求目标钳到 2600 字，
        // 并在提示里说明「一次写不完」由用户改用分段工艺。
        targetChars: cfg.chapterWordTarget > kSoloTargetChars
            ? kSoloTargetChars
            : cfg.chapterWordTarget,
      ),
      maxTokens: kSoloBudgetTokens,
      temperature: 0.9,
    );
    final String text = _cleanFinalChapter(raw);
    final String note = _qualityNote(text, cfg);
    onPhase?.call(
      MultiAgentChapterPhase.polishing,
      0.95,
      note.isEmpty ? '定稿 ${text.length} 字，通过质量闸' : '$note，按草稿保存',
    );
    // 单笔直书同样没有组长验收环节 → 补一次设定/履历抽取（同串行/优选工艺）。
    final TeamAcceptance extracted = note.isNotEmpty
        ? const TeamAcceptance()
        : await _extractAcceptanceFromProse(
            chat: chat,
            team: team,
            chapterText: text,
            chapterOutline: chapterOutline,
          );
    return (
      content: text.isEmpty ? null : text,
      acceptance: extracted.updateItems.isEmpty ? null : extracted,
      shortfall: note.isNotEmpty,
      qualityNote: note,
      sections: <ChapterExportSection>[
        ChapterExportSection(
          slot: 1,
          personaId: 'lead',
          personaName: '主笔',
          title: '整章',
          brief: chapterOutline,
          boundary: '',
          wordTarget: cfg.chapterWordTarget,
          draft: text,
          accepted: note.isEmpty,
          problems: note,
          reworked: false,
          leaderFixed: false,
        ),
      ],
    );
  }

  /// 主笔分段串行（推荐工艺）：同一主笔按段续写，**只携带上一段尾部 300 字**。
  ///
  /// 为什么这样最稳（实测）：① 每段只让模型写 ~2200 字，落在他自然收敛区间内；
  /// ② 段间只回灌尾部而非全文，既保证衔接又把「已出现 n-gram 抬概率」压到最小；
  /// ③ 每段 max_tokens 贴近目标，杜绝「给大预算就放飞」。
  Future<
    ({
      String? content,
      TeamAcceptance? acceptance,
      bool shortfall,
      String qualityNote,
      List<ChapterExportSection> sections,
    })
  >
  _writeChapterSerial({
    required AgentChatExecutor chat,
    required AgentStateGroup team,
    required MultiAgentBookConfig cfg,
    required String mainOutline,
    required String volumeOutline,
    required String chapterOutline,
    void Function(String step)? onStep,
    void Function(MultiAgentChapterPhase phase, double progress, String detail)?
    onPhase,
    String sessionKeyPrefix = '',
  }) async {
    final String volText = volumeOutline.isEmpty
        ? '（见主线大纲）'
        : _ref(volumeOutline, 0.15);
    final String chText = chapterOutline.isEmpty
        ? '（见主线大纲与分卷大纲）'
        : _ref(chapterOutline, 0.22);
    final _AgentChannel lead = _AgentChannel(
      team.leader!,
      _leadWriterSystemPrompt(),
      chat,
      keepHistory: false,
      sessionKeyPrefix: sessionKeyPrefix,
    );

    // 实测每段自然产出 2100~2800 字（目标 2200 时），故按四舍五入定段数：
    // 4500 字章 → 2 段（≈5000 字），比 ceil 的 3 段（≈7400 字）更贴近目标。
    // 目标留 20% 余量：定稿清洗（去 Markdown / 折叠重复段 / 退化截断）会掉字数，
    // +18 实测有 3 章正好卡在 3800 < 4000 —— 就是这份清洗损耗。
    final int withMargin = (cfg.minFinalWords * 1.2).ceil();
    final int target = cfg.chapterWordTarget > withMargin
        ? cfg.chapterWordTarget
        : withMargin;
    onStep?.call('主笔分段串行：按字数驱动续写（目标 $target 字）');
    onPhase?.call(MultiAgentChapterPhase.planning, 0.05, '主笔分段串行（按字数驱动）');

    // ⚠ 不预设固定段数：7.2B 模型输出长度极不稳定（实测同一提示词 156~2937 字
    // 都能出现），固定段数要么凑不够字数、要么段段顶预算退化。
    // 改为「写到够为止」：每轮按剩余字数下单，过短则下一轮明确要求补足。
    final List<ChapterExportSection> sections = <ChapterExportSection>[];
    final StringBuffer sb = StringBuffer();
    String tail = '';
    int round = 0;
    int lastAsk = 0;
    int lastSegLen = 0;
    while (round < kMaxSerialRounds) {
      final int produced = sb.toString().trim().length;
      if (produced >= target) break;
      round++;
      final int remaining = target - produced;
      final int ask = remaining < kSegmentTargetChars
          ? remaining
          : kSegmentTargetChars;
      onStep?.call('主笔续写第 $round 段（已 $produced / 目标 $target 字）…');
      onPhase?.call(
        MultiAgentChapterPhase.writing,
        0.10 + 0.80 * (round - 1) / kMaxSerialRounds,
        '主笔续写第 $round 段（已 $produced 字）',
      );
      final String promptText = _serialSegmentPrompt(
        mainOutline: mainOutline,
        volText: volText,
        chText: chText,
        index: round,
        targetChars: ask,
        tail: tail,
        // 上一段明显偏短 → 本轮明确要求补足，否则模型会一直「礼貌地短」
        shortLast: lastAsk > 0 && lastSegLen < (lastAsk * 0.6).floor(),
      );
      String seg = _cleanFinalChapter(
        await lead.send(
          promptText,
          maxTokens: kSegmentBudgetTokens,
          temperature: 0.9,
        ),
      );
      // 段级复读检修：单段重复率过高时换**更高温度**重写一次。
      //（RWKV 的复读靠提高温度比降低温度更容易打断；只采纳更好的一稿。）
      if (seg.isNotEmpty && _repeatRatio(seg) > 0.4) {
        final int bad = (_repeatRatio(seg) * 100).round();
        onStep?.call('第 $round 段复读率 $bad%，换高温重写一次…');
        final String retrySeg = _cleanFinalChapter(
          await lead.send(
            '$promptText\n\n⚠ 上一稿重复严重（同一批句子反复出现）。本轮**必须换用全新的'
            '句子、动作与意象推进剧情**，严禁重复已写过的表述，也不要复述上文。',
            maxTokens: kSegmentBudgetTokens,
            temperature: 0.98,
          ),
        );
        if (retrySeg.isNotEmpty && _repeatRatio(retrySeg) < _repeatRatio(seg)) {
          seg = retrySeg;
        }
      }
      lastAsk = ask;
      lastSegLen = seg.length;
      if (seg.isEmpty) {
        if (round >= 3) break;
        continue;
      }
      final String mergedSeg = _mergeSegment(sb.toString(), seg);
      sb
        ..clear()
        ..write(mergedSeg);
      tail = mergedSeg.length > 300
          ? mergedSeg.substring(mergedSeg.length - 300)
          : mergedSeg;
      sections.add(
        ChapterExportSection(
          slot: round,
          personaId: 'lead',
          personaName: '主笔',
          title: '第 $round 段',
          brief: '',
          boundary: '',
          wordTarget: ask,
          draft: seg,
          accepted: true,
          problems: '',
          reworked: false,
          leaderFixed: false,
        ),
      );
    }
    final String text = _cleanFinalChapter(sb.toString());
    final String note = _qualityNote(text, cfg);
    onPhase?.call(
      MultiAgentChapterPhase.polishing,
      0.95,
      note.isEmpty ? '定稿 ${text.length} 字，通过质量闸' : '$note，按草稿保存',
    );
    // 本工艺**没有**组长逐段验收环节 → 定稿后补一次「设定/履历抽取」，
    // 否则验收后更新分派永远拿不到 updateItems，人物管理与世界观不会更新
    //（质量闸未过的草稿不抽取：它本来也不会走分派）。
    final TeamAcceptance extracted = note.isNotEmpty
        ? const TeamAcceptance()
        : await _extractAcceptanceFromProse(
            chat: chat,
            team: team,
            chapterText: text,
            chapterOutline: chapterOutline,
          );
    return (
      content: text.isEmpty ? null : text,
      acceptance: extracted.updateItems.isEmpty ? null : extracted,
      shortfall: note.isNotEmpty,
      qualityNote: note,
      sections: sections,
    );
  }

  Future<
    ({
      String? content,
      TeamAcceptance? acceptance,
      bool shortfall,
      String qualityNote,
      List<ChapterExportSection> sections,
    })
  >
  _writeChapterWithTeam({
    required AgentChatExecutor chat,
    required AgentStateGroup team,
    required MultiAgentBookConfig cfg,
    required String mainOutline,
    required String volumeOutline,
    required String chapterOutline,
    void Function(String step)? onStep,
    void Function(MultiAgentChapterPhase phase, double progress, String detail)?
    onPhase,
    String sessionKeyPrefix = '',
  }) async {
    final String volText = volumeOutline.isEmpty
        ? '（见主线大纲）'
        : _ref(volumeOutline, 0.15);
    final String chText = chapterOutline.isEmpty
        ? '（见主线大纲与分卷大纲）'
        : _ref(chapterOutline, 0.22);

    final _AgentChannel leader = _AgentChannel(
      team.leader!,
      _leaderSystemPrompt(),
      chat,
      sessionKeyPrefix: sessionKeyPrefix,
    );
    final List<_AgentChannel> writers = <_AgentChannel>[
      for (int s = 1; s <= kWriterCount; s++)
        _AgentChannel(
          stateManager.stateOf(team.groupId, 'writer-$s'),
          _writerSystemPrompt(s),
          chat,
          // 正文写手不累积历史：同一写手可能被派到本章多段，
          // 回灌自己的上一段会导致整段自我复读（RWKV 尤甚）。
          keepHistory: false,
          sessionKeyPrefix: sessionKeyPrefix,
        ),
    ];

    // ④-1 组长偏向派活：切分 9 段并给每段指定偏向写手
    final String planRaw = await leader.send(
      _planPrompt(cfg, mainOutline, volText, chText),
      maxTokens: 4000,
      temperature: 0.5,
    );
    List<SectionPlan> plan = parseSectionPlan(
      planRaw,
      expectedWriters: kWriterCount,
    );
    if (plan.isEmpty) {
      plan = fallbackPlan(
        writers: kWriterCount,
        targetWords: cfg.chapterWordTarget,
      );
    }

    // 段落 → 偏向写手：组长指定 > 关键词匹配 > 槽位轮转；
    // 同时记录偏向元数据（slot/persona），供结构化导出分析。
    final List<({int slot, String personaId, String personaName})> meta =
        <({int slot, String personaId, String personaName})>[
          for (final SectionPlan s in plan) _personaMeta(s),
        ];
    _AgentChannel channelFor(int index) => writers[meta[index].slot - 1];
    final List<bool> reworkedFlags = List<bool>.filled(plan.length, false);
    final List<bool> leaderFixedFlags = List<bool>.filled(plan.length, false);

    // ④-2 写手并行成稿（各自独享 state；单段失败留空，由验收环节处置）。
    // 逐段完成即上报（矩阵进度实时刷新）。
    onStep?.call('组长已完成偏向派活（${plan.length} 段），写手并行写作中…');
    onPhase?.call(
      MultiAgentChapterPhase.planning,
      0.05,
      '组长偏向派活（${plan.length} 段）',
    );
    final List<String> drafts = List<String>.filled(plan.length, '');
    int draftsDone = 0;
    final List<Future<void>> draftFutures = <Future<void>>[
      for (int i = 0; i < plan.length; i++)
        () async {
          final SectionPlan s = plan[i];
          drafts[i] = await channelFor(i).send(
            _writerPrompt(cfg, mainOutline, volText, chText, s, plan.length),
            maxTokens: 4000,
            temperature: 0.85,
          );
          draftsDone++;
          onPhase?.call(
            MultiAgentChapterPhase.writing,
            0.10 + 0.40 * draftsDone / plan.length,
            '写手成稿 $draftsDone/${plan.length} 段',
          );
        }(),
    ];
    await Future.wait(draftFutures);

    // ④-3 组长逐段验收（解析失败按原流程放行，防回归）
    onStep?.call('写手已交稿，组长逐段验收中…');
    onPhase?.call(
      MultiAgentChapterPhase.accepting,
      0.55,
      '组长逐段验收（${plan.length} 段）',
    );
    final String acceptRaw = await leader.send(
      _acceptancePrompt(chText, plan, drafts),
      maxTokens: 3000,
      temperature: 0.3,
    );
    final TeamAcceptance? acceptance = parseAcceptanceReport(acceptRaw);
    // 组长判定 + 确定性字数判定合并：段落清洗后字数低于目标 80% 一律判不合格
    //（防「思考残留 / 复读大纲」类垃圾稿蒙混过关）
    final Map<int, ParagraphVerdict> merged = <int, ParagraphVerdict>{
      for (final ParagraphVerdict v
          in acceptance?.verdicts ?? const <ParagraphVerdict>[])
        v.agent: v,
    };
    for (int i = 0; i < plan.length && i < drafts.length; i++) {
      final int len = drafts[i].trim().length;
      final int floor = (plan[i].wordTarget * 0.8).floor();
      final ParagraphVerdict? existing = merged[plan[i].agent];
      final bool alreadyAccepted = existing?.accepted ?? false;
      if (len < floor && !alreadyAccepted) {
        merged[plan[i].agent] = ParagraphVerdict(
          agent: plan[i].agent,
          accepted: false,
          problems:
              '段落字数不足（$len / 目标 ${plan[i].wordTarget} 字），'
              '疑似混入大纲复述或思考残留',
        );
      }
    }
    final List<ParagraphVerdict> verdicts = merged.values.toList();

    // ④-4 打回返工一轮；仍不合格由组长亲自补写
    final List<String> finalDrafts = List<String>.of(drafts);
    for (int i = 0; i < plan.length && i < finalDrafts.length; i++) {
      ParagraphVerdict? verdict;
      for (final ParagraphVerdict v in verdicts) {
        if (v.agent == plan[i].agent) {
          verdict = v;
          break;
        }
      }
      if (verdict == null || verdict.accepted) continue;
      onStep?.call('段落${i + 1}「${plan[i].title}」未通过验收，打回对应写手返工…');
      onPhase?.call(
        MultiAgentChapterPhase.rework,
        0.60 + 0.10 * (i + 1) / plan.length,
        '段落${i + 1}「${plan[i].title}」返工中',
      );
      final _AgentChannel w = channelFor(i);
      final String reworked = await w.send(
        _reworkPrompt(plan[i], verdict.problems, finalDrafts[i]),
        maxTokens: 4000,
        temperature: 0.8,
      );
      final int threshold = (plan[i].wordTarget * 0.5).floor().clamp(
        60,
        100000,
      );
      if (reworked.trim().length >= threshold) {
        finalDrafts[i] = reworked;
        reworkedFlags[i] = true;
        continue;
      }
      onStep?.call('段落${i + 1}返工仍不合格，组长亲自补写…');
      onPhase?.call(
        MultiAgentChapterPhase.leaderFix,
        0.70 + 0.05 * (i + 1) / plan.length,
        '段落${i + 1}组长补写中',
      );
      final String fixed = await leader.send(
        _leaderRewritePrompt(plan[i], verdict.problems),
        maxTokens: 4000,
        temperature: 0.7,
      );
      if (fixed.trim().isNotEmpty) {
        finalDrafts[i] = fixed;
        leaderFixedFlags[i] = true;
      }
    }

    // —— 结构化导出用段落过程数据（写手偏向 / 目标·实际字数 / 验收 / 返工）——
    final Map<int, ParagraphVerdict> verdictByAgent = <int, ParagraphVerdict>{
      for (final ParagraphVerdict v in verdicts) v.agent: v,
    };
    final List<ChapterExportSection> exportSections = <ChapterExportSection>[
      for (int i = 0; i < plan.length && i < finalDrafts.length; i++)
        ChapterExportSection(
          slot: meta[i].slot,
          personaId: meta[i].personaId,
          personaName: meta[i].personaName,
          title: plan[i].title,
          brief: plan[i].brief,
          boundary: plan[i].boundary,
          wordTarget: plan[i].wordTarget,
          draft: finalDrafts[i],
          accepted: verdictByAgent[plan[i].agent]?.accepted ?? true,
          problems: verdictByAgent[plan[i].agent]?.problems ?? '',
          reworked: reworkedFlags[i],
          leaderFixed: leaderFixedFlags[i],
        ),
    ];

    // ④-5 组长拼接 + 润色 + 排版 + 质量闸（定稿 ≥ minFinalWords 字）
    onPhase?.call(MultiAgentChapterPhase.polishing, 0.85, '拼接润色定稿中');
    final StringBuffer sections = StringBuffer();
    for (int i = 0; i < plan.length && i < finalDrafts.length; i++) {
      final String draft = finalDrafts[i].trim();
      sections
        ..writeln('【段落${i + 1} · ${plan[i].title}】')
        ..writeln(draft.isEmpty ? '（该段落缺失：写手未交稿，请依据大纲补写）' : draft)
        ..writeln();
    }
    String finalText = _cleanFinalChapter(
      await leader.send(
        _assemblyPrompt(mainOutline, chText, plan.length, sections.toString()),
        maxTokens: 8000,
        temperature: 0.6,
      ),
    );
    // —— 质量闸：字数不足 / 复读率超阈值 → 放大预算二次删重定稿一次 ——
    // 复读闸的由来：RWKV7-G1J 实测里整章常出现 85%+ 的段落级重复，
    // 而旧闸只看字数 —— 只要凑够 4000 字就标「已完成」，复读稿一路放行。
    if (finalText.length < cfg.minFinalWords ||
        _repeatRatio(finalText) > cfg.maxRepeatRatio) {
      final double ratio = _repeatRatio(finalText);
      final bool byRepeat = ratio > cfg.maxRepeatRatio;
      onPhase?.call(
        MultiAgentChapterPhase.polishing,
        0.90,
        byRepeat
            ? '复读率 ${(ratio * 100).round()}%，组长删重重新定稿中…'
            : '字数 ${finalText.length} < ${cfg.minFinalWords}，组长重新定稿中…',
      );
      onStep?.call(
        byRepeat
            ? '定稿复读率 ${(ratio * 100).round()}%（上限 '
                  '${(cfg.maxRepeatRatio * 100).round()}%），组长删重定稿…'
            : '定稿仅 ${finalText.length} 字（下限 ${cfg.minFinalWords}），组长二次定稿…',
      );
      final String retryRaw = await leader.send(
        '${_assemblyPrompt(mainOutline, chText, plan.length, sections.toString())}\n\n'
        '⚠ 上一稿不合格（${finalText.length} 字，复读率 ${(ratio * 100).round()}%；'
        '或混入大纲复述/思考残留）。'
        '本次必须重写，并**大幅删去重复的句子、意象与对白**（同一内容只保留一处，'
        '换个说法推进剧情而不是重复上一句）；只输出整章正文本身，'
        '禁止复述大纲、小标题、任何元信息与思考过程，'
        '正文不得少于 ${cfg.minFinalWords} 字。',
        maxTokens: 12000,
        temperature: 0.55,
      );
      final String retryClean = _cleanFinalChapter(retryRaw);
      // 二次稿「不更差」才采纳：字数不低于原稿 90%，且复读率不升。
      if (retryClean.isNotEmpty &&
          retryClean.length >= (finalText.length * 0.9).floor() &&
          _repeatRatio(retryClean) <= ratio) {
        finalText = retryClean;
      }
    }
    if (finalText.isEmpty) {
      // 组长终稿失败 → 直接拼段兜底（保证有产出）
      final String joined = _cleanFinalChapter(
        finalDrafts.where((String d) => d.trim().isNotEmpty).join('\n\n'),
      );
      final String joinedNote = _qualityNote(joined, cfg);
      return (
        content: joined.isEmpty ? null : joined,
        acceptance: acceptance,
        shortfall: joinedNote.isNotEmpty,
        qualityNote: joinedNote,
        sections: exportSections,
      );
    }
    final String qualityNote = _qualityNote(finalText, cfg);
    final bool shortfall = qualityNote.isNotEmpty;
    if (!shortfall) {
      onPhase?.call(
        MultiAgentChapterPhase.polishing,
        0.95,
        '定稿 ${finalText.length} 字，通过质量闸',
      );
    } else {
      onPhase?.call(
        MultiAgentChapterPhase.polishing,
        0.95,
        '$qualityNote，按草稿保存',
      );
    }
    return (
      content: finalText,
      acceptance: acceptance,
      shortfall: shortfall,
      qualityNote: qualityNote,
      sections: exportSections,
    );
  }

  /// 质量闸判定：返回不合格原因（空串 = 通过）。
  static String _qualityNote(String text, MultiAgentBookConfig cfg) =>
      _qualityNoteParams(
        text,
        minWords: cfg.minFinalWords,
        maxRepeatRatio: cfg.maxRepeatRatio,
      );

  /// 质量闸的**参数化实现**（[MultiAgentBookConfig] 之外的调用方也能用）。
  static String _qualityNoteParams(
    String text, {
    required int minWords,
    required double maxRepeatRatio,
  }) {
    final issue = FictionQuality.issue(text);
    if (issue != null) return '正文质量异常：$issue';
    final int len = text.trim().length;
    if (len < minWords) {
      return '字数不足（$len < $minWords）';
    }
    if (_looksLikeOutline(text)) {
      return '疑似大纲式输出（正文混入 Markdown 结构，AI 把写小说做成了续写大纲）';
    }
    final double ratio = _repeatRatio(text);
    if (ratio > maxRepeatRatio) {
      return '复读率过高（${(ratio * 100).round()}% > '
          '${(maxRepeatRatio * 100).round()}%）';
    }
    return '';
  }

  /// 公开入口：**定稿正文清洗**（供单章重写等外部调用方复用）。
  ///
  /// 单章重写与「一键生成书籍」必须走**同一套**清洗与质量闸 —— 两条路径各写
  /// 一份实现，正是历史上「一处修好、另一处照旧」的 BUG 来源。见
  /// `lib/application/services/chapter_rewrite_service.dart`。
  static String cleanFinalChapter(String raw) => _cleanFinalChapter(raw);

  /// 公开入口：**定稿质量闸**（空串 = 通过；非空 = 不合格原因）。
  static String chapterQualityNote(
    String text, {
    int minWords = kDefaultMinFinalWords,
    double maxRepeatRatio = kDefaultMaxRepeatRatio,
  }) => _qualityNoteParams(
    text,
    minWords: minWords,
    maxRepeatRatio: maxRepeatRatio,
  );

  /// 单章重写默认沿用的质量闸阈值（与 [MultiAgentBookConfig] 缺省一致）。
  static const int kDefaultMinFinalWords = 3200;
  static const double kDefaultMaxRepeatRatio = 0.5;

  /// 判断「写成了大纲」而不是小说。
  ///
  /// 注意：必须在**已清洗**的文本上判定 —— `_cleanFinalChapter` 已经把
  /// `#`/`**`/清单符号剥掉了，所以这里同时看两类证据：
  /// ① 残留的结构标记行；② **标签式条目行**（`地点：…` / `冲突：…` /
  /// `章节：…`），后者在清洗后依然存活，是「整段退化成大纲」的可靠特征
  ///（对照实验 D 组：`地点：…` `时间：…` 这类行成片出现）。
  static bool _looksLikeOutline(String text) {
    int hits = 0;
    for (final String raw in text.split(RegExp(r'\r?\n'))) {
      final String l = raw.trim();
      if (l.isEmpty) continue;
      if (RegExp(r'^#{1,6}\s').hasMatch(l) ||
          RegExp(r'^[-*+]\s{1,2}\S').hasMatch(l) ||
          RegExp(
            r'^(?:地点|时间|人物|事件|主题|冲突|场景|目标|伏笔|钩子|'
            r'章节|大纲|要求|设定|简介|概览|说明)[：:]',
          ).hasMatch(l)) {
        hits++;
      }
    }
    return hits >= 4;
  }

  /// 段落级重复率 = 1 - 去重段落数 / 总段落数（[0,1]，越高越复读）。
  ///
  /// 只统计 ≥12 字的段落（过滤「他说。」这类短对白，避免误判）。
  static double _repeatRatio(String text) {
    final List<String> paras = text
        .split(RegExp(r'\n+'))
        .map((String p) => p.trim())
        .where((String p) => p.length >= 12)
        .toList(growable: false);
    if (paras.length < 4) return 0;
    final int uniq = paras.toSet().length;
    return 1 - uniq / paras.length;
  }

  /// 段落 → 偏向写手元数据（组长指定 > 关键词匹配 > 槽位轮转）。
  ({int slot, String personaId, String personaName}) _personaMeta(
    SectionPlan s,
  ) {
    final WriterPersona? persona = matchPersona(
      s.title,
      s.brief,
      assignedPersonaId: s.personaId,
    );
    final int slot = persona?.slot ?? ((s.agent - 1) % kWriterCount) + 1;
    final WriterPersona p = personaForSlot(slot);
    return (slot: slot, personaId: p.id, personaName: p.nameZh);
  }

  /// 定稿正文清洗：剥思考块（成对/未闭合/裸标签）与段落小标题标记，
  /// 折叠多余空行 —— 质量闸在清洗后的纯正文上计量。
  static String _cleanFinalChapter(String raw) {
    String t = raw;
    // 参考素材 / 状态更新块剥离（最先做）：G1K 串行写书实测会把「线性状态更新
    // 参考素材履历」用的 `{"updates":[…]}` / `【设定更新】` 块一并吐进正文，
    // 必须在后续 Markdown / 复读折叠之前清掉，否则会被当成正文段落参与判重。
    t = AIOutputSanitizer.stripStateUpdateBlocks(t);
    // 元话语 / 元信息抬头剥离：模型会把「我是……主编智能体」「---润色后版本：」
    // 「【主编修订稿】…*目标：…*」「【本章正式章名】…【章末钩子】…」这类
    // **正文之前**的东西一并吐进章节（用户实测 BUG，见 output_sanitizer.dart
    // 顶部三种真实形态注释）。必须在这里做 —— 质量闸与复读判重都在其后。
    t = AIOutputSanitizer.stripMetaPreambles(t);
    t = t.replaceAll(
      RegExp(
        r'<think>[\s\S]*?</think>|<thinking>[\s\S]*?</thinking>',
        caseSensitive: false,
      ),
      '',
    );
    t = t.replaceFirst(
      RegExp(r'^\s*<(?:think|thinking)>[\s\S]*$', caseSensitive: false),
      '',
    );
    t = t.replaceAll(
      RegExp(r'</?(?:think|thinking)>', caseSensitive: false),
      '',
    );
    t = t.replaceAll(RegExp(r'【段落\d+[^】]*】'), '');
    // 剥掉 chat 模板泄漏标记（实测 RWKV 云端正文首行常是「>」/「>>」，
    // 也会偶发 `<|Assistant|>` 之类的特殊 token 文本）。
    t = t.replaceAll(RegExp(r'<\|[^|]{0,24}\|>'), '');
    t = t.replaceFirst(RegExp(r'^[\s>＞]+'), '');
    // Markdown 残留清理：整行标题（`# 第一章：xxx`）、行内加粗、清单符号
    // —— 实测模型会顺着 Markdown 大纲「续写文档」而不是写小说。
    t = t.replaceAll(RegExp(r'^[ \t]*#{1,6}[ \t]*.*$', multiLine: true), '');
    t = t.replaceAll(RegExp(r'^[ \t]*[-*+][ \t]+', multiLine: true), '');
    t = t.replaceAll('**', '');
    // 元信息开场白（「好的，我将…」「以下是…」「第 1/2 段…」）整行丢弃。
    t = t.replaceFirst(
      RegExp(
        r'^[ \t]*(?:\*\*)?(?:好的[，,]|我将|以下是|'
        r'第\s*\d+\s*[/／]\s*\d+\s*段)[^\n]*\n?',
      ),
      '',
    );
    // 收尾语剥离：「（全文完）」「（完）」「全文完」/「THE END」等
    //（模型常把「一章」误当「全书」写完，过早收尾 —— 这些标记与正文无关）。
    t = t.replaceAll(_closingMarkerLineRegExp, '');
    t = t.replaceAll(_closingMarkerInlineRegExp, '');
    // 相邻重复段落折叠（RWKV 复读最典型的形态：整段原样重复）。
    t = _dropAdjacentDuplicateParagraphs(t);
    // 尾部退化截断：一旦滑窗 4-gram 去重率跌破阈值就说明模型进入复读循环，
    // 其后的内容基本都是噪音 —— 从退化点截断，比整章丢弃划算得多
    //（实测退化尾部的 4-gram 去重率只有 0.10~0.29，而正常段落 ≥0.98）。
    final int onset = _degenerationOnset(t);
    if (onset > 0) t = t.substring(0, onset);
    t = t.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return t.trim();
  }

  /// 句末边界（含引号/括号收尾）。用于识别「被 max_tokens 截断的半句」。
  static final RegExp _sentenceBoundaryRegex = RegExp(
    r'[。！？!?…；;”』」）)\]】]',
  );

  /// 把新段 [next] 并入已累积正文 [accumulated]，去掉**跨段重复**。
  ///
  /// 两种真实形态（用户实测，第一卷第一章正文由 3 段拼成）：
  ///
  ///   ① **残句重起**：上一段被 `max_tokens` 截断在半句
  ///      （`…艾登惊呼道。薇拉猛地回过神`），新段把这半句重新写了一遍
  ///      （`薇拉猛地回过神来，瞳孔在昏暗的光线中骤然收缩。…`）
  ///      → 丢掉上一段的残句，保留新段。
  ///
  ///   ② **复述开篇**：模型把提示词里的「前文末尾」整段复述后再续写
  ///      → 丢掉新段里与已有内容重叠的前缀，只留新增部分。
  ///
  /// 判据刻意保守：动词性重合（无句末边界的残句）要求 ≥4 字且长度 ≤30；
  /// 整段重叠要求 ≥ [minOverlap]（12）字。误删正文比留一点重复更糟。
  static String _mergeSegment(
    String accumulated,
    String next, {
    int minOverlap = 12,
  }) {
    final String prev = accumulated.trimRight();
    final String n = next.trimLeft().trimRight();
    if (prev.isEmpty) return n;
    if (n.isEmpty) return prev;

    // ---- 形态①：上一段收在半句，新段正好从这半句重新起笔 ----
    final int lastBoundary = _lastSentenceBoundaryIndex(prev);
    final String partial = prev.substring(lastBoundary + 1).trimLeft();
    if (_isDroppableTail(partial) && n.startsWith(partial)) {
      return '${prev.substring(0, lastBoundary + 1).trimRight()}\n\n$n';
    }

    // ---- 形态②：新段前缀与已写内容尾部重叠 ----
    final int probe = n.length < 900 ? n.length : 900;
    int overlap = 0;
    for (int len = probe; len >= minOverlap; len--) {
      if (prev.endsWith(n.substring(0, len))) {
        overlap = len;
        break;
      }
    }
    if (overlap == 0) {
      // 没重叠，但上一段吊着一个短残句（截断）→ 丢掉残句再并入，
      // 否则正文里会留下 `…但眼神中却` 这种断句后被无关新句接上的痕迹。
      if (_isDroppableTail(partial) && lastBoundary >= 0) {
        return '${prev.substring(0, lastBoundary + 1).trimRight()}\n\n$n';
      }
      return '$prev\n\n$n';
    }
    final String fresh = n.substring(overlap).trimLeft();
    return fresh.isEmpty ? prev : '$prev\n\n$fresh';
  }

  /// 该残句是否属于「被截断、且不指向后续」的尾巴（可安全丢弃）。
  ///
  /// 收在 `：` `，` `、` 的残句是**明确的延续信号**（`他低声说：` / `…，`），
  /// 必须保留；只有收在实字上的短残句（`…但眼神中却`）才是 max_tokens 截断的
  /// 产物，丢掉它再接新段才读得通。
  static bool _isDroppableTail(String partial) {
    if (partial.length < 4 || partial.length > 30) return false;
    return !RegExp(r'[：:，,、~～\-—–]$').hasMatch(partial);
  }

  /// 最后一个句末边界字符的下标；无边界返回 -1。
  static int _lastSentenceBoundaryIndex(String text) {
    int last = -1;
    for (final Match m in _sentenceBoundaryRegex.allMatches(text)) {
      last = m.end - 1;
    }
    return last;
  }

  /// 检测尾部退化起点（字符下标；0 = 未退化）。
  ///
  /// 做法：按 [window] 字滑窗统计 4-gram 去重率，从尾部往前找**连续**
  /// 低于 [threshold] 的区间；退化起点取该区间之后的第一个窗口边界。
  /// 只在前半部分健康、后半部分退化时才截断（避免误伤正常文本）。
  static int _degenerationOnset(
    String text, {
    double threshold = 0.55,
    int window = 400,
  }) {
    final String t = text.replaceAll(RegExp(r'\s'), '');
    if (t.length < window * 4) return 0;
    final int n = 4;
    double distinctAt(int start) {
      final String seg = t.substring(start, start + window);
      final List<String> grams = <String>[
        for (int i = 0; i + n <= seg.length; i++) seg.substring(i, i + n),
      ];
      if (grams.isEmpty) return 1;
      return grams.toSet().length / grams.length;
    }

    final int step = window ~/ 2;
    // ⚠ 必须找「**连续的退化后缀**」，而不是「第一个低窗口」——
    // 旧实现从头扫描、命中第一个低窗口就砍掉其后全部内容：一章中间只要
    // 有一段对白/复述导致某窗口去重率偏低，整章后半就被腰斩
    //（+18 实测：多章最终只有 2000~2600 字卡在字数闸，就是被误伤砍掉的）。
    int onset = -1;
    bool anyDegenerate = false;
    for (int s = t.length - window; s >= 0; s -= step) {
      if (distinctAt(s) < threshold) {
        onset = s;
        anyDegenerate = true;
      } else {
        break;
      }
    }
    if (!anyDegenerate || onset <= 0) return 0;
    // ⚠ 健康前缀必须够长（≥ 全文 30%）：否则说明**整篇都在退化**
    //（典型：同一句式只换数字重复 300 遍），此时循环步进会停在 >0 的
    // 位置并返回一个极小的 onset，把正文砍成几十字 —— 这类稿子应当交给
    // 复读质量闸判「不合格并重写」，而不是截成残篇。
    if (onset < (t.length * 0.30).floor()) return 0;
    // 退化后缀同理必须够长（≥ 全文 25%）；零星的局部低窗口视为噪声。
    if (t.length - onset < (t.length * 0.25).floor()) return 0;
    return onset;
  }

  /// 收尾语：整行独占（如「（全文完）」单独一行）。
  static final RegExp _closingMarkerLineRegExp = RegExp(
    r'^[ \t]*[（(【\[]?\s*(?:全文完|全书完|全書完|剧终|終章|完结|完|'
    r'THE\s*END|END)\s*[)）】\]]?[ \t]*$',
    caseSensitive: false,
    multiLine: true,
  );

  /// 收尾语：行内括号声明（如「……就此结束。（全文完）」）。
  static final RegExp _closingMarkerInlineRegExp = RegExp(
    r'[（(【\[]\s*(?:全文完|全书完|全書完|剧终|完结|完)\s*[)）】\]]',
  );

  /// 折叠「与前一段完全相同」的段落，并顺带丢弃重复的空段。
  static String _dropAdjacentDuplicateParagraphs(String text) {
    final List<String> paras = text.split(RegExp(r'\n\s*\n'));
    final StringBuffer sb = StringBuffer();
    String prev = '';
    for (final String raw in paras) {
      final String cur = raw.trim();
      if (cur.isEmpty) continue;
      if (cur == prev) continue;
      if (sb.isNotEmpty) sb.write('\n\n');
      sb.write(cur);
      prev = cur;
    }
    return sb.toString();
  }

  // -----------------------------------------------------------------------
  // 提示词（静态，便于审阅与单测）
  // -----------------------------------------------------------------------

  String _mainOutlinePrompt(MultiAgentBookConfig cfg) =>
      _renderPrompt('Book/mainOutline', <String, String>{
        'cfg_bookTitle': (cfg.bookTitle).toString(),
        'cfg_authorName': (cfg.authorName).toString(),
        'cfg_targetVolumes': (cfg.targetVolumes).toString(),
        'cfg_chaptersPerVolume': (cfg.chaptersPerVolume).toString(),
      });

  String _volumeOutlinePrompt(
    MultiAgentBookConfig cfg,
    String mainOutline,
    int index,
  ) => _renderPrompt('Book/volumeOutline', <String, String>{
    'cfg_bookTitle': (cfg.bookTitle).toString(),
    'cfg_authorName': (cfg.authorName).toString(),
    'mainOutline': (mainOutline).toString(),
    'index': (index).toString(),
    'cfg_targetVolumes': (cfg.targetVolumes).toString(),
    'cfg_chaptersPerVolume': (cfg.chaptersPerVolume).toString(),
  });

  String _chapterOutlinePrompt(
    MultiAgentBookConfig cfg,
    String mainOutline,
    String volumeOutline,
    int chapterIndex,
  ) => _renderPrompt('Book/chapterOutline', <String, String>{
    'cfg_bookTitle': (cfg.bookTitle).toString(),
    'mainOutline': (mainOutline).toString(),
    'context3': (volumeOutline.isEmpty ? '（见主线大纲中该卷的推进脉络）' : volumeOutline)
        .toString(),
    'chapterIndex': (chapterIndex).toString(),
    'cfg_chaptersPerVolume': (cfg.chaptersPerVolume).toString(),
    'styleRules': _styleSection(),
  });

  String _leaderSystemPrompt() => _renderPrompt(
    'Book/leaderSystem',
    <String, String>{'context1': (describePersonasForPrompt()).toString()},
  );

  String _writerSystemPrompt(int slot) {
    final WriterPersona p = personaForSlot(slot);
    return _renderPrompt('Book/writerSystem', <String, String>{
      'slot': (slot).toString(),
      'p_nameZh': (p.nameZh).toString(),
      'p_biasPrompt': (p.biasPrompt).toString(),
    });
  }

  /// 主笔系统提示（单笔直书 / 分段串行共用）——独立完成整章，不派活。
  String _leadWriterSystemPrompt() =>
      _renderPrompt('Book/leadWriterSystem', <String, String>{});

  /// 单笔直书：一次调用写出整章正文（实测仅适合短章：≤ ~2600 字）。
  String _soloChapterPrompt(
    String mainOutline,
    String volumeOutline,
    String chapterOutline, {
    required int targetChars,
  }) => _renderPrompt('Book/soloChapter', <String, String>{
    'context1': (_ref(mainOutline, 0.20)).toString(),
    'context2': (volumeOutline.isEmpty ? '（见主线大纲）' : _ref(volumeOutline, 0.15))
        .toString(),
    'context3':
        (chapterOutline.isEmpty ? '（见主线大纲与分卷大纲）' : _ref(chapterOutline, 0.22))
            .toString(),
    'targetChars': (targetChars).toString(),
    'styleRules': _styleSection(),
  });

  /// 分段串行：第 [index] 段（[tail] 非空时接着上文续写）。
  String _serialSegmentPrompt({
    required String mainOutline,
    required String volText,
    required String chText,
    required int index,
    required int targetChars,
    required String tail,
    required bool shortLast,
  }) {
    final bool first = tail.trim().isEmpty;
    return _renderPrompt('Book/serialSegment', <String, String>{
      'context1': (_ref(mainOutline, 0.20)).toString(),
      'volText': (volText).toString(),
      'chText': (chText).toString(),
      'context4':
          (first
                  ? '请从本章开篇写起。'
                  // 同 [_beamCandidatePrompt]：去掉会被回抄的 `【上文结尾】` 标记，
                  // 换成「前文末尾」+ 明确禁止输出。
                  : '【前文末尾（仅供衔接上下文，**不要输出这一段**）】\n$tail\n\n'
                        '请**紧接上文继续写**，只输出新增的正文；'
                        '若前文末尾停在半句，请先把那半句补完再往下写。')
              .toString(),
      'index': (index).toString(),
      'targetChars': (targetChars).toString(),
      'context7':
          (shortLast ? '⚠ 上一段写得太短，本段必须写足约 $targetChars 字，不要提前收尾。\n' : '')
              .toString(),
      'styleRules': _styleSection(),
    });
  }

  String _planPrompt(
    MultiAgentBookConfig cfg,
    String mainOutline,
    String volText,
    String chText,
  ) => _renderPrompt('Book/plan', <String, String>{
    'context1': (_ref(mainOutline, 0.20)).toString(),
    'volText': (volText).toString(),
    'chText': (chText).toString(),
    'kWriterCount': (kWriterCount).toString(),
    'cfg_chapterWordTarget': (cfg.chapterWordTarget).toString(),
    'styleRules': _styleSection(),
  });

  String _writerPrompt(
    MultiAgentBookConfig cfg,
    String mainOutline,
    String volText,
    String chText,
    SectionPlan plan,
    int total,
  ) => _renderPrompt('Book/writer', <String, String>{
    'context1': (_ref(mainOutline, 0.20)).toString(),
    'volText': (volText).toString(),
    'chText': (chText).toString(),
    'plan_agent': (plan.agent).toString(),
    'total': (total).toString(),
    'plan_title': (plan.title).toString(),
    'plan_brief': (plan.brief).toString(),
    'plan_boundary': (plan.boundary).toString(),
    'plan_wordTarget': (plan.wordTarget).toString(),
    'styleRules': _styleSection(),
  });

  String _acceptancePrompt(
    String chText,
    List<SectionPlan> plan,
    List<String> drafts,
  ) {
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < plan.length && i < drafts.length; i++) {
      sb
        ..writeln(
          '【段落${i + 1} · ${plan[i].title}（agent=${plan[i].agent}，'
          '目标 ${plan[i].wordTarget} 字）】',
        )
        ..writeln(
          drafts[i].trim().isEmpty ? '（未交稿）' : _truncate(drafts[i], 900),
        )
        ..writeln();
    }
    return _renderPrompt('Book/acceptance', <String, String>{
      'chText': (chText).toString(),
      'sb': (sb).toString(),
    });
  }

  /// 定稿后从**最终正文**抽取「设定 / 履历待更新项」。
  ///
  /// 为什么必须有这一步：只有「组长 + 9 写手」工艺（[_writeChapterWithTeam]）
  /// 会产生 `TeamAcceptance.updateItems`，而**单笔直书 / 主笔分段串行 /
  /// 续写优选**这三种工艺都返回 `acceptance: null` —— 于是它们跑完后
  /// 「验收后更新分派」无事可做，人物管理与世界观子项**不会有任何更新**
  /// （只剩规则同步按名匹配追加的履历）。用户实测的正是「G1K 串行写书，
  /// 章节完成后人物/世界观没更新」，即命中这条。
  ///
  /// 这里补一次轻量抽取，复用与组长验收完全相同的 `updates[]` 模板接口，
  /// 让四种工艺在「审核通过 → 自动更新人物与世界观」上行为一致。
  ///
  /// 任何失败（未配 leader / 解析失败 / 通道异常）都返回空 `TeamAcceptance`，
  /// 绝不阻断章节落库。
  Future<TeamAcceptance> _extractAcceptanceFromProse({
    required AgentChatExecutor chat,
    required AgentStateGroup team,
    required String chapterText,
    required String chapterOutline,
  }) async {
    final AgentStateEntry? leaderEntry = team.leader;
    if (leaderEntry == null || chapterText.trim().isEmpty) {
      return const TeamAcceptance();
    }
    try {
      // 独立通道（不累积历史）：抽取属于一次性任务，混进写作通道会污染
      // 上下文并抬高后续段落的复读概率（RWKV 是 RNN，见本文件顶部注释）。
      final _AgentChannel probe = _AgentChannel(
        leaderEntry,
        _leadWriterSystemPrompt(),
        chat,
        keepHistory: false,
      );
      final String raw = await probe.send(
        _renderPrompt('Book/stateUpdates', <String, String>{
          'chText': _ref(chapterOutline, 0.25),
          'chapter': _truncate(chapterText, 6000),
        }),
        maxTokens: 1600,
        temperature: 0.2,
      );
      return parseAcceptanceReport(raw) ?? const TeamAcceptance();
    } on Object {
      return const TeamAcceptance();
    }
  }

  /// 章节池结束后：把**质量未达标 / 正文为空**的章节**先调大纲、再重写**一遍。
  ///
  /// 用户 2026-10-09 要求：「章节中质量校验失败的在所有章节完成后需要
  /// 自动执行关联前后章节内容信息和该章节大纲重写该章节动作」；2026-10-10 定位
  /// （`.workbuddy/memory/2026-10-10.md` §11）后把「关联前后章节」落成**先修订
  /// 本章大纲、再走重写链路** —— 只重写正文而不修大纲，等于照着坏大纲再写一遍
  /// 坏正文，实测会次次失败。
  ///
  /// 复用 [ChapterRewriteService.repairOutlineAndRewrite]，它自带：
  /// 前章结尾 / 下章开头 800 字 + 同卷梗概 + 本卷大纲的修订上下文、
  /// `OutlineRepairText` 的元信息清洗（「（约700字）」这类残渣一律剔除）、
  /// 与本服务**同一套**清洗与质量闸、以及落库后的设定同步（含故事内时间节点）。
  ///
  /// 每章修复期间经 [onChapterEvent] 上报矩阵事件（polishing → done / failed），
  /// 让「写作动态」面板显示的是**修复后**的最终状态，而不是修复前的红格。
  ///
  /// 安全：每章独立 try/catch；任何失败只记 warning，绝不改变已落库的正文。
  ///
  /// 返回**本次修复成功**的章数（供 [generate] 修正 `written` 计数 ——
  /// 否则跑完 30 章、结果摘要还说「27/30 章已落库」，与事实不符）。
  Future<int> _rewriteFailedChapters({
    required String projectId,
    required MultiAgentBookConfig cfg,
    required List<String> warnings,
    void Function(String step, double? progress)? onProgress,
    MultiAgentChapterListener? onChapterEvent,
    Map<String, String> volumeTitleById = const <String, String>{},
  }) async {
    final ChapterRewriteService? rewriter = chapterRewriter;
    if (rewriter == null) return 0;
    final List<ChapterRow> rows = await chapters.getByProjectId(projectId);
    final List<ChapterRow> failed = <ChapterRow>[
      for (final ChapterRow ch in rows)
        if (_needsRewrite(ch, cfg)) ch,
    ];
    if (failed.isEmpty) return 0;
    onProgress?.call(
      '正在按前后章节调整 ${failed.length} 章的大纲并重写…', 0.972);
    int fixed = 0;
    for (int i = 0; i < failed.length; i++) {
      final ChapterRow ch = failed[i];
      final String tag = '${i + 1}/${failed.length}';
      onProgress?.call('调整大纲并重写《${ch.title}》（$tag）…', null);
      void emit(MultiAgentChapterPhase phase, double progress, String detail) {
        onChapterEvent?.call(
          MultiAgentChapterEvent(
            chapterId: ch.id,
            chapterTitle: ch.title,
            volumeTitle: volumeTitleById[ch.volumeId] ?? '',
            phase: phase,
            progress: progress,
            detail: detail,
          ),
        );
      }

      emit(MultiAgentChapterPhase.outlineRepair, 0.05, '正在按前后章节调整本章大纲…');
      try {
        final ChapterOutlineRepairResult res =
            await rewriter.repairOutlineAndRewrite(
          chapterId: ch.id,
          projectId: projectId,
          onProgress: (String phase) => onProgress?.call(
              '调整大纲并重写《${ch.title}》· $phase（$tag）…', null),
        );
        if (res.applied) {
          fixed++;
          emit(MultiAgentChapterPhase.done, 1, res.message);
        } else {
          emit(MultiAgentChapterPhase.failed, 1, res.message);
          warnings.add('《${ch.title}》自动修复未通过：${res.message}');
        }
      } on Object catch (e) {
        emit(MultiAgentChapterPhase.failed, 1, '$e');
        warnings.add('《${ch.title}》自动修复未执行：$e');
      }
    }
    warnings.add(
      '自动修复：$fixed/${failed.length} 章已按前后章节调整大纲并通过质量闸，'
      '其余可在「写作动态」或「章节管理」里手动重写。',
    );
    return fixed;
  }

  /// 把「已完成章 / 总章数」写回 `projects.progress`（失败静默）。
  ///
  /// 生成过程里那个百分比只反映**本次运行**；`projects.progress` 是持久化的
  /// 完成度。收尾必须刷新一次，否则跑完 30 章、项目卡片上仍显示 0%
  ///（用户实测「项目进度未随编写完成度更新」）。
  Future<void> _refreshProgress(String projectId) async {
    try {
      final List<ChapterRow> rows = await chapters.getByProjectId(projectId);
      final int completed =
          rows.where((ChapterRow c) => c.status == 'Completed').length;
      await projects.updateProgress(
        projectId,
        progressFromChapterCounts(completed, rows.length).round(),
      );
    } on Object {
      // 进度只是展示用派生量，失败不能影响生成结果返回。
    }
  }

  /// 该章是否需要自动重写。
  ///
  /// 与 `ModuleStateService` 的前置条件同源 —— **只看正文事实，不看 status**
  /// （草稿章同样值得补，它们的正文往往只是短，不是坏）：
  ///   1. 正文为空：生成彻底失败，或污染纠偏后仍不合格而**根本没落库**；
  ///   2. 过不了定稿质量闸（[chapterQualityNote]：字数不足 / 疑似大纲式输出 /
  ///      复读率过高 / `FictionQuality` 异常）。
  static bool _needsRewrite(ChapterRow chapter, MultiAgentBookConfig cfg) {
    final String text = (chapter.content ?? '').trim();
    if (text.isEmpty) return true;
    return chapterQualityNote(
      text,
      minWords: cfg.minFinalWords,
      maxRepeatRatio: cfg.maxRepeatRatio,
    ).isNotEmpty;
  }

  String _reworkPrompt(
    SectionPlan plan,
    String problems,
    String previousDraft,
  ) => _renderPrompt('Book/rework', <String, String>{
    'plan_title': (plan.title).toString(),
    'context2': (problems.isEmpty ? '内容与边界不符' : problems).toString(),
    'plan_brief': (plan.brief).toString(),
    'plan_boundary': (plan.boundary).toString(),
    'context5':
        (previousDraft.trim().isEmpty
                ? ''
                : '你上一稿的问题是「重复拖沓」，上一稿内容（供你避开，'
                      '不要照抄其句式）：\n${_truncate(previousDraft.trim(), 300)}\n\n')
            .toString(),
    'plan_wordTarget': (plan.wordTarget).toString(),
  });

  String _leaderRewritePrompt(SectionPlan plan, String problems) =>
      _renderPrompt('Book/leaderRewrite', <String, String>{
        'plan_title': (plan.title).toString(),
        'plan_brief': (plan.brief).toString(),
        'plan_boundary': (plan.boundary).toString(),
        'context4': (problems.isEmpty ? '内容与边界不符' : problems).toString(),
        'plan_wordTarget': (plan.wordTarget).toString(),
      });

  String _assemblyPrompt(
    String mainOutline,
    String chText,
    int count,
    String sections,
  ) => _renderPrompt('Book/assembly', <String, String>{
    'context1': (_ref(mainOutline, 0.20)).toString(),
    'chText': (chText).toString(),
    'count': (count).toString(),
    'sections': (sections).toString(),
  });

  // -----------------------------------------------------------------------
  // 落库 / 归档 / 工具
  // -----------------------------------------------------------------------

  Future<({String id, String name, bool adjusted, bool revived})>
  _createProject(MultiAgentBookConfig cfg) async {
    // 重名解决统一交给仓储层（曾因只查「未删除」同名项目而漏判，
    // 直接插入炸 UNIQUE constraint failed: projects.name）。
    final ProjectNameResolution res = await projects.createResolvingName(
      ProjectsCompanion.insert(
        id: _uuid.v4(),
        name: cfg.bookTitle,
        type: '其他',
        settings: Value(
          jsonEncode(<String, Object?>{
            'author': cfg.authorName,
            'targetVolumes': cfg.targetVolumes,
            'chaptersPerVolume': cfg.chaptersPerVolume,
            'subAgentCount': cfg.subAgentCount,
            'concurrency': cfg.concurrency,
            'enableAI': true,
            'template': 'AI多智能体协同',
          }),
        ),
      ),
    );
    return (
      id: res.row.id,
      name: res.actualName,
      adjusted: res.adjusted,
      revived: res.revived,
    );
  }

  /// 归档钩子包装：任何失败折叠为 warning，绝不阻塞主流程。
  Future<void> _emitArchive(
    List<String> warnings, {
    required String level,
    required String? projectId,
    required String title,
    required String content,
    required Map<String, String> metadata,
  }) async {
    final TeamArchiveHook? hook = archiveHook;
    if (hook == null) return;
    try {
      await hook(
        level: level,
        projectId: projectId,
        title: title,
        content: content,
        metadata: metadata,
      );
    } on Object catch (e) {
      warnings.add('[$level] 档案写入失败：$e');
    }
  }

  /// 简单并发池：最多 [limit] 个 worker，按序消费任务，保持结果顺序。
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

  /// 与 [_runPool] 相同，但把**并发道的固定编号**透给任务函数。
  ///
  /// 为什么要它：规划组的 9 条写手通道各自持有一条 RWKV state 会话，
  /// 「同一 session 绝不并发写」必须靠**排程**保证 —— 一个道固定绑一条通道，
  /// 任何时刻任一通道只被一个道使用。若改成按「任务序号取模」轮转，
  /// 任务序号一旦跨过通道数的整数倍（章节大纲的序号是**卷内序号**，
  /// 每卷都从 1 重新数），就会出现两条在飞任务落到同一条会话上。
  static Future<List<B>> _runPoolIndexed<A, B>(
    int limit,
    List<A> items,
    Future<B> Function(A item, int lane) task,
  ) async {
    if (items.isEmpty) return <B>[];
    final List<B?> results = List<B?>.filled(items.length, null);
    int next = 0;
    Future<void> worker(int lane) async {
      while (true) {
        final int i = next++;
        if (i >= items.length) return;
        results[i] = await task(items[i], lane);
      }
    }

    final int workers = limit.clamp(1, items.length);
    await Future.wait(<Future<void>>[
      for (int w = 0; w < workers; w++) worker(w),
    ]);
    return <B>[for (final B? r in results) r as B];
  }

  static String _truncate(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}…';

  /// 参考上下文预算（字符）—— 由运行时「参考预算 token」折算，按提示词槽位分摊：
  /// 主线大纲 45% / 分卷大纲 30% / 章节大纲 15%（合计 ≤ 90%，余量给指令与段落任务）。
  ///
  /// ⚠ 折算系数是**实测值 1 token ≈ 1 中文字**（`kTokensPerChineseChar`），
  /// 不是早先假定的 1.6 字/token —— 旧系数把 token 数低估约 60%，
  /// 在「最大令牌数 = 16000、窗口 = 16384」时会让提示词自己就撑爆上下文。
  static int _refBudgetChars(double share) {
    final int tokens = aiRuntimeSettings.referenceBudgetTokens;
    if (tokens <= 0) return 1500;
    final int chars = (tokens * share / AiRuntimeSettings.kTokensPerChineseChar)
        .floor();
    return chars.clamp(600, 24000);
  }

  /// 把 Markdown 大纲「去格式化」后再喂给模型。
  ///
  /// ⚠ 实测踩坑：本项目的大纲是 Markdown 格式（`#`/`##`/`**`），直接整段塞进
  /// 提示词会让模型**续写大纲格式**而不是写小说 —— 产出里出现
  /// `# 第一章：织女星异常` / `## 场景设定与时间线` / `**地点**：…`，
  /// 甚至整段退化成大纲（对照实验 D 组 1589 字全是结构标记）。
  /// 去掉结构标记后，模型更倾向把它当「剧情素材」而非「待续写的文档」。
  static String _deMarkdown(String text) {
    String t = text;
    t = t.replaceAll(RegExp(r'^[ \t]*#{1,6}[ \t]*', multiLine: true), '');
    t = t.replaceAll(RegExp(r'^[ \t]*[-*+][ \t]+', multiLine: true), '');
    t = t.replaceAll('**', '').replaceAll('__', '');
    t = t.replaceAll(RegExp(r'^[ \t]*>[ \t]?', multiLine: true), '');
    t = t.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return t.trim();
  }

  /// 大纲入 prompt 的统一处理：去 Markdown → 按预算截断。
  ///
  /// ⚠ **正文阶段的参考预算必须收窄**：实测同一提示词把大纲从 350 字加到
  /// 3800 字，段落复读率从 0.000 涨到 0.102、段 2 直接退化到 0.896 ——
  /// RWKV 是 RNN，**提示词里出现过的 n-gram 会被持续抬高概率**，
  /// 长大纲等于给模型一堆可复读的素材。正文只喂：
  /// 本章大纲（≈全文）+ 精简卷纲 + 主线提要。
  static String _ref(String outline, double share) =>
      _truncate(_deMarkdown(outline), _refBudgetChars(share));

  /// 从章节大纲提取**正式章节名**（大纲提示词要求首行 `标题：《…》`）。
  /// 章节梗概（一句话，≤120 字）。
  ///
  /// 章节记录**只保留最终正文 + 短梗概**，不再塞入大纲草稿与过程数据 ——
  /// 旧实现把 900 字大纲原文写进 `summary`，章节编辑页里「正文」区域看起来
  /// 像一堆草稿（用户反馈）。清洗规则见 `ChapterTitleParser.extractBrief`。
  static String _chapterBrief(String outline, String name) =>
      ChapterTitleParser.extractBrief(outline, name);

  /// 批量章名整理：一次调用为**所有**格式不规范的章节重新命名。
  ///
  /// 为什么要批量而不是逐章：3 卷 × 10 章的规模下逐章调用会多出 30 次往返；
  /// 而「给一组摘要各起一个章名」本来就是同一个小任务，合并成一次调用既快
  /// 又天然避免相邻章重名。失败/未配模型时返回空表，调用方回落到「第N章」。
  Future<Map<int, String>> _synthesiseChapterNames({
    required AgentChatExecutor chat,
    required MultiAgentBookConfig cfg,
    required List<String> outlines,
    required List<int> indices,
    required List<(VolumeRow, int)> slots,
    required List<VolumeRow> volumes,
  }) async {
    if (indices.isEmpty) return const <int, String>{};
    final StringBuffer items = StringBuffer();
    for (final int i in indices.take(60)) {
      final (VolumeRow vol, int cIdx) = slots[i];
      final int vIdx = volumes.indexOf(vol);
      final String snippet = ChapterTitleParser.extractBrief(
        outlines[i],
        '',
        maxChars: 90,
      );
      items.writeln(
        '${i + 1}. 第${_cn(vIdx + 1)}卷第${_cn(cIdx)}章｜'
        '${snippet.isEmpty ? '（该章大纲为空，请取一个中性的文学化章名）' : snippet}',
      );
    }
    try {
      final String raw = await chat(
        _renderPrompt('Book/chapterNamesSystem', const <String, String>{}),
        <ChatMessage>[
          ChatMessage.user(
            _renderPrompt('Book/chapterNames', <String, String>{
              'cfg_bookTitle': cfg.bookTitle,
              'items': items.toString().trim(),
            }),
          ),
        ],
        maxTokens: 1600,
        temperature: 0.5,
      );
      return _parseChapterNameMap(raw, indices);
    } on Object {
      // 命名失败不阻断写书 —— 回落「第N章」比让整本书开不了工好得多。
      return const <int, String>{};
    }
  }

  /// 从模型回复中解析 `{"names":[{"i":1,"name":"…"}]}`，容忍围栏与前后杂文本。
  ///
  /// [allowed] 是**全书 1-based 序号**白名单；不在表里的条目一律忽略，
  /// 避免模型多吐/错位把章名安到别的章上。
  static Map<int, String> _parseChapterNameMap(
    String raw,
    List<int> allowed,
  ) {
    final Map<int, String> out = <int, String>{};
    final Set<int> allowedSet = <int>{for (final int i in allowed) i + 1};
    String text = raw.trim();
    final RegExp fence = RegExp(r'```(?:json)?([\s\S]*?)```', multiLine: true);
    final RegExpMatch? fenced = fence.firstMatch(text);
    if (fenced != null) text = fenced.group(1)!.trim();
    for (int start = 0; start < text.length; start++) {
      if (text[start] != '{') continue;
      int depth = 0;
      bool quoted = false;
      bool escaped = false;
      for (int i = start; i < text.length; i++) {
        final String ch = text[i];
        if (escaped) {
          escaped = false;
          continue;
        }
        if (ch == r'\' && quoted) {
          escaped = true;
          continue;
        }
        if (ch == '"') quoted = !quoted;
        if (quoted) continue;
        if (ch == '{') depth++;
        if (ch == '}') {
          depth--;
          if (depth != 0) continue;
          final Object? decoded = _tryDecode(text.substring(start, i + 1));
          if (decoded is Map && decoded['names'] is List) {
            for (final Object? item in decoded['names'] as List) {
              if (item is! Map) continue;
              final Object? rawIndex = item['i'] ?? item['index'] ?? item['n'];
              final int? index = rawIndex is int
                  ? rawIndex
                  : int.tryParse(rawIndex?.toString() ?? '');
              final String name = (item['name'] ?? item['title'] ?? '')
                  .toString()
                  .trim();
              if (index == null || name.isEmpty) continue;
              if (!allowedSet.contains(index)) continue;
              out[index - 1] = name;
            }
            if (out.isNotEmpty) return out;
          }
          break;
        }
      }
    }
    return out;
  }

  static Object? _tryDecode(String json) {
    try {
      return jsonDecode(json);
    } on FormatException {
      return null;
    }
  }

  static String _firstLine(String text, int max) {
    final String line = text
        .trim()
        .split(RegExp(r'\r?\n'))
        .firstWhere((String l) => l.trim().isNotEmpty, orElse: () => '');
    return _truncate(line.trim(), max);
  }

  static String _fmtDate(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  static String _cn(int n) {
    const List<String> cn = <String>[
      '零',
      '一',
      '二',
      '三',
      '四',
      '五',
      '六',
      '七',
      '八',
      '九',
      '十',
    ];
    if (n <= 10) return cn[n];
    if (n < 20) return '十${cn[n - 10]}';
    if (n < 100) {
      final int tens = n ~/ 10;
      final int ones = n % 10;
      return '${cn[tens]}十${ones == 0 ? '' : cn[ones]}';
    }
    return '$n';
  }

  // ---- 纯解析：组长 JSON 段落计划 ----

  /// 解析组长的段落分工 JSON。容忍 Markdown 围栏与前后杂文本；
  /// 解析失败或为空返回空列表（调用方走 fallbackPlan）。
  static List<SectionPlan> parseSectionPlan(
    String raw, {
    required int expectedWriters,
  }) {
    String text = raw.trim();
    final RegExp fence = RegExp(r'```(?:json)?([\s\S]*?)```', multiLine: true);
    final RegExpMatch? m = fence.firstMatch(text);
    if (m != null) text = m.group(1)!.trim();
    final int start = text.indexOf('[');
    final int end = text.lastIndexOf(']');
    if (start < 0 || end <= start) return const <SectionPlan>[];
    final Object? decoded;
    try {
      decoded = jsonDecode(text.substring(start, end + 1));
    } on Object {
      return const <SectionPlan>[];
    }
    if (decoded is! List) return const <SectionPlan>[];
    final List<SectionPlan> plans = <SectionPlan>[];
    for (final Object? item in decoded) {
      if (item is! Map) continue;
      final String title = (item['title'] ?? '段落').toString();
      final String brief = (item['brief'] ?? '').toString();
      final String boundary = (item['boundary'] ?? '').toString();
      if (brief.trim().isEmpty && boundary.trim().isEmpty) continue;
      plans.add(
        SectionPlan(
          agent: (item['agent'] as num?)?.toInt() ?? plans.length + 1,
          title: title,
          brief: brief,
          boundary: boundary,
          wordTarget: (item['wordTarget'] as num?)?.toInt() ?? 350,
          personaId: ((item['persona'] ?? item['personaId']) ?? '').toString(),
        ),
      );
    }
    return plans;
  }

  /// 组长规划失败时的兜底：均匀切分章节能给写手的最低保障任务。
  static List<SectionPlan> fallbackPlan({
    required int writers,
    required int targetWords,
  }) {
    final int per = (targetWords / writers).round();
    return <SectionPlan>[
      for (int i = 1; i <= writers; i++)
        SectionPlan(
          agent: i,
          title: '第$i段',
          brief:
              '按章节大纲顺序推进剧情的第 $i/$writers 部分：'
              '从上一段结束处继续，完成该部分的关键事件与人物互动，'
              '保持情绪节奏递进。',
          boundary: i == writers
              ? '完成章节大纲的全部内容，并以本章钩子收尾。'
              : '开始于上一段结束边界，结束于本章进度约 ${(100 * i / writers).round()}% 处的剧情点。',
          wordTarget: per,
        ),
    ];
  }

  // ---- 纯解析：组长验收报告 ----

  /// 解析组长验收 JSON（容忍围栏与杂文本）；解析失败返回 null
  /// （调用方按「全部合格 + 空报告」放行，防回归）。
  static TeamAcceptance? parseAcceptanceReport(String raw) {
    String text = raw.trim();
    final RegExp fence = RegExp(r'```(?:json)?([\s\S]*?)```', multiLine: true);
    final RegExpMatch? m = fence.firstMatch(text);
    if (m != null) text = m.group(1)!.trim();
    final int start = text.indexOf('{');
    final int end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(text.substring(start, end + 1));
    } on Object {
      return null;
    }
    if (decoded is! Map) return null;

    final List<ParagraphVerdict> verdicts = <ParagraphVerdict>[];
    final Object? rawVerdicts = decoded['paragraphs'] ?? decoded['verdicts'];
    if (rawVerdicts is List) {
      for (final Object? item in rawVerdicts) {
        if (item is! Map) continue;
        verdicts.add(
          ParagraphVerdict(
            agent: (item['agent'] as num?)?.toInt() ?? 0,
            accepted: item['accepted'] == true,
            problems: (item['problems'] ?? item['issue'] ?? '').toString(),
          ),
        );
      }
    }

    final Object? rawReport = decoded['report'];
    String timeRange = '', themeTask = '', gains = '', safeguards = '';
    if (rawReport is Map) {
      timeRange = (rawReport['timeRange'] ?? '').toString();
      themeTask = (rawReport['themeTask'] ?? '').toString();
      gains = (rawReport['gains'] ?? rawReport['gainsLosses'] ?? '').toString();
      safeguards = (rawReport['safeguards'] ?? '').toString();
    }

    final List<Map<String, Object?>> updates = <Map<String, Object?>>[];
    final Object? rawUpdates = decoded['updates'];
    if (rawUpdates is List) {
      for (final Object? item in rawUpdates) {
        if (item is Map) {
          updates.add(
            item.map(
              (Object? k, Object? v) => MapEntry<String, Object?>('$k', v),
            ),
          );
        }
      }
    }

    return TeamAcceptance(
      verdicts: verdicts,
      timeRange: timeRange,
      themeTask: themeTask,
      gainsLosses: gains,
      safeguards: safeguards,
      updateItems: updates,
    );
  }
}
