import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di.dart';
import '../../l10n/l10n.dart';
import '../../ai/models/chat.dart';
import '../../ai/workflow/workflow.dart';
import '../../ai/agents/agent.dart';
import '../../ai/utils/chapter_intent.dart';
import '../../application/services/chapter_revision_service.dart';
import '../../data/database.dart';
import '../../ui/layout/navigation.dart';
import '../../ui/state/chapter_referral.dart';
import '../../ui/state/copilot_chat_log.dart';
import '../widgets/readonly_prose_view.dart';

enum _ChatMode { freechat, workflow }

/// 预设工作流（UI入口
class _WorkflowPreset {
  final String id;
  final IconData icon;
  final String workflowType;
  final List<String> params;

  const _WorkflowPreset({
    required this.id,
    required this.icon,
    required this.workflowType,
    required this.params,
  });
}

const _presets = [
  _WorkflowPreset(
    id: 'init',
    icon: Icons.auto_fix_high_outlined,
    workflowType: 'ProjectInitialization',
    params: ['项目名称', '主题描述', '目标读者群'],
  ),
  _WorkflowPreset(
    id: 'chapter',
    icon: Icons.edit_note_outlined,
    workflowType: 'ChapterCreation',
    params: ['所属卷宗', '章节标题', '章节概要'],
  ),
  _WorkflowPreset(
    id: 'review',
    icon: Icons.reviews_outlined,
    workflowType: 'ContentReview',
    params: ['待审内容'],
  ),
  _WorkflowPreset(
    id: 'consistency',
    icon: Icons.verified_user_outlined,
    workflowType: 'ConsistencyCheck',
    params: ['检查范围'],
  ),
];

String _presetTitleFor(String id, L10n l10n) => switch (id) {
  'init' => l10n.t('AC.Preset.Init.Title', '项目初始化'),
  'chapter' => l10n.t('AC.Preset.Chapter.Title', '章节创作'),
  'review' => l10n.t('AC.Preset.Review.Title', '内容审查'),
  'consistency' => l10n.t('AC.Preset.Consistency.Title', '一致性检查'),
  _ => id,
};

String _presetSubtitleFor(String id, L10n l10n) => switch (id) {
  'init' => l10n.t('AC.Preset.Init.Subtitle', '分析主题 → 生成大纲 → 创建世界设定'),
  'chapter' => l10n.t('AC.Preset.Chapter.Subtitle', '生成正文 → 章节总结 → 读者评价'),
  'review' => l10n.t('AC.Preset.Review.Subtitle', '基于编辑Agent的整体质量审校'),
  'consistency' => l10n.t(
    'AC.Preset.Consistency.Subtitle',
    '排查人设 / 世界 / 时间线一致性',
  ),
  _ => id,
};

String _presetParamFor(String id, String param, L10n l10n) {
  if (id == 'init') {
    return switch (param) {
      '项目名称' => l10n.t('AC.Preset.Init.Param.ProjectName', '项目名称'),
      '主题描述' => l10n.t('AC.Preset.Init.Param.ThemeDesc', '主题描述'),
      '目标读者群' => l10n.t('AC.Preset.Init.Param.TargetAudience', '目标读者群'),
      _ => param,
    };
  }
  if (id == 'chapter') {
    return switch (param) {
      '所属卷宗' => l10n.t('AC.Preset.Chapter.Param.Volume', '所属卷宗'),
      '章节标题' => l10n.t('AC.Preset.Chapter.Param.Title', '章节标题'),
      '章节概要' => l10n.t('AC.Preset.Chapter.Param.Summary', '章节概要'),
      _ => param,
    };
  }
  if (id == 'review') {
    return switch (param) {
      '待审内容' => l10n.t('AC.Preset.Review.Param.Content', '待审内容'),
      _ => param,
    };
  }
  if (id == 'consistency') {
    return switch (param) {
      '检查范围' => l10n.t('AC.Preset.Consistency.Param.Scope', '检查范围'),
      _ => param,
    };
  }
  return param;
}

String _formatStatus(WorkflowStatus s, L10n l10n) => switch (s) {
  WorkflowStatus.completed => l10n.t('AC.Status.Completed', '已完成'),
  WorkflowStatus.failed => l10n.t('AC.Status.Failed', '失败'),
  WorkflowStatus.cancelled => l10n.t('AC.Status.Cancelled', '已取消'),
  WorkflowStatus.paused => l10n.t('AC.Status.Paused', '已暂停'),
  WorkflowStatus.running => l10n.t('AC.Status.Running', '执行中'),
  _ => l10n.t('AC.Status.Pending', '待执行'),
};

