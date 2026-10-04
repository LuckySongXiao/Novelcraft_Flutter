import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:novelcraft/ai/models/provider.dart';
import 'package:novelcraft/ai/providers/rwkv_cloud_provider.dart';

/// 云端 RWKV Provider 的回归测试（PITFALLS §27.2 / §31）。
///
/// 核心风险点是「**静默失败**」：CF Service Token 头名拼错不会 401，
/// 而是返回一段 HTML，`jsonDecode` 抛异常或连接被判定成功但实际拿不到数据。
/// 所以这里直接断言「出网的请求头里到底有没有那两个头」。
///
/// 运行：`flutter test test/rwkv_cloud_provider_test.dart`
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Uri capturedUrl;
  late Map<String, String> capturedHeaders;

  MockClient okModels() => MockClient((http.Request req) async {
    capturedUrl = req.url;
    capturedHeaders = req.headers;
    return http.Response(
      jsonEncode(<String, dynamic>{
        'object': 'list',
        'data': <dynamic>[
          <String, dynamic>{
            'id': 'rwkv7-g1k-7.2b-20261004-ctx25600',
            'object': 'model',
            'owned_by': 'rwkv_lighting_cuda',
          },
        ],
      }),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });

  group('Cloudflare Access 头（精确大小写）', () {
    test('两个头名常量必须逐字节正确', () {
      expect(
        kHeaderCfAccessClientId,
        'CF-Access-Client-Id',
        reason: '必须是 Id（I 大写 + d 小写），不是 ID',
      );
      expect(kHeaderCfAccessClientSecret, 'CF-Access-Client-Secret');
    });

    test('/models 探测会带上两个 CF 头，且 URL 前缀是 /v1', () async {
      final prov = RwkvCloudProvider(client: okModels());
      final cfg = RwkvCloudConfiguration(
        cfAccessClientId: 'abc.access',
        cfAccessClientSecret: 'deadbeef',
      );
      final ok = await prov.initialize(cfg);
      expect(ok, isTrue);

      // mock client 看到的键是规范化后的小写
      expect(capturedHeaders['cf-access-client-id'], 'abc.access');
      expect(capturedHeaders['cf-access-client-secret'], 'deadbeef');
      expect(capturedUrl.toString(), '$kRwkvCloudDefaultBaseUrl/models');
      expect(
        capturedUrl.toString().contains('/openai/v1'),
        isFalse,
        reason: '/openai/v1/* 在 rwkv_lightning_cuda 上是 404（PITFALLS §31.5）',
      );
      prov.dispose();
    });

    test('没填 Token 时不注入空头（避免污染请求）', () async {
      final prov = RwkvCloudProvider(client: okModels());
      await prov.initialize(RwkvCloudConfiguration());
      expect(capturedHeaders.containsKey('cf-access-client-id'), isFalse);
      expect(capturedHeaders.containsKey('cf-access-client-secret'), isFalse);
      prov.dispose();
    });

    test('官方端点模板不预置 API Key、模型 ID 或 CF 凭据', () {
      expect(kRwkvOfficialEndpointProfiles, hasLength(4));
      expect(
        kRwkvOfficialEndpointProfiles.map((p) => p.baseUrl),
        containsAll(<String>[
          'https://api-1b5.rwkvos.com/v1',
          'https://api-3b.rwkvos.com/v1',
          'https://api-7b.rwkvos.com/v1',
          'https://api-13b.rwkvos.com/v1',
        ]),
      );
      for (final RwkvCloudEndpointProfile profile
          in kRwkvOfficialEndpointProfiles) {
        expect(profile.apiKey, isEmpty);
        expect(profile.defaultModel, isEmpty);
        expect(profile.cfAccessClientId, isEmpty);
        expect(profile.cfAccessClientSecret, isEmpty);
      }
    });

    test('RWKV Cloud 接受空 API Key 与空默认模型', () {
      final RwkvCloudConfiguration cfg = RwkvCloudConfiguration();
      expect(cfg.apiKey, isEmpty);
      expect(cfg.defaultModel, isEmpty);
      expect(cfg.getValidationErrors(), isEmpty);
      expect(cfg.isValid(), isTrue);
    });

    test('按配置的 API 地址自动请求 /models 并读取返回模型名', () async {
      final MockClient client = MockClient((http.Request req) async {
        capturedUrl = req.url;
        capturedHeaders = req.headers;
        return http.Response(
          jsonEncode(<String, Object?>{
            'data': <Map<String, String>>[
              <String, String>{'id': 'rwkv7-g1k-1.5b-test'},
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final RwkvCloudProvider provider = RwkvCloudProvider(client: client);
      await provider.initialize(
        RwkvCloudConfiguration(
          baseUrl: 'https://api-1b5.rwkvos.com/v1',
          cfAccessClientId: 'test.access',
          cfAccessClientSecret: 'test-secret',
        ),
      );
      final List<ModelInfo> models = await provider.getAvailableModels();
      expect(capturedUrl.toString(), 'https://api-1b5.rwkvos.com/v1/models');
      expect(capturedHeaders['cf-access-client-id'], 'test.access');
      expect(models.map((m) => m.id), <String>['rwkv7-g1k-1.5b-test']);
      provider.dispose();
    });

    test('Cloudflare HTML 认证失败时不伪造模型列表', () async {
      final RwkvCloudProvider provider = RwkvCloudProvider(
        client: MockClient(
          (http.Request req) async => http.Response(
            '<html>Access denied</html>',
            403,
            headers: <String, String>{'content-type': 'text/html'},
          ),
        ),
      );
      await provider.initialize(
        RwkvCloudConfiguration(defaultModel: 'manually-entered-model'),
      );
      expect(await provider.getAvailableModels(), isEmpty);
      provider.dispose();
    });
  });

  group('配置持久化', () {
    test('toCloudMap / fromCloudMap 往返不丢字段', () {
      final cfg = RwkvCloudConfiguration(
        cfAccessClientId: 'id.access',
        cfAccessClientSecret: 'sec',
        baseUrl: kRwkvCloudDefaultBaseUrl,
        defaultModel: kRwkvCloudDefaultModel,
      );
      final back = RwkvCloudConfiguration.fromCloudMap(
        jsonDecode(jsonEncode(cfg.toCloudMap())) as Map<String, Object?>,
      );
      expect(back.cfAccessClientId, 'id.access');
      expect(back.cfAccessClientSecret, 'sec');
      expect(back.baseUrl, kRwkvCloudDefaultBaseUrl);
      expect(back.defaultModel, kRwkvCloudDefaultModel);
      expect(back.hasCfCredentials, isTrue);
    });

    test('自定义端点配置序列化保留凭据、模型和运行参数', () {
      const RwkvCloudEndpointProfile profile = RwkvCloudEndpointProfile(
        id: 'custom-1',
        name: 'Private RWKV',
        baseUrl: 'https://rwkv.example/v1',
        apiKey: 'user-api-key',
        defaultModel: 'rwkv-custom-model',
        cfAccessClientId: 'private.access',
        cfAccessClientSecret: 'private-secret',
        timeoutSeconds: 240,
        defaultMaxTokens: 8192,
        defaultTemperature: 0.9,
        enableStreaming: false,
      );
      final RwkvCloudEndpointProfile restored =
          RwkvCloudEndpointProfile.fromJson(profile.toJson());
      expect(restored.baseUrl, profile.baseUrl);
      expect(restored.apiKey, profile.apiKey);
      expect(restored.defaultModel, profile.defaultModel);
      expect(restored.cfAccessClientId, profile.cfAccessClientId);
      expect(restored.cfAccessClientSecret, profile.cfAccessClientSecret);
      expect(restored.timeoutSeconds, profile.timeoutSeconds);
      expect(restored.defaultMaxTokens, profile.defaultMaxTokens);
      expect(restored.defaultTemperature, profile.defaultTemperature);
      expect(restored.enableStreaming, profile.enableStreaming);
    });

    test('空凭证不算已配置', () {
      expect(RwkvCloudConfiguration().hasCfCredentials, isFalse);
    });
  });

  group('CF 认证失败识别', () {
    test('返回 HTML 时给可读提示而不是裸 FormatException', () async {
      final prov = RwkvCloudProvider(
        client: MockClient(
          (http.Request req) async => http.Response(
            '<!DOCTYPE html><html><head><title>Sign in</title></head>'
            '<body>cloudflareaccess.com Access login</body></html>',
            403,
            headers: <String, String>{'content-type': 'text/html'},
          ),
        ),
      );
      final r = await prov.testConnection();
      expect(r.isSuccess, isFalse);
      expect(r.errorMessage, contains('Cloudflare Access 认证失败'));
      expect(r.errorMessage, contains(kHeaderCfAccessClientId));
      prov.dispose();
    });
  });

  group('/v1/server/status 解析', () {
    // 真实抓包数据（api-7b.rwkvos.com，engine albatross-1.3.0）
    const realStatus = <String, dynamic>{
      'status': 'running',
      'api_version': '1.3',
      'engine_version': 'albatross-1.3.0',
      'capabilities': <String, dynamic>{
        'batch_completion': true,
        'chat_messages': true,
        'concurrent_generation': true,
        'metrics': true,
        'pause_resume': true,
        'session_cache': true,
        'stream': true,
        'think_type': true,
        'token_count': true,
      },
      'prefill_chunk_size': 128,
      'prefill_queue': <String, dynamic>{
        'available_bsz': 169,
        'bytes_per_bsz': 54927364,
        'dynamic_max_bsz': 169,
        'free_vram_bytes': 10476191744,
        'hard_max_bsz': 169,
        'queued_requests': 0,
        'reserve_vram_bytes': 1047619174,
        'reserved_bsz': 0,
        'total_vram_bytes': 25280839680,
      },
      'last_request': <String, dynamic>{
        'decode_speed': 84.554370280766705,
        'prefill_speed': 1429.3326049030873,
        'generated_tokens': 46,
        'prompt_tokens': 27,
      },
    };

    test('从真实状态体抽出 UI 摘要', () {
      final s = RwkvCloudServerSummary.fromStatus(realStatus);
      expect(s.status, 'running');
      expect(s.apiVersion, '1.3');
      expect(s.engineVersion, 'albatross-1.3.0');
      expect(s.hardMaxBsz, 169);
      expect(s.dynamicMaxBsz, 169);
      expect(s.availableBsz, 169);
      expect(s.queuedRequests, 0);
      expect(s.totalVramGb, closeTo(23.5, 0.2));
      expect(s.freeVramGb, closeTo(9.8, 0.2));
      expect(s.lastDecodeSpeed, closeTo(84.55, 0.01));
      expect(s.capabilities['concurrent_generation'], isTrue);
      expect(s.capabilities['session_cache'], isTrue);
    });

    test('异常/残缺响应不会抛异常', () {
      final s = RwkvCloudServerSummary.fromStatus(<String, dynamic>{});
      expect(s.status, 'unknown');
      expect(s.hardMaxBsz, isNull);
      expect(s.capabilities, isEmpty);
    });
  });
}
