import 'package:flutter_test/flutter_test.dart';
import 'package:novelcraft/ai/rwkv/rwkv_engine_state_index.dart';
import 'package:novelcraft/ai/rwkv/state_tuning_registry.dart';
import 'package:novelcraft/ai/rwkv/writing_step_state_plan.dart';

RwkvStateArtifact _artifact({
  String id = 'st1',
  RwkvStateTarget target = RwkvStateTarget.novelistProse,
  String mergedModelId = '',
  String uploadedStateId = '',
  String engineModelId = '',
  String bookId = '',
  bool enabled = true,
  String baseModelId = 'rwkv7-g1l-1.5b-20261031-ctx34304',
}) => RwkvStateArtifact(
  id: id,
  target: target,
  statePath: 'states/$id.pth',
  baseModelId: baseModelId,
  mergedModelId: mergedModelId,
  uploadedStateId: uploadedStateId,
  engineModelId: engineModelId,
  bookId: bookId,
  enabled: enabled,
);

void main() {
  group('WritingCraftStep', () {
    test('stage id 能反查到步骤', () {
      expect(
        WritingCraftStep.fromStageId('Book/mainOutline'),
        WritingCraftStep.mainOutline,
      );
      expect(
        WritingCraftStep.fromStageId(' Book/polish '),
        WritingCraftStep.polish,
      );
      expect(WritingCraftStep.fromStageId('Book/unknown'), isNull);
      expect(WritingCraftStep.fromStageId(''), isNull);
    });

    test('每个 stage id 只属于一个步骤', () {
      final Set<String> seen = <String>{};
      for (final WritingCraftStep step in WritingCraftStep.values) {
        for (final String id in step.stageIds) {
          expect(seen.add(id), isTrue, reason: '$id 重复归属');
        }
      }
    });
  });

  group('WritingStepStatePlan', () {
    test('没有产物时所有步骤回落基模，且原因可读', () {
      final plan = WritingStepStatePlan(registry: RwkvStateRegistry());
      final StepStateBinding b = plan.resolve(WritingCraftStep.prose);
      expect(b.applied, isFalse);
      expect(b.requestModel, isEmpty);
      expect(b.reason, contains('未注册'));
      expect(plan.appliedCount, 0);
    });

    test('未合并成独立模型时不可用（当前后端无法挂载 .pth）', () {
      final registry = RwkvStateRegistry(
        artifacts: <RwkvStateArtifact>[_artifact()],
      );
      final plan = WritingStepStatePlan(registry: registry);
      final StepStateBinding b = plan.resolve(WritingCraftStep.prose);
      expect(b.applied, isFalse);
      expect(b.reason, contains('合并'));
      expect(b.stateId, 'st1');
    });

    group('引擎上传初始 state（新路线）', () {
      test('只上传 state id 即可用，模型仍下发给基模', () {
        final plan = WritingStepStatePlan(
          registry: RwkvStateRegistry(
            artifacts: <RwkvStateArtifact>[
              _artifact(uploadedStateId: 'state_abc123'),
            ],
          ),
        );
        final StepStateBinding b = plan.resolve(WritingCraftStep.prose);
        expect(b.applied, isTrue);
        expect(b.engineStateId, 'state_abc123');
        expect(b.requestModel, 'rwkv7-g1l-1.5b-20261031-ctx34304');
      });

      test('填了引擎模型 id（量化基模）时按它下发', () {
        final plan = WritingStepStatePlan(
          registry: RwkvStateRegistry(
            artifacts: <RwkvStateArtifact>[
              _artifact(
                uploadedStateId: 'state_abc123',
                engineModelId: 'rwkv7-g1l-1.5b-sb6_w4',
              ),
            ],
          ),
          currentBaseModelId: 'rwkv7-g1l-1.5b-sb6_w4',
        );
        final StepStateBinding b = plan.resolve(WritingCraftStep.prose);
        expect(b.applied, isTrue);
        expect(b.requestModel, 'rwkv7-g1l-1.5b-sb6_w4');
        expect(b.engineStateId, 'state_abc123');
      });

      test('上传路线也做基底校验：换 g1k 端点照样拒绝', () {
        final plan = WritingStepStatePlan(
          registry: RwkvStateRegistry(
            artifacts: <RwkvStateArtifact>[
              _artifact(uploadedStateId: 'state_abc123'),
            ],
          ),
          currentBaseModelId: 'rwkv7-g1k-2.9b',
        );
        final StepStateBinding b = plan.resolve(WritingCraftStep.prose);
        expect(b.applied, isFalse);
        expect(b.reason, contains('基底模型不匹配'));
      });

      test('上传 state 优先于合并模型', () {
        final plan = WritingStepStatePlan(
          registry: RwkvStateRegistry(
            artifacts: <RwkvStateArtifact>[
              _artifact(
                mergedModelId: 'base+st1',
                uploadedStateId: 'state_abc123',
                engineModelId: 'rwkv7-g1l-1.5b-sb6_w4',
              ),
            ],
          ),
          currentBaseModelId: 'rwkv7-g1l-1.5b-sb6_w4',
        );
        final StepStateBinding b = plan.resolve(WritingCraftStep.prose);
        expect(b.applied, isTrue);
        expect(b.requestModel, 'rwkv7-g1l-1.5b-sb6_w4');
        expect(b.engineStateId, 'state_abc123');
      });

      test('角色解析同样带上 state_id', () {
        final plan = WritingStepStatePlan(
          registry: RwkvStateRegistry(
            artifacts: <RwkvStateArtifact>[
              _artifact(
                id: 'st7',
                target: RwkvStateTarget.reviewReport,
                uploadedStateId: 'state_rev',
              ),
            ],
          ),
        );
        final RoleStateBinding b = plan.resolveForRole(RwkvAgentRole.reviewer);
        expect(b.applied, isTrue);
        expect(b.engineStateId, 'state_rev');
        expect(b.requestModel, 'rwkv7-g1l-1.5b-20261031-ctx34304');
      });

      test('引擎索引按文件名覆盖写死的旧 id（重启后 id 会变）', () {
        final plan = WritingStepStatePlan(
          registry: RwkvStateRegistry(
            artifacts: <RwkvStateArtifact>[
              _artifact(uploadedStateId: 'stale-id'),
            ],
          ),
          engineStates: RwkvEngineStateIndex(
            fetched: true,
            byFilename: <String, String>{'st1.pth': 'fresh-id'},
          ),
        );
        final StepStateBinding b = plan.resolve(WritingCraftStep.prose);
        expect(b.applied, isTrue);
        expect(b.engineStateId, 'fresh-id');
      });

      test('引擎已同步但该 state 没上传 → 如实回落基模', () {
        final plan = WritingStepStatePlan(
          registry: RwkvStateRegistry(
            artifacts: <RwkvStateArtifact>[
              _artifact(uploadedStateId: 'stale-id'),
            ],
          ),
          engineStates: RwkvEngineStateIndex(
            fetched: true,
            byFilename: <String, String>{'other.pth': 'x'},
          ),
        );
        final StepStateBinding b = plan.resolve(WritingCraftStep.prose);
        expect(b.applied, isFalse);
        expect(b.reason, contains('尚未上传'));
      });

      test('同岗位多代产物时优先选引擎里真有的那一代', () {
        final plan = WritingStepStatePlan(
          registry: RwkvStateRegistry(
            artifacts: <RwkvStateArtifact>[
              // 旧代（1.5B）：排在前，但当前引擎没有它
              _artifact(
                id: 'st1_prose-v2',
                mergedModelId: 'base+st1-old',
              ),
              // 新代（3B）：排在后面，但引擎已上传
              _artifact(
                id: 'st1_prose-3b-v1',
                baseModelId: 'rwkv-g1m-3b-temp-6056-ctx65536',
                engineModelId: 'rwkv-g1m-3b-temp-6056-ctx65536.w8a16',
              ),
            ],
          ),
          currentBaseModelId: 'rwkv-g1m-3b-temp-6056-ctx65536.w8a16',
          engineStates: RwkvEngineStateIndex(
            fetched: true,
            byFilename: <String, String>{
              'st1_prose-3b-v1.pth': 'new-3b-id',
            },
          ),
        );
        final StepStateBinding b = plan.resolve(WritingCraftStep.prose);
        expect(b.applied, isTrue);
        expect(b.stateId, 'st1_prose-3b-v1');
        expect(b.engineStateId, 'new-3b-id');
        expect(b.requestModel, 'rwkv-g1m-3b-temp-6056-ctx65536.w8a16');
      });
    });

    group('引擎 state 索引', () {
      test('解析 /v1/state/list 并按路径 basename 取 id', () {
        final RwkvEngineStateIndex idx = RwkvEngineStateIndex.parse('''
          {"data":[{"original_filename":"st1_prose-v2.pth",
                    "state_id":"st1_prose-v2-abc"},
                   {"original_filename":"book.pth","state_id":"book-xyz"}]}
        ''');
        expect(idx.fetched, isTrue);
        expect(idx.byFilename.length, 2);
        expect(idx.stateIdForPath(r'F:\m\states\st1_prose-v2.pth'),
            'st1_prose-v2-abc');
        expect(idx.stateIdForPath('rwkv_models/states/book.pth'), 'book-xyz');
        expect(idx.stateIdForPath('rwkv_models/states/missing.pth'), isNull);
      });

      test('坏 JSON 视为「没查到」而不是空列表', () {
        final RwkvEngineStateIndex idx = RwkvEngineStateIndex.parse('not json');
        expect(idx.fetched, isFalse);
      });
    });

    test('已合并时正文步骤使用「基模+state」模型', () {
      final registry = RwkvStateRegistry(
        artifacts: <RwkvStateArtifact>[
          _artifact(mergedModelId: 'rwkv7-g1l-1.5b-st1'),
        ],
      );
      final plan = WritingStepStatePlan(
        registry: registry,
        currentBaseModelId: 'rwkv7-g1l-1.5b-20261031-ctx34304',
      );
      final StepStateBinding b = plan.resolve(WritingCraftStep.prose);
      expect(b.applied, isTrue);
      expect(b.requestModel, 'rwkv7-g1l-1.5b-st1');
      expect(b.reason, isEmpty);
      expect(plan.appliedCount, greaterThan(0));
    });

    test('按目标分别取产物：正文与大纲各用各的 state', () {
      final registry = RwkvStateRegistry(
        artifacts: <RwkvStateArtifact>[
          _artifact(id: 'st1', mergedModelId: 'base+st1'),
          _artifact(
            id: 'st2',
            target: RwkvStateTarget.outlinerStruct,
            mergedModelId: 'base+st2',
          ),
        ],
      );
      final plan = WritingStepStatePlan(registry: registry);
      expect(plan.resolve(WritingCraftStep.prose).requestModel, 'base+st1');
      expect(
        plan.resolve(WritingCraftStep.mainOutline).requestModel,
        'base+st2',
      );
      expect(
        plan.resolve(WritingCraftStep.chapterOutline).requestModel,
        'base+st2',
      );
    });

    test('基底不一致直接判不可用（宁可回落，不能乱挂）', () {
      final registry = RwkvStateRegistry(
        artifacts: <RwkvStateArtifact>[_artifact(mergedModelId: 'base+st1')],
      );
      final plan = WritingStepStatePlan(
        registry: registry,
        currentBaseModelId: 'rwkv7-g1k-2.9b',
      );
      final StepStateBinding b = plan.resolve(WritingCraftStep.prose);
      expect(b.applied, isFalse);
      expect(b.reason, contains('基底模型不匹配'));
    });

    test('当前模型就是合并后的模型 id → 视为匹配', () {
      final registry = RwkvStateRegistry(
        artifacts: <RwkvStateArtifact>[_artifact(mergedModelId: 'base+st1')],
      );
      final plan = WritingStepStatePlan(
        registry: registry,
        currentBaseModelId: 'base+st1',
      );
      expect(plan.resolve(WritingCraftStep.prose).applied, isTrue);
    });

    test('大纲步骤按 MainAgent 模型校验，正文步骤按 SubAgent 模型校验', () {
      final registry = RwkvStateRegistry(artifacts: <RwkvStateArtifact>[
        _artifact(id: 'st1', mergedModelId: 'base+st1'),
        _artifact(
          id: 'st2',
          target: RwkvStateTarget.outlinerStruct,
          mergedModelId: 'base+st2',
        ),
      ]);
      final plan = WritingStepStatePlan(
        registry: registry,
        currentBaseModelId: 'base+st1',
        plannerModelId: 'base+st2',
      );
      expect(plan.resolve(WritingCraftStep.prose).applied, isTrue);
      expect(plan.resolve(WritingCraftStep.mainOutline).applied, isTrue);
      // 正文 1 步 + 三个大纲步骤（主/分卷/章）共 4 步
      expect(plan.appliedCount, 4);
    });

    test('同一基底下其它岗位的合并模型 id 也算匹配（逐岗位切 state）', () {
      final registry = RwkvStateRegistry(artifacts: <RwkvStateArtifact>[
        _artifact(id: 'st1', mergedModelId: 'base+st1'),
        _artifact(
          id: 'st4',
          target: RwkvStateTarget.copyeditorPatch,
          mergedModelId: 'base+st4',
        ),
      ]);
      final plan = WritingStepStatePlan(
        registry: registry,
        currentBaseModelId: 'base+st1',
      );
      expect(plan.resolve(WritingCraftStep.repair).applied, isTrue);
    });

    test('不同基底的端点仍然拒绝（云端 g1k）', () {
      final registry = RwkvStateRegistry(artifacts: <RwkvStateArtifact>[
        _artifact(
          id: 'st4',
          target: RwkvStateTarget.copyeditorPatch,
          mergedModelId: 'base+st4',
        ),
      ]);
      final plan = WritingStepStatePlan(
        registry: registry,
        currentBaseModelId: 'rwkv7-g1k-2.9b',
      );
      expect(plan.resolve(WritingCraftStep.repair).applied, isFalse);
    });

    test('禁用的产物不生效', () {
      final registry = RwkvStateRegistry(
        artifacts: <RwkvStateArtifact>[
          _artifact(enabled: false, mergedModelId: 'base+st1'),
        ],
      );
      final plan = WritingStepStatePlan(registry: registry);
      expect(plan.resolve(WritingCraftStep.prose).applied, isFalse);
    });

    test('无固定输出形状的步骤永不绑定 state', () {
      final registry = RwkvStateRegistry(
        artifacts: <RwkvStateArtifact>[
          _artifact(mergedModelId: 'base+st1'),
          _artifact(
            id: 'st2',
            target: RwkvStateTarget.outlinerStruct,
            mergedModelId: 'base+st2',
          ),
        ],
      );
      final plan = WritingStepStatePlan(registry: registry);
      expect(plan.resolve(WritingCraftStep.planning).applied, isFalse);
      expect(plan.resolve(WritingCraftStep.stateUpdate).applied, isFalse);
    });

    test('summary 逐步骤标注用基模还是基模+state', () {
      final registry = RwkvStateRegistry(
        artifacts: <RwkvStateArtifact>[_artifact(mergedModelId: 'base+st1')],
      );
      final plan = WritingStepStatePlan(registry: registry);
      final String text = plan.summary();
      expect(text, contains('正文写手'));
      expect(text, contains('基模+state（base+st1）'));
      expect(text, contains('主大纲'));
    });

    group('按角色解析', () {
      RwkvStateRegistry registryWithAll() => RwkvStateRegistry(
        artifacts: <RwkvStateArtifact>[
          _artifact(id: 'st1', mergedModelId: 'base+st1'),
          _artifact(
            id: 'st2',
            target: RwkvStateTarget.outlinerStruct,
            mergedModelId: 'base+st2',
          ),
          _artifact(
            id: 'st4',
            target: RwkvStateTarget.copyeditorPatch,
            mergedModelId: 'base+st4',
          ),
          _artifact(
            id: 'st7',
            target: RwkvStateTarget.reviewReport,
            mergedModelId: 'base+st7',
          ),
        ],
      );

      test('写手/组长用正文 state，读者/审查用审查 state', () {
        final plan = WritingStepStatePlan(registry: registryWithAll());
        expect(
          plan.resolveForRole(RwkvAgentRole.writer).requestModel,
          'base+st1',
        );
        expect(
          plan.resolveForRole(RwkvAgentRole.teamLeader).requestModel,
          'base+st1',
        );
        expect(
          plan.resolveForRole(RwkvAgentRole.reviewer).requestModel,
          'base+st7',
        );
        expect(
          plan.resolveForRole(RwkvAgentRole.reader).requestModel,
          'base+st7',
        );
        expect(
          plan.resolveForRole(RwkvAgentRole.copyeditor).requestModel,
          'base+st4',
        );
        expect(
          plan.resolveForRole(RwkvAgentRole.outliner).requestModel,
          'base+st2',
        );
      });

      test('每个角色只归属一个岗位', () {
        for (final RwkvAgentRole role in RwkvAgentRole.values) {
          final Iterable<RwkvStatePost> owners =
              kStatePosts.where((RwkvStatePost p) => p.serves(role));
          expect(owners.length, lessThanOrEqualTo(1), reason: role.code);
        }
      });

      test('显式角色绑定优先于角色默认目标', () {
        final registry = registryWithAll()
          ..bind(RwkvAgentRole.reader, 'st2');
        final plan = WritingStepStatePlan(registry: registry);
        final RoleStateBinding b = plan.resolveForRole(RwkvAgentRole.reader);
        expect(b.applied, isTrue);
        expect(b.requestModel, 'base+st2');
      });

      test('缺少对应产物的角色回落基模并给出原因', () {
        final plan = WritingStepStatePlan(
          registry: RwkvStateRegistry(
            artifacts: <RwkvStateArtifact>[_artifact(mergedModelId: 'base+st1')],
          ),
        );
        final RoleStateBinding b = plan.resolveForRole(RwkvAgentRole.reviewer);
        expect(b.applied, isFalse);
        expect(b.reason, contains('未注册'));
      });

      test('角色摘要逐角色标注', () {
        final plan = WritingStepStatePlan(registry: registryWithAll());
        final String text = plan.roleSummary();
        expect(text, contains('写手'));
        expect(text, contains('审查员'));
        expect(text, contains('基模+state'));
        expect(plan.roles.length, RwkvAgentRole.values.length);
      });
    });

    group('按书覆盖（ST-5）', () {
      RwkvStateRegistry registryWithBook({
        String bookId = 'hehuanzong',
        String bookMerged = 'base+book_hehuanzong',
      }) => RwkvStateRegistry(
        artifacts: <RwkvStateArtifact>[
          _artifact(id: 'st1', mergedModelId: 'base+st1'),
          _artifact(
            id: 'book_hehuanzong',
            target: RwkvStateTarget.bookWorld,
            mergedModelId: bookMerged,
            bookId: bookId,
          ),
        ],
      );

      test('不指定书时正文仍走通用 ST-1', () {
        final plan = WritingStepStatePlan(registry: registryWithBook());
        expect(plan.resolve(WritingCraftStep.prose).requestModel, 'base+st1');
        expect(
          plan.resolveForRole(RwkvAgentRole.writer).requestModel,
          'base+st1',
        );
      });

      test('forBook 命中本书 ST-5 后正文与写手改用它', () {
        final plan = WritingStepStatePlan(
          registry: registryWithBook(),
        ).forBook('hehuanzong');
        final StepStateBinding b = plan.resolve(WritingCraftStep.prose);
        expect(b.applied, isTrue);
        expect(b.requestModel, 'base+book_hehuanzong');
        expect(b.target, RwkvStateTarget.bookWorld);
        expect(
          plan.resolveForRole(RwkvAgentRole.writer).requestModel,
          'base+book_hehuanzong',
        );
        expect(
          plan.resolveForRole(RwkvAgentRole.teamLeader).requestModel,
          'base+book_hehuanzong',
        );
      });

      test('按书名也能命中本书 ST-5（项目 id 是 UUID，书名更可读）', () {
        final plan = WritingStepStatePlan(
          registry: registryWithBook(bookId: '合欢宗'),
        ).forBook('9f3c-uuid', title: '合欢宗');
        expect(
          plan.resolve(WritingCraftStep.prose).requestModel,
          'base+book_hehuanzong',
        );
      });

      test('别的书不会串用本书 ST-5', () {
        final plan = WritingStepStatePlan(
          registry: registryWithBook(),
        ).forBook('another_book');
        expect(plan.resolve(WritingCraftStep.prose).requestModel, 'base+st1');
      });

      test('本书 ST-5 未合并时正文回落 ST-1', () {
        final plan = WritingStepStatePlan(
          registry: registryWithBook(bookMerged: ''),
        ).forBook('hehuanzong');
        expect(plan.resolve(WritingCraftStep.prose).requestModel, 'base+st1');
        expect(
          plan.resolveForRole(RwkvAgentRole.writer).requestModel,
          'base+st1',
        );
      });

      test('单书覆盖只改正文/写手，大纲与审查岗位不受影响', () {
        final plan = WritingStepStatePlan(
          registry: RwkvStateRegistry(
            artifacts: <RwkvStateArtifact>[
              _artifact(id: 'st1', mergedModelId: 'base+st1'),
              _artifact(
                id: 'st2',
                target: RwkvStateTarget.outlinerStruct,
                mergedModelId: 'base+st2',
              ),
              _artifact(
                id: 'st7',
                target: RwkvStateTarget.reviewReport,
                mergedModelId: 'base+st7',
              ),
              _artifact(
                id: 'book_hehuanzong',
                target: RwkvStateTarget.bookWorld,
                mergedModelId: 'base+book_hehuanzong',
                bookId: 'hehuanzong',
              ),
            ],
          ),
        ).forBook('hehuanzong');
        expect(
          plan.resolve(WritingCraftStep.mainOutline).requestModel,
          'base+st2',
        );
        expect(
          plan.resolveForRole(RwkvAgentRole.reviewer).requestModel,
          'base+st7',
        );
      });
    });
  });
}