final _chatModeProvider = NotifierProvider<_ChatModeNotifier, _ChatMode>(
  _ChatModeNotifier.new,
);

class _ChatModeNotifier extends Notifier<_ChatMode> {
  @override
  _ChatMode build() => _ChatMode.freechat;
  void setMode(_ChatMode m) => state = m;
}

class AICollaborationPage extends ConsumerStatefulWidget {
  const AICollaborationPage({super.key});

  @override
  ConsumerState<AICollaborationPage> createState() =>
      _AICollaborationPageState();
}

class _AICollaborationPageState extends ConsumerState<AICollaborationPage> {
  final TextEditingController _promptCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  bool _sending = false;
  String? _streamText;

  final Map<String, TextEditingController> _wfCtrl = {
    for (final p in _presets)
      for (final param in p.params) param: TextEditingController(),
  };
  final Map<String, WorkflowDefinition?> _activeFlows = {};
  final Map<String, bool> _flowRunning = {};

  // ---- 会话状态都不在本页面 ----
  //
  // ⚠ 聊天记录在全局 [copilotChatLogProvider]、关联状态在全局 [chapterReferralProvider]：
  // 页面 State 会随导航销毁（AppShell 每次只挂一个页面），放这里的话
  // 切页面/重启会话就断了。详见 `ui/state/`。
  // 开场白由聊天记录 notifier 在"恢复不到记录"时补，页面不再插手。

  @override
  void dispose() {
    _promptCtrl.dispose();
    for (final c in _wfCtrl.values) {
      c.dispose();
    }
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final l10n = ref.read(l10nProvider);
    final text = _promptCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    if (ref.read(modelManagerProvider).getDefaultProvider() == null) {
      _showError(l10n.t('AC.NoDefaultProvider',
          '未找到可用的默认模型提供商。请先到「AI 配置」注册并设置默认模型。'));
      return;
    }
    // 已关联目标章节 → 按意图分派（解除 / 提问 / 改稿）
    if (ref.read(chapterReferralProvider).isLinked) {
      await _handleLinkedInput(text, l10n);
      return;
    }
    _pushEntry(ChatMessage.user(text));
    setState(() {
      _sending = true;
      _streamText = null;
    });
    _promptCtrl.clear();
    _scrollToBottom();

    final mm = ref.read(modelManagerProvider);
    final defaultProvider = mm.getDefaultProvider();
    if (defaultProvider == null) {
      _pushEntry(
        ChatMessage.assistant(
          l10n.t('AC.NoDefaultProvider', '未找到可用的默认模型提供商。请先到「AI 配置」注册并设置默认模型。'),
        ),
      );
      if (mounted) setState(() => _sending = false);
      _scrollToBottom();
      return;
    }

    // 构造请求（历史消息 + 最新用户输入）
    final history = <ChatMessage>[
      for (final ChatMessage m in ref.read(copilotChatLogProvider).messages)
        if (m.role != ChatRole.system) m,
    ];
    // 项目上下文注入：自由问答也带上当前项目的大纲 / 角色 / 世界设定。
    // 否则 Agent 对项目内容一无所知，写出的东西与项目脱节（这也是用户报的
    // 「边聊的 Agent 不能作用于项目内容」的根因之一）。
    String projectContext = '';
    final currentProjectId = ref.read(currentProjectIdProvider);
    if (currentProjectId != null) {
      try {
        final ctx = await ref
            .read(projectContextAssemblerProvider)
            .build(currentProjectId);
        projectContext = ctx.promptSummary;
      } on Object {
        projectContext = '';
      }
    }
    final String systemBase = l10n.t(
      'AC.ChatSystem',
      '你是 NovelCraft 的书籍创作助手，负责帮助作者构思、分析与撰写作品。回答简洁、可执行。',
    );
    final request = ChatRequest(
      model: '',
      messages: <ChatMessage>[
        if (projectContext.isNotEmpty)
          ChatMessage.system('$systemBase\n\n$projectContext'),
        ...history,
      ],
      temperature: 0.7,
      maxTokens: 2000,
      stream: true,
    );

    final sb = StringBuffer();
    try {
      await mm.chatStream(request, (chunk) {
        if (!mounted) return;
        if (chunk.content.isNotEmpty) {
          sb.write(chunk.content);
          setState(() => _streamText = sb.toString());
        }
        _scrollToBottom();
      });
      _pushEntry(ChatMessage.assistant(sb.toString()));
      if (mounted) {
        setState(() {
          _streamText = null;
          _sending = false;
        });
      }
    } catch (e) {
      if (mounted && _promptCtrl.text.trim().isEmpty) {
        _promptCtrl.text = text;
      }
      _pushEntry(
        ChatMessage.assistant(l10n.tf('AC.StreamFailed', '流式请求失败: {0}', [e])),
      );
      if (mounted) {
        setState(() {
          _streamText = null;
          _sending = false;
        });
      }
    }
    _scrollToBottom();
  }

