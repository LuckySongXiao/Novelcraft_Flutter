// 客户端 RWKV 云端会话台账 + Provider 分流链路的回归测试（BUG 2）。
//
// 覆盖两块此前**零测试**的高风险逻辑：
//   1. `RwkvCloudSessionLedger` / `RwkvCloudSessionRecord` 的纯逻辑 ——
//      存储键转义（Windows 文件名禁冒号）、增量提示词契约（contents 恰好 1 条）、
//      转写本截断对齐、`runExclusive` 的同会话串行与失败放行；
//   2. `RwkvCloudProvider.chat()` 的分流 —— 带 key 走 `/state/chat/completions`
//      且**不吃流式**，服务端丢会话时先用本地转写本重放重建再重试，
//      连重放都不行则回落无状态链路（客户端 state 是增强，不能拖死主流程）。
//
// 运行：`flutter test test/rwkv_cloud_state_test.dart`
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:novelcraft/ai/models/chat.dart';
import 'package:novelcraft/ai/providers/rwkv_cloud_provider.dart';
import 'package:novelcraft/ai/rwkv/rwkv_cloud_state.dart';

/// 内存版 KeyValueStore 打桩：key → json 字符串。
class _MemoryStore {
  final Map<String, String> data = <String, String>{};
  final List<String> removed = <String>[];

