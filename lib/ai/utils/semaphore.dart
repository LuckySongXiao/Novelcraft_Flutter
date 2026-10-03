// 轻量级异步信号量。
//
// 对应 C# `System.Threading.SemaphoreSlim`。用于限制并发请求数（如 Ollama
// 本地服务限流、`workflow` 任务的并发执行）。基于 `Completer` 实现，不依赖
// 任何平台专属 API，可在 Web 与 Native 两端通用。
library;

import 'dart:async';

/// 轻量信号量。
class Semaphore {
  int _available;
  final int _max;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  /// 构造信号量。
  ///
  /// [max] 为最大并发许可数。
  Semaphore(int max) : _max = max < 1 ? 1 : max, _available = max < 1 ? 1 : max;

  /// 当前可用许可数（仅用于观测，不应据此做并发判断）。
  int get available => _available;

  /// 最大许可数。
  int get max => _max;

  /// 获取一个许可；若无可用许可则等待直至被 [release] 释放。
  Future<void> acquire() {
    if (_available > 0) {
      _available--;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  /// 释放一个许可；若有等待者则直接交给等待者，否则增加可用计数。
  void release() {
    if (_waiters.isNotEmpty) {
      final waiter = _waiters.removeAt(0);
      waiter.complete();
    } else {
      _available = _available < _max ? _available + 1 : _max;
    }
  }
}
