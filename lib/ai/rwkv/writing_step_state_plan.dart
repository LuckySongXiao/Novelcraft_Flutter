// 「自动化写作 → 每个工艺步骤用 基模 + 对应 state 执行」的绑定层。
//
// ## 解决的问题
//
// State Tuning 的产物是**初始 state**（24 个 `blocks.N.att.time_state`），不是
// 完整权重，当前后端（llama.cpp / `rwkv_lightning_cuda`）都无法在推理时挂载。
// 唯一能真跑起来的方式：
//
//   1. 把 state 合并进基底权重，得到一个**独立的模型**（同一个 base、不同 state
//      就是不同模型）；
//   2. 在端点上把它注册成一个 model id，写进 [RwkvStateArtifact.mergedModelId]；
//   3. 自动化写作时，**每个工艺步骤**按自己的 target 解析出对应模型 id 并下发。
//
// 本文件只做第 3 步的纯逻辑：步骤 → state 目标 → 产品 → 请求模型 id / 阻塞原因。
// 不做 IO，不依赖 Flutter，便于单测与在健康页/日志里如实展示。
//
// ⚠ 硬约束（与 `state_tuning_registry.dart` 一致）：
//   * 一个 state 只服一种输出形状 —— 正文写手不能吃「大纲 JSON」的 state；
//   * state 必须配同款基底模型，基底不一致直接判不可用（宁可回落基模，不能乱挂）。
library;

import 'rwkv_engine_state_index.dart';
import 'state_tuning_registry.dart';

/// 自动化写作里会调用模型的工艺步骤。
///
/// [stageIds] 对应「写作工艺 Prompt 模板」的 stage id（见 `writing_prompt_catalog.dart`），
/// 用于把运行时渲染的模板反查回步骤（日志 / 健康页展示）。
enum WritingCraftStep {
  /// 主线大纲（JSON 结构）。
  mainOutline(
    labelZh: '主大纲',
    stageIds: <String>['Book/mainOutline'],
    target: RwkvStateTarget.outlinerStruct,
  ),

  /// 分卷大纲（JSON 结构）。
  volumeOutline(
    labelZh: '分卷大纲',
    stageIds: <String>['Book/volumeOutline'],
    target: RwkvStateTarget.outlinerStruct,
  ),

  /// 章节大纲（JSON 结构）。
  chapterOutline(
    labelZh: '章节大纲',
    stageIds: <String>['Book/chapterOutline'],
    target: RwkvStateTarget.outlinerStruct,
  ),

  /// 组长派活 / 规划组写手分工（输出是任务指令，没有固定形状）。
  planning(
    labelZh: '组长派活',
    stageIds: <String>[
      'Book/planningLeader',
      'Book/planningWriter',
      'Book/plan',
    ],
    target: null,
  ),

  /// 章节正文（含单笔直书 / 主笔分段 / 续写优选 / 9 写手）。
  prose(
    labelZh: '正文写手',
    stageIds: <String>[
      'Book/leaderSystem',
      'Book/writerSystem',
      'Book/leadWriterSystem',
      'Book/soloChapter',
      'Book/serialSegment',
      'Book/beamCandidate',
      'Book/writer',
    ],
    target: RwkvStateTarget.novelistProse,
  ),

  /// 拼接润色定稿。
  polish(
    labelZh: '拼接润色',
    stageIds: <String>['Book/polishSystem', 'Book/polish', 'Book/assembly'],
    target: RwkvStateTarget.copyeditorPatch,
  ),

  /// 验收打回后的返工 / 组长补写 / 整章重写。
  repair(
    labelZh: '返工修复',
    stageIds: <String>[
      'Book/repairSystem',
      'Book/repair',
      'Book/rework',
      'Book/leaderRewrite',
    ],
    target: RwkvStateTarget.copyeditorPatch,
  ),

  /// 章节细纲契约（8 字段纯文本行，分层写书的 L3）。
  chapterBrief(
    labelZh: '章节细纲',
    stageIds: <String>[],
    target: RwkvStateTarget.briefContract,
  ),

  /// 章节命名（输出是标题行列表）。
  chapterNames(
    labelZh: '章节命名',
    stageIds: <String>['Book/chapterNamesSystem', 'Book/chapterNames'],
    target: RwkvStateTarget.briefContract,
  ),

