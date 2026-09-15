// 真实端点集成测试（HANDOFF P4-30）。
//
// ⚠ 为什么放 `integration_test/` 而不是 `test/`：
//   `test/` 是**纯 Dart 单测、无网络**；这里要真的打 `api-7b.rwkvos.com`，
//   会依赖外网、CF Access 凭证、以及那台 GPU 是否在线 —— 必须与单测隔离，
//   否则 CI 会被网络抖动搞成红的。
//
// 运行：
//   flutter test integration_test/rwkv_cloud_live_test.dart
// 若不想把凭证写进仓库，可用 --dart-define 覆盖：
//   flutter test integration_test/rwkv_cloud_live_test.dart \
//     --dart-define=RWKV_CF_ID=xxx.access --dart-define=RWKV_CF_SECRET=yyy
//
// ⚠ 若凭证失效/过期，HTTP 层会返回 **HTML 登录页而不是 401**，
//   `RwkvBatchException(kind: authFailed)` 会带上这个判断（PITFALLS §27.2）。
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:novelcraft/ai/models/batch_chat.dart';
import 'package:novelcraft/ai/rwkv/rwkv_batch_client.dart';
import 'package:novelcraft/ai/rwkv/rwkv_concurrency.dart';
import 'package:novelcraft/ai/workflow/workflow_branch.dart';
import 'package:novelcraft/ai/providers/rwkv_cloud_provider.dart';

const String _cfId = String.fromEnvironment(
  'RWKV_CF_ID',
  defaultValue: '7e06b7648f552e22842e308939e68be6.access',
);
const String _cfSecret = String.fromEnvironment(
  'RWKV_CF_SECRET',
  defaultValue:
      '8f97be4d651e792df1c29c005533e55aad72354b536ca486f65413b96a93d83a',
);

void main() {
  late RwkvCloudProvider provider;

  setUp(() async {
    provider = RwkvCloudProvider(client: http.Client());
    await provider.initialize(RwkvCloudConfiguration(
      cfAccessClientId: _cfId,
      cfAccessClientSecret: _cfSecret,
    ));
  });

  tearDown(() => provider.dispose());

  group('连通性（P2 验收）', () {
    test('testConnection 拿到 200，且 CF 头拼写正确', () async {
      final r = await provider.testConnection();
      expect(r.isSuccess, isTrue,
          reason: '失败信息：${r.errorMessage}\n'
              '若是 HTML 登录页，说明 CF-Access-Client-Id/Secret 拼错或过期');
    });

    test('/v1/server/status 能取到引擎能力与容量', () async {
      final summary = await provider.fetchServerSummary();
      expect(summary, isNotNull, reason: '端点未响应或不是 rwkv_lightning_cuda');
      expect(summary!.status, 'running');
      expect(summary.engineVersion, isNotEmpty);
      // 关键能力：批量 + 流式 + 并发
      expect(summary.capabilities['concurrent_generation'], isTrue);
      expect(summary.availableBsz, isNotNull);
      // ⚠ available_bsz 会随显存变化，**不能**断言等值（PITFALLS §31.3）
      expect(summary.availableBsz! > 0, isTrue);
    });
  });

  group('批量补全（HANDOFF P4-30：最小 2 条 ping）', () {
    test('contents=[ping1, ping2] → 2 条 choice，HTTP 200 不超时', () async {
      final List<String?> out = await provider.batchChat(
        RwkvBatchRequest(
          contents: <String>[
            'User: 只回复两个字：收到\n\nAssistant:',
            'User: 只回复两个字：明白\n\nAssistant:',
          ],
          maxTokens: 16,
        ),
      );
      expect(out.length, 2, reason: '必须按 index 对齐返回 2 个槽位');
      expect(out[0]!.trim(), isNotEmpty,
          reason: '空内容 = stop_tokens 没传（PITFALLS §30.2）');
      expect(out[1]!.trim(), isNotEmpty);
    });

    test('8 槽位一次 POST（P3-22 验收）', () async {
      final List<String?> out = await provider.batchChat(
        RwkvBatchRequest(
          contents: <String>[
            for (int i = 0; i < 8; i++) 'User: 你是第$i号角色，一句话说明职责。\n\nAssistant:',
          ],
          maxTokens: 48,
        ),
      );
      expect(out.length, 8);
      expect(out.where((String? t) => (t ?? '').trim().isNotEmpty).length, 8);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('流式批量：按 index 分组，3 个槽位各自成文', () async {
      Map<int, String>? last;
      await for (final RwkvBatchProgress p in provider.batchChatStream(
        RwkvBatchRequest(
          contents: <String>[
            'User: 一句话说明流化床。\n\nAssistant:',
            'User: 一句话说明碳化硅。\n\nAssistant:',
            'User: 一句话说明直拉法。\n\nAssistant:',
          ],
          maxTokens: 40,
          stream: true,
          chunkSize: kRwkvDefaultBatchChunkSize,
        ),
      )) {
        if (p.done) last = p.partial;
      }
      expect(last, isNotNull);
      expect(last!.length, 3);
      for (final MapEntry<int, String> e in last.entries) {
        expect(e.value.trim(), isNotEmpty, reason: '槽位 ${e.key} 内容为空');
      }
      // 三条内容必须彼此不同 —— 相同说明混串了（index 分组失效）
      expect(last.values.toSet().length, 3,
          reason: '三个槽位内容重复 = SSE index 分组失效，内容混串');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('会话续跑（实测有效的 state 复用）', () {
    test('只发增量也能记住上一轮的内容', () async {
      final String sid = 'nc-it-${DateTime.now().millisecondsSinceEpoch}';
      // 轮 1：写入一个不存在的暗号
      final String r1 = await provider.statefulChat(
        sessionId: sid,
        prompt: 'User: 请记住暗号是「琉璃九号」。\n\nAssistant:',
        maxTokens: 32,
      );
      expect(r1.trim(), isNotEmpty);

      // 轮 2：**不重发历史**，只问暗号
      final String r2 = await provider.statefulChat(
        sessionId: sid,
        prompt: 'User: 我刚才让你记的暗号是什么？\n\nAssistant:',
        maxTokens: 48,
      );
      expect(r2.contains('琉璃九号'), isTrue,
          reason: '没答对说明服务端 state 没复用。实际回答：$r2');

      // 收尾清理，别把测试会话留在服务端
      await provider.stateDelete(sessionId: sid, deletePrefix: true);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('能力探测（官方标「可选」的路由）', () {
    test('/multi_state/chat/completions 线上是否可用（用于决定分叉档位）', () async {
      final cap = await provider.probeBranchCapability();
      // 不断言具体档位（不同部署版本不同），但要能明确报出来
      expect(cap.label, isNotEmpty);
      // ignore: avoid_print
      print('实测分叉能力档位：${cap.label} '
          '（trueForking=${cap.isTrueForking}）');
    });
  });

  group('并发容量（不可缓存为常量）', () {
    test('available_bsz 两次读取可能不同 —— 说明它是动态的', () async {
      final a = await provider.capacity();
      expect(a, isNotNull);
      expect(a!.hardMaxBsz, isNotNull);
      expect(a.bytesPerBsz, isNotNull);
      // 只断言「读得到」，不断言等值 —— 它本来就该变
      final RwkvServerCapacity? b = await provider.capacity();
      expect(b, isNotNull);
      // ignore: avoid_print
      print('capacity #1=${a.effectiveAvailable} #2=${b!.effectiveAvailable} '
          '（hard=${a.hardMaxBsz}）');
    });
  });
}
