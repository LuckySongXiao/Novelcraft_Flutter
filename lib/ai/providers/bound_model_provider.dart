import '../models/chat.dart';
import '../models/provider.dart';

/// Binds a role's model without mutating the shared platform configuration.
///
/// [stateId] 非空时给每次请求都带上 `state_id` —— `rwkv_lightning_cuda` 会从
/// 这个**已上传的初始 state** 接着算（设定抽取等单步骤专用 state 就走这条路）。
class BoundModelProvider implements IModelProvider {
  BoundModelProvider(this.inner, this.model, {this.stateId = ''});
  final IModelProvider inner;
  final String model;

  /// 引擎侧已上传的初始 state id（空 = 不携带）。
  final String stateId;

  ChatRequest _bind(ChatRequest r) => ChatRequest(
    model: r.model.isEmpty ? model : r.model,
    messages: List.of(r.messages),
    systemPrompt: r.systemPrompt,
    temperature: r.temperature,
    maxTokens: r.maxTokens,
    stream: r.stream,
    parameters: <String, dynamic>{
      ...Map.of(r.parameters),
      if (stateId.isNotEmpty) 'state_id': stateId,
    },
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