  /// 章末设定/履历抽取（`类别|名称|字段|一句话变化` 登记行）。
  stateUpdate(
    labelZh: '设定同步',
    stageIds: <String>['Book/stateUpdates', 'State/extract'],
    target: RwkvStateTarget.stateUpdates,
  ),

  /// 人物履历回放：按章节顺序维护人物状态与经历（ST-9）。
  characterUpdate(
    labelZh: '人物履历',
    stageIds: <String>['Book/characterLedger', 'State/character'],
    target: RwkvStateTarget.characterLedger,
  ),

  /// 世界观履历回放：按章节顺序维护地点/势力/设定变化（ST-10）。
  worldUpdate(
    labelZh: '世界观履历',
    stageIds: <String>['Book/worldLedger', 'State/world'],
    target: RwkvStateTarget.worldLedger,
  ),

  /// 审查（评分/问题清单，JSON）。
  review(
    labelZh: '审查',
    stageIds: <String>[
      'Review/reviewerSystem',
      'Review/reviewer',
      'Review/seniorSystem',
      'Review/senior',
      'Review/writerSystem',
      'Review/writer',
      'Review/guestSystem',
      'Review/guest',
    ],
    target: RwkvStateTarget.reviewReport,
  ),

  /// 跨章续写（伏笔义务 + 前章尾巴）。
  link(
    labelZh: '跨章续写',
    stageIds: <String>['Book/link'],
    target: RwkvStateTarget.chapterLinker,
  );

  const WritingCraftStep({
    required this.labelZh,
    required this.stageIds,
    required this.target,
  });

  final String labelZh;

  /// 该步骤会用到的写作工艺模板 stage id。
  final List<String> stageIds;

  /// 对应的 state 目标；null = 该步骤没有固定输出形状，不绑定 state。
  final RwkvStateTarget? target;

  /// 按模板 stage id 反查步骤（未知 stage 返回 null）。
  static WritingCraftStep? fromStageId(String stageId) {
    final String id = stageId.trim();
    if (id.isEmpty) return null;
    for (final WritingCraftStep step in values) {
      if (step.stageIds.contains(id)) return step;
    }
    return null;
  }
}

/// 某一步骤本轮实际使用的「模型 + state」。
class StepStateBinding {
  const StepStateBinding({
    required this.step,
    required this.stateId,
    required this.target,
    required this.statePath,
    required this.requestModel,
    required this.applied,
    required this.reason,
    this.engineStateId = '',
  });

  /// 未绑定 / 不可用：请求回落到基模。
  const StepStateBinding.fallback(
    this.step, {
    this.target,
    this.stateId = '',
    this.statePath = '',
    required this.reason,
  }) : requestModel = '',
       engineStateId = '',
       applied = false;

  final WritingCraftStep step;

  final RwkvStateTarget? target;

  /// 绑定的 state 产物 id（空 = 没有产物）。
  final String stateId;

  final String statePath;

  /// 该步骤应下发的 model id（空 = 沿用调用方给的基模）。
  final String requestModel;

  /// 该步骤应下发的 `state_id`（空 = 不带，按普通请求处理）。
  ///
  /// 非空时说明走「引擎上传初始 state」路线：模型是基模，state 由
  /// `rwkv_lightning_cuda` 在服务端切进来。
  final String engineStateId;

  /// 是否真的会把 state 那套权重用在这次调用上。
  final bool applied;

  /// 未生效的原因（applied = true 时为空）。
  final String reason;

  Map<String, Object?> toJson() => <String, Object?>{
    'step': step.name,
    'target': target?.code ?? '',
    'stateId': stateId,
    'requestModel': requestModel,
    'engineStateId': engineStateId,
    'applied': applied,
    'reason': reason,
  };
}

/// 一个 state 的「岗位」——固化它的职责、服务的对象与产出形状。
///
/// 这样做的目的：基模固定不变，**某个岗位表现不好只需重训它自己的 state**，
/// 不会牵动其它岗位；也让「谁该用哪个 state」从散落的 if 收敛成一张岗位表。
class RwkvStatePost {
  const RwkvStatePost({
    required this.target,
    required this.dutyZh,
    required this.dutyEn,
    required this.roles,
  });

  final RwkvStateTarget target;

