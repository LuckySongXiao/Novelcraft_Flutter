// RWKV State Tuning 产物注册表 —— 「哪个 state 文件给哪个智能体角色用」的唯一事实源。
//
// ## 背景（为什么需要这一层）
//
// State Tuning 微调的是 **RWKV 的初始 state**，产物是一个几 MB 的 `.pth`
// （24 个 `blocks.N.att.time_state`），**不是**完整权重。它能替换的只是
// 「模型开始生成时的默认偏置」，因此有两条硬约束：
//
//   1. **必须配训练它的同款基底模型**（官方明确要求）—— 基底换了，state 的
//      形状含义全变，轻则效果归零，重则直接崩；
//   2. **当前本地后端 `rwkv_lightning_cuda` 不支持挂载初始 state**
//      （`rwkv_lightning_launch_args.dart` 顶部参数表只有会话缓存
//      `--state-db-path`，没有 `--state-path`）。要用必须：
//        · 用官方 `demo-state-merge.sh` 把 state 合并进基底模型，或
//        · 换 Runner / Ai00 这类支持挂载 state 的自托管后端。
//
// 所以本层提供的是**可校验、可持久化、可生成挂载计划**的配置接口，
// 而不是假装「选一个 state 就生效」。UI 必须如实展示 [RwkvStateArtifact.mountHint]。
//
// 与 `g1k_model_preset.dart` 的关系：后者管「用哪个云端模型」，
// 本文件管「给模型叠哪个微调 state」，两者正交、可组合。
//
// 本文件不 `import 'dart:io'`，Web 端可编译；持久化由调用方注入回调。
//
// ⚠ 参数当量口径（实测张量形状，不按文件名猜）：
//   * 1B / 1.5B 底座的 state 都是 24 个 `blocks.N.att.time_state`，
//     每块 BF16 `(32,64,64)` → 约 6 MiB，归为 S6M 当量；
//   * 3B 底座是 32 块、每块 BF16 `(40,64,64)` → 约 10 MiB，归为 S10M 当量。
//   底座参数类与 state 当量是两件事：1B 与 1.5B 底座不能互换，
//   但它们的 state 文件尺寸/形状相同。分类工具把两者都显式展示。
library;

/// State Tuning 的 6 个目标（对应 Part II 数据集范式 ST-1 ~ ST-6）。
///
/// 一个 state 只许一种输出形状 —— 这是 Part II 的核心约束，不要合并训练。
enum RwkvStateTarget {
  /// ST-1 正文写手（通用手感，不含单书设定）。
  novelistProse(
    code: 'novelist_prose',
    labelZh: 'ST-1 正文写手',
    labelEn: 'ST-1 Novelist Prose',
    outputShape: 'prose',
    datasetKey: 'st1_prose',
  ),

  /// ST-2 大纲规划（分卷 / 章节大纲文本，逐段推进式）。
  ///
  /// 数据集只有大纲文本（`vol02_volume_outline` + `vol03_chapter_outline`），
  /// 没有「里程碑 JSON 数组」的样本，所以形状按其真实数据记为大纲文本。
  outlinerStruct(
    code: 'outliner_struct',
    labelZh: 'ST-2 大纲规划',
    labelEn: 'ST-2 Outliner',
    outputShape: 'outlineText',
    datasetKey: 'st2_plan',
  ),

  /// ST-3 细纲契约（8 字段纯文本行）。
  briefContract(
    code: 'brief_contract',
    labelZh: 'ST-3 细纲契约',
    labelEn: 'ST-3 Brief Contract',
    outputShape: 'textLines',
    datasetKey: 'st3_brief',
  ),

  /// ST-4 自查补丁（只回差异行）。
  copyeditorPatch(
    code: 'copyeditor_patch',
    labelZh: 'ST-4 自查补丁',
    labelEn: 'ST-4 Copyeditor Patch',
    outputShape: 'textLines',
    datasetKey: 'st4_patch',
  ),

