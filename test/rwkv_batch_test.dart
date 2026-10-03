import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';

import 'package:novelcraft/ai/agents/agent.dart';
import 'package:novelcraft/ai/models/batch_chat.dart';
import 'package:novelcraft/ai/rwkv/rwkv_batch_client.dart';
import 'package:novelcraft/ai/rwkv/rwkv_concurrency.dart';
import 'package:novelcraft/ai/workflow/batch_agent_executor.dart';
import 'package:novelcraft/ai/workflow/workflow.dart';
import 'package:novelcraft/ai/workflow/workflow_branch.dart';

/// P3（批量 / 并发 / 分叉）的回归测试。
///
/// 这里守的是几条**实测得来、写错就静默出错**的契约（PITFALLS §27.3 / §30.2 / §31.3）：
///   1. `stop_tokens` 必须默认携带（不传 → 每个槽位返回空文本）
///   2. 批量路由是 `/v1/batch/completions`（不是 `/v1/chat/completions`，
///      更不是 `/openai/v1/...`）
///   3. SSE 多槽位**交错到达** → 必须按 index 分组
///   4. `400 bsz overflow` → **拆批**，不是退避
///   5. 服务端没有 429 → 别写 429 退避
///
/// 运行：`flutter test test/rwkv_batch_test.dart`
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Logger.root.level = Level.OFF;

  group('批量请求体（PITFALLS §30.2）', () {
    test('默认显式携带 stop_tokens —— 不传会让每个槽位返回空文本', () {
      final m = RwkvBatchRequest(contents: <String>['a']).toJson();
      expect(m['stop_tokens'], kRwkvDefaultStopTokens);
      expect(m['contents'], <String>['a']);
      expect(m.containsKey('messages'), isFalse, reason: '批量路由只认 contents');
    });

    test('subset 保持参数、只换内容', () {
      final r = RwkvBatchRequest(
        contents: <String>['a', 'b', 'c'],
        maxTokens: 77,
        temperature: 0.5,
      );
      final sub = r.subset(<int>[0, 2]);
      expect(sub.contents, <String>['a', 'c']);
      expect(sub.maxTokens, 77);
      expect(sub.temperature, 0.5);
      expect(sub.stopTokens, kRwkvDefaultStopTokens);
    });
  });

  group('响应解析（缺失槽位不能臆造）', () {
    test('contentsByIndex 按 index 对齐，缺的留 null', () {
      final res = RwkvBatchResponse.fromJson(<String, dynamic>{
        'id': 'rwkv7-fast-batch',
        'choices': <dynamic>[
          <String, dynamic>{
            'index': 2,
            'message': <String, dynamic>{'content': 'C'},
          },
          <String, dynamic>{
            'index': 0,
            'message': <String, dynamic>{'content': 'A'},
          },
        ],
      });
      expect(res.contentsByIndex(3), <String?>['A', null, 'C']);
      expect(res.missingIndices(3), <int>[1]);
    });

    test('空内容的槽位也算缺失（要触发子集重试）', () {
      final res = RwkvBatchResponse.fromJson(<String, dynamic>{
        'choices': <dynamic>[
          <String, dynamic>{
            'index': 0,
            'message': <String, dynamic>{'content': 'ok'},
            'finish_reason': 'stop',
          },
          <String, dynamic>{
            'index': 1,
            'message': <String, dynamic>{'content': ''},
            'finish_reason': 'stop',
          },
        ],
      });
      expect(res.missingIndices(2), <int>[1],
          reason: 'stop_tokens 没传时就是这个症状：200 + index 正确 + 内容为空');
    });
  });

  group('bsz overflow 是「拆批」而不是「退避」（PITFALLS §31.3）', () {
    test('suggestedBatchSize 取上限与折半的较小值', () {
      const e = RwkvBatchException(
        kind: RwkvBatchFailureKind.bszOverflow,
        message: 'x',
        maxBsz: 169,
        requestBsz: 200,
      );
      expect(e.suggestedBatchSize(), 100);
      expect(e.isRetryable, isTrue);
    });

    test('服务端根本没有 429 → 该枚举里也不该出现 429 分支', () {
      const e = RwkvBatchException(
        kind: RwkvBatchFailureKind.fatal,
        message: 'x',
        statusCode: 404,
      );
      expect(e.isRetryable, isFalse, reason: '404 是路由不存在，重试没意义');
    });

    test('真实 400 响应体会被自动拆批并完整取回', () async {
      int posts = 0;
      final client = MockClient((http.Request req) async {
        posts++;
        final Map<String, dynamic> body =
            jsonDecode(req.body) as Map<String, dynamic>;
        final List<dynamic> contents = body['contents'] as List<dynamic>;
        if (contents.length > 2) {
          // 超过服务端上限 → 真实格式的 400
          return http.Response(
            jsonEncode(<String, dynamic>{
              'error': 'bsz overflow, Max bsz=2',
              'max_bsz': 2,
              'request_bsz': contents.length,
            }),
            400,
          );
        }
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <dynamic>[
              for (int i = 0; i < contents.length; i++)
                <String, dynamic>{
                  'index': i,
                  'message': <String, dynamic>{'content': 'R${contents[i]}'},
                  'finish_reason': 'stop',
                },
            ],
          }),
          200,
        );
      });
      final c = RwkvBatchClient(
        client: client,
        baseUrl: () => 'https://x',
        headers: () => <String, String>{},
      );
      final out = await c.chat(RwkvBatchRequest(contents: <String>['a', 'b', 'c', 'd']));
      expect(out, <String?>['Ra', 'Rb', 'Rc', 'Rd'],
          reason: '拆成 2+2 两次，结果要按原始顺序归位');
      expect(posts, greaterThan(1), reason: '必须发生拆批重发');
    });

    test('HTTP 200 但 body 是 error → 视为运行时错误并重试', () async {
      int n = 0;
      final client = MockClient((http.Request req) async {
        n++;
        if (n == 1) {
          return http.Response(
              jsonEncode(<String, dynamic>{'error': 'boom'}), 200);
        }
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <dynamic>[
              <String, dynamic>{
                'index': 0,
                'message': <String, dynamic>{'content': 'ok'},
              },
            ],
          }),
          200,
        );
      });
      final c = RwkvBatchClient(
        client: client,
        baseUrl: () => 'https://x',
        headers: () => <String, String>{},
        retryBaseDelay: const Duration(milliseconds: 1),
      );
      expect(await c.chat(RwkvBatchRequest(contents: <String>['a'])),
          <String?>['ok']);
      expect(n, 2);
    });
  });

  group('SSE 按 index 分组（PITFALLS §27.3：到达顺序无序）', () {
    test('流式响应正文消费完之前保持并发许可', () async {
      final body = StreamController<List<int>>();
      final client = MockClient.streaming(
          (http.BaseRequest req, http.ByteStream _) async {
        return http.StreamedResponse(body.stream, 200);
      });
      final capacity = RwkvConcurrencyController(clientHardCap: 1);
      final batch = RwkvBatchClient(
        client: client,
        baseUrl: () => 'https://x',
        headers: () => <String, String>{},
        concurrency: capacity,
      );
      final subscription = batch
          .chatStream(RwkvBatchRequest(contents: <String>['p0'], stream: true))
          .listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(capacity.inFlight, 1);
      body.add(utf8.encode(
          'data: {"choices":[{"index":0,"delta":{"content":"ok"}}]}\n\n'
          'data: {"choices":[{"index":0,"finish_reason":"stop","delta":{}}]}\n\n'
          'data: [DONE]\n\n'));
      await body.close();
      await subscription.asFuture<void>();
      expect(capacity.inFlight, 0);
    });

    test('交错到达时内容不混串，且最后按 index 对齐', () async {
      // 构造 index 1 先到、index 0 后到的交错流
      const String sse = 'data: {"choices":[{"index":1,"delta":{"content":"B1"}}]}\n'
          '\n'
          'data: {"choices":[{"index":0,"delta":{"content":"A1"}}]}\n'
          '\n'
          'data: {"choices":[{"index":1,"delta":{"content":"B2"}}]}\n'
          '\n'
          'data: {"choices":[{"index":0,"finish_reason":"stop","delta":{}}]}\n'
          '\n'
          'data: {"choices":[{"index":1,"finish_reason":"stop","delta":{}}]}\n'
          '\n'
          'data: [DONE]\n\n';
      final client = MockClient.streaming(
          (http.BaseRequest req, http.ByteStream body) async {
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable(<List<int>>[utf8.encode(sse)]),
          200,
          headers: <String, String>{'content-type': 'text/event-stream'},
        );
      });
      final c = RwkvBatchClient(
        client: client,
        baseUrl: () => 'https://x',
        headers: () => <String, String>{},
      );
      RwkvBatchProgress? last;
      await for (final RwkvBatchProgress p
          in c.chatStream(RwkvBatchRequest(
        contents: <String>['p0', 'p1'],
        stream: true,
      ))) {
        last = p;
      }
      expect(last, isNotNull);
      expect(last!.done, isTrue);
      expect(last.partial[0], 'A1', reason: 'index 0 的内容不能被 index 1 污染');
      expect(last.partial[1], 'B1B2');
      expect(last.finished.containsAll(<int>{0, 1}), isTrue);
    });

    test('SSE 里的 error 事件（HTTP 仍 200）要抛出而不是当成正常结束', () async {
      const String sse =
          'data: {"error":"bsz overflow, Max bsz=16"}\n\ndata: [DONE]\n\n';
      final client = MockClient.streaming(
          (http.BaseRequest req, http.ByteStream body) async {
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable(<List<int>>[utf8.encode(sse)]),
          200,
        );
      });
      final c = RwkvBatchClient(
        client: client,
        baseUrl: () => 'https://x',
        headers: () => <String, String>{},
      );
      await expectLater(
        c.chatStream(RwkvBatchRequest(contents: <String>['p0'], stream: true)),
        emitsError(isA<RwkvBatchException>()),
      );
    });
  });

  group('并发容量控制器（PITFALLS §31.3）', () {
    test('取服务端 available_bsz 与客户端硬上限的较小值', () async {
      final ctrl = RwkvConcurrencyController(
        probe: () async => const RwkvServerCapacity(
          hardMaxBsz: 169,
          dynamicMaxBsz: 169,
          availableBsz: 169,
        ),
        clientHardCap: 16,
      );
      expect(await ctrl.effectivePermits(), 16,
          reason: '服务端能开 169 也不该真开 169（跨境尾延迟）');
    });

    test('服务端比客户端更小则听服务端的', () async {
      final ctrl = RwkvConcurrencyController(
        probe: () async => const RwkvServerCapacity(availableBsz: 4),
        clientHardCap: 16,
      );
      expect(await ctrl.effectivePermits(), 4);
    });

    test('已在排队时再压一半', () async {
      final ctrl = RwkvConcurrencyController(
        probe: () async => const RwkvServerCapacity(
          availableBsz: 16,
          queuedRequests: 3,
        ),
        clientHardCap: 16,
      );
      expect(await ctrl.effectivePermits(), 8);
    });

    test('bsz overflow 后降档，连续成功后再缓慢回升', () async {
      final ctrl = RwkvConcurrencyController(
        probe: () async => const RwkvServerCapacity(availableBsz: 64),
        clientHardCap: 16,
      );
      expect(await ctrl.effectivePermits(), 16);
      ctrl.noteBszOverflow(16, 6);
      expect(await ctrl.effectivePermits(), 6);
      for (int i = 0; i < 5; i++) {
        ctrl.noteSuccess();
      }
      expect(await ctrl.effectivePermits(), 7);
    });
  });

  group('BatchAgentExecutor：多个 Agent 攒成一次 POST（P3-22 验收）', () {
    test('8 个提交 → 1 次 HTTP POST，且各槽位回到各自 Agent', () async {
      int posts = 0;
      int lastContentsLen = 0;
      final client = MockClient((http.Request req) async {
        posts++;
        final Map<String, dynamic> body =
            jsonDecode(req.body) as Map<String, dynamic>;
        final List<dynamic> contents = body['contents'] as List<dynamic>;
        lastContentsLen = contents.length;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'id': 'rwkv7-fast-batch',
            'choices': <dynamic>[
              for (int i = 0; i < contents.length; i++)
                <String, dynamic>{
                  'index': i,
                  'message': <String, dynamic>{'content': 'out-$i'},
                  'finish_reason': 'stop',
                },
            ],
          }),
          200,
        );
      });
      final batch = RwkvBatchClient(
        client: client,
        baseUrl: () => 'https://x',
        headers: () => <String, String>{},
      );
      final ex = BatchAgentExecutor(
        batchClient: batch,
        maxBatchSize: 8,
        batchWaitWindow: const Duration(milliseconds: 60),
      );

      final List<_FakeAgent> agents = <_FakeAgent>[
        for (int i = 0; i < 8; i++) _FakeAgent('agent-$i'),
      ];
      final List<WorkflowTask> tasks = <WorkflowTask>[
        for (int i = 0; i < 8; i++)
          WorkflowTask(
            name: 't$i',
            taskType: 'GenerateChapterContent',
            parameters: <String, dynamic>{'prompt': 'prompt-$i'},
          ),
      ];

      final List<AgentTaskResult> results = await Future.wait<AgentTaskResult>(
        <Future<AgentTaskResult>>[
          for (int i = 0; i < 8; i++) ex.submit(agents[i], tasks[i]),
        ],
      );

      expect(posts, 1, reason: 'P3-22 硬指标：8 个 Agent 只发 1 次 HTTP POST');
      expect(lastContentsLen, 8);
      expect(results.length, 8);
      expect(results.every((AgentTaskResult r) => r.isSuccess), isTrue);
      for (int i = 0; i < 8; i++) {
        expect(results[i].data, 'out-$i', reason: '第 $i 个 Agent 要拿到第 $i 个槽位');
      }
      expect(ex.stats['httpPosts'], 1);
      expect(ex.stats['submits'], 8);
      ex.dispose();
    });

    test('未实现批量 prompt 的 Agent **不会被攒批**，且失败原因可读', () async {
      int posts = 0;
      final client = MockClient((http.Request req) async {
        posts++;
        final List<dynamic> contents =
            (jsonDecode(req.body) as Map<String, dynamic>)['contents']
                as List<dynamic>;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <dynamic>[
              for (int i = 0; i < contents.length; i++)
                <String, dynamic>{
                  'index': i,
                  'message': <String, dynamic>{'content': 'x'},
                },
            ],
          }),
          200,
        );
      });
      final ex = BatchAgentExecutor(
        batchClient: RwkvBatchClient(
          client: client,
          baseUrl: () => 'https://x',
          headers: () => <String, String>{},
        ),
        maxBatchSize: 8,
        batchWaitWindow: const Duration(milliseconds: 40),
      );
      // 1 个有能力的 + 1 个没能力的，人为把它们塞进同一组
      final List<AgentTaskResult> rs = await Future.wait(<Future<AgentTaskResult>>[
        ex.submit(
            _FakeAgent('good'),
            WorkflowTask(parameters: <String, dynamic>{
              'prompt': 'p',
              'batchGroupId': 'same',
            })),
        ex.submit(
            _NoBatchAgent('bad'),
            WorkflowTask(parameters: <String, dynamic>{
              'batchGroupId': 'same',
            })),
      ]);
      final AgentTaskResult bad = rs.firstWhere(
          (AgentTaskResult r) => (r.errorMessage ?? '').contains('buildPromptForBatch'));
      expect(bad.isSuccess, isFalse,
          reason: '⚠ 绝不能拿兜底文本去攒批 —— 那会静默降低成文质量');
      expect(bad.errorMessage, contains('未实现 buildPromptForBatch'));
      expect(posts, 1, reason: '有能力的那个仍然被批发了');
      ex.dispose();
    });

    test('不同 batchGroupId 分开成批（长 prompt 隔离）', () async {
      int posts = 0;
      final client = MockClient((http.Request req) async {
        posts++;
        final List<dynamic> contents =
            (jsonDecode(req.body) as Map<String, dynamic>)['contents']
                as List<dynamic>;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <dynamic>[
              for (int i = 0; i < contents.length; i++)
                <String, dynamic>{
                  'index': i,
                  'message': <String, dynamic>{'content': 'x'},
                },
            ],
          }),
          200,
        );
      });
      final ex = BatchAgentExecutor(
        batchClient: RwkvBatchClient(
          client: client,
          baseUrl: () => 'https://x',
          headers: () => <String, String>{},
        ),
        maxBatchSize: 8,
        batchWaitWindow: const Duration(milliseconds: 50),
      );
      final List<Future<AgentTaskResult>> fs = <Future<AgentTaskResult>>[
        for (int i = 0; i < 2; i++)
          ex.submit(
            _FakeAgent('g1-$i'),
            WorkflowTask(parameters: <String, dynamic>{
              'prompt': 'p',
              'batchGroupId': 'short',
            }),
          ),
        for (int i = 0; i < 2; i++)
          ex.submit(
            _FakeAgent('g2-$i'),
            WorkflowTask(parameters: <String, dynamic>{
              'prompt': 'p',
              'batchGroupId': 'long',
            }),
          ),
      ];
      await Future.wait<AgentTaskResult>(fs);
      expect(posts, 2, reason: '两个分组 → 两次 POST');
      ex.dispose();
    });
  });

  group('世界观分支三级降级（PITFALLS §33.3）', () {
    test('服务端无 multi_state → 走独立会话播种，并标记 usedFallback', () async {
      final model = _FakeBranchModel(BranchCapability.sessionSeed);
      final runner = WorkflowBranchRunner(model: model);
      final List<WorkflowBranch> branches = <WorkflowBranch>[
        WorkflowBranch(branchId: 'A', divergencePrompt: '如果选择复仇'),
        WorkflowBranch(branchId: 'B', divergencePrompt: '如果选择放手'),
      ];
      final out = await runner.run(branches,
          baseSessionId: 'wf42', seedContext: '共同前情');
      expect(out.length, 2);
      expect(out.every((WorkflowBranch b) => b.usedFallback), isTrue);
      expect(out.every((WorkflowBranch b) => b.isSuccess), isTrue);
      // 每条分支用独立 sessionId
      expect(model.statefulSessions.toSet().length, 2);
      expect(model.statefulSessions.first, startsWith('wf42:branch-'));
      // 首次播种必须带上父上下文
      expect(model.firstPrompts.every((String p) => p.contains('共同前情')), isTrue);
    });

    test('非 RWKV Provider（model 为 null）→ 串行重编码兜底', () async {
      int serial = 0;
      final runner = WorkflowBranchRunner(
        model: null,
        serialChat: (String prompt, int? maxTokens) async {
          serial++;
          return 'serial:$prompt';
        },
      );
      final out = await runner.run(
        <WorkflowBranch>[
          WorkflowBranch(branchId: 'BE', divergencePrompt: 'bad end'),
        ],
        baseSessionId: 'wf',
        seedContext: 'ctx',
      );
      expect(serial, 1);
      expect(out.single.isSuccess, isTrue);
      expect(out.single.usedFallback, isTrue);
    });

    test('单条分支失败不拖垮其他分支', () async {
      final model = _FakeBranchModel(BranchCapability.sessionSeed, failOn: 'B');
      final runner = WorkflowBranchRunner(model: model);
      final out = await runner.run(
        <WorkflowBranch>[
          WorkflowBranch(branchId: 'A', divergencePrompt: 'a'),
          WorkflowBranch(branchId: 'B', divergencePrompt: 'b'),
          WorkflowBranch(branchId: 'C', divergencePrompt: 'c'),
        ],
        baseSessionId: 'wf',
      );
      expect(out[0].isSuccess, isTrue);
      expect(out[1].isSuccess, isFalse);
      expect(out[2].isSuccess, isTrue);
    });

    test('multi_state 可用时用 dialogueIdx 且 usedFallback=false', () async {
      final model = _FakeBranchModel(BranchCapability.multiState);
      final runner = WorkflowBranchRunner(model: model);
      final out = await runner.run(
        <WorkflowBranch>[
          WorkflowBranch(branchId: 'A', divergencePrompt: 'a', dialogueIdx: 0),
        ],
        baseSessionId: 'wf',
      );
      expect(out.single.usedFallback, isFalse);
      expect(out.single.allocatedIdx, 1, reason: '服务端会分配新 idx');
      expect(model.statefulSessions, isEmpty, reason: '不该退到独立会话');
    });
  });
}

