// RWKV State Tuning 注册表（配置接口层）单元验证。
//
// 运行：flutter test test/state_tuning_registry_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:novelcraft/ai/rwkv/state_tuning_registry.dart';

RwkvStateArtifact _art({
  String id = 'st1-v1',
  RwkvStateTarget target = RwkvStateTarget.novelistProse,
  String base = 'rwkv7-g1l-1.5b-20261031-ctx34304',
  bool enabled = true,
}) =>
    RwkvStateArtifact(
      id: id,
      target: target,
      statePath: 'F:/models/states/$id.pth',
      baseModelId: base,
      baseModelPath: 'F:/models/base.pth',
      enabled: enabled,
    );

void main() {
  group('目标 / 角色序列化', () {
    test('state 目标 code 唯一且可反查', () {
      expect(RwkvStateTarget.values.length, 10);
      final Set<String> codes =
          RwkvStateTarget.values.map((RwkvStateTarget t) => t.code).toSet();
      expect(codes.length, RwkvStateTarget.values.length);
      for (final RwkvStateTarget t in RwkvStateTarget.values) {
        expect(RwkvStateTarget.fromCode(t.code), t);
      }
    });

    test('未知 code 返回 null', () {
      expect(RwkvStateTarget.fromCode('nope'), isNull);
      expect(RwkvAgentRole.fromCode('nope'), isNull);
    });
  });

  group('注册表绑定', () {
    test('绑定后可解析；禁用或删除后解析为 null', () {
      final RwkvStateRegistry reg = RwkvStateRegistry();
      reg.upsert(_art());
      reg.bind(RwkvAgentRole.writer, 'st1-v1');
      expect(reg.resolveForRole(RwkvAgentRole.writer)?.id, 'st1-v1');

      reg.upsert(_art(enabled: false));
      expect(reg.resolveForRole(RwkvAgentRole.writer), isNull);

      reg.upsert(_art());
      reg.remove('st1-v1');
      expect(reg.resolveForRole(RwkvAgentRole.writer), isNull);
      expect(reg.bindings, isEmpty, reason: '删除产物应连带清理绑定');
    });

    test('同角色重复绑定后者覆盖前者', () {
      final RwkvStateRegistry reg = RwkvStateRegistry();
      reg.upsert(_art(id: 'a'));
      reg.upsert(_art(id: 'b'));
      reg.bind(RwkvAgentRole.writer, 'a');
      reg.bind(RwkvAgentRole.writer, 'b');
      expect(reg.bindings.length, 1);
      expect(reg.resolveForRole(RwkvAgentRole.writer)?.id, 'b');
    });

    test('同目标可并存多个版本（byTarget 只返回启用的）', () {
      final RwkvStateRegistry reg = RwkvStateRegistry();
      reg.upsert(_art(id: 'v1'));
      reg.upsert(_art(id: 'v2'));
      reg.upsert(_art(id: 'v3', enabled: false));
      expect(
        reg.byTarget(RwkvStateTarget.novelistProse).map((RwkvStateArtifact a) => a.id),
        <String>['v1', 'v2'],
      );
    });
  });

  group('挂载校验（官方同款基底约束）', () {
    test('基底一致 → 通过，且要求先合并', () {
      final RwkvStateRegistry reg = RwkvStateRegistry();
      final RwkvStateMountCheck c = reg.checkMount(
        _art(),
        currentBaseModelId: 'rwkv7-g1l-1.5b-20261031-ctx34304',
      );
      expect(c.ok, isTrue);
      expect(c.requiresMerge, isTrue);
    });

    test('基底不一致 → 拒绝并给出可读原因', () {
      final RwkvStateRegistry reg = RwkvStateRegistry();
      final RwkvStateMountCheck c = reg.checkMount(
        _art(),
        currentBaseModelId: 'rwkv7-g1k-7.2b',
      );
      expect(c.ok, isFalse);
      expect(c.reason, contains('基底模型不匹配'));
    });

    test('空路径 / 空基底 → 拒绝', () {
      final RwkvStateRegistry reg = RwkvStateRegistry();
      expect(
        reg.checkMount(
          const RwkvStateArtifact(
            id: 'x',
            target: RwkvStateTarget.novelistProse,
            statePath: '',
            baseModelId: 'b',
          ),
          currentBaseModelId: 'b',
        ).ok,
        isFalse,
      );
      expect(
        reg.checkMount(
          const RwkvStateArtifact(
            id: 'x',
            target: RwkvStateTarget.novelistProse,
            statePath: 'p',
            baseModelId: '',
          ),
          currentBaseModelId: 'b',
        ).ok,
        isFalse,
      );
    });
  });

  group('JSON 往返', () {
    test('产物 + 绑定完整还原', () {
      final RwkvStateRegistry reg = RwkvStateRegistry();
      reg.upsert(_art(id: 'st3', target: RwkvStateTarget.briefContract));
      reg.bind(RwkvAgentRole.outliner, 'st3');
      final RwkvStateRegistry back =
          RwkvStateRegistry.fromJson(reg.toJson());
      expect(back.artifacts.length, 1);
      expect(back.artifacts.single.target, RwkvStateTarget.briefContract);
      expect(back.resolveForRole(RwkvAgentRole.outliner)?.id, 'st3');
    });

    test('损坏字段回落安全默认', () {
      final RwkvStateRegistry back = RwkvStateRegistry.fromJson(
        <String, Object?>{
          'artifacts': <Object?>[
            <String, Object?>{'id': 'x', 'target': 'bogus', 'statePath': 'p'},
          ],
          'bindings': <Object?>[
            <String, Object?>{'role': 'bogus', 'stateId': 'x'},
          ],
        },
      );
      expect(back.artifacts.single.target, RwkvStateTarget.novelistProse);
      expect(back.bindings.single.role, RwkvAgentRole.writer);
    });
  });
}