  /// ST-5 单书世界观与文风（`book_world_<bookId>`）。
  ///
  /// ⚠ 与 ST-1 必须分开训练：一个是通用手感、一个是单书设定，
  /// 混在一起会得到「都不像」的平均人格。
  bookWorld(
    code: 'book_world',
    labelZh: 'ST-5 单书设定',
    labelEn: 'ST-5 Book World',
    outputShape: 'prose',
    datasetKey: '',
  ),

  /// ST-6 跨章续写 + 伏笔义务。
  chapterLinker(
    code: 'chapter_linker',
    labelZh: 'ST-6 跨章续写',
    labelEn: 'ST-6 Chapter Linker',
    outputShape: 'prose',
    datasetKey: 'st6_linker',
  ),

  /// ST-7 审查/读者反馈（问题清单 JSON：severity/位置/建议）。
  ///
  /// 与 ST-4 分开：ST-4 产出「改哪几行」的补丁，ST-7 产出「哪里有问题」的评审，
  /// 两者形状不同，混训会互相拖累。
  reviewReport(
    code: 'review_report',
    labelZh: 'ST-7 审查反馈',
    labelEn: 'ST-7 Review Report',
    outputShape: 'json_comments',
    datasetKey: 'st7_review',
  ),

  /// ST-8 设定抽取（`类别|名称|字段|一句话变化` 登记行）。
  ///
  /// 与 ST-3（8 字段细纲）/ ST-4（差异行）都不同：这里只产出**实体变更登记**，
  /// 每行 4 段、类别取自固定词表。不单独成 state 的话，抽取只能靠提示词纠偏 ——
  /// 整书实测 3B 有 7/12 的分段会把指令原样复述出来。
  stateUpdates(
    code: 'state_updates',
    labelZh: 'ST-8 设定抽取',
    labelEn: 'ST-8 State Updates',
    outputShape: 'textLines',
    datasetKey: 'st8_state_updates',
  ),

  /// ST-9 人物履历：按章节顺序维护人物的状态与经历。
  ///
  /// 与 ST-8 的区别：ST-8 是「整章所有实体的变更登记」，本岗位只负责
  /// **人物**这一类，输出同样是登记行，但只写人物履历，便于单独重训。
  characterLedger(
    code: 'character_ledger',
    labelZh: 'ST-9 人物履历',
    labelEn: 'ST-9 Character Ledger',
    outputShape: 'textLines',
    datasetKey: 'st9_character_ledger',
  ),

  /// ST-10 世界观履历：按章节顺序维护地点 / 势力 / 设定等变化。
  worldLedger(
    code: 'world_ledger',
    labelZh: 'ST-10 世界观履历',
    labelEn: 'ST-10 World Ledger',
    outputShape: 'textLines',
    datasetKey: 'st10_world_ledger',
  );

  const RwkvStateTarget({
    required this.code,
    required this.labelZh,
    required this.labelEn,
    required this.outputShape,
    required this.datasetKey,
  });

  /// 对外机器码（写入配置/日志，保持稳定）。
  final String code;

  final String labelZh;
  final String labelEn;

  /// 该 state 只接受的输出形状（Part II 同质性约束）。
  final String outputShape;

  /// 训练数据集在 `定向微调数据集` 中的卷名（空 = 需按书单独构建）。
  final String datasetKey;

  String label(bool isEnglish) => isEnglish ? labelEn : labelZh;

  static RwkvStateTarget? fromCode(String code) {
    for (final RwkvStateTarget t in values) {
      if (t.code == code) return t;
    }
    return null;
  }
}

/// 智能体角色（state 绑定的作用对象）。
enum RwkvAgentRole {
  mainAgent('main_agent', '主智能体', 'MainAgent'),
  subAgent('sub_agent', '子智能体', 'SubAgent'),
  teamLeader('team_leader', '写作组长', 'TeamLead'),
  writer('writer', '写手', 'Writer'),
  copyeditor('copyeditor', '自查/润色', 'Copyeditor'),
  outliner('outliner', '大纲规划', 'Outliner'),

  /// 读者（客座读者/试读）：输出是「读后反馈/挑毛病」。
  reader('reader', '读者', 'Reader'),