// ---------------------------------------------------------------------------
// 测试替身
// ---------------------------------------------------------------------------

/// 最小可用的 BaseAgent 子类：只覆写必需成员。
class _FakeAgent extends BaseAgent {
  _FakeAgent(this._name) : super(logger: Logger('FakeAgent.$_name'));

  final String _name;

  @override
  String get name => _name;

  @override
  String get description => 'fake agent for tests';

  @override
  List<AgentCapability> supportedCapabilities() => const <AgentCapability>[];

  @override
  Future<AgentTaskResult> executeTask(
    String taskType,
    Map<String, dynamic> parameters,
  ) async =>
      AgentTaskResult(isSuccess: true, data: 'single');

  /// ✅ 实现批量 prompt（返回非 null）才算「支持攒批」。
  /// 默认实现返回 null，这正是 P4-28 的能力闸依据。
  @override
  String? buildPromptForBatch(
    String taskType,
    Map<String, dynamic> parameters,
  ) =>
      parameters['prompt']?.toString() ?? 'prompt-for-$_name';
}

/// ❌ 故意**不**实现批量 prompt 的 Agent —— 用来验证"不会被静默攒批"。
class _NoBatchAgent extends BaseAgent {
  _NoBatchAgent(this._name) : super(logger: Logger('NoBatch.$_name'));

