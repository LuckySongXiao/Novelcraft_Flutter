import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import 'package:novelcraft/ai/agents/agent.dart';
import 'package:novelcraft/ai/agents/agent_factory.dart';

/// 「批量 prompt 与单路等价」这个claim的可执行断言（P4-28 收尾）。
///
/// 为什么必须断言而不是"看一眼觉得对"：
/// 单路请求是
/// `ChatRequest(systemPrompt: buildSystemPrompt(t), messages: [user(buildUserPrompt(t,p))])`
/// —— 只有 system + **一条** user。批量路由是无状态的（只吃 `contents: string[]`），
/// 所以 system 必须**内联**进 prompt。少内联一次，模型就丢掉角色与格式约束，
/// 表现为"开了攒批之后文笔变差"，**且不会报任何错**。
///
/// 运行：`flutter test test/agent_batch_prompt_test.dart`
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Logger.root.level = Level.OFF;

  final List<BaseAgent> agents = createAllAgents(logger: Logger('Test'));

  /// 每个 Agent 挑一个它自己声明支持的任务类型
  String pickTask(BaseAgent a) =>
      a.supportedCapabilities().isNotEmpty
          ? a.supportedCapabilities().first.name
          : 'AnalyzeTheme';

  final Map<String, dynamic> params = <String, dynamic>{
    'projectId': 'proj-1',
    'title': '玄穹剑主',
    'chapterIndex': 3,
    'content': '叶知秋握剑而立。',
  };

  group('8 个内置 Agent 都必须支持攒批', () {
    test('Agent 数量与名单', () {
      expect(agents.length, 8, reason: 'HANDOFF 说的 8 Agent');
      final List<String> names = agents.map((BaseAgent a) => a.name).toList();
      expect(
        names,
        containsAll(<String>[
          'Director',
          'Writer',
          'Character',
          'Plot',
          'World',
          'Reader',
          'Summarizer',
          'Editor',
        ]),
      );
    });

    test('全部 supportsBatchPrompt = true', () {
      for (final BaseAgent a in agents) {
        expect(a.supportsBatchPrompt, isTrue,
            reason: '${a.name} 未声明支持批量 prompt');
      }
    });

    test('全部 buildPromptForBatch 返回非 null', () {
      for (final BaseAgent a in agents) {
        final String? p = a.buildPromptForBatch(pickTask(a), params);
        expect(p, isNotNull, reason: '${a.name} 产不出批量 prompt');
        expect(p!.trim(), isNotEmpty, reason: '${a.name} 产出了空 prompt');
      }
    });
  });

  group('「与单路等价」的具体含义（逐步断言）', () {
    for (final BaseAgent a in agents) {
      test('${a.name}：system 被内联、user 被包含、以 Assistant: 收尾', () {
        final String task = pickTask(a);
        final String sys = a.buildSystemPrompt(task);
        final String user = a.buildUserPrompt(task, params);
        final String prompt = a.buildPromptForBatch(task, params)!;

        // ① system 必须**原样内联**（否则角色/格式约束丢失）
        expect(prompt.contains(sys.trim()), isTrue,
            reason: '${a.name} 的批量 prompt 丢了 system 段:\n$prompt');
        // ② user 段必须在
        expect(prompt.contains(user.trim()), isTrue,
            reason: '${a.name} 的批量 prompt 丢了 user 段');
        // ③ 经典 RWKV 模板收尾，服务端据此续写
        expect(prompt.endsWith('Assistant:'), isTrue,
            reason: '${a.name} 的批量 prompt 结尾不是 Assistant:');
        // ④ system 出现在 user **之前**（顺序不能颠倒）
        expect(prompt.indexOf(sys.trim()) < prompt.indexOf(user.trim()), isTrue,
            reason: '${a.name} 的 system/user 顺序反了');
      });
    }
  });

  group('调用方显式给定 batchPrompt 时优先', () {
    test('给了就用给的，不走拼接', () {
      final BaseAgent a = agents.first;
      const String custom = 'User: 自定义\n\nAssistant:';
      final String? p = a.buildPromptForBatch('AnalyzeTheme', <String, dynamic>{
        'batchPrompt': custom,
      });
      expect(p, custom);
    });

    test('空字符串不算给定', () {
      final BaseAgent a = agents.first;
      final String? p = a.buildPromptForBatch('AnalyzeTheme', <String, dynamic>{
        'batchPrompt': '   ',
      });
      expect(p, isNotNull);
      expect(p, isNot('   '), reason: '空白应被忽略并回退到拼接');
    });
  });

  group('与「无能力」Agent 的区分（能力闸的依据）', () {
    test('默认 BaseAgent 既没有 supportsBatchPrompt 也产不出 prompt', () {
      final _PlainAgent plain = _PlainAgent();
      expect(plain.supportsBatchPrompt, isFalse);
      expect(plain.buildPromptForBatch('X', <String, dynamic>{}), isNull,
          reason: '这是 P4-28 能力闸的根本依据：默认必须为 null');
    });

    test('无能力 Agent 也不会被 buildSelfContainedPrompt 蒙混过关', () {
      final _PlainAgent plain = _PlainAgent();
      // 即使直接调拼接助手，能力闸仍然在 buildPromptForBatch 那一层挡着
      final String joined = plain.buildSelfContainedPrompt('X', <String, dynamic>{});
      expect(joined, contains('Assistant:'));
      expect(plain.buildPromptForBatch('X', <String, dynamic>{}), isNull);
    });
  });

  group('max_tokens 与单路同源', () {
    test('resolveRwkvMaxTokens 对长任务给更大上限', () {
      final BaseAgent a = agents.first;
      final int outline = a.resolveRwkvMaxTokens('GenerateOutline');
      final int polish = a.resolveRwkvMaxTokens('PolishText');
      expect(outline, greaterThan(0));
      expect(polish, greaterThan(0));
      expect(outline, greaterThanOrEqualTo(polish),
          reason: '大纲类任务应比润色类给更多 token（与单路映射一致）');
    });
  });
}

/// 一个什么都不覆写的最小 Agent —— 用来验证"默认不支持攒批"。
class _PlainAgent extends BaseAgent {
  _PlainAgent() : super(logger: Logger('Plain'));

  @override
  String get name => 'Plain';

  @override
  String get description => 'plain agent';

  @override
  List<AgentCapability> supportedCapabilities() => const <AgentCapability>[];

  @override
  Future<AgentTaskResult> executeTask(
    String taskType,
    Map<String, dynamic> parameters,
  ) async =>
      AgentTaskResult(isSuccess: true, data: 'plain');
}