  /// 审查员（资深审查/质检）：输出是问题清单与修改意见。
  reviewer('reviewer', '审查员', 'Reviewer'),

  /// 人物履历管理员：按章节顺序维护人物状态与经历（ST-9）。
  characterKeeper('character_keeper', '人物履历管理员', 'CharacterKeeper'),

  /// 世界观履历管理员：按章节顺序维护地点/势力/设定变化（ST-10）。
  worldKeeper('world_keeper', '世界观履历管理员', 'WorldKeeper');

  const RwkvAgentRole(this.code, this.labelZh, this.labelEn);

  final String code;
  final String labelZh;
  final String labelEn;

  String label(bool isEnglish) => isEnglish ? labelEn : labelZh;

  static RwkvAgentRole? fromCode(String code) {
    for (final RwkvAgentRole r in values) {
      if (r.code == code) return r;
    }
    return null;
  }
}

/// 训练基底的参数量分类（从模型 id / 路径解析，绝不按文件体积猜）。
///
/// 1B 与 1.5B 必须分开记：它们的 state 张量同形（S6M），但底座不能互换。
enum RwkvBaseParamClass {
  b1(code: '1b', labelZh: '1B 底座', labelEn: '1B base'),
  b1p5(code: '1.5b', labelZh: '1.5B 底座', labelEn: '1.5B base'),
  b3(code: '3b', labelZh: '3B 底座', labelEn: '3B base'),
  b7(code: '7b', labelZh: '7B 底座', labelEn: '7B base'),
  b13p3(code: '13.3b', labelZh: '13.3B 底座', labelEn: '13.3B base'),
  unknown(code: 'unknown', labelZh: '未知底座', labelEn: 'Unknown base');

  const RwkvBaseParamClass({
    required this.code,
    required this.labelZh,
    required this.labelEn,
  });

  final String code;
  final String labelZh;
  final String labelEn;

  String label(bool isEnglish) => isEnglish ? labelEn : labelZh;
}

/// State 文件的参数当量类（由张量形状实测归类，而非按文件名/体积估算）。
///
/// [expectedStateBytes] 是**单个 state 产物**的理论字节数，仅用于展示与
/// 一致性核验；真正能不能挂还要走同款底座校验。
enum RwkvStateParamTier {
  s6m(
    code: 's6m',
    labelZh: 'S6M · 1B/1.5B 当量',
    labelEn: 'S6M · 1B/1.5B class',
    shapeZh: '24 块 × BF16 (32,64,64)',
    shapeEn: '24 blocks × BF16 (32,64,64)',
    expectedStateBytes: 6291456,
  ),
  s10m(
    code: 's10m',
    labelZh: 'S10M · 3B 当量',
    labelEn: 'S10M · 3B class',
    shapeZh: '32 块 × BF16 (40,64,64)',
    shapeEn: '32 blocks × BF16 (40,64,64)',
    expectedStateBytes: 10485760,
  ),
  unknown(
    code: 'unknown',
    labelZh: '未测当量',
    labelEn: 'Unknown class',
    shapeZh: '未实测张量形状',
    shapeEn: 'Tensor shape not measured',
    expectedStateBytes: 0,
  );

  const RwkvStateParamTier({
    required this.code,
    required this.labelZh,
    required this.labelEn,
    required this.shapeZh,
    required this.shapeEn,
    required this.expectedStateBytes,
  });

  final String code;
  final String labelZh;
  final String labelEn;
  final String shapeZh;
  final String shapeEn;

  /// 单产物理论字节数；0 = 未实测。
  final int expectedStateBytes;

  String label(bool isEnglish) => isEnglish ? labelEn : labelZh;

  String shape(bool isEnglish) => isEnglish ? shapeEn : shapeZh;

  /// 人类可读的 MiB 体积（仅展示）。
  String get sizeLabel =>
      expectedStateBytes <= 0 ? '-' : '${expectedStateBytes / 1048576} MiB';
}

