import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_theme.dart';
import 'ai_health_page.dart';
import 'agent_batch_config_page.dart';
import 'writing_prompt_settings_page.dart';

/// 设置页 —— 对应 C# 的「选项 / 设置」对话框
///
/// 目前覆盖两块用户可即时切换的偏好：
///  - 皮肤（白昼 / 黑夜 / 花漾少女 / 自动按时段）
///  - 语言（中文 / English）
/// 二者分别由 [themeControllerProvider] 与 [localeControllerProvider] 持久化，
/// 切换后通过 Riverpod 自动驱动整个 MaterialApp 重建。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = ref.watch(l10nProvider);
    final theme = ref.watch(themeControllerProvider);
    final locale = ref.watch(localeControllerProvider);

    final skinName = _skinName(theme.skinId, l10n);

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          l10n.t('Common.Settings', '设置'),
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 20),
        Card(child: ListTile(
          leading: const Icon(Icons.edit_note),
          title: Text(l10n.t('Set.WritingPrompt', '写作工艺 Prompt 模板')),
          subtitle: Text(
            l10n.t('Set.WritingPromptDesc', '编辑各节点提示词、保存多套模板并选择生效模板'),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => const WritingPromptSettingsPage(),
          )),
        )),

        // ---- 皮肤 ----
        _SectionCard(
          title: l10n.t('Set.ThemeSkin', '主题皮肤'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.tf('Set.CurrentSkin', '当前：{0}', [skinName]), style: TextStyle(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final id in SkinIds.all)
                    _SkinChip(
                      skinId: id,
                      selected: theme.skinId == id,
                      onTap: () =>
                          ref.read(themeControllerProvider.notifier).selectSkin(id),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.t('Set.AutoByTime', '按时间段自动切换（19:00–07:00 走黑夜）')),
                value: theme.autoByTime,
                onChanged: (v) =>
                    ref.read(themeControllerProvider.notifier).setAutoByTime(v),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // ---- 语言 ----
        _SectionCard(
          title: l10n.t('Set.UILanguage', '界面语言'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.tf('Set.CurrentLang', '当前：{0}', [locale.languageCode == 'en' ? 'English' : '中文']),
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              SegmentedButton<Locale>(
                selected: {locale},
                onSelectionChanged: (set) {
                  final next = set.first;
                  ref.read(localeControllerProvider.notifier).setLocale(next);
                },
                segments: [
                  ButtonSegment(
                    value: AppLocales.zh,
                    label: Text(l10n.t('Set.LangZh', '中文')),
                    icon: const Icon(Icons.translate),
                  ),
                  ButtonSegment(
                    value: AppLocales.en,
                    label: Text(l10n.t('Set.LangEn', 'English')),
                    icon: const Icon(Icons.translate),
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // ---- 诊断（P4-26 健康面板入口）----
        _SectionCard(
          title: l10n.t('Set.Diagnostics', '诊断'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.layers_outlined),
                title: Text(l10n.t('Set.AgentBatch', 'Agent 攒批配置')),
                subtitle: Text(l10n.t('Set.AgentBatchDesc',
                    '指定哪些 Agent 参与攒批、各自归到哪个分组（长 prompt 单独成组）')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (BuildContext _) => const AgentBatchConfigPage(),
                  ),
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.monitor_heart_outlined),
                title: Text(l10n.t('Set.AiHealth', 'AI 健康检查')),
                subtitle: Text(
                  l10n.t('Set.AiHealthDesc',
                      '并发/排队、QPS 与 p95 长尾、失败分类、State 命中率'),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (BuildContext _) => const AiHealthPage(),
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // ---- 关于 ----
        _SectionCard(
          title: l10n.t('Set.About', '关于'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.t('Set.AboutApp', 'NovelCraft —— AI 小说创作管理系统（Flutter 版）')),
              const SizedBox(height: 4),
              Text(
                l10n.t('Set.AboutDesc', '由 C# WPF 版整体移植，复用同一套业务模型。'),
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _skinName(String id, L10n l10n) {
    if (id == SkinIds.auto) return l10n.t('Skin.Auto', '自动（按时段）');
    for (final s in builtInSkins) {
      if (s.id == id) return l10n.isEnglish ? s.nameEn : s.nameZh;
    }
    return id;
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: scheme.primary,
                  ),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _SkinChip extends ConsumerWidget {
  const _SkinChip({
    required this.skinId,
    required this.selected,
    required this.onTap,
  });

  final String skinId;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    final isAuto = skinId == SkinIds.auto;
    final skin = isAuto
        ? builtInSkins.first
        : builtInSkins.firstWhere(
            (s) => s.id == skinId,
            orElse: () => builtInSkins.first,
          );

    final preview = isAuto
        ? Row(
            children: [
              _Swatch(color: builtInSkins[0].seed),
              const SizedBox(width: 4),
              _Swatch(color: builtInSkins[1].seed),
            ],
          )
        : _Swatch(color: skin.seed);

    final label = isAuto ? l10n.t('Skin.ChipAuto', '自动') : (l10n.isEnglish ? skin.nameEn : skin.nameZh);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 96,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: [
            preview,
            const SizedBox(height: 8),
            Text(label, style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.black12),
        ),
      );
}