  /// 岗位职责（配置页展示，也是重训时的目标说明）。
  final String dutyZh;
  final String dutyEn;

  /// 该岗位固定服务的智能体角色（同一角色只允许属于一个岗位）。
  final Set<RwkvAgentRole> roles;

  bool serves(RwkvAgentRole role) => roles.contains(role);
}

/// 岗位表（唯一事实源）：state 目标 → 职责 + 服务对象。
const List<RwkvStatePost> kStatePosts = <RwkvStatePost>[
  RwkvStatePost(
    target: RwkvStateTarget.novelistProse,
    dutyZh: '章节正文写作：9 位偏向写手、写作组长、主笔（单笔直书/分段/续写优选）',
    dutyEn: 'Chapter prose: 9 writers, team lead, lead writer',
    roles: <RwkvAgentRole>{
      RwkvAgentRole.writer,
      RwkvAgentRole.teamLeader,
      RwkvAgentRole.subAgent,
    },
  ),
  RwkvStatePost(
    target: RwkvStateTarget.outlinerStruct,
    dutyZh: '大纲规划：主线 / 分卷 / 章节大纲、规划组派活',
    dutyEn: 'Outlining: main / volume / chapter outlines',
    roles: <RwkvAgentRole>{RwkvAgentRole.outliner, RwkvAgentRole.mainAgent},
  ),
  RwkvStatePost(
    target: RwkvStateTarget.briefContract,
    dutyZh: '章节细纲与章节命名（8 字段契约行）',
    dutyEn: 'Chapter brief and chapter naming',
    roles: <RwkvAgentRole>{},
  ),
  RwkvStatePost(
    target: RwkvStateTarget.copyeditorPatch,
    dutyZh: '自查补丁与润色返工（只回差异行）',
    dutyEn: 'Copyedit patch and rework',
    roles: <RwkvAgentRole>{RwkvAgentRole.copyeditor},
  ),
  RwkvStatePost(
    target: RwkvStateTarget.chapterLinker,
    dutyZh: '跨章续写：接住前章结尾并兑现伏笔义务',
    dutyEn: 'Cross-chapter continuation with foreshadow duties',
    roles: <RwkvAgentRole>{},
  ),
  RwkvStatePost(
    target: RwkvStateTarget.bookWorld,
    dutyZh: '单书世界观与文风（按书训练，不跨书复用）',
    dutyEn: 'Per-book world and style',
    roles: <RwkvAgentRole>{},
  ),
  RwkvStatePost(
    target: RwkvStateTarget.reviewReport,
    dutyZh: '审查与读者反馈：输出问题清单（严重度/位置/建议）',
    dutyEn: 'Review and reader feedback: issue list',
    roles: <RwkvAgentRole>{RwkvAgentRole.reviewer, RwkvAgentRole.reader},
  ),
  RwkvStatePost(
    target: RwkvStateTarget.stateUpdates,
    dutyZh: '设定抽取：按「类别|名称|字段|一句话变化」登记实体变更',
    dutyEn: 'State ledger updates: entity change register rows',
    roles: <RwkvAgentRole>{},
  ),
  RwkvStatePost(
    target: RwkvStateTarget.characterLedger,
    dutyZh: '人物履历：按章节顺序维护人物状态与经历',
    dutyEn: 'Character ledger: ordered per-chapter character history',
    roles: <RwkvAgentRole>{RwkvAgentRole.characterKeeper},
  ),
  RwkvStatePost(
    target: RwkvStateTarget.worldLedger,
    dutyZh: '世界观履历：按章节顺序维护地点/势力/设定变化',
    dutyEn: 'World ledger: ordered per-chapter world-state history',
    roles: <RwkvAgentRole>{RwkvAgentRole.worldKeeper},
  ),
];

/// 角色 → 岗位（由岗位表反推，保证「一个角色只属于一个岗位」）。
final Map<RwkvAgentRole, RwkvStatePost> kPostByRole =
    <RwkvAgentRole, RwkvStatePost>{
  for (final RwkvStatePost post in kStatePosts)
    for (final RwkvAgentRole role in post.roles) role: post,
};

/// 角色 → state 目标的默认表（没有显式 `bind` 时生效）。
final Map<RwkvAgentRole, RwkvStateTarget?> kRoleDefaultTargets =
    <RwkvAgentRole, RwkvStateTarget?>{
  for (final RwkvAgentRole role in RwkvAgentRole.values)
    role: kPostByRole[role]?.target,
};