  // ---------------------------------------------------------------------------
  // 目标章节关联：书籍 → 分卷 → 章节 三级选择 + 按意见改稿回写
  // ---------------------------------------------------------------------------

  /// 往聊天记录里追加一条消息（记录在全局 provider 里，落 KVStore 后
  /// 导航切页面与 App 重启都不丢）。写入是异步的，界面靠 provider 通知刷新。
  void _pushEntry(ChatMessage msg) {
    unawaited(ref.read(copilotChatLogProvider.notifier).append(msg));
  }

  ChapterReferralController get _referral =>
      ref.read(chapterReferralProvider.notifier);

  Future<void> _toggleRefPanel() async {
    final l10n = ref.read(l10nProvider);
    await _referral.toggleExpanded();
    if (!ref.read(chapterReferralProvider).expanded) return;
    // 首次展开才查库；切回页面时列表已在全局状态里，不重复加载
    try {
      await _referral.ensureProjectsLoaded();
    } on Object catch (e) {
      _showError(l10n.tf('CRP.LoadBooksFailed', '加载书籍列表失败：{0}', <Object>[e]));
    }
  }

  Future<void> _onRefProjectChanged(String? id) async {
    final l10n = ref.read(l10nProvider);
    try {
      await _referral.selectProject(id);
    } on Object catch (e) {
      _showError(l10n.tf('CRP.LoadVolumesFailed', '加载分卷失败：{0}', <Object>[e]));
    }
  }

  Future<void> _onRefVolumeChanged(String? id) async {
    final l10n = ref.read(l10nProvider);
    bool dropped = false;
    try {
      dropped = await _referral.selectVolume(id);
    } on Object catch (e) {
      _showError(l10n.tf('CRP.LoadChaptersFailed', '加载章节失败：{0}', <Object>[e]));
    }
    // 切换分卷会丢掉原关联章节：用**区别于手动解除**的文案提示，
    // 否则作者会以为是自己点了「解除关联」。
    if (dropped && mounted) {
      setState(() {
        _pushEntry(
          ChatMessage.system(
            l10n.t('AC.Ref.LinkDropped', '已切换分卷，原关联章节随之解除：输入仍为普通问答，不会改动项目文件。'),
          ),
        );
      });
    }
  }

  void _onRefChapterChanged(String? id) {
    // 仅记录选择，不进入改写模式 —— 必须点「关联」才生效
    unawaited(_referral.pickChapter(id));
  }

  Future<void> _linkChapter() async {
    final l10n = ref.read(l10nProvider);
    if (!await _referral.link()) {
      _showError(l10n.t('AC.Ref.PickIncomplete', '请先选择书籍、分卷与章节。'));
      return;
    }
    // ⚠ 刻意**不收起**面板：收起后「按意见改写 / 按意见续写」切换器会一起消失，
    // 作者就只能在关联前先选好模式（关联后再想改模式必须重新展开面板）。
    final ChapterReferral s = ref.read(chapterReferralProvider);
    setState(() {
      _pushEntry(
        ChatMessage.system(
          l10n.tf('AC.Ref.Linked', '已关联《{0}》第{1}卷第{2}章《{3}》', <Object>[
            s.project?.name ?? '',
            s.volumeOrder,
            s.chapterOrder,
            s.linkedChapter?.title ?? '',
          ]),
        ),
      );
    });
    _scrollToBottom();
  }

  Future<void> _unlinkChapter() async {
    final l10n = ref.read(l10nProvider);
    await _referral.unlink();
    if (!mounted) return;
    setState(() {
      _pushEntry(
        ChatMessage.system(
          l10n.t('AC.Ref.NotLinked', '未关联章节：输入仍为普通问答，不会改动项目文件。'),
        ),
      );
    });
  }

  /// 关联模式下的输入分派（对应 C# `HandleChapterRefInputAsync`）：
  /// 「取消关联」→ 解除；疑问句 → 只作答**不改正文**；其余 → 按意见改稿并回写。
  Future<void> _handleLinkedInput(String text, L10n l10n) async {
    final ChapterRefIntent intent = ChapterIntent.resolve(
      text,
      isEnglish: l10n.isEnglish,
    );
    if (intent == ChapterRefIntent.unlink) {
      _promptCtrl.clear();
      await _unlinkChapter();
      return;
    }
    await _sendToLinkedChapter(
      text,
      l10n,
      isQuestion: intent == ChapterRefIntent.question,
    );
  }

