import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ai/rwkv/rwkv_engine_state_index.dart';
import '../../ai/rwkv/state_tuning_registry.dart';
import '../../ai/rwkv/writing_step_state_plan.dart';
import '../../core/di.dart';

/// State 岗位配置页：一个 state 一个岗位，岗位固定、产物可换。
///
/// 设计要点（与「基模固定 + 按岗位切 state」一致）：
/// * 岗位（职责 / 服务对象 / 产出形状）由 [kStatePosts] 固化，页面不可改；
/// * 页面上能改的只有**产物本身**：state 文件、训练基底、合并后的模型 id、启停；
/// * 缺产物的岗位明确显示「未训练」，并给出数据集 key 与重训入口。
class StatePostsPage extends ConsumerWidget {
  const StatePostsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final RwkvStateRegistry registry = ref.watch(stateTuningRegistryProvider);
    final WritingStepStatePlan plan = ref.watch(writingStepStatePlanProvider);
    final Map<RwkvStateParamTier, int> tierCounts =
        <RwkvStateParamTier, int>{};
    for (final RwkvStateArtifact artifact in registry.artifacts) {
      tierCounts[artifact.paramTier] =
          (tierCounts[artifact.paramTier] ?? 0) + 1;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('State 岗位配置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                '基模固定、按岗位切 state：每个岗位只负责一种输出形状。'
                '某岗位产出不合格时，只重训该岗位的 state，不影响其它岗位。',
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.sync),
              title: Text(
                plan.engineStates.fetched
                    ? '引擎已同步：${plan.engineStates.byFilename.length} 个 state'
                    : '尚未从引擎同步 state（引擎未启动时会回落手工填的 id）',
              ),
              subtitle: Text(
                plan.engineStates.source.isEmpty
                    ? 'state_id 每次引擎重启都会变，启动引擎后点这里重新同步。'
                    : '来源：${plan.engineStates.source}/state/list',
              ),
              trailing: TextButton(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  await ref
                      .read(rwkvEngineStateIndexProvider.notifier)
                      .refreshAll(ref.read(localEngineBaseUrlsProvider));
                  final RwkvEngineStateIndex idx =
                      ref.read(rwkvEngineStateIndexProvider);
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(
                        idx.fetched
                            ? '同步完成：${idx.byFilename.length} 个 state'
                            : '同步失败：本地推理引擎未响应',
                      ),
                    ),
                  );
                },
                child: const Text('同步'),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '按参数当量归类（实测 state 张量形状，不按文件名估算）',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  if (tierCounts.isEmpty)
                    const Text('尚未登记 state 产物')
                  else
                    for (final RwkvStateParamTier tier
                        in RwkvStateParamTier.values)
                      if (tierCounts.containsKey(tier))
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '${tier.label(false)}：${tierCounts[tier]} 个产物 · '
                            '${tier.shape(false)} · 单产物 ${tier.sizeLabel}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                  const SizedBox(height: 6),
                  const Text(
                    '1B 与 1.5B 的 state 同形（S6M），但底座不能互换；3B 单独一类（S10M）。',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          for (final RwkvStatePost post in kStatePosts)
            _PostCard(
              post: post,
              // 含已停用的产物：停用只是「绑定不生效」，不是「从页面消失」——
              // 否则停用后的那一代就再也点不回来（隐藏 → 无法启用）。
              artifacts: <RwkvStateArtifact>[
                for (final RwkvStateArtifact a in registry.artifacts)
                  if (a.target == post.target) a,
              ],
              engineStates: plan.engineStates,
              appliedRoles: <RwkvAgentRole>[
                for (final RoleStateBinding b in plan.roles)
                  if (b.applied && b.target == post.target) b.role,
              ],
            ),
        ],
      ),
    );
  }
}

class _PostCard extends ConsumerWidget {
  const _PostCard({
    required this.post,
    required this.artifacts,
    required this.engineStates,
    required this.appliedRoles,
  });

  final RwkvStatePost post;
  final List<RwkvStateArtifact> artifacts;

  /// 引擎已上传的 state（文件名 → state_id）：用于如实显示「引擎里真的有」。
  final RwkvEngineStateIndex engineStates;

  final List<RwkvAgentRole> appliedRoles;