/// 匹配模型 id / 路径里的 `1b` / `1.5b` / `3b`，要求两侧是分隔符。
///
/// 不能写成 `RegExp(r'(\d+)b')`：`rwkv7b-g1b-0.1b` 会先命中家族前缀里的 7b。
final RegExp kRwkvBaseParamRankPattern = RegExp(
  r'(?:^|[-_/])([0-9]+(?:\.[0-9]+)?)b(?=$|[-_/])',
  caseSensitive: false,
);

/// 从模型 id 或路径解析底座参数类；解析不出返回 [RwkvBaseParamClass.unknown]。
RwkvBaseParamClass parseRwkvBaseParamClass(String text) {
  final RegExpMatch? match = kRwkvBaseParamRankPattern.firstMatch(text.trim());
  if (match == null) return RwkvBaseParamClass.unknown;
  final double? rank = double.tryParse(match.group(1) ?? '');
  if (rank == null || rank <= 0) return RwkvBaseParamClass.unknown;
  if (rank <= 1.0) return RwkvBaseParamClass.b1;
  if (rank <= 1.5) return RwkvBaseParamClass.b1p5;
  if (rank <= 3.0) return RwkvBaseParamClass.b3;
  if (rank <= 7.5) return RwkvBaseParamClass.b7;
  if (rank <= 14.0) return RwkvBaseParamClass.b13p3;
  return RwkvBaseParamClass.unknown;
}

/// 底座参数类 → state 当量。
///
/// 只有已实测形状的 1B/1.5B/3B 会落到具体档；7B/13.3B 暂无 state 样本，
/// 如实返回 unknown，不能套用 3B 的字节数。
RwkvStateParamTier rwkvStateTierFor(RwkvBaseParamClass baseClass) {
  switch (baseClass) {
    case RwkvBaseParamClass.b1:
    case RwkvBaseParamClass.b1p5:
      return RwkvStateParamTier.s6m;
    case RwkvBaseParamClass.b3:
      return RwkvStateParamTier.s10m;
    case RwkvBaseParamClass.b7:
    case RwkvBaseParamClass.b13p3:
    case RwkvBaseParamClass.unknown:
      return RwkvStateParamTier.unknown;
  }
}

/// 综合分类：优先看训练底座 id；缺底座时退回 state 路径。
RwkvStateParamTier classifyRwkvStateTier(
  String baseModelId, {
  String statePath = '',
}) {
  final RwkvBaseParamClass fromBase = parseRwkvBaseParamClass(baseModelId);
  if (fromBase != RwkvBaseParamClass.unknown) {
    return rwkvStateTierFor(fromBase);
  }
  return rwkvStateTierFor(parseRwkvBaseParamClass(statePath));
}

/// 一次 state tuning 训练产物。
class RwkvStateArtifact {
  const RwkvStateArtifact({
    required this.id,
    required this.target,
    required this.statePath,
    required this.baseModelId,
    this.baseModelPath = '',
    this.mergedModelId = '',
    this.uploadedStateId = '',
    this.engineModelId = '',
    this.bookId = '',
    this.displayName = '',
    this.steps = 0,
    this.finalLoss = 0,
    this.sampleCount = 0,
    this.trainedAt,
    this.enabled = true,
    this.notes = '',
  });

  /// 唯一标识（稳定，用于绑定）。
  final String id;

  final RwkvStateTarget target;

  /// `.pth` state 文件绝对路径（24 个 `blocks.N.att.time_state`）。
  final String statePath;

  /// 训练所用基底模型的标识（如 `rwkv7-g1l-1.5b-20261031-ctx34304`）。
  ///
  /// 挂载前必须与当前基底**完全一致** —— 官方硬约束。
  final String baseModelId;

  /// 基底模型文件路径（可空；用于合并脚本生成）。
  final String baseModelPath;

  /// 「基底 + 本 state」合并后**可加载**的模型标识（端点上的 model id 或文件名）。
  ///
  /// 旧路线：后端只能加载完整权重，先把 state 合并进基底注册成独立模型。
  /// 空 = 未合并。
  final String mergedModelId;