/// 某 state 目标对应的岗位定义。
RwkvStatePost? postForTarget(RwkvStateTarget target) {
  for (final RwkvStatePost post in kStatePosts) {
    if (post.target == target) return post;
  }
  return null;
}

/// 某个智能体角色本轮实际使用的「模型 + state」。
class RoleStateBinding {
  const RoleStateBinding({
    required this.role,
    required this.target,
    required this.stateId,
    required this.statePath,
    required this.requestModel,
    required this.applied,
    required this.reason,
    this.engineStateId = '',
  });

  const RoleStateBinding.fallback(
    this.role, {
    this.target,
    this.stateId = '',
    this.statePath = '',
    required this.reason,
  }) : requestModel = '',
       engineStateId = '',
       applied = false;

  final RwkvAgentRole role;
  final RwkvStateTarget? target;
  final String stateId;
  final String statePath;

  /// 该角色应下发的 model id（空 = 沿用调用方给的基模）。
  final String requestModel;

  /// 该角色应下发的 `state_id`（空 = 不带；非空 = 引擎侧切初始 state）。
  final String engineStateId;

  final bool applied;
  final String reason;

  Map<String, Object?> toJson() => <String, Object?>{
    'role': role.code,
    'target': target?.code ?? '',
    'stateId': stateId,
    'requestModel': requestModel,
    'engineStateId': engineStateId,
    'applied': applied,
    'reason': reason,
  };
}

/// 把「工艺步骤」翻译成「这次请求该用哪个模型」。
///
/// 每个步骤独立解析：某个步骤缺 state 只回落该步骤，不影响其它步骤。
class WritingStepStatePlan {
  WritingStepStatePlan({
    required this.registry,
    this.currentBaseModelId = '',
    String plannerModelId = '',
    this.bookId = '',
    this.bookTitle = '',
    this.engineStates = const RwkvEngineStateIndex(),
  }) : plannerModelId = plannerModelId.trim().isEmpty
           ? currentBaseModelId
           : plannerModelId;

  final RwkvStateRegistry registry;

  /// 引擎当前已上传的初始 state（文件名 → state_id，见 [RwkvEngineStateIndex]）。
  ///
  /// 引擎重启后 id 会变，所以默认按文件名实时反查；查不到才回落到产物上
  /// 手工填的 `uploadedStateId`。
  final RwkvEngineStateIndex engineStates;

  /// 正文/润色类步骤当前用的模型标识（双代理的 SubAgent 模型）；空 = 跳过基底校验。
  final String currentBaseModelId;

  /// 大纲/规划类步骤当前用的模型标识（双代理的 MainAgent 模型）；空 = 跟随上面那个。
  final String plannerModelId;

  /// 当前书的 id（用于匹配 `book_world_<bookId>` 产物）；空 = 不做单书覆盖。
  final String bookId;

  /// 当前书的书名（作品名）。
  ///
  /// 为什么也要匹配书名：ST-5 数据集是按「书」构建的，产物上的 `bookId`
  /// 往往填的是训练语料里的书代号或**书名**，而项目 id 是随机 UUID。
  /// 只按 id 匹配会让「按书覆盖」静默失效，所以两者都认。
  final String bookTitle;

  /// 复制出一个「绑定到某本书」的计划（正文优先用该书 state）。
  WritingStepStatePlan forBook(String id, {String title = ''}) =>
      WritingStepStatePlan(
        registry: registry,
        currentBaseModelId: currentBaseModelId,
        plannerModelId: plannerModelId,
        bookId: id,
        bookTitle: title,
        engineStates: engineStates,
      );

  /// 本书的 ST-5 产物（未训练过这本书时返回 null）。
  ///
  /// 匹配规则：产物 `bookId` == 项目 id，或 == 书名（都做去空白比较）。
  /// 同一本书可能有多代产物（1.5B / 3B），优先选**当前引擎里真的存在**的那个。
  RwkvStateArtifact? _bookWorldForBook() {
    final String id = bookId.trim();
    final String title = bookTitle.trim();
    if (id.isEmpty && title.isEmpty) return null;
    final List<RwkvStateArtifact> matched = <RwkvStateArtifact>[
      for (final RwkvStateArtifact a in registry.byTarget(RwkvStateTarget.bookWorld))
        if (a.bookId.trim().isNotEmpty &&
            (a.bookId.trim() == id ||
                (title.isNotEmpty && a.bookId.trim() == title)))
          a,
    ];
    return _preferEngineReady(matched).isEmpty
        ? null
        : _preferEngineReady(matched).first;
  }