  /// 该产物是否有可用挂载形态（引擎已上传 / 手工 state id / 已合并）。
  bool _ready(RwkvStateArtifact a) =>
      a.statePath.trim().isNotEmpty &&
      (engineStates.stateIdForPath(a.statePath) != null ||
          a.uploadedStateId.trim().isNotEmpty ||
          a.mergedModelId.trim().isNotEmpty);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool trained = artifacts.isNotEmpty;
    final bool anyReady =
        artifacts.any((RwkvStateArtifact a) => a.enabled && _ready(a));

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${post.target.labelZh} · ${post.target.code}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Chip(
                  label: Text(
                    !trained
                        ? '未训练'
                        : (anyReady
                            ? '已就绪（${artifacts.where((RwkvStateArtifact a) => a.enabled).length} 个启用产物）'
                            : '未挂载'),
                  ),
                  backgroundColor: anyReady
                      ? Colors.green.withValues(alpha: .15)
                      : Colors.orange.withValues(alpha: .15),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(post.dutyZh),
            const SizedBox(height: 6),
            Text(
              '服务对象：${post.roles.isEmpty ? '按工艺步骤（无固定角色）' : post.roles.map((RwkvAgentRole r) => r.labelZh).join(' / ')}'
              '${appliedRoles.isEmpty ? '' : '（生效：${appliedRoles.map((r) => r.labelZh).join('、')}）'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              '产出形状：${post.target.outputShape}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (!trained) ...[
              const Divider(height: 20),
              Text(
                '数据集：${post.target.datasetKey.isEmpty ? '需按书构建' : post.target.datasetKey}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                '重训：powershell -File _state_tuning\\train_missing.ps1',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.edit, size: 18),
                label: const Text('登记产物'),
                onPressed: () => _edit(context, ref, null),
              ),
            ] else
              for (final RwkvStateArtifact artifact in artifacts)
                _VariantBlock(
                  artifact: artifact,
                  engineStateId:
                      engineStates.stateIdForPath(artifact.statePath) ?? '',
                  isBookWorld: post.target == RwkvStateTarget.bookWorld,
                  onEdit: () => _edit(context, ref, artifact),
                  onToggle: () => ref
                      .read(stateTuningRegistryProvider.notifier)
                      .upsert(artifact.copyWith(enabled: !artifact.enabled)),
                ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    RwkvStateArtifact? current,
  ) async {
    final TextEditingController statePath =
        TextEditingController(text: current?.statePath ?? '');
    final TextEditingController baseModel =
        TextEditingController(text: current?.baseModelId ?? '');
    final TextEditingController merged =
        TextEditingController(text: current?.mergedModelId ?? '');
    final TextEditingController uploaded =
        TextEditingController(text: current?.uploadedStateId ?? '');
    final TextEditingController engineModel =
        TextEditingController(text: current?.engineModelId ?? '');
    final TextEditingController book =
        TextEditingController(text: current?.bookId ?? '');
    final bool isBookWorld = post.target == RwkvStateTarget.bookWorld;
    final String id = current?.id ?? '${post.target.code}-v1';

    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('${post.target.labelZh} · 产物配置'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: statePath,
                decoration: const InputDecoration(
                  labelText: 'state 文件（.pth）',
                  hintText: 'rwkv_models/states/st4_patch-v1.pth',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: baseModel,
                decoration: const InputDecoration(
                  labelText: '训练基底模型 id',
                  hintText: 'rwkv7-g1l-1.5b-20261031-ctx34304',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: uploaded,
                decoration: const InputDecoration(
                  labelText: '已上传 state id（新引擎路线，优先）',
                  hintText: 'POST /v1/state/upload 返回的 state_id',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: engineModel,
                decoration: const InputDecoration(
                  labelText: '引擎模型 id（量化后的基模）',
                  hintText: '留空 = 用训练基底 id；如 ...-sb6_w4',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: merged,
                decoration: const InputDecoration(
                  labelText: '合并后的模型 id（旧后端路线）',
                  hintText: '留空 = 未合并',
                ),
              ),
              if (isBookWorld) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: book,
                  decoration: const InputDecoration(
                    labelText: '绑定书籍（项目 id 或书名）',
                    hintText: '例如 hehuanzong 或《合欢宗》；空 = 通用',
                  ),
                ),
              ],
              const SizedBox(height: 8),
              const Text(
                '⚠ 基底必须与训练时同款；两条路线只需填一条：上传 state id（推荐）或合并模型 id。',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (saved != true) return;
    final RwkvStateArtifact next = RwkvStateArtifact(
      id: id,
      target: post.target,
      statePath: statePath.text.trim(),
      baseModelId: baseModel.text.trim(),
      baseModelPath: current?.baseModelPath ?? '',
      mergedModelId: merged.text.trim(),
      uploadedStateId: uploaded.text.trim(),
      engineModelId: engineModel.text.trim(),
      bookId: book.text.trim(),
      displayName: current?.displayName ?? post.target.labelZh,
      steps: current?.steps ?? 0,
      finalLoss: current?.finalLoss ?? 0,
      sampleCount: current?.sampleCount ?? 0,
      trainedAt: current?.trainedAt,
      enabled: current?.enabled ?? true,
      notes: current?.notes ?? '',
    );
    await ref.read(stateTuningRegistryProvider.notifier).upsert(next);
  }
}

/// 同一岗位下的一代产物。
///
/// 基底升级后会有多代并存（如 1.5B 与 1B），必须逐条展示 —— 只看第一条会
/// 让「新训好的那一代」在页面上完全隐形。
class _VariantBlock extends StatelessWidget {
  const _VariantBlock({
    required this.artifact,
    required this.engineStateId,
    required this.isBookWorld,
    required this.onEdit,
    required this.onToggle,
  });

  final RwkvStateArtifact artifact;

  /// 引擎 `/v1/state/list` 里这个文件的 state_id（空 = 引擎里没有）。
  final String engineStateId;

  final bool isBookWorld;
  final VoidCallback onEdit;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final TextStyle? small = text.bodySmall;
    final bool ready = engineStateId.isNotEmpty ||
        artifact.uploadedStateId.trim().isNotEmpty ||
        artifact.mergedModelId.trim().isNotEmpty;
    final String uploaded = engineStateId.isNotEmpty
        ? engineStateId
        : (artifact.uploadedStateId.trim().isEmpty
              ? '（未上传）'
              : '${artifact.uploadedStateId}（手工填）');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 20),
        Row(
          children: [
            Expanded(
              child: Text(
                artifact.displayName.isEmpty ? artifact.id : artifact.displayName,
                style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              ready ? '● 可用' : '○ 未挂载',
              style: small?.copyWith(
                color: ready ? Colors.green : Colors.orange,
              ),
            ),
            if (!artifact.enabled) Text('  · 已停用', style: small),
          ],
        ),
        Text('id：${artifact.id}', style: small),
        Text('文件：${artifact.statePath}', style: small),
        Text('基底：${artifact.baseModelId}', style: small),
        Text('参数当量：${artifact.paramClassLabel(false)}', style: small),
        Text(
          '训练：${artifact.steps} 步 · loss ${artifact.finalLoss}'
          '${artifact.sampleCount > 0 ? ' · ${artifact.sampleCount} 样本' : ''}',
          style: small,
        ),
        Text(
          '合并模型 id：${artifact.mergedModelId.isEmpty ? '（未填）' : artifact.mergedModelId}',
          style: small,
        ),
        Text('引擎内 state id：$uploaded', style: small),
        if (artifact.engineModelId.isNotEmpty)
          Text('引擎模型 id：${artifact.engineModelId}', style: small),
        if (isBookWorld)
          Text(
            '绑定书籍：${artifact.bookId.isEmpty ? '（通用，不覆盖任何书）' : artifact.bookId}',
            style: small,
          ),
        if (artifact.notes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '备注：${artifact.notes}',
              style: small?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            FilledButton.tonalIcon(
              icon: const Icon(Icons.edit, size: 18),
              label: const Text('编辑产物'),
              onPressed: onEdit,
            ),
            TextButton.icon(
              icon: Icon(
                artifact.enabled
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline,
                size: 18,
              ),
              label: Text(artifact.enabled ? '停用' : '启用'),
              onPressed: onToggle,
            ),
          ],
        ),
      ],
    );
  }
}
