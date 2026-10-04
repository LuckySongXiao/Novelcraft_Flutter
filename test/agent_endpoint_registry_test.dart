import 'package:flutter_test/flutter_test.dart';
import 'package:novelcraft/ai/models/chat.dart';
import 'package:novelcraft/ai/models/provider.dart';
import 'package:novelcraft/ai/providers/bound_model_provider.dart';
import 'package:novelcraft/ai/providers/rwkv_cloud_provider.dart';
import 'package:novelcraft/application/services/agent_endpoint_registry.dart';

class _Model implements IModelProvider {
  ChatRequest? received;
  @override
  Future<ChatResponse> chat(ChatRequest request) async {
    received = request;
    return ChatResponse(content: 'ok', model: request.model);
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('saved endpoints keep independent credentials and clients', () async {
    final registry = AgentEndpointRegistry();
    addTearDown(registry.dispose);
    final a = RwkvCloudEndpointProfile(
      id: 'a', name: 'A', baseUrl: 'https://a.example/v1',
      cfAccessClientId: 'test-a', cfAccessClientSecret: 'test-a-secret',
    );
    final b = a.copyWith(id: 'b', name: 'B', baseUrl: 'https://b.example/v1',
      cfAccessClientId: 'test-b', cfAccessClientSecret: 'test-b-secret');
    await registry.replace([a, b]);
    final clientA = registry.providers[AgentEndpointRegistry.key('a')]!;
    final clientB = registry.providers[AgentEndpointRegistry.key('b')]!;
    expect(clientA, isNot(same(clientB)));
    expect(clientA.configuration.customHeaders[kHeaderCfAccessClientId], 'test-a');
    expect(clientB.configuration.customHeaders[kHeaderCfAccessClientId], 'test-b');
    await registry.replace([a.copyWith(defaultModel: 'new'), b]);
    expect(clientA.configuration.defaultModel, isNot('new'),
        reason: 'in-flight client must not be reconfigured');
    expect(registry.providers[AgentEndpointRegistry.key('b')], same(clientB));
  });
  test('role model is bound without modifying original request', () async {
    final platform = _Model();
    final main = BoundModelProvider(platform, 'model-a');
    final sub = BoundModelProvider(platform, 'model-b');
    final request = ChatRequest();
    expect((await main.chat(request)).model, 'model-a');
    expect((await sub.chat(request)).model, 'model-b');
    expect(request.model, '');
  });
}