  /// 优先返回「当前引擎已上传」的产物，其余按原顺序排在后面。
  ///
  /// 用途：同一个岗位会随底座升级出现多代产物（1.5B / 3B），引擎里只会上传
  /// 当前那一代。按可用性排序可以自动选中能跑的那个，而不是按注册顺序瞎猜。
  List<RwkvStateArtifact> _preferEngineReady(List<RwkvStateArtifact> list) {
    final List<RwkvStateArtifact> ready = <RwkvStateArtifact>[];
    final List<RwkvStateArtifact> rest = <RwkvStateArtifact>[];
    for (final RwkvStateArtifact a in list) {
      (_engineStateIdFor(a).isNotEmpty ? ready : rest).add(a);
    }
    return <RwkvStateArtifact>[...ready, ...rest];
  }

  /// 解析单个步骤。
  StepStateBinding resolve(WritingCraftStep step) {
    // 单书覆盖：正文步骤优先用本书的 ST-5（未训练过这本书则照常走 ST-1）。
    if (step == WritingCraftStep.prose) {
      final RwkvStateArtifact? bookWorld = _bookWorldForBook();
      if (bookWorld != null) {
        final ({bool applied, String reason}) verdict =
            _evaluate(bookWorld, currentBaseModelId.trim());
        if (verdict.applied) {
          return StepStateBinding(
            step: step,
            stateId: bookWorld.id,
            target: RwkvStateTarget.bookWorld,
            statePath: bookWorld.statePath,
            requestModel: _requestModelFor(
              bookWorld,
              currentBaseModelId.trim(),
            ),
            engineStateId: _engineStateIdFor(bookWorld),
            applied: true,
            reason: '',
          );
        }
      }
    }
    final RwkvStateTarget? target = step.target;
    if (target == null) {
      return StepStateBinding.fallback(step, reason: '该步骤没有固定输出形状，不绑定 state');
    }
    final List<RwkvStateArtifact> candidates =
        _preferEngineReady(registry.byTarget(target));
    if (candidates.isEmpty) {
      return StepStateBinding.fallback(
        step,
        target: target,
        reason: '未注册 ${target.labelZh} 的 state 产物',
      );
    }
    final RwkvStateArtifact artifact = candidates.first;
    final ({bool applied, String reason}) verdict =
        _evaluate(artifact, _currentModelFor(step));
    if (!verdict.applied) {
      return StepStateBinding.fallback(
        step,
        target: target,
        stateId: artifact.id,
        statePath: artifact.statePath,
        reason: verdict.reason,
      );
    }
    return StepStateBinding(
      step: step,
      stateId: artifact.id,
      target: target,
      statePath: artifact.statePath,
      requestModel: _requestModelFor(artifact, _currentModelFor(step)),
      engineStateId: _engineStateIdFor(artifact),
      applied: true,
      reason: '',
    );
  }