  /// 已上传到推理引擎的**初始 state id**（`POST /v1/state/upload` 的返回值）。
  ///
  /// 新路线（rwkv_lightning_cuda ≥ v1.8.13）：基模只加载一份，请求里带
  /// `state_id` 就从这个初始状态接着算 —— 不再需要为每个岗位各存一份
  /// 2.9GB 的 merged 模型。非空时优先于 [mergedModelId]。
  final String uploadedStateId;

  /// 走 state 上传路线时，本次请求要下发的**引擎模型 id**。
  ///
  /// 通常是量化后的文件名（如 `rwkv7-g1l-1.5b-...-sb6_w4`）。空 = 用
  /// [baseModelId]（未量化时与文件名一致）。
  final String engineModelId;

  /// 单书产物所属的书（仅 [RwkvStateTarget.bookWorld] 用）。
  ///
  /// 可填**项目 id** 或**书名**（运行时两者都比对，去空白）——
  /// 项目 id 是随机 UUID，手填不现实，书名才是人写得出来的绑定方式。
  /// 空 = 通用产物（不覆盖任何书）。
  final String bookId;

  final String displayName;

  final int steps;

  /// 训练末段 loss（仅作记录，不参与判定）。
  final double finalLoss;

  final int sampleCount;

  final DateTime? trainedAt;

  /// 是否启用（禁用后绑定不生效）。
  final bool enabled;

  final String notes;

  /// 挂载方式提示（UI 必须如实展示）。
  ///
  /// 有两条可用路径：
  /// 1. `rwkv_lightning_cuda ≥ v1.8.13`：上传 `.pth` 初始 state 拿 `state_id`，
  ///    请求里带 `state_id` 即可，基模只加载一份（推荐）；
  /// 2. 旧后端：把 state 合并进基底模型，注册成独立模型。
  String get mountHint =>
      '推荐：POST /v1/state/upload 上传后把返回的 state_id 填进「已上传 state id」；'
      '旧后端：合并进基底模型后填「合并模型 id」。';

  RwkvStateArtifact copyWith({
    String? displayName,
    bool? enabled,
    String? notes,
    String? mergedModelId,
    String? uploadedStateId,
    String? engineModelId,
    String? bookId,
  }) =>
      RwkvStateArtifact(
        id: id,
        target: target,
        statePath: statePath,
        baseModelId: baseModelId,
        baseModelPath: baseModelPath,
        mergedModelId: mergedModelId ?? this.mergedModelId,
        uploadedStateId: uploadedStateId ?? this.uploadedStateId,
        engineModelId: engineModelId ?? this.engineModelId,
        bookId: bookId ?? this.bookId,
        displayName: displayName ?? this.displayName,
        steps: steps,
        finalLoss: finalLoss,
        sampleCount: sampleCount,
        trainedAt: trainedAt,
        enabled: enabled ?? this.enabled,
        notes: notes ?? this.notes,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'target': target.code,
        'statePath': statePath,
        'baseModelId': baseModelId,
        'baseModelPath': baseModelPath,
        'mergedModelId': mergedModelId,
        'uploadedStateId': uploadedStateId,
        'engineModelId': engineModelId,
        'bookId': bookId,
        'displayName': displayName,
        'steps': steps,
        'finalLoss': finalLoss,
        'sampleCount': sampleCount,
        'trainedAt': trainedAt?.toIso8601String(),
        'enabled': enabled,
        'notes': notes,
      };

  factory RwkvStateArtifact.fromJson(Map<String, Object?> json) =>
      RwkvStateArtifact(
        id: (json['id'] as String?) ?? '',
        target: RwkvStateTarget.fromCode((json['target'] as String?) ?? '') ??
            RwkvStateTarget.novelistProse,
        statePath: (json['statePath'] as String?) ?? '',
        baseModelId: (json['baseModelId'] as String?) ?? '',
        baseModelPath: (json['baseModelPath'] as String?) ?? '',
        mergedModelId: (json['mergedModelId'] as String?) ?? '',
        uploadedStateId: (json['uploadedStateId'] as String?) ?? '',
        engineModelId: (json['engineModelId'] as String?) ?? '',
        bookId: (json['bookId'] as String?) ?? '',
        displayName: (json['displayName'] as String?) ?? '',
        steps: (json['steps'] as num?)?.toInt() ?? 0,
        finalLoss: (json['finalLoss'] as num?)?.toDouble() ?? 0,
        sampleCount: (json['sampleCount'] as num?)?.toInt() ?? 0,
        trainedAt: DateTime.tryParse((json['trainedAt'] as String?) ?? ''),
        enabled: (json['enabled'] as bool?) ?? true,
        notes: (json['notes'] as String?) ?? '',
      );
}

