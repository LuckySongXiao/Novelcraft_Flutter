import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/services/book_review_settings.dart';
import '../../core/di.dart';

class BookReviewSettingsCard extends ConsumerStatefulWidget {
  const BookReviewSettingsCard({super.key});

  @override
  ConsumerState<BookReviewSettingsCard> createState() => _BookReviewSettingsCardState();
}

class _BookReviewSettingsCardState extends ConsumerState<BookReviewSettingsCard> {
  late TextEditingController _seniorProvider;
  late TextEditingController _seniorModel;
  late List<GuestReaderProfile> _guests;

  @override
  void initState() {
    super.initState();
    final BookReviewSettings settings = ref.read(bookReviewSettingsProvider);
    _seniorProvider = TextEditingController(text: settings.seniorProvider);
    _seniorModel = TextEditingController(text: settings.seniorModel);
    _guests = List<GuestReaderProfile>.generate(
      3,
      (int index) => settings.guestReaders.length > index
          ? settings.guestReaders[index]
          : GuestReaderProfile(id: 'guest-${index + 1}', name: '客座读者 ${index + 1}'),
    );
  }

  @override
  void dispose() {
    _seniorProvider.dispose();
    _seniorModel.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await ref.read(bookReviewSettingsProvider.notifier).update(
          BookReviewSettings(
            seniorProvider: _seniorProvider.text.trim(),
            seniorModel: _seniorModel.text.trim(),
            guestReaders: _guests,
            enableSeniorReview: true,
          ),
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('审查团队配置已保存')));
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(children: <Widget>[
            Icon(Icons.groups_2_outlined, color: scheme.primary),
            const SizedBox(width: 8),
            const Expanded(child: Text('客座读者与 13B 高级审查员')),
            TextButton(onPressed: _save, child: const Text('保存')),
          ]),
          const Text('7B 会读取客座意见，再向 13B 请教；13B 可认可 7B 或提出修订意见。平台可填 RWKV Cloud::official-13b 或任意已配置第三方平台。'),
          const SizedBox(height: 8),
          Row(children: <Widget>[
            Expanded(child: TextField(controller: _seniorProvider, decoration: const InputDecoration(labelText: '13B 审查员平台'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _seniorModel, decoration: const InputDecoration(labelText: '13B 审查员模型'))),
          ]),
          const SizedBox(height: 8),
          for (int index = 0; index < _guests.length; index++) _guestEditor(index),
        ],
      ),
    );
  }

  Widget _guestEditor(int index) {
    final GuestReaderProfile profile = _guests[index];
    final TextEditingController name = TextEditingController(text: profile.name);
    final TextEditingController provider = TextEditingController(text: profile.provider);
    final TextEditingController model = TextEditingController(text: profile.model);
    final TextEditingController taste = TextEditingController(text: profile.taste);
    return StatefulBuilder(
      builder: (BuildContext context, StateSetter setLocal) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Column(children: <Widget>[
          Row(children: <Widget>[
            Switch(
              value: profile.enabled,
              onChanged: (bool enabled) => setLocal(() {
                _guests[index] = profile.copyWith(enabled: enabled);
              }),
            ),
            Expanded(child: TextField(controller: name, decoration: const InputDecoration(labelText: '读者称呼'), onChanged: (String _) => setLocal(() {
              _guests[index] = _guests[index].copyWith(name: name.text);
            }))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: provider, decoration: const InputDecoration(labelText: '平台'), onChanged: (String _) => setLocal(() {
              _guests[index] = _guests[index].copyWith(provider: provider.text);
            }))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: model, decoration: const InputDecoration(labelText: '模型'), onChanged: (String _) => setLocal(() {
              _guests[index] = _guests[index].copyWith(model: model.text);
            }))),
          ]),
          TextField(
            controller: taste,
            decoration: const InputDecoration(labelText: '人类品味/关注点'),
            onChanged: (String value) => _guests[index] = _guests[index].copyWith(
              name: name.text,
              provider: provider.text,
              model: model.text,
              taste: value,
            ),
          ),
        ]),
      ),
    );
  }
}
