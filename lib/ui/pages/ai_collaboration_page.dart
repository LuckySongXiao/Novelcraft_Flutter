import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di.dart';
import '../../l10n/l10n.dart';
import '../../ai/models/chat.dart';
import '../../ai/workflow/workflow.dart';
import '../../ai/agents/agent.dart';
import '../../ui/layout/navigation.dart';

enum _ChatMode {
  freechat,
  workflow,
}

class _ChatEntry {
  final String id;
  final ChatMessage msg;
  _ChatEntry(this.id, this.msg);
}

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
      'init' =>
        l10n.t('AC.Preset.Init.Subtitle', '分析主题 → 生成大纲 → 创建世界设定'),
      'chapter' => l10n.t(
          'AC.Preset.Chapter.Subtitle', '生成正文 → 章节总结 → 读者评价'),
      'review' => l10n.t(
          'AC.Preset.Review.Subtitle', '基于编辑Agent的整体质量审校'),
      'consistency' => l10n.t(
          'AC.Preset.Consistency.Subtitle', '排查人设 / 世界 / 时间线一致性'),
      _ => id,
    };

String _presetParamFor(String id, String param, L10n l10n) {
  if (id == 'init') {
    return switch (param) {
      '项目名称' => l10n.t('AC.Preset.Init.Param.ProjectName', '项目名称'),
      '主题描述' => l10n.t('AC.Preset.Init.Param.ThemeDesc', '主题描述'),
      '目标读者群' =>
        l10n.t('AC.Preset.Init.Param.TargetAudience', '目标读者群'),
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

final _chatModeProvider =
    NotifierProvider<_ChatModeNotifier, _ChatMode>(_ChatModeNotifier.new);

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
  final List<_ChatEntry> _entries = [];
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final l10n = ref.read(l10nProvider);
      _entries.add(_ChatEntry(
        DateTime.now().microsecondsSinceEpoch.toString(),
        ChatMessage(
          role: ChatRole.system,
          content: l10n.t('AC.Welcome',
              '这里是 NovelCraft AI 协作工作台。\n• 在「自由聊天」可以与默认提供商的大模型自由问答；\n• 在「一键工作流」可以执行主编 / 写作 / 审稿 / 一致性检查 等完整 Agent 流水线。\n先到「AI 配置」注册并设置默认模型后开始使用更稳定。'),
        ),
      ));
      setState(() {});
    });
  }

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
    final userMsg = ChatMessage.user(text);
    final userEntry = _ChatEntry(
      DateTime.now().microsecondsSinceEpoch.toString(),
      userMsg,
    );
    setState(() {
      _entries.add(userEntry);
      _sending = true;
      _streamText = null;
    });
    _promptCtrl.clear();
    _scrollToBottom();

    final mm = ref.read(modelManagerProvider);
    final defaultProvider = mm.getDefaultProvider();
    if (defaultProvider == null) {
      final respEntry = _ChatEntry(
        DateTime.now().microsecondsSinceEpoch.toString(),
        ChatMessage.assistant(l10n.t('AC.NoDefaultProvider',
            '未找到可用的默认模型提供商。请先到「AI 配置」注册并设置默认模型。')),
      );
      setState(() {
        _entries.add(respEntry);
        _sending = false;
      });
      _scrollToBottom();
      return;
    }

    // 构造请求（历史消息 + 最新用户输入
    final history = <ChatMessage>[];
    for (final e in _entries) {
      if (e.msg.role != ChatRole.system) history.add(e.msg);
    }
    final request = ChatRequest(
      model: '',
      messages: history,
      temperature: 0.7,
      maxTokens: 2000,
      stream: true,
    );

    final sb = StringBuffer();
    final streamId = DateTime.now().microsecondsSinceEpoch.toString();
    try {
      await mm.chatStream(
        request,
        (chunk) {
          if (!mounted) return;
          if (chunk.content.isNotEmpty) {
            sb.write(chunk.content);
            setState(() => _streamText = sb.toString());
          }
          _scrollToBottom();
        },
      );
      final assistantMsg = ChatMessage.assistant(sb.toString());
      if (mounted) {
        setState(() {
          _entries.add(_ChatEntry(streamId, assistantMsg));
          _streamText = null;
          _sending = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _entries.add(_ChatEntry(
            DateTime.now().microsecondsSinceEpoch.toString(),
            ChatMessage.assistant(
                l10n.tf('AC.StreamFailed', '流式请求失败: {0}', [e])),
          ));
          _streamText = null;
          _sending = false;
        });
      }
    }
    _scrollToBottom();
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
      final wf =
          await engine.createPredefinedWorkflow(preset.workflowType, params);
      setState(() => _activeFlows[preset.id] = wf);
      await engine.executeWorkflow(wf);
      if (mounted) {
        final presetTitle = _presetTitleFor(preset.id, l10n);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(wf.status == WorkflowStatus.completed
                ? l10n.tf(
                    'AC.WorkflowDone',
                    '{0} 执行完成 · 成功 {1}/{2}',
                    [
                      presetTitle,
                      wf.tasks
                          .where((t) => t.status == WorkflowStatus.completed)
                          .length,
                      wf.tasks.length,
                    ],
                  )
                : l10n.tf('AC.WorkflowEnded', '{0} 结束 · {1}',
                    [presetTitle, _formatStatus(wf.status, l10n)])),
            backgroundColor:
                wf.status == WorkflowStatus.failed ? Colors.red : null,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        final presetTitle = _presetTitleFor(preset.id, l10n);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(l10n.tf(
                  'AC.WorkflowFailed', '{0} 失败: {1}', [presetTitle, e])),
              backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _flowRunning[preset.id] = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final mode = ref.watch(_chatModeProvider);
    final agents = ref.watch(allAgentsProvider);
    final projectId = ref.watch(currentProjectIdProvider);

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.t('AC.Title', 'AI 协作创作'),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            SegmentedButton<_ChatMode>(
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
            const SizedBox(height: 12),
            if (projectId == null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.orange.withValues(alpha: 0.5)),
                    borderRadius: BorderRadius.circular(10),
                    color: Colors.orange.withValues(alpha: 0.06),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline, color: Colors.orange),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.t('AC.NoProjectHint',
                                '未选择项目。请先在「项目管理」中选择项目，工作流会附加项目上下文。'),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.smart_toy_outlined,
                          size: 16, color: scheme.primary),
                      const SizedBox(width: 6),
                      Text(
                          l10n.tf('AC.SessionInfo', '聊天会话 · 共 {0} 个 Agent 待命',
                              [agents.length]),
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant)),
                      const Spacer(),
                      Text(
                          l10n.tf(
                              'AC.DefaultProvider',
                              '默认：{0}',
                              [
                                ref
                                        .watch(modelManagerProvider)
                                        .getDefaultProvider()
                                        ?.providerName ??
                                    l10n.t('AC.NotSet', '未设置')
                              ]),
                          style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.all(12),
                    itemCount: _entries.length + (_streamText != null ? 1 : 0),
                    itemBuilder: (ctx, i) {
                      if (i == _entries.length && _streamText != null) {
                        return _MessageBubble(
                            role: ChatRole.assistant,
                            text: _streamText!,
                            streaming: true);
                      }
                      final e = _entries[i];
                      return _MessageBubble(
                          role: e.msg.role,
                          text: e.msg.content,
                          time: e.msg.timestamp);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(10),
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
                  maxLines: 5,
                  minLines: 1,
                  decoration: InputDecoration(
                    hintText: l10n.t('AC.PromptHint',
                        '输入问题或请求…（Shift+Enter 换行，Enter 发送）'),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _sending ? null : _send,
                icon: _sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.send, size: 18),
                label: Text(_sending
                    ? l10n.t('AC.Generating', '生成中')
                    : l10n.t('AC.Send', '发送')),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildWorkflows(BuildContext context, L10n l10n) {
    final scheme = Theme.of(context).colorScheme;
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 20),
      itemCount: _presets.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (ctx, i) {
        final p = _presets[i];
        final flow = _activeFlows[p.id];
        final running = _flowRunning[p.id] ?? false;
        final presetTitle = _presetTitleFor(p.id, l10n);
        final presetSubtitle = _presetSubtitleFor(p.id, l10n);
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
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
                          Text(presetTitle,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(color: scheme.primary)),
                          const SizedBox(height: 2),
                          Text(presetSubtitle,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant)),
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
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.play_arrow, size: 18),
                      label: Text(running
                          ? _formatStatus(WorkflowStatus.running, l10n)
                          : l10n.t('AC.Run', '运行')),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    for (final param in p.params)
                      SizedBox(
                        width: 260,
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
                          color: scheme.primary.withValues(alpha: 0.3)),
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
                                    _formatStatus(flow.status, l10n)
                                  ]),
                                  style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold)),
                              const Spacer(),
                              Text(
                                '${flow.tasks.where((t) => t.status == WorkflowStatus.completed).length}'
                                '/${flow.tasks.length}',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: flow.tasks.isEmpty
                                ? 0
                                : (flow.tasks
                                            .where((t) =>
                                                t.status ==
                                                    WorkflowStatus.completed ||
                                                t.status ==
                                                    WorkflowStatus.failed)
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
                                      horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                        color: scheme.outlineVariant),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _StatusDot(size: 8, status: t.status),
                                      const SizedBox(width: 4),
                                      Text(t.name,
                                          style: const TextStyle(fontSize: 11)),
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
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Text(text,
                style: TextStyle(
                    fontSize: 12, color: scheme.onSurfaceVariant)),
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
              maxWidth: MediaQuery.of(context).size.width * 0.7),
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isUser
                ? scheme.primary
                : scheme.surfaceContainerHighest,
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
                    color: isUser
                        ? scheme.onPrimary
                        : scheme.onSurfaceVariant,
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
                        fontWeight: FontWeight.w500),
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
                        color: (isUser
                                ? scheme.onPrimary
                                : scheme.onSurfaceVariant)
                            .withValues(alpha: 0.6)),
                  ),
                ),
            ],
          ),
        ),
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