/// 参数当量视图（UI / 日志用；不改变持久化格式）。
extension RwkvStateArtifactParamClass on RwkvStateArtifact {
  RwkvBaseParamClass get baseParamClass => parseRwkvBaseParamClass(
        baseModelId.trim().isEmpty ? statePath : baseModelId,
      );

  RwkvStateParamTier get paramTier => rwkvStateTierFor(baseParamClass);

  /// 一行展示：`S6M · 1B/1.5B 当量 / 1.5B 底座 / 6.0 MiB`。
  String paramClassLabel(bool isEnglish) {
    final String base = baseParamClass.label(isEnglish);
    final String tier = paramTier.label(isEnglish);
    final String size = paramTier.sizeLabel;
    return size == '-' ? '$tier / $base' : '$tier / $base / $size';
  }
}

/// 角色 → state 的绑定。
class RwkvStateBinding {
  const RwkvStateBinding({required this.role, required this.stateId});

  final RwkvAgentRole role;
  final String stateId;

  Map<String, Object?> toJson() =>
      <String, Object?>{'role': role.code, 'stateId': stateId};

  factory RwkvStateBinding.fromJson(Map<String, Object?> json) =>
      RwkvStateBinding(
        role: RwkvAgentRole.fromCode((json['role'] as String?) ?? '') ??
            RwkvAgentRole.writer,
        stateId: (json['stateId'] as String?) ?? '',
      );
}

/// 挂载校验结果。
class RwkvStateMountCheck {
  const RwkvStateMountCheck({
    required this.ok,
    this.reason = '',
    this.requiresMerge = false,
  });

  final bool ok;
  final String reason;

  /// 是否必须先把 state 合并进基底模型（当前后端恒为 true）。
  final bool requiresMerge;
}

/// State 产物注册表（纯数据 + 纯校验，可单测）。
class RwkvStateRegistry {
  RwkvStateRegistry({
    List<RwkvStateArtifact> artifacts = const <RwkvStateArtifact>[],
    List<RwkvStateBinding> bindings = const <RwkvStateBinding>[],
  })  : _artifacts = List<RwkvStateArtifact>.of(artifacts),
        _bindings = List<RwkvStateBinding>.of(bindings);

  final List<RwkvStateArtifact> _artifacts;
  final List<RwkvStateBinding> _bindings;

  List<RwkvStateArtifact> get artifacts =>
      List<RwkvStateArtifact>.unmodifiable(_artifacts);

  List<RwkvStateBinding> get bindings =>
      List<RwkvStateBinding>.unmodifiable(_bindings);