  /// 关联模式下的输入处理：改进意见 → Agent 处理章节 → 回写 → 如实汇报。
  ///
  /// [isQuestion] 为 true 时只带章节上下文作答，**不落库**（作者问一句不该被改写）。
  Future<void> _sendToLinkedChapter(
    String text,
    L10n l10n, {
    required bool isQuestion,
  }) async {
    final ChapterReferral referral = ref.read(chapterReferralProvider);
    final ChapterRow? chapter = referral.linkedChapter;
    final ProjectRow? project = referral.project;
    // 关联可能在这一瞬间被解除/被切走（异步间隙），此时静默放弃本次输入
    if (chapter == null || project == null) return;
    setState(() {
      _pushEntry(ChatMessage.user(text));
      _sending = true;
      _streamText = isQuestion
          ? l10n.t('AC.Ref.Answering', '正在阅读本章并作答…')
          : l10n.t('AC.Ref.Processing', '正在处理关联章节…');
    });
    _promptCtrl.clear();
    _scrollToBottom();

    ChapterRevisionResult result;
    try {
      final svc = ref.read(chapterRevisionServiceProvider);
      if (isQuestion) {
        // 提问：只作答，不落库（见 ChapterRevisionService.askAboutChapter）
        result = await svc.askAboutChapter(
          projectId: project.id,
          chapterId: chapter.id,
          question: text,
        );
      } else if (referral.reviseMode) {
        result = await svc.revise(
          projectId: project.id,
          chapterId: chapter.id,
          instruction: text,
          // 长章要跑好几轮分段，实时告诉作者进行到哪一段
          onProgress: (int done, int total) {
            if (!mounted || total <= 1) return;
            final int shown = done < 1 ? 1 : done;
            setState(
              () => _streamText = l10n.tf(
                'AC.Ref.SegmentProgress',
                '正在分段改写 {0}/{1} 段…',
                <Object>[shown, total],
              ),
            );
          },
        );
      } else {
        result = await svc.continueWriting(
          projectId: project.id,
          chapterId: chapter.id,
          instruction: text,
        );
      }
    } on Object catch (e) {
      result = ChapterRevisionResult(
        isSuccess: false,
        content: '',
        message: l10n.tf('AC.Ref.Failed', '章节处理失败：{0}', <Object>[e]),
      );
    }

    // 回写成功后重新读一次，保证面板里的章节快照与库一致
    final ChapterRow? refreshed = result.persisted
        ? await ref.read(chapterRepositoryProvider).getById(chapter.id)
        : null;
    if (!mounted) return;
    if (refreshed != null) _referral.replaceChapter(refreshed);
    setState(() {
      _streamText = null;
      _sending = false;
      if (result.isSuccess && result.content.isNotEmpty) {
        _pushEntry(ChatMessage.assistant(result.content));
      }
      // 问答路径的 message 是空的（不改正文就没什么可汇报的），别塞空气泡
      if (result.message.isNotEmpty) {
        _pushEntry(ChatMessage.system(result.message));
      }
    });
    _scrollToBottom();
    if (!result.isSuccess) _showError(result.message);
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _runWorkflow(_WorkflowPreset preset) async {
    final l10n = ref.read(l10nProvider);
    setState(() => _flowRunning[preset.id] = true);
    try {
      final engine = ref.read(workflowEngineProvider);
      final params = <String, dynamic>{};
      final projectId = ref.read(currentProjectIdProvider);
      if (projectId != null) params['projectId'] = projectId;
      for (final p in preset.params) {
        params[p] = _wfCtrl[p]?.text.trim() ?? '';
      }
      final wf = await engine.createPredefinedWorkflow(
        preset.workflowType,
        params,
      );
      setState(() => _activeFlows[preset.id] = wf);
      await engine.executeWorkflow(wf);
      if (mounted) {
        final presetTitle = _presetTitleFor(preset.id, l10n);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              wf.status == WorkflowStatus.completed
                  ? l10n.tf('AC.WorkflowDone', '{0} 执行完成 · 成功 {1}/{2}', [
                      presetTitle,
                      wf.tasks
                          .where((t) => t.status == WorkflowStatus.completed)
                          .length,
                      wf.tasks.length,
                    ])
                  : l10n.tf('AC.WorkflowEnded', '{0} 结束 · {1}', [
                      presetTitle,
                      _formatStatus(wf.status, l10n),
                    ]),
            ),
            backgroundColor: wf.status == WorkflowStatus.failed
                ? Colors.red
                : null,
            // 功能 B：工作流产物不再即弃，可点开查看各任务文本结果
            action: SnackBarAction(
              label: l10n.t('AC.ViewResult', '查看结果'),
              onPressed: () => _showWorkflowResult(wf),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        final presetTitle = _presetTitleFor(preset.id, l10n);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.tf('AC.WorkflowFailed', '{0} 失败: {1}', [presetTitle, e]),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _flowRunning[preset.id] = false);
    }
  }

  /// 功能 B：工作流产物查看 —— 各任务的 result.data 文本不再即弃。
  void _showWorkflowResult(WorkflowDefinition wf) {
    final l10n = ref.read(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    String? textOf(WorkflowTask t) {
      final d = t.result?.data;
      final String s = d is String ? d : (d?.toString() ?? '');
      return s.trim().isEmpty ? null : s;
    }

    final viewable = <WorkflowTask>[
      for (final t in wf.tasks)
        if (textOf(t) != null) t,
    ];
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(l10n.t('AC.WorkflowResult', '工作流产物')),
        content: SizedBox(
          width: 480,
          child: viewable.isEmpty
              ? Text(l10n.t('AC.WorkflowNoOutput', '本次工作流没有可查看的文本产物'))
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 420),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: viewable.length,
                    itemBuilder: (_, i) {
                      final t = viewable[i];
                      final text = textOf(t)!;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: Icon(
                            t.status == WorkflowStatus.completed
                                ? Icons.check_circle_outline
                                : Icons.error_outline,
                            size: 20,
                            color: t.status == WorkflowStatus.completed
                                ? Colors.green
                                : scheme.error,
                          ),
                          title: Text(
                            t.name.trim().isNotEmpty ? t.name : t.taskType,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Text(
                            text.length > 80 ? '${text.substring(0, 80)}…' : text,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: const Icon(Icons.chevron_right, size: 18),
                          onTap: () => Navigator.push(
                            dialogCtx,
                            MaterialPageRoute(
                              builder: (_) => Scaffold(
                                appBar: AppBar(title: Text(t.name.trim().isNotEmpty
                                    ? t.name
                                    : t.taskType)),
                                body: ListView(
                                  padding: const EdgeInsets.all(16),
                                  children: [
                                    ReadonlyProseView(
                                        content: text, fontSize: 15),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: Text(l10n.t('Common.Confirm', '确定')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final mode = ref.watch(_chatModeProvider);
    final agents = ref.watch(allAgentsProvider);
    final projectId = ref.watch(currentProjectIdProvider);

    // 手机横屏高度只有 ~400 逻辑像素：页内大标题与 AppBar 标题重复，
    // 关联面板展开后固定头直接溢出且滚不到 → 矮视口走紧凑布局。
    final bool short = MediaQuery.sizeOf(context).height < 520;

    return Scaffold(
      body: Padding(
        padding: EdgeInsets.all(short ? 10 : 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!short) ...[
              Text(
                l10n.t('AC.Title', 'AI 协作创作'),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
            ],
            // 手机横屏：模式切换器压缩高度（默认 ~48px 挤占聊天区）
            SizedBox(
              height: short ? 36 : null,
              child: SegmentedButton<_ChatMode>(
              segments: [
                ButtonSegment(
                  value: _ChatMode.freechat,
                  label: Text(l10n.t('AC.Mode.FreeChat', '自由聊天')),
                  icon: const Icon(Icons.chat_bubble_outline),
                ),
                ButtonSegment(
                  value: _ChatMode.workflow,
                  label: Text(l10n.t('AC.Mode.Workflow', '一键工作流')),
                  icon: const Icon(Icons.route_outlined),
                ),
              ],
              selected: {mode},
              onSelectionChanged: (set) =>
                  ref.read(_chatModeProvider.notifier).setMode(set.first),
              ),
            ),
            SizedBox(height: short ? 8 : 12),
            if (projectId == null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Colors.orange.withValues(alpha: 0.5),
                    ),
                    borderRadius: BorderRadius.circular(10),
                    color: Colors.orange.withValues(alpha: 0.06),
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(short ? 6 : 10),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline,
                            size: short ? 16 : 24, color: Colors.orange),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.t(
                              'AC.NoProjectHint',
                              '未选择项目。请先在「项目管理」中选择项目，工作流会附加项目上下文。',
                            ),
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Expanded(
              child: mode == _ChatMode.freechat
                  ? _buildChat(context, agents, l10n)
                  : _buildWorkflows(context, l10n),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChat(BuildContext context, List<BaseAgent> agents, L10n l10n) {
    final scheme = Theme.of(context).colorScheme;
    // 矮视口（手机横屏）下输入框最多 2 行，给消息区和关联面板留高度
    final bool short = MediaQuery.sizeOf(context).height < 520;
    final bool touch = Theme.of(context).platform == TargetPlatform.android ||
        Theme.of(context).platform == TargetPlatform.iOS;
    // 聊天记录来自全局 provider（落 KVStore）：切页面 / 重启后接着上一段对话
    final List<ChatMessage> messages = ref
        .watch(copilotChatLogProvider)
        .messages;
    return Column(
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.smart_toy_outlined,
                        size: 16,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(child: Text(
                        l10n.tf('AC.SessionInfo', '聊天会话 · 共 {0} 个 Agent 待命', [
                          agents.length,
                        ]),
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )),
                      if (!short) Text(
                        l10n.tf('AC.DefaultProvider', '默认：{0}', [
                          ref
                                  .watch(modelManagerProvider)
                                  .getDefaultProvider()
                                  ?.providerName ??
                              l10n.t('AC.NotSet', '未设置'),
                        ]),
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 清空会话：记录落在 KVStore（重启不丢），此前用户想
                      // 重开对话只能卸载重装 —— 交接文档遗留 #7。
                      _ClearChatButton(
                        onConfirmed: () => ref
                            .read(copilotChatLogProvider.notifier)
                            .clear(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.all(12),
                    itemCount: messages.length + (_streamText != null ? 1 : 0),
                    itemBuilder: (ctx, i) {
                      if (i == messages.length && _streamText != null) {
                        return _MessageBubble(
                          role: ChatRole.assistant,
                          text: _streamText!,
                          streaming: true,
                        );
                      }
                      final ChatMessage m = messages[i];
                      return _MessageBubble(
                        role: m.role,
                        text: m.content,
                        time: m.timestamp,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        _buildChapterRefBar(context, l10n, ref.watch(chapterReferralProvider)),
        const SizedBox(height: 8),
        Container(
          padding: EdgeInsets.all(short ? 6 : 10),
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _promptCtrl,
                  keyboardType: TextInputType.multiline,
                  textInputAction: touch ? TextInputAction.newline : TextInputAction.send,
                  maxLines: short ? 2 : 5,
                  minLines: 1,
                  decoration: InputDecoration(
                    hintText: ref.watch(chapterReferralProvider).isLinked
                        ? l10n.t(
                            'AC.Ref.InstructionHint',
                            '输入改进意见（如：重写开头，加强冲突；扩写战斗场面）… 带问号则只作解答，不改正文',
                          )
                        : l10n.t(
                            'AC.PromptHint',
                            '输入问题或请求…（Shift+Enter 换行，Enter 发送）',
                          ),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  onSubmitted: touch ? null : (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              if (short) IconButton.filled(
                tooltip: _sending
                    ? l10n.t('AC.Generating', '生成中')
                    : l10n.t('AC.Send', '发送'),
                onPressed: _sending ? null : _send,
                icon: _sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send, size: 20),
              ) else FilledButton.icon(
                onPressed: _sending ? null : _send,
                icon: _sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.send, size: 18),
                label: Text(
                  _sending
                      ? l10n.t('AC.Generating', '生成中')
                      : l10n.t('AC.Send', '发送'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 关联目标章节面板（对应 C# Copilot 输入区的 `ChapterRefPicker`）。
  ///
  /// 收起态只显示一行状态；展开态是「书籍 / 分卷 / 章节」三级下拉 + 关联按钮，
  /// 关联后可切换「按意见改写 / 按意见续写」两种处理方式。
  Widget _buildChapterRefBar(
    BuildContext context,
    L10n l10n,
    ChapterReferral r,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final bool linked = r.isLinked;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(
          color: linked
              ? scheme.primary.withValues(alpha: 0.5)
              : scheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(12),
        color: linked ? scheme.primary.withValues(alpha: 0.05) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                linked ? Icons.link : Icons.link_off,
                size: 16,
                color: linked ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  linked
                      ? l10n.tf(
                          'AC.Ref.Linked',
                          '已关联《{0}》第{1}卷第{2}章《{3}》',
                          <Object>[
                            r.project?.name ?? '',
                            r.volumeOrder,
                            r.chapterOrder,
                            r.linkedChapter?.title ?? '',
                          ],
                        )
                      : l10n.t('AC.Ref.NotLinked', '未关联章节：输入仍为普通问答，不会改动项目文件。'),
                  style: TextStyle(
                    fontSize: 12,
                    color: linked ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (linked)
                TextButton(
                  onPressed: _unlinkChapter,
                  child: Text(l10n.t('AC.Ref.Unlink', '解除关联')),
                ),
              IconButton(
                onPressed: _toggleRefPanel,
                tooltip: l10n.t('AC.Ref.Heading', '关联目标章节'),
                icon: Icon(
                  r.expanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                ),
              ),
            ],
          ),
          if (r.expanded) ...[
            const Divider(height: 8),
            // 手机横屏下展开态比剩余空间还高：限高 + 内部滚动，避免把输入框
            // 挤出屏幕（桌面高度充裕，通常不会触发滚动）。
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.45,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _refDropdown(
                          label: l10n.t('CRP.Book', '书籍'),
                          value: r.projectId,
                          hint: l10n.t('CRP.Book', '书籍'),
                          items: r.projects
                              .map(
                                (p) => DropdownMenuItem<String>(
                                  value: p.id,
                                  child: Text(
                                    p.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(growable: false),
                          onChanged: _onRefProjectChanged,
                        ),
                        _refDropdown(
                          label: l10n.t('CRP.Volume', '分卷'),
                          value: r.volumeId,
                          hint: l10n.t('CRP.Volume', '分卷'),
                          items: r.volumes
                              .asMap()
                              .entries
                              .map(
                                (e) => DropdownMenuItem<String>(
                                  value: e.value.id,
                                  child: Text(
                                    l10n.tf(
                                      'CRP.VolumeDisplay',
                                      '第{0}卷 {1}',
                                      <Object>[e.key + 1, e.value.title],
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(growable: false),
                          onChanged: _onRefVolumeChanged,
                        ),
                        _refDropdown(
                          label: l10n.t('CRP.Chapter', '章节'),
                          value: r.pickedChapterId,
                          hint: l10n.t('CRP.Chapter', '章节'),
                          width: 240,
                          items: r.chapters
                              .asMap()
                              .entries
                              .map(
                                (e) => DropdownMenuItem<String>(
                                  value: e.value.id,
                                  child: Text(
                                    l10n.tf(
                                      'CRP.ChapterDisplay',
                                      '第{0}章 《{1}》',
                                      <Object>[e.key + 1, e.value.title],
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(growable: false),
                          onChanged: _onRefChapterChanged,
                        ),
                        FilledButton.tonalIcon(
                          onPressed: r.loading ? null : _linkChapter,
                          icon: r.loading
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.link, size: 16),
                          label: Text(l10n.t('CRP.Link', '关联')),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<bool>(
                      segments: [
                        ButtonSegment<bool>(
                          value: true,
                          label: Text(l10n.t('AC.Ref.Mode.Revise', '按意见改写')),
                          icon: const Icon(
                            Icons.auto_fix_high_outlined,
                            size: 16,
                          ),
                        ),
                        ButtonSegment<bool>(
                          value: false,
                          label: Text(l10n.t('AC.Ref.Mode.Continue', '按意见续写')),
                          icon: const Icon(Icons.playlist_add, size: 16),
                        ),
                      ],
                      selected: <bool>{r.reviseMode},
                      onSelectionChanged: (Set<bool> s) =>
                          unawaited(_referral.setReviseMode(s.first)),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      l10n.t(
                        'AC.Ref.Description',
                        '依次选择书籍、分卷、章节后点「关联」。关联后输入即作用于该章：处理要求（如「重写开头，加强冲突」）按上方模式改写或续写，并直接回写项目文件；带问号的疑问句只作解答、不改动正文；输入「取消关联」可解除。',
                      ),
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 三级选择用的小型下拉（用 [DropdownButton] 而非 FormField，
  /// 避免 `DropdownButtonFormField.value` 的弃用告警）。
  Widget _refDropdown({
    required String label,
    required String? value,
    required String hint,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?> onChanged,
    double width = 200,
  }) {
    // 末道防线：`DropdownButton` 要求 value 必须**恰好命中** items 中的一项，
    // 否则直接抛断言红屏。候选列表是异步查库来的，任何时序（恢复中途、
    // 项目/卷/章刚被删）都可能让 value 短暂落在 items 之外 —— 这里统一
    // 降级为 null（显示 hint），把崩溃收敛成"看起来没选中"。
    final bool hit = value != null &&
        items.any((DropdownMenuItem<String> i) => i.value == value);
    return SizedBox(
      width: width,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: hit ? value : null,
            isDense: true,
            isExpanded: true,
            hint: Text(
              hint,
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
            items: items,
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }

  Widget _buildWorkflows(BuildContext context, L10n l10n) {
    final scheme = Theme.of(context).colorScheme;
    // 手机横屏：卡片与输入控件压缩，参数字段宽度自适应（防横向溢出）
    final bool short = MediaQuery.sizeOf(context).height < 520;
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: _presets.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (ctx, i) {
        final p = _presets[i];
        final flow = _activeFlows[p.id];
        final running = _flowRunning[p.id] ?? false;
        final presetTitle = _presetTitleFor(p.id, l10n);
        final presetSubtitle = _presetSubtitleFor(p.id, l10n);
        return Card(
          child: Padding(
            padding: EdgeInsets.all(short ? 10 : 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(p.icon, color: scheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            presetTitle,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(color: scheme.primary),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            presetSubtitle,
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: running ? null : () => _runWorkflow(p),
                      icon: running
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.play_arrow, size: 18),
                      label: Text(
                        running
                            ? _formatStatus(WorkflowStatus.running, l10n)
                            : l10n.t('AC.Run', '运行'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    for (final param in p.params)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 260),
                        child: TextField(
                          controller: _wfCtrl[param],
                          decoration: InputDecoration(
                            labelText: _presetParamFor(p.id, param, l10n),
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                  ],
                ),
                if (flow != null) ...[
                  const SizedBox(height: 12),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: scheme.primary.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              _StatusDot(status: flow.status),
                              const SizedBox(width: 6),
                              Text(
                                l10n.tf('AC.WorkflowInfo', '工作流 {0} · {1}', [
                                  flow.name,
                                  _formatStatus(flow.status, l10n),
                                ]),
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                '${flow.tasks.where((t) => t.status == WorkflowStatus.completed).length}'
                                '/${flow.tasks.length}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: flow.tasks.isEmpty
                                ? 0
                                : (flow.tasks
                                              .where(
                                                (t) =>
                                                    t.status ==
                                                        WorkflowStatus
                                                            .completed ||
                                                    t.status ==
                                                        WorkflowStatus.failed,
                                              )
                                              .length /
                                          flow.tasks.length)
                                      .clamp(0.0, 1.0)
                                      .toDouble(),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final t in flow.tasks)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: scheme.outlineVariant,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _StatusDot(size: 8, status: t.status),
                                      const SizedBox(width: 4),
                                      Text(
                                        t.name,
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MessageBubble extends ConsumerWidget {
  const _MessageBubble({
    required this.role,
    required this.text,
    this.time,
    this.streaming = false,
  });

  final ChatRole role;
  final String text;
  final DateTime? time;
  final bool streaming;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    final isUser = role == ChatRole.user;
    final isSystem = role == ChatRole.system;
    if (isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 520),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.7,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isUser ? scheme.primary : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isUser ? Icons.person : Icons.smart_toy,
                    size: 12,
                    color: isUser ? scheme.onPrimary : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    isUser
                        ? l10n.t('AC.Bubble.Me', '我')
                        : (streaming
                              ? l10n.t('AC.Bubble.AIGenerating', 'AI 生成中…')
                              : l10n.t('AC.Bubble.AI', 'AI 助手')),
                    style: TextStyle(
                      fontSize: 10,
                      color: isUser
                          ? scheme.onPrimary.withValues(alpha: 0.85)
                          : scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                text,
                style: TextStyle(
                  color: isUser ? scheme.onPrimary : null,
                  height: 1.4,
                ),
              ),
              if (time != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    time!.toLocal().toString().split(' ')[1].split('.')[0],
                    style: TextStyle(
                      fontSize: 10,
                      color:
                          (isUser ? scheme.onPrimary : scheme.onSurfaceVariant)
                              .withValues(alpha: 0.6),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 清空会话按钮：带确认对话框（记录会落 KVStore 持久清除，不可撤销）。
class _ClearChatButton extends ConsumerWidget {
  const _ClearChatButton({required this.onConfirmed});

  /// 用户在确认对话框点「清空」后执行（由页面传入 notifier.clear）。
  final Future<void> Function() onConfirmed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = ref.watch(l10nProvider);
    return Tooltip(
      message: l10n.t('AC.ClearChat', '清空会话'),
      child: IconButton(
        icon: Icon(
          Icons.delete_sweep_outlined,
          size: 16,
          color: scheme.onSurfaceVariant,
        ),
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        padding: EdgeInsets.zero,
        onPressed: () async {
          final bool? ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(l10n.t('AC.ClearChat', '清空会话')),
              content: Text(l10n.t(
                'AC.ClearChatConfirm',
                '将清空当前聊天记录并重新开始（已持久保存的历史将被删除，此操作不可撤销）。',
              )),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(l10n.t('Common.Cancel', '取消')),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(l10n.t('AC.ClearChat', '清空会话')),
                ),
              ],
            ),
          );
          if (ok == true) {
            await onConfirmed();
          }
        },
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({this.size = 10, required this.status});
  final double size;
  final WorkflowStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      WorkflowStatus.completed => Colors.green,
      WorkflowStatus.failed => Colors.red,
      WorkflowStatus.running => Colors.blue,
      WorkflowStatus.paused => Colors.orange,
      WorkflowStatus.cancelled => Colors.grey,
      _ => Colors.grey.shade400,
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 1),
      ),
    );
  }
}