  /// 按**智能体角色**解析（写手 / 组长 / 读者 / 审查员…）。
  ///
  /// 优先级：显式角色绑定（注册表 `bind`）→ 角色默认目标下第一个启用的产物
  /// → 回落基模。于是「不同对象按各自工作要求用不同的 state」是配置问题，
  /// 不是代码分支问题。
  RoleStateBinding resolveForRole(RwkvAgentRole role) {
    // 单书覆盖：正文类角色优先用本书的 ST-5（未训练则回落下方常规解析）。
    final RwkvStateTarget? defaultTarget = kRoleDefaultTargets[role];
    if (defaultTarget == RwkvStateTarget.novelistProse) {
      final RwkvStateArtifact? bookWorld = _bookWorldForBook();
      if (bookWorld != null) {
        final ({bool applied, String reason}) verdict =
            _evaluate(bookWorld, currentBaseModelId.trim());
        if (verdict.applied) {
          return RoleStateBinding(
            role: role,
            stateId: bookWorld.id,
            target: RwkvStateTarget.bookWorld,
            statePath: bookWorld.statePath,
            requestModel: _requestModelFor(
              bookWorld,
              currentBaseModelId.trim(),
            ),
            engineStateId: _engineStateIdFor(bookWorld),
            applied: true,
            reason: '',
          );
        }
      }
    }
    final RwkvStateTarget? target = defaultTarget;
    final RwkvStateArtifact? bound = registry.resolveForRole(role);
    final RwkvStateArtifact? artifact =
        bound ?? (target == null ? null : _firstEnabledFor(target));
    if (artifact == null) {
      return RoleStateBinding.fallback(
        role,
        target: target,
        reason: target == null
            ? '该角色没有对应的 state 目标'
            : '未注册 ${target.labelZh} 的 state 产物',
      );
    }
    final bool planning = role == RwkvAgentRole.mainAgent ||
        role == RwkvAgentRole.outliner;
    final ({bool applied, String reason}) verdict = _evaluate(
      artifact,
      (planning ? plannerModelId : currentBaseModelId).trim(),
    );
    if (!verdict.applied) {
      return RoleStateBinding.fallback(
        role,
        target: artifact.target,
        stateId: artifact.id,
        statePath: artifact.statePath,
        reason: verdict.reason,
      );
    }
    return RoleStateBinding(
      role: role,
      stateId: artifact.id,
      target: artifact.target,
      statePath: artifact.statePath,
      requestModel: _requestModelFor(
        artifact,
        (planning ? plannerModelId : currentBaseModelId).trim(),
      ),
      engineStateId: _engineStateIdFor(artifact),
      applied: true,
      reason: '',
    );
  }

  /// 本产物这次请求要下发的 model id。
  ///
  /// - 引擎上传路线（[engineStates] 命中或填了 `uploadedStateId`）：
  ///   模型用引擎上的基模 —— 优先 [RwkvStateArtifact.engineModelId]（量化后的
  ///   文件名），其次训练基底，最后才用调用方当前模型；
  /// - 否则沿用「合并进基底」路线（[RwkvStateArtifact.mergedModelId]）。
  String _requestModelFor(RwkvStateArtifact artifact, String current) {
    if (_engineStateIdFor(artifact).isNotEmpty) {
      final String engine = artifact.engineModelId.trim();
      if (engine.isNotEmpty) return engine;
      final String base = artifact.baseModelId.trim();
      return base.isNotEmpty ? base : current;
    }
    return artifact.mergedModelId.trim();
  }

  /// 该产物在当前引擎上可用的 state_id（空 = 走不了上传路线）。
  ///
  /// 优先按**文件名**实时反查（引擎重启后 id 会变）；只有还没问过引擎时
  /// 才用产物上手工填的 id。
  String _engineStateIdFor(RwkvStateArtifact artifact) {
    if (engineStates.fetched) {
      return engineStates.stateIdForPath(artifact.statePath) ?? '';
    }
    return artifact.uploadedStateId.trim();
  }

  RwkvStateArtifact? _firstEnabledFor(RwkvStateTarget target) {
    final List<RwkvStateArtifact> list =
        _preferEngineReady(registry.byTarget(target));
    return list.isEmpty ? null : list.first;
  }

  /// 统一校验：路径 / 可加载形态 / 基底一致性。
  ({bool applied, String reason}) _evaluate(
    RwkvStateArtifact artifact,
    String current,
  ) {
    if (artifact.statePath.trim().isEmpty) {
      return (applied: false, reason: 'state 文件路径为空');
    }
    final bool byEngine = _engineStateIdFor(artifact).isNotEmpty;
    if (engineStates.fetched && !byEngine) {
      // 已经问过引擎，但这个 state 不在上传列表里 —— 此时合并模型 id 在
      // 单模型引擎上没有意义，如实回落基模。
      return (
        applied: false,
        reason: '该 state 尚未上传到当前引擎（${engineStates.byFilename.length} 个已上传）',
      );
    }
    if (!byEngine && artifact.mergedModelId.trim().isEmpty) {
      return (
        applied: false,
        reason: '该 state 既未上传到推理引擎（state_id），也未合并进可加载模型',
      );
    }
    if (current.isNotEmpty && !_matchesCurrent(artifact, current)) {
      return (
        applied: false,
        reason: '基底模型不匹配：state 由 ${artifact.baseModelId} 训练，'
            '当前为 $current（官方要求必须同款）',
      );
    }
    return (applied: true, reason: '');
  }

