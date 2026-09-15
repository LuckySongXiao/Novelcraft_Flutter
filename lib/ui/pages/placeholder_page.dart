import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../layout/navigation.dart';

/// 尚未移植的功能页占位
///
/// 随着各页面逐个补齐，这里的分支会逐步减少。
class PlaceholderPage extends ConsumerWidget {
  const PlaceholderPage({super.key, required this.target});

  final NavigationTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.construction_outlined, size: 56, color: scheme.outline),
          const SizedBox(height: 16),
          Text(
            l10n.tf('PH.PageTitle', '{0} 页面', [target.name]),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.t('PH.NotPorted', '该页面待移植'),
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