  Future<String?> read(String key) async => data[key];
  Future<void> write(String key, String value) async => data[key] = value;
  Future<void> removeKey(String key) async {
    removed.add(key);
    data.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('存储键转义（native KeyValueStore 拿 key 当文件名）', () {
    test('冒号必须被替换掉，否则 Windows 写盘静默失败', () {
      final String key = RwkvCloudSessionLedger.storageKey(
        'a1b2-uuid::chapter::c9d8::leader',
      );
      expect(key.contains(':'), isFalse, reason: 'Windows 文件名不允许冒号');
      expect(key, 'a1b2-uuid__chapter__c9d8__leader');
    });

    test('中文字符同样会被转义（书名做前缀时会出现）', () {
      final String key = RwkvCloudSessionLedger.storageKey('测试书::plan::leader');
      expect(key.contains(':'), isFalse);
      expect(RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(key), isTrue, reason: key);
    });

    test('已是安全字符时原样保留（保证旧台账能被读回）', () {
      expect(
        RwkvCloudSessionLedger.storageKey('abc-123_x.y'),
        'abc-123_x.y',
      );
    });
  });

  group('会话记录：增量提示词契约', () {
    test('首轮带 system + 全部 messages；之后**只发最后一条**', () {
      final RwkvCloudSessionRecord rec = RwkvCloudSessionRecord(
        sessionKey: 'p::leader',
        sessionId: 'nc-1',
      );
      expect(rec.isFresh, isTrue);

      final first = rec.buildTurnPrompt(
        ChatRequest(
          systemPrompt: '你是主笔',
          messages: <ChatMessage>[
            ChatMessage.user('写第一章'),
          ],
        ),
      );
      expect(first.isFirstTurn, isTrue);
      expect(first.prompt, contains('System: 你是主笔'));
      expect(first.prompt, contains('User: 写第一章'));
      expect(first.prompt, endsWith('Assistant:'));

      rec.appendTurn('写第一章', '正文……');
      expect(rec.isFresh, isFalse);

      final second = rec.buildTurnPrompt(
        ChatRequest(
          systemPrompt: '你是主笔',
          messages: <ChatMessage>[
            ChatMessage.user('写第一章'),
            ChatMessage.assistant('正文……'),
            ChatMessage.user('继续写第二段'),
          ],
        ),
      );
      expect(second.isFirstTurn, isFalse);
      // `/state/chat/completions` 的 contents 必须恰好 1 条 —— 多带一条直接 400
      expect(second.prompt, 'User: 继续写第二段\n\nAssistant:');
      expect(second.prompt.contains('System:'), isFalse);
      expect(second.prompt.contains('写第一章'), isFalse);
    });

    test('buildPrompt：有外部 systemPrompt 时不再注入 system 角色的消息', () {
      final String withExternal = RwkvCloudSessionRecord.buildPrompt(
        <ChatMessage>[
          ChatMessage.system('内部系统词'),
          ChatMessage.user('问题'),
        ],
        systemPrompt: '外部系统词',
      );
      expect(withExternal, 'System: 外部系统词\n\nUser: 问题\n\nAssistant:');

      final String withoutExternal = RwkvCloudSessionRecord.buildPrompt(
        <ChatMessage>[
          ChatMessage.system('内部系统词'),
          ChatMessage.user('问题'),
        ],
      );
      expect(
        withoutExternal,
        'System: 内部系统词\n\nUser: 问题\n\nAssistant:',
      );
    });

    test('toJson / fromJson 往返不丢转写本与轮次', () {
      final RwkvCloudSessionRecord rec = RwkvCloudSessionRecord(
        sessionKey: 'p::writer-3',
        sessionId: 'nc-99',
      )..appendTurn('问', '答');
      final RwkvCloudSessionRecord back = RwkvCloudSessionRecord.fromJson(
        rec.toJson(),
      );
      expect(back.sessionKey, 'p::writer-3');
      expect(back.sessionId, 'nc-99');
      expect(back.turnCount, 1);
      expect(back.transcript, hasLength(2));
      expect(back.transcript.first.content, '问');
      expect(back.transcript.last.content, '答');
    });
  });

  group('台账：解析 / 落盘 / 截断 / 遗忘', () {
    test('新键生成带 nc- 前缀的客户端会话 ID，且并发批量生成互不重复', () async {
      final _MemoryStore store = _MemoryStore();
      final RwkvCloudSessionLedger ledger = RwkvCloudSessionLedger(
        read: store.read,
        write: store.write,
      );
      final RwkvCloudSessionRecord rec = await ledger.resolve('p::leader');
      expect(rec.sessionId.startsWith('nc-'), isTrue);
      expect(rec.isFresh, isTrue);

      final Set<String> ids = <String>{
        for (int i = 0; i < 200; i++) ledger.newSessionId(),
      };
      expect(ids.length, 200, reason: '并发写多章时每角色必须拿到不同 session_id');
    });

    test('落盘后能被读回（会话 ID 跨重启不变）', () async {
      final _MemoryStore store = _MemoryStore();
      final RwkvCloudSessionLedger a = RwkvCloudSessionLedger(
        read: store.read,
        write: store.write,
      );
      final RwkvCloudSessionRecord first = await a.resolve('p::leader');
      first.appendTurn('问', '答');
      await a.persist(first);

      // 模拟重启：新的台账实例，同一个 store
      final RwkvCloudSessionLedger b = RwkvCloudSessionLedger(
        read: store.read,
        write: store.write,
      );
      final RwkvCloudSessionRecord again = await b.resolve('p::leader');
      expect(again.sessionId, first.sessionId);
      expect(again.turnCount, 1);
      expect(again.transcript, hasLength(2));
    });

    test('落盘内容损坏 / sessionId 缺失 → 重建新会话，绝不把空 ID 下发', () async {
      final _MemoryStore store = _MemoryStore();
      store.data['p::leader'] = '{broken';
      final RwkvCloudSessionLedger ledger = RwkvCloudSessionLedger(
        read: store.read,
        write: store.write,
      );
      final RwkvCloudSessionRecord rec = await ledger.resolve('p::leader');
      expect(rec.sessionId.startsWith('nc-'), isTrue);
      expect(rec.isFresh, isTrue);

      store.data['p::writer-1'] = jsonEncode(<String, Object?>{
        'sessionKey': 'p::writer-1',
        'sessionId': '',
        'turnCount': 5,
      });
      ledger.clearMemo();
      final RwkvCloudSessionRecord rec2 = await ledger.resolve('p::writer-1');
      expect(rec2.sessionId.trim().isEmpty, isFalse);
      expect(rec2.isFresh, isTrue, reason: '空 sessionId 视为不可用，必须重建');
    });

    test('转写本超出上限时**成对**丢最旧轮次，保持 user/assistant 对齐', () async {
      final _MemoryStore store = _MemoryStore();
      final RwkvCloudSessionLedger ledger = RwkvCloudSessionLedger(
        read: store.read,
        write: store.write,
        maxStoredChars: 120,
      );
      final RwkvCloudSessionRecord rec = await ledger.resolve('p::leader');
      for (int i = 0; i < 10; i++) {
        rec.appendTurn('用户第 $i 条提问内容刚好二十字', '助手第 $i 条回复内容刚好二十字');
      }
      await ledger.persist(rec);

      int total = 0;
      for (final ChatMessage m in rec.transcript) {
        total += m.content.length;
      }
      expect(total <= 120, isTrue, reason: '必须真的截断到上限内');
      expect(rec.transcript.length.isEven, isTrue, reason: 'user/assistant 必须成对');
      expect(rec.transcript.first.role, ChatRole.user);
      expect(rec.transcript.last.role, ChatRole.assistant);
      expect(rec.transcript.last.content, '助手第 9 条回复内容刚好二十字');
      expect(rec.turnCount, 10, reason: 'turnCount 是历史累计，不随截断回退');
    });

    test('落盘失败被静默吞掉（持久化是增强，不能拖垮推理）', () async {
      final RwkvCloudSessionLedger ledger = RwkvCloudSessionLedger(
        read: (String key) async => null,
        write: (String key, String value) async =>
            throw const _FakeWriteFailure(),
      );
      final RwkvCloudSessionRecord rec = await ledger.resolve('p::leader');
      rec.appendTurn('问', '答');
      await expectLater(ledger.persist(rec), completes);
    });

    test('forget 清掉内存缓存并调用删除回调', () async {
      final _MemoryStore store = _MemoryStore();
      final RwkvCloudSessionLedger ledger = RwkvCloudSessionLedger(
        read: store.read,
        write: store.write,
        remove: store.removeKey,
      );
      await ledger.resolve('p::leader');
      expect(ledger.cachedCount, 1);
      await ledger.forget('p::leader');
      expect(ledger.cachedCount, 0);
      expect(store.removed, contains('p::leader'));
    });

    test('resolve 空键抛 StateError', () async {
      final _MemoryStore store = _MemoryStore();
      final RwkvCloudSessionLedger ledger = RwkvCloudSessionLedger(
        read: store.read,
        write: store.write,
      );
      await expectLater(ledger.resolve('   '), throwsStateError);
    });
  });

  group('runExclusive：同会话串行、跨会话并行、失败不锁链', () {
    test('同 key 严格按提交顺序执行（state 是单条可变递归状态）', () async {
      final RwkvCloudSessionLedger ledger = RwkvCloudSessionLedger(
        read: (_) async => null,
        write: (_, _) async {},
      );
      final List<int> order = <int>[];
      Future<void> job(int i) => ledger.runExclusive<void>('s', () async {
        await Future<void>.delayed(Duration(milliseconds: 8 - i));
        order.add(i);
      });
      await Future.wait<void>(<Future<void>>[job(0), job(1), job(2), job(3)]);
      expect(order, <int>[0, 1, 2, 3], reason: '完成顺序必须等于提交顺序');
    });

    test('不同 key 互不阻塞', () async {
      final RwkvCloudSessionLedger ledger = RwkvCloudSessionLedger(
        read: (_) async => null,
        write: (_, _) async {},
      );
      final List<String> done = <String>[];
      final Future<void> slow = ledger.runExclusive<void>('a', () async {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        done.add('a');
      });
      final Future<void> fast = ledger.runExclusive<void>('b', () async {
        done.add('b');
      });
      await fast;
      expect(done, <String>['b'], reason: 'b 不应等 a');
      await slow;
      expect(done, <String>['b', 'a']);
    });

    test('前一个任务抛异常，下一个照常放行且异常原样上抛', () async {
      final RwkvCloudSessionLedger ledger = RwkvCloudSessionLedger(
        read: (_) async => null,
        write: (_, _) async {},
      );
      Object? captured;
      final Future<void> bad = ledger.runExclusive<void>('s', () async {
        throw StateError('boom');
      }).catchError((Object e) => captured = e);
      final Future<int> good = ledger.runExclusive<int>('s', () async => 42);
      await bad;
      expect(captured, isA<StateError>());
      expect(await good, 42, reason: '一次失败绝不能把整条链锁死');
    });

    test('空 key 直接执行（等于关闭客户端 state 的旧路径）', () async {
      final RwkvCloudSessionLedger ledger = RwkvCloudSessionLedger(
        read: (_) async => null,
        write: (_, _) async {},
      );
      expect(await ledger.runExclusive<int>('  ', () async => 7), 7);
      expect(ledger.pendingSessionCount, 0);
    });

    test('队尾自回收：跑完不留残留键', () async {
      final RwkvCloudSessionLedger ledger = RwkvCloudSessionLedger(
        read: (_) async => null,
        write: (_, _) async {},
      );
      await Future.wait<void>(<Future<void>>[
        for (int i = 0; i < 20; i++)
          ledger.runExclusive<void>('k$i', () async {}),
      ]);
      expect(ledger.pendingSessionCount, 0);
    });
  });

  group('Provider 分流：带 key 走 /state，服务端丢会话则重放重建', () {
    /// `/models` 探测的最小合法响应。
    http.Response modelsJson() => http.Response(
      jsonEncode(<String, dynamic>{
        'object': 'list',
        'data': <dynamic>[
          <String, dynamic>{
            'id': 'rwkv7-g1k-2.9b-20261004-ctx25600',
            'object': 'model',
          },
        ],
      }),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );

    /// 造一个云端 provider：`/models` 永远成功，其余请求交给 [onPost] 决策。
    Future<RwkvCloudProvider> buildProvider(
      Future<http.Response> Function(http.Request req, Map<String, dynamic> body)
      onPost,
      RwkvCloudSessionLedger ledger, {
      bool clientState = true,
    }) async {
      final MockClient client = MockClient((http.Request req) async {
        // 注意：`/state/*` 与 `/v1/*` 是两套前缀规则（PITFALLS §32.1）——
        // state 路由挂在根上（`/state/chat/completions`），chat 路由带 `/v1`
        // （`/v1/chat/completions`），所以一律用 endsWith 匹配。
        final String path = req.url.path;
        if (path.endsWith('/models')) return modelsJson();
        if (path.endsWith('/state/chat/completions') ||
            path.endsWith('/chat/completions')) {
          final Map<String, dynamic> body = req.body.trim().isEmpty
              ? <String, dynamic>{}
              : jsonDecode(req.body) as Map<String, dynamic>;
          return onPost(req, body);
        }
        // 其它探测（容量 / 引擎状态）不参与断言，给一个合法 JSON 即可。
        return modelsJson();
      });
      final RwkvCloudProvider provider = RwkvCloudProvider(
        client: client,
        sessionLedger: ledger,
        clientStateEnabled: clientState,
      );
      await provider.initialize(RwkvCloudConfiguration());
      return provider;
    }

    http.Response stateReply(String text) => http.Response(
      jsonEncode(<String, dynamic>{
        'choices': <dynamic>[
          <String, dynamic>{
            'message': <String, dynamic>{'content': text},
          },
        ],
      }),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );

    ChatRequest request({bool stream = false}) => ChatRequest(
      model: 'rwkv7-g1k-2.9b-20261004-ctx25600',
      systemPrompt: '你是主笔',
      stream: stream,
      maxTokens: 2048,
      messages: <ChatMessage>[ChatMessage.user('写第一段')],
      parameters: <String, dynamic>{'rwkvSessionKey': 'proj::chapter::c1::leader'},
    );

    test('带 key → 只打 /state/chat/completions，contents 恰好 1 条且强制非流式', () async {
      final _MemoryStore store = _MemoryStore();
      final RwkvCloudSessionLedger ledger = RwkvCloudSessionLedger(
        read: store.read,
        write: store.write,
      );
      final List<String> paths = <String>[];
      late Map<String, dynamic> seen;
      final RwkvCloudProvider provider = await buildProvider((req, body) async {
        paths.add(req.url.path);
        seen = body;
        return stateReply('第一段正文');
      }, ledger);

      // 即使调用方要求流式，state 端点也不支持 → 必须下发 stream: false
      final ChatResponse res = await provider.chat(request(stream: true));
      expect(res.isSuccess, isTrue);
      expect(res.content, '第一段正文');
      expect(paths, <String>['/state/chat/completions']);
      expect(seen['contents'], hasLength(1));
      expect((seen['contents'] as List<dynamic>).single, contains('你是主笔'));
      expect(seen['stream'], isFalse);
      expect((seen['session_id'] as String).startsWith('nc-'), isTrue);

      // 台账已落盘：transcript 有 user/assistant 成对的一条。
      // ⚠ key 里带**端点 host** 前缀 —— state 存在服务端，两个不同端点上的
      // 同名 session_id 是两条完全不同的状态链，必须隔离命名空间。
      expect(
        store.data.keys.single,
        endsWith('::proj::chapter::c1::leader'),
        reason: '实际落盘键：${store.data.keys}',
      );
      expect(
        store.data.keys.single,
        contains('api-7b.rwkvos.com'),
        reason: '落盘键必须带端点身份',
      );
    });

    test('第二轮只发增量且复用同一个 session_id', () async {
      final _MemoryStore store = _MemoryStore();
      final RwkvCloudSessionLedger ledger = RwkvCloudSessionLedger(
        read: store.read,
        write: store.write,
      );
      final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];
      final RwkvCloudProvider provider = await buildProvider((req, body) async {
        bodies.add(body);
        return stateReply('第${bodies.length}段正文');
      }, ledger);

      await provider.chat(request());
      await provider.chat(
        ChatRequest(
          model: 'rwkv7-g1k-2.9b-20261004-ctx25600',
          systemPrompt: '你是主笔',
          maxTokens: 2048,
          messages: <ChatMessage>[ChatMessage.user('写第二段')],
          parameters: <String, dynamic>{
            'rwkvSessionKey': 'proj::chapter::c1::leader',
          },
        ),
      );

      expect(bodies, hasLength(2));
      expect(bodies[0]['session_id'], bodies[1]['session_id']);
      expect((bodies[1]['contents'] as List<dynamic>).single, 'User: 写第二段\n\nAssistant:');
    });

    test('服务端丢了会话 → 先用本地转写本重放重建，再重试本轮', () async {
      final _MemoryStore store = _MemoryStore();
      final RwkvCloudSessionLedger ledger = RwkvCloudSessionLedger(
        read: store.read,
        write: store.write,
      );
      int calls = 0;
      final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];
      final RwkvCloudProvider provider = await buildProvider((req, body) async {
        calls++;
        bodies.add(body);
        // 第 1 次：首轮建 state，成功
        if (calls == 1) return stateReply('第一段正文');
        // 第 2 次：服务端已丢会话 → 失败（触发重放）
        if (calls == 2) return http.Response('{"error":"session not found"}', 404);
        // 第 3 次：重放重建（max_tokens == 1），必须成功
        if (calls == 3) {
          expect(body['max_tokens'], 1);
          expect((body['contents'] as List<dynamic>), hasLength(1));
          return stateReply('ok');
        }
        // 第 4 次：重试本轮
        return stateReply('第二段正文');
      }, ledger);

      await provider.chat(request());
      final ChatResponse second = await provider.chat(
        ChatRequest(
          model: 'rwkv7-g1k-2.9b-20261004-ctx25600',
          systemPrompt: '你是主笔',
          maxTokens: 2048,
          messages: <ChatMessage>[ChatMessage.user('写第二段')],
          parameters: <String, dynamic>{
            'rwkvSessionKey': 'proj::chapter::c1::leader',
          },
        ),
      );

      expect(calls, 4, reason: '首轮 + 失败 + 重放 + 重试');
      expect(second.isSuccess, isTrue);
      expect(second.content, '第二段正文');
      final String replay = (bodies[2]['contents'] as List<dynamic>).single as String;
      expect(replay, contains('User: 写第一段'), reason: '重放必须带上完整转写本');
      expect(replay, contains('Assistant: 第一段正文'));
    });

    test('连重放都不行 → 清台账并回落无状态链路（不能拖死写书主流程）', () async {
      final _MemoryStore store = _MemoryStore();
      final RwkvCloudSessionLedger ledger = RwkvCloudSessionLedger(
        read: store.read,
        write: store.write,
      );
      final List<String> paths = <String>[];
      final RwkvCloudProvider provider = await buildProvider((req, body) async {
        paths.add(req.url.path);
        if (req.url.path.endsWith('/state/chat/completions')) {
          return http.Response('{"error":"down"}', 500);
        }
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <dynamic>[
              <String, dynamic>{
                'message': <String, dynamic>{'content': '无状态兜底正文'},
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }, ledger);

      final ChatResponse res = await provider.chat(request());
      expect(res.isSuccess, isTrue);
      expect(res.content, '无状态兜底正文');
      expect(paths, contains('/v1/chat/completions'), reason: '必须真的回落到无状态链路');
      expect(ledger.cachedCount, 0, reason: '回落时要顺手清掉本地台账');
    });

    test('开关关闭 / 未带 key → 完全走旧的无状态链路', () async {
      final _MemoryStore store = _MemoryStore();
      final RwkvCloudSessionLedger ledger = RwkvCloudSessionLedger(
        read: store.read,
        write: store.write,
      );
      final List<String> paths = <String>[];
      final RwkvCloudProvider provider = await buildProvider((req, body) async {
        paths.add(req.url.path);
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <dynamic>[
              <String, dynamic>{
                'message': <String, dynamic>{'content': '旧链路'},
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }, ledger, clientState: false);

      final ChatResponse res = await provider.chat(request());
      expect(res.content, '旧链路');
      expect(paths, <String>['/v1/chat/completions']);
      expect(store.data, isEmpty);
    });
  });
}

/// 一个只用于「落盘失败被吞掉」用例的假异常（避免 import dart:io 以保持 Web 可编译）。
class _FakeWriteFailure implements Exception {
  const _FakeWriteFailure();
}
