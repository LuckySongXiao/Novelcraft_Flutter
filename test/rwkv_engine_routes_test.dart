import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:novelcraft/ai/models/chat.dart';
import 'package:novelcraft/ai/rwkv/rwkv_engine.dart';

/// rwkv_lightning_cuda 路由 / 请求体形态的回归测试（对应 PITFALLS §31.1 / §31.2 / §31.5）。
///
/// 这一组 bug 的共同特征是「**HTTP 恒 200、回答也正常**」，看日志完全正常，
/// 只有把真实请求抓下来比对才能发现。所以这里用 MockClient 直接断言
/// 出网的 **URL** 与 **body 顶层字段**。
///
/// 运行：`flutter test test/rwkv_engine_routes_test.dart`
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 捕获到的一次请求
  late Uri capturedUrl;
  late Map<String, String> capturedHeaders;
  late Map<String, dynamic> capturedBody;

  MockClient buildMock() => MockClient((http.Request req) async {
        capturedUrl = req.url;
        capturedHeaders = req.headers;
        capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'id': 'rwkv7-fast-state',
            'object': 'chat.completion',
            'model': 'rwkv7-g1j',
            'choices': <dynamic>[
              <String, dynamic>{
                'index': 0,
                'message': <String, dynamic>{
                  'role': 'assistant',
                  'content': '好的',
                },
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });

  // modelScanner / processLauncher 走引擎默认实现：测试里根本不会触发
  // 扫盘或拉进程，传进来只会多一层平台条件导入的依赖。
  RwkvEngine engineWith(RwkvEngineConfig cfg, http.Client client) =>
      RwkvEngine(config: cfg, client: client);

  ChatRequest oneTurn() => ChatRequest(
        messages: <ChatMessage>[
          ChatMessage(role: ChatRole.user, content: '你好'),
        ],
        maxTokens: 32,
      );

  group('原生生成参数（文档 §4）', () {
    test('默认显式带 stop_tokens —— 批量路由不传会返回空文本', () {
      final body = const RwkvNativeOptions().toRequestBody();
      expect(body['stop_tokens'], <int>[0, 261, 24281],
          reason: 'stop_tokens 必须默认携带（PITFALLS §30.2）');
    });

    test('只输出显式设置过的字段', () {
      const opts = RwkvNativeOptions(thinkType: 'fast', topK: 20);
      final body = opts.toRequestBody();
      expect(body['think_type'], 'fast');
      expect(body['top_k'], 20);
      expect(body.containsKey('top_p'), isFalse, reason: '未设置的不应出现');
      expect(body.containsKey('chunk_size'), isFalse);
    });

    test('JSON 往返不丢字段', () {
      const opts = RwkvNativeOptions(
        thinkType: 'enLong',
        topK: 5,
        topP: 0.3,
        alphaPresence: 2.0,
        alphaFrequency: 0.2,
        alphaDecay: 0.996,
        chunkSize: 8,
        forceReasoning: true,
      );
      final back = RwkvNativeOptions.fromJson(opts.toMap());
      expect(back.toMap(), opts.toMap());
    });
  });

  group('RwkvEngineConfig JSON 往返', () {
    test('baseUrl / 原生参数 / stateful 开关都能存回来', () {
      const cfg = RwkvEngineConfig(
        baseUrl: 'https://api-7b.rwkvos.com',
        nativeOptions: RwkvNativeOptions(thinkType: 'free', chunkSize: 4),
        useStatefulRoute: true,
        maxConcurrentSessions: 12,
      );
      final back = RwkvEngineConfig.fromJson(
          jsonDecode(jsonEncode(cfg.toMap())) as Map<String, Object?>);
      expect(back.baseUrl, 'https://api-7b.rwkvos.com');
      expect(back.useStatefulRoute, isTrue);
      expect(back.maxConcurrentSessions, 12);
      expect(back.nativeOptions.thinkType, 'free');
      expect(back.nativeOptions.chunkSize, 4);
      expect(back.nativeOptions.stopTokens, <int>[0, 261, 24281]);
    });
  });

  group('路由前缀（PITFALLS §31.5：曾经错拼成 /openai/v1）', () {
    test('stateful 关闭 → /v1/chat/completions，且参数在**顶层**', () async {
      final engine = engineWith(
        const RwkvEngineConfig(
          baseUrl: 'https://example.com',
          useStatefulRoute: false,
          nativeOptions: RwkvNativeOptions(thinkType: 'fast'),
        ),
        buildMock(),
      );
      final s = engine.sessionManager.create(label: 't');
      await engine.chatWithSession(oneTurn(), sessionId: s.sessionId);

      expect(capturedUrl.toString(), 'https://example.com/v1/chat/completions');
      expect(capturedUrl.toString().contains('/openai/v1'), isFalse);
      // ⚠ 核心断言：参数必须在**顶层**，不能嵌套进 extra_body
      expect(capturedBody.containsKey('extra_body'), isFalse,
          reason: 'extra_body 会被服务端静默忽略（PITFALLS §31.1）');
      expect(capturedBody['think_type'], 'fast');
      expect(capturedBody['stop_tokens'], <int>[0, 261, 24281]);
      expect(capturedBody['messages'], isA<List<dynamic>>());
      engine.dispose();
    });

    test('baseUrl 已带 /v1 时不会重复拼', () async {
      final engine = engineWith(
        const RwkvEngineConfig(baseUrl: 'https://example.com/v1'),
        buildMock(),
      );
      final s = engine.sessionManager.create();
      await engine.chatWithSession(oneTurn(), sessionId: s.sessionId);
      expect(capturedUrl.toString(), 'https://example.com/v1/chat/completions');
      engine.dispose();
    });

    test('stateful 开启 → /state/chat/completions（**无** /v1 前缀）', () async {
      final engine = engineWith(
        const RwkvEngineConfig(
          baseUrl: 'https://example.com',
          useStatefulRoute: true,
        ),
        buildMock(),
      );
      final s = engine.sessionManager.create(label: 't');
      await engine.chatWithSession(oneTurn(), sessionId: s.sessionId);

      expect(capturedUrl.toString(),
          'https://example.com/state/chat/completions');
      // contents 必须**恰好 1 条**（传 2 条服务端 400）
      expect(capturedBody['contents'], isA<List<dynamic>>());
      expect((capturedBody['contents'] as List<dynamic>).length, 1);
      expect(capturedBody['session_id'], s.sessionId);
      expect(capturedBody.containsKey('messages'), isFalse);
      // stateful 路由不靠 body 传 state_id，也不发 X-RWKV-State-Id
      expect(capturedBody.containsKey('state_id'), isFalse);
      expect(capturedHeaders.containsKey('X-RWKV-State-Id'), isFalse);
      // 单条 prompt 用官方经典模板收尾
      expect((capturedBody['contents'] as List<dynamic>).first.toString(),
          endsWith('Assistant:'));
      engine.dispose();
    });
  });

  group('state_id 走表头而非 body（PITFALLS §31.2）', () {
    test('会话有 state 时注入 X-RWKV-State-Id，body 里不出现 state_id', () async {
      final engine = engineWith(
        const RwkvEngineConfig(baseUrl: 'https://example.com'),
        buildMock(),
      );
      final s = engine.sessionManager.create(label: 't');
      s.advanceState('uploaded-state.pth', 0);

      await engine.chatWithSession(oneTurn(), sessionId: s.sessionId);

      expect(capturedHeaders['X-RWKV-State-Id'], 'uploaded-state.pth');
      expect(capturedBody.containsKey('state_id'), isFalse,
          reason: 'body 通道会校验 state 存在性，未上传过直接 400（PITFALLS §31.2）');
      engine.dispose();
    });
  });

  group('每会话串行化（服务端不可并发写同一 session_id）', () {
    test('同一 session 并发发起 5 轮 → 请求逐个完成，不重叠', () async {
      int inFlight = 0;
      int maxInFlight = 0;
      final client = MockClient((http.Request req) async {
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        inFlight--;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <dynamic>[
              <String, dynamic>{
                'index': 0,
                'message': <String, dynamic>{'role': 'assistant', 'content': 'ok'},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
        );
      });
      final engine = engineWith(
        const RwkvEngineConfig(
          baseUrl: 'https://example.com',
          useStatefulRoute: true,
          maxConcurrentSessions: 8,
        ),
        client,
      );
      final s = engine.sessionManager.create(label: 'serial');

      await Future.wait<void>(<Future<void>>[
        for (int i = 0; i < 5; i++)
          engine.chatWithSession(oneTurn(), sessionId: s.sessionId),
      ]);

      expect(maxInFlight, 1,
          reason: '同一 session 的请求必须串行（后完成者会覆盖先完成者的 state）');
      engine.dispose();
    });
  });
}
