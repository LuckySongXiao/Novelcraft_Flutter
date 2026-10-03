// TaskQueue 修复项验证：取消竞态、取消态不被覆盖、唤醒式门控、终结态清理。
//
// 运行：flutter test test/task_queue_test.dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import 'package:novelcraft/ai/agents/agent.dart';
import 'package:novelcraft/ai/workflow/task_queue.dart';
import 'package:novelcraft/ai/workflow/workflow.dart';

WorkflowTask _task(String name, {List<String>? deps}) =>
    WorkflowTask(name: name, taskType: 'Test', dependencies: deps);

AgentTaskResult _ok() => AgentTaskResult(isSuccess: true, data: 'ok');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Logger.root.level = Level.OFF;

  group('TaskQueue 修复项', () {
    test('门控等待期间被取消 → 任务不执行且收尾（无僵尸任务）', () async {
      final q = TaskQueue(Logger('t'), maxConcurrentTasks: 1);
      final gate = Completer<void>();
      var ranFirst = false;

      // 任务1：占住唯一的并发槽直到 gate 放行
      final t1 = _task('t1');
      final t2 = _task('t2');
      q.enqueueAll(<WorkflowTask>[t1, t2]);

      final running = q.runAll((task) async {
        if (identical(task, t1)) {
          ranFirst = true;
          await gate.future;
        }
        return _ok();
      });
      // 等 t1 进入 running（事件循环两拍足够）
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(ranFirst, isTrue);
      expect(t2.status, isNot(WorkflowStatus.running));

      // t2 在门控等待时被取消
      final cancelled = q.cancel(t2.id);
      expect(cancelled, isTrue);

      gate.complete();
      await running;

      // 取消后的 t2 不应被执行，状态保持 cancelled
      expect(t2.status, WorkflowStatus.cancelled);
      expect(t2.startedAt, isNull);
      q.dispose();
    });

    test('runner 运行期间被取消 → 取消态不被完成态覆盖', () async {
      final q = TaskQueue(Logger('t'), maxConcurrentTasks: 2);
      final t1 = _task('t1');
      q.enqueueAll(<WorkflowTask>[t1]);
      final finish = Completer<void>();

      final running = q.runAll((task) async {
        // 模拟长任务：取消发生在 runner 进行中
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return _ok();
      });
      await Future<void>.delayed(const Duration(milliseconds: 5));
      q.cancel(t1.id); // 运行中取消
      finish.complete();
      await running;

      // 此前 finally 会把状态覆盖为 completed；修复后保留取消语义
      expect(t1.status, WorkflowStatus.cancelled);
      q.dispose();
    });

    test('取消运行中任务不会提前释放并发槽', () async {
      final q = TaskQueue(Logger('t'), maxConcurrentTasks: 1);
      final gate = Completer<void>();
      final t1 = _task('t1');
      final t2 = _task('t2');
      q.enqueueAll(<WorkflowTask>[t1, t2]);
      var t2Started = false;
      final running = q.runAll((task) async {
        if (identical(task, t1)) {
          await gate.future;
        } else {
          t2Started = true;
        }
        return _ok();
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(q.cancel(t1.id), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(t2Started, isFalse, reason: '取消只改变状态，runner 未退出前仍应占用并发槽');
      gate.complete();
      await running;
      expect(t1.status, WorkflowStatus.cancelled);
      expect(t2.status, WorkflowStatus.completed);
      q.dispose();
    });

    test('clearFinishedState 清理终结态登记（防内存泄漏）', () async {
      final q = TaskQueue(Logger('t'), maxConcurrentTasks: 2);
      q.enqueueAll(<WorkflowTask>[_task('a'), _task('b')]);
      await q.runAll((_) async => _ok());

      // 运行结束：两张 Map 已有数据
      expect(q.getByStatus(WorkflowStatus.completed).length, 2);

      q.clearFinishedState();
      expect(
        q.getByStatus(WorkflowStatus.completed).isEmpty,
        isTrue,
        reason: 'clearFinishedState 后终结态应被清理',
      );
      q.dispose();
    });

    test('运行中 clearFinishedState 不应清理（保护并发场景）', () async {
      final q = TaskQueue(Logger('t'), maxConcurrentTasks: 1);
      final gate = Completer<void>();
      q.enqueueAll(<WorkflowTask>[_task('a')]);
      final running = q.runAll((_) async {
        await gate.future;
        return _ok();
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      // running 非空 → clearFinishedState 应拒绝清理
      q.clearFinishedState();
      gate.complete();
      await running;
      expect(q.getByStatus(WorkflowStatus.completed).length, 1);
      q.dispose();
    });

    test('唤醒式门控：任务完成立即放行等待者（无需等轮询周期）', () async {
      final q = TaskQueue(Logger('t'), maxConcurrentTasks: 1);
      final t1 = _task('t1');
      final t2 = _task('t2');
      q.enqueueAll(<WorkflowTask>[t1, t2]);

      final sw = Stopwatch()..start();
      await q.runAll((_) async {
        // 快速完成（5ms），若门控仍是 100ms 忙等，t2 要多等 ~100ms
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return _ok();
      });
      sw.stop();
      expect(t1.status, WorkflowStatus.completed);
      expect(t2.status, WorkflowStatus.completed);
      // 唤醒路径下总耗时应远小于忙等轮询的量级（留 3 倍余量防 CI 抖动）
      expect(sw.elapsedMilliseconds, lessThan(60), reason: '任务完成应即时唤醒门控等待者');
      q.dispose();
    });

    test('setMaxConcurrentTasks 调大时立即唤醒等待者', () async {
      final q = TaskQueue(Logger('t'), maxConcurrentTasks: 1);
      final gate = Completer<void>();
      final t1 = _task('t1');
      final t2 = _task('t2');
      q.enqueueAll(<WorkflowTask>[t1, t2]);

      final running = q.runAll((task) async {
        if (identical(task, t1)) {
          await gate.future;
        }
        return _ok();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // t1 占槽、t2 在门控等待：调大上限应立即放行 t2（t2 的 runner
      // 立即返回，因此 50ms 后应已进入终态 completed 而非卡在 pending）
      q.setMaxConcurrentTasks(4);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(t2.status, WorkflowStatus.completed, reason: '上限调大后等待任务应被唤醒并完成执行');

      gate.complete();
      await running;
      q.dispose();
    });
  });
}
