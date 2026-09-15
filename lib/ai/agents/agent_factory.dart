// Agent 工厂。
//
// 对应 C# 中分散在各 Agent 的构造逻辑。集中创建 8 个内置 Agent 并可选注入
// 共享依赖（记忆管理器、思维链处理器、模型管理器、RWKV 服务）。其余 Agent 的
// 注册（如工作流引擎所需的 `director` / `writer` / `summarizer` / `reader` 等
// 目标名）由调用方在 `NovelWorkflowEngine` 中按其 `id` 完成。
library;

import 'package:logging/logging.dart';

import '../memory/memory.dart';
import '../providers/model_manager.dart';
import '../thinking/thinking_processor.dart';
import 'agent.dart';
import 'agents.dart';
import 'package:novelcraft/ai/providers/rwkv_provider.dart' show RwkvProvider;

/// 创建全部内置 Agent 的列表。
///
/// [logger] 为必填；其余依赖可选，传入后 Agent 将具备对应能力（记忆 / 思维链 /
/// 远程模型 / 本地 RWKV 推理）。
List<BaseAgent> createAllAgents({
  required Logger logger,
  IMemoryManager? memoryManager,
  IThinkingChainProcessor? thinkingChainProcessor,
  ModelManager? modelManager,
  RwkvProvider? rwkvService,
}) {
  return [
    DirectorAgent(
      logger: logger,
      memoryManager: memoryManager,
      thinkingChainProcessor: thinkingChainProcessor,
      modelManager: modelManager,
      rwkvService: rwkvService,
    ),
    WriterAgent(
      logger: logger,
      memoryManager: memoryManager,
      thinkingChainProcessor: thinkingChainProcessor,
      modelManager: modelManager,
      rwkvService: rwkvService,
    ),
    CharacterAgent(
      logger: logger,
      memoryManager: memoryManager,
      thinkingChainProcessor: thinkingChainProcessor,
      modelManager: modelManager,
      rwkvService: rwkvService,
    ),
    PlotAgent(
      logger: logger,
      memoryManager: memoryManager,
      thinkingChainProcessor: thinkingChainProcessor,
      modelManager: modelManager,
      rwkvService: rwkvService,
    ),
    WorldAgent(
      logger: logger,
      memoryManager: memoryManager,
      thinkingChainProcessor: thinkingChainProcessor,
      modelManager: modelManager,
      rwkvService: rwkvService,
    ),
    ReaderAgent(
      logger: logger,
      memoryManager: memoryManager,
      thinkingChainProcessor: thinkingChainProcessor,
      modelManager: modelManager,
      rwkvService: rwkvService,
    ),
    SummarizerAgent(
      logger: logger,
      memoryManager: memoryManager,
      thinkingChainProcessor: thinkingChainProcessor,
      modelManager: modelManager,
      rwkvService: rwkvService,
    ),
    EditorAgent(
      logger: logger,
      memoryManager: memoryManager,
      thinkingChainProcessor: thinkingChainProcessor,
      modelManager: modelManager,
      rwkvService: rwkvService,
    ),
  ];
}
