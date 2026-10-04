import '../models/chat.dart';
import '../models/provider.dart';

/// Binds a role's model without mutating the shared platform configuration.
class BoundModelProvider implements IModelProvider {
  BoundModelProvider(this.inner, this.model);
  final IModelProvider inner;
  final String model;

  ChatRequest _bind(ChatRequest r) => ChatRequest(
    model: r.model.isEmpty ? model : r.model,
    messages: List.of(r.messages),
    systemPrompt: r.systemPrompt,
    temperature: r.temperature,
    maxTokens: r.maxTokens,
    stream: r.stream,
    parameters: Map.of(r.parameters),
  );

  @override
  String get providerName => inner.providerName;
  @override
  ModelProviderType get providerType => inner.providerType;
  @override
  bool get isAvailable => inner.isAvailable;
  @override
  Stream<ModelConfigurationChangedEventArgs> get configurationChanged => inner.configurationChanged;
  @override
  Stream<ConnectionStatusChangedEventArgs> get connectionStatusChanged => inner.connectionStatusChanged;
  @override
  Future<bool> initialize(IModelConfiguration configuration) => throw StateError('Configure the platform, not the role');
  @override
  Future<ConnectionTestResult> testConnection() => inner.testConnection();
  @override
  Future<List<ModelInfo>> getAvailableModels() => inner.getAvailableModels();
  @override
  Future<ChatResponse> chat(ChatRequest request) => inner.chat(_bind(request));
  @override
  Future<ChatResponse> chatStream(ChatRequest request, void Function(ChatChunk) onChunkReceived) =>
      inner.chatStream(_bind(request), onChunkReceived);
  @override
  Future<ProviderStatistics> getStatistics() => inner.getStatistics();
  @override
  void dispose() {} // The registry owns the client.
}