  /// 按 id 查找。
  RwkvStateArtifact? byId(String id) {
    for (final RwkvStateArtifact a in _artifacts) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// 某目标下已启用的产物（同目标允许多个版本并存）。
  List<RwkvStateArtifact> byTarget(RwkvStateTarget target) => _artifacts
      .where((RwkvStateArtifact a) => a.target == target && a.enabled)
      .toList(growable: false);

  /// 注册（同 id 覆盖）。
  void upsert(RwkvStateArtifact artifact) {
    final int i = _artifacts.indexWhere((RwkvStateArtifact a) => a.id == artifact.id);
    if (i >= 0) {
      _artifacts[i] = artifact;
    } else {
      _artifacts.add(artifact);
    }
  }

  void remove(String id) {
    _artifacts.removeWhere((RwkvStateArtifact a) => a.id == id);
    _bindings.removeWhere((RwkvStateBinding b) => b.stateId == id);
  }

  /// 绑定角色 → state（同角色覆盖）。
  void bind(RwkvAgentRole role, String stateId) {
    _bindings.removeWhere((RwkvStateBinding b) => b.role == role);
    _bindings.add(RwkvStateBinding(role: role, stateId: stateId));
  }

  void unbind(RwkvAgentRole role) {
    _bindings.removeWhere((RwkvStateBinding b) => b.role == role);
  }

  /// 角色当前生效的 state（未绑定 / 已禁用 / 产物缺失 → null）。
  RwkvStateArtifact? resolveForRole(RwkvAgentRole role) {
    RwkvStateBinding? binding;
    for (final RwkvStateBinding b in _bindings) {
      if (b.role == role) binding = b;
    }
    if (binding == null) return null;
    final RwkvStateArtifact? a = byId(binding.stateId);
    if (a == null || !a.enabled) return null;
    return a;
  }

  /// 挂载前校验：基底模型必须与训练时一致。
  ///
  /// [currentBaseModelId] 取自当前加载的模型文件名（去扩展名）。
  RwkvStateMountCheck checkMount(
    RwkvStateArtifact artifact, {
    required String currentBaseModelId,
  }) {
    if (artifact.statePath.trim().isEmpty) {
      return const RwkvStateMountCheck(ok: false, reason: 'state 文件路径为空');
    }
    if (artifact.baseModelId.trim().isEmpty) {
      return const RwkvStateMountCheck(ok: false, reason: '未记录训练基底模型');
    }
    if (artifact.baseModelId.trim() != currentBaseModelId.trim()) {
      return RwkvStateMountCheck(
        ok: false,
        reason: '基底模型不匹配：state 由 ${artifact.baseModelId} 训练，'
            '当前为 $currentBaseModelId（官方要求必须同款）',
      );
    }
    return const RwkvStateMountCheck(ok: true, requiresMerge: true);
  }

  /// 生成自托管后端的挂载参数（Runner / Ai00 风格）。
  ///
  /// 仅作配置输出；`rwkv_lightning_cuda` 不认这些参数。
  List<String> mountArgs(
    RwkvStateArtifact artifact, {
    String baseModelPath = '',
  }) =>
      <String>[
        '--model-path', baseModelPath.isEmpty ? artifact.baseModelPath : baseModelPath,
        '--state-path', artifact.statePath,
      ];

  /// 生成合并命令提示（官方 `demo-state-merge.sh`）。
  String mergeCommandHint({String baseModelPath = '', String outPath = ''}) =>
      'bash merge/demo-state-merge.sh '
      '${baseModelPath.isEmpty ? '<base.pth>' : baseModelPath} '
      '${outPath.isEmpty ? '<merged.pth>' : outPath}';

  Map<String, Object?> toJson() => <String, Object?>{
        'artifacts': <Object?>[
          for (final RwkvStateArtifact a in _artifacts) a.toJson(),
        ],
        'bindings': <Object?>[
          for (final RwkvStateBinding b in _bindings) b.toJson(),
        ],
      };

  factory RwkvStateRegistry.fromJson(Map<String, Object?> json) {
    final List<RwkvStateArtifact> artifacts = <RwkvStateArtifact>[];
    final Object? rawA = json['artifacts'];
    if (rawA is List) {
      for (final Object? item in rawA) {
        if (item is Map) {
          artifacts.add(RwkvStateArtifact.fromJson(_stringKeyed(item)));
        }
      }
    }
    final List<RwkvStateBinding> bindings = <RwkvStateBinding>[];
    final Object? rawB = json['bindings'];
    if (rawB is List) {
      for (final Object? item in rawB) {
        if (item is Map) {
          bindings.add(RwkvStateBinding.fromJson(_stringKeyed(item)));
        }
      }
    }
    return RwkvStateRegistry(artifacts: artifacts, bindings: bindings);
  }

  static Map<String, Object?> _stringKeyed(Map<dynamic, dynamic> m) =>
      m.map((dynamic k, dynamic v) => MapEntry<String, Object?>('$k', v));
}