  /// 当前模型是否与「该 state 的基底」兼容。
  ///
  /// 成立条件（任一）：
  /// 1. 当前就是基底 id（引擎上传 state / 直接挂载 state 的场景）；
  /// 2. 当前就是该 state 合并后的模型 id；
  /// 3. 当前就是该 state 指定的引擎模型 id（量化后的基模文件名）；
  /// 4. 当前是**同一基底**下其它岗位的合并/引擎模型 id —— 说明端点加载的是
  ///    同款基底，只是按岗位切 state（本项目「基模固定 + 逐岗位切 state」的常态）。
  ///
  /// 换成不同基底的端点（如云端 g1k）时四条都不成立 → 如实判不可用。
  bool _matchesCurrent(RwkvStateArtifact artifact, String current) {
    final String base = artifact.baseModelId.trim();
    final String merged = artifact.mergedModelId.trim();
    final String engine = artifact.engineModelId.trim();
    if (current == base ||
        (merged.isNotEmpty && current == merged) ||
        (engine.isNotEmpty && current == engine)) {
      return true;
    }
    for (final RwkvStateArtifact other in registry.artifacts) {
      if (other.baseModelId.trim() != base) continue;
      final String otherMerged = other.mergedModelId.trim();
      if (otherMerged.isNotEmpty && otherMerged == current) return true;
      final String otherEngine = other.engineModelId.trim();
      if (otherEngine.isNotEmpty && otherEngine == current) return true;
    }
    return false;
  }

  /// 取该步骤当前使用的模型标识（规划类走 MainAgent，其余走 SubAgent）。
  String _currentModelFor(WritingCraftStep step) {
    final bool planning =
        step == WritingCraftStep.mainOutline ||
        step == WritingCraftStep.volumeOutline ||
        step == WritingCraftStep.chapterOutline ||
        step == WritingCraftStep.chapterNames;
    return (planning ? plannerModelId : currentBaseModelId).trim();
  }

  /// 按模板 stage id 解析（未知 stage → null）。
  StepStateBinding? resolveStageId(String stageId) {
    final WritingCraftStep? step = WritingCraftStep.fromStageId(stageId);
    return step == null ? null : resolve(step);
  }

  /// 全部步骤的绑定快照（日志 / 健康页 / 启动自检）。
  List<StepStateBinding> get all => <StepStateBinding>[
    for (final WritingCraftStep s in WritingCraftStep.values) resolve(s),
  ];

  /// 生效中的步骤数（0 = 整套写作仍跑基模）。
  int get appliedCount => all.where((StepStateBinding b) => b.applied).length;

  /// 全部角色的绑定快照（写手/组长/读者/审查员…各用哪个 state）。
  List<RoleStateBinding> get roles => <RoleStateBinding>[
    for (final RwkvAgentRole r in RwkvAgentRole.values) resolveForRole(r),
  ];

  /// 角色视角的可读摘要（启动日志 / 健康页）。
  String roleSummary() {
    final StringBuffer sb = StringBuffer();
    for (final RoleStateBinding b in roles) {
      sb.writeln(
        '${b.role.label(false)}(${b.role.code}) → ${b.target?.code ?? '-'}：'
        '${_describe(b.applied, b.requestModel, b.engineStateId, b.reason)}',
      );
    }
    return sb.toString().trimRight();
  }

  /// 人类可读摘要（逐步骤一行）。
  String summary() {
    final StringBuffer sb = StringBuffer();
    for (final StepStateBinding b in all) {
      final String target = b.target?.code ?? '-';
      sb.writeln(
        '${b.step.labelZh}(${b.step.name}) → $target：'
        '${_describe(b.applied, b.requestModel, b.engineStateId, b.reason)}',
      );
    }
    return sb.toString().trimRight();
  }

  /// 「基模」/「基模+state」的一句话描述（区分合并模型与 state_id 两条路线）。
  String _describe(
    bool applied,
    String model,
    String engineStateId,
    String reason,
  ) {
    if (!applied) return '基模（$reason）';
    return engineStateId.isEmpty
        ? '基模+state（$model）'
        : '基模+state（$model + state_id=$engineStateId）';
  }
}
