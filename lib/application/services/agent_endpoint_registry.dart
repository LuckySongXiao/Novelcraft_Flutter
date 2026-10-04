import 'dart:convert';

import '../../ai/providers/rwkv_cloud_provider.dart';

/// Dedicated clients for saved endpoints; never reconfigure an active client.
class AgentEndpointRegistry {
  final Map<String, RwkvCloudProvider> providers = {};
  final Map<String, RwkvCloudEndpointProfile> profiles = {};
  final List<RwkvCloudProvider> _retired = [];

  static String key(String id) => 'RWKV Cloud::$id';
  static String platform(String key) => key.split('::').first;

  Future<void> replace(List<RwkvCloudEndpointProfile> next) async {
    final ids = next.map((p) => key(p.id)).toSet();
    for (final old in providers.keys.toList()) {
      if (!ids.contains(old)) {
        _retired.add(providers.remove(old)!);
        profiles.remove(old);
      }
    }
    for (final profile in next) {
      final id = key(profile.id);
      if (jsonEncode(profiles[id]?.toJson()) == jsonEncode(profile.toJson())) continue;
      final provider = RwkvCloudProvider();
      if (!await provider.configure(profile.toConfiguration(), probe: false)) {
        provider.dispose();
        continue;
      }
      final old = providers[id];
      if (old != null) _retired.add(old);
      providers[id] = provider;
      profiles[id] = profile;
    }
  }

  void dispose() {
    for (final p in [...providers.values, ..._retired]) {
      p.dispose();
    }
  }
}