  final String _name;

  @override
  String get name => _name;

  @override
  String get description => 'agent without batch prompt';

  @override
  List<AgentCapability> supportedCapabilities() => const <AgentCapability>[];

  @override
  Future<AgentTaskResult> executeTask(
    String taskType,
    Map<String, dynamic> parameters,
  ) async =>
      AgentTaskResult(isSuccess: true, data: 'single');
}

class _FakeBranchModel implements IBranchingChatModel {
  _FakeBranchModel(this.cap, {this.failOn});

  final BranchCapability cap;
  final String? failOn;
  final List<String> statefulSessions = <String>[];
  final List<String> firstPrompts = <String>[];
  int _multiIdx = 0;

  @override
  Future<BranchCapability> probeBranchCapability() async => cap;

  @override
  Future<String> statefulChat({
    required String sessionId,
    required String prompt,
    int? maxTokens,
  }) async {
    if (failOn != null && sessionId.endsWith('branch-$failOn')) {
      throw StateError('boom');
    }
    statefulSessions.add(sessionId);
    firstPrompts.add(prompt);
    return 'text-$sessionId';
  }

  @override
  Future<(String text, int? newIdx)> multiStateChat({
    required String sessionId,
    required int dialogueIdx,
    required String prompt,
    int? maxTokens,
  }) async {
    _multiIdx = dialogueIdx + 1;
    return ('multistate:$prompt', _multiIdx);
  }
}
