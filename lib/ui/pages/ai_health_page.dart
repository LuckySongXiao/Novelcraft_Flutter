// AI 健康检查页（P4-26）。
//
// 目的很具体：用户说「生成好慢」时，让他**先看这一页**，一眼分辨到底是哪一类问题 ——
//   ① 客户端并发排队（QPS 到顶 + 延迟长尾比高）
//   ② State 没命中（命中率低 → 每次都在重 prefill）
//   ③ 云端在拆批/重试（失败分类里全是 bszOverflow / truncated）
//   ④ 服务端显存吃紧（available_bsz 变小 + queued > 0）
// 不用来回发日志来回问。
//
// ⚠ 本页面最核心的设计：**客户端真值**与**服务端真值分开展示，并排对照**。
//   把两边混成一个数字是最容易犯的错 —— 客户端 Semaphore 的 16 是「我方保守限流」，
//   服务端的 available_bsz 是「引擎真实容量」，两者含义完全不同（PITFALLS §31.3 / §34.3）。
//   State 命中同理：客户端只有内存命中/未命中，服务端才有 L1 VRAM / L2 RAM / SQLite
//   三级，且多节点部署下 `/state/status` 可能问到别的节点（PITFALLS §32.6）。
//
// 折线用 CustomPainter 手写（约 100 行）：引 charts 包会明显增大 Web 产物体积，
// 而这里只需要一条 60 点的柱/线图。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ai/observability/ai_runtime_stats.dart';
import '../../ai/providers/rwkv_cloud_provider.dart';
import '../../ai/rwkv/rwkv_concurrency.dart';
import '../../core/di.dart';
import '../../l10n/l10n.dart';

class AiHealthPage extends ConsumerStatefulWidget {
  const AiHealthPage({super.key});

  @override
  ConsumerState<AiHealthPage> createState() => _AiHealthPageState();
}

class _AiHealthPageState extends ConsumerState<AiHealthPage> {
  Timer? _ticker;
  RwkvCloudServerSummary? _server;
  bool _loadingServer = false;
  String? _serverError;

  @override
  void initState() {
    super.initState();
    // 1s 采样一次刷新（与 QPS 分桶粒度一致）
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _refreshServer();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _refreshServer() async {
    if (_loadingServer) return;
    setState(() {
      _loadingServer = true;
      _serverError = null;
    });
    try {
      final prov = ref.read(rwkvCloudProviderInstanceProvider);
      final s = await prov.fetchServerSummary();
      if (!mounted) return;
      setState(() {
        _server = s;
        _serverError = s == null
            ? ref.read(l10nProvider).t('AIH.ServerUnavailable',
                '取不到服务端状态（端点未响应，或不是 rwkv_lightning_cuda）')
            : null;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _serverError = '$e');
    } finally {
      if (mounted) setState(() => _loadingServer = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    final AiRuntimeStats stats = ref.watch(aiRuntimeStatsProvider);
    final AiStatsSnapshot snap = stats.snapshot();
    final List<int> series = stats.qpsSeries();
    final RwkvConcurrencyController conc =
        ref.watch(rwkvCloudProviderInstanceProvider).concurrency;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('AIH.Title', 'AI 健康检查')),
        actions: <Widget>[
          IconButton(
            tooltip: l10n.t('AIH.Refresh', '刷新服务端状态'),
            onPressed: _loadingServer ? null : _refreshServer,
            icon: _loadingServer
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _section(context, l10n.t('AIH.Sec.Server', '服务端真值（引擎侧）'),
              Icons.dns_outlined, scheme.primary, _serverBlock(l10n, scheme, conc)),
          const SizedBox(height: 14),
          _section(context, l10n.t('AIH.Sec.Throughput', '请求吞吐（客户端侧）'),
              Icons.speed_outlined, scheme.secondary, _throughputBlock(l10n, scheme, snap, series)),
          const SizedBox(height: 14),
          _section(context, l10n.t('AIH.Sec.Batch', '批量与失败分类'),
              Icons.layers_outlined, scheme.tertiary, _batchBlock(l10n, scheme, snap)),
          const SizedBox(height: 14),
          _section(context, l10n.t('AIH.Sec.State', 'State 诊断'),
              Icons.memory_outlined, scheme.error, _stateBlock(l10n, scheme, snap)),
          const SizedBox(height: 14),
          _section(
              context,
              l10n.t('AIH.Sec.AgentState', '智能体 State 分组（团队 state）'),
              Icons.groups_outlined,
              scheme.primary,
              _agentStateBlock(l10n, scheme)),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------

  Widget _section(BuildContext context, String title, IconData icon,
      Color color, Widget child) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Text(title, style: Theme.of(context).textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  /// 服务端真值：引擎自报的容量/队列/吞吐 + 客户端自己的限流上限（并排对照）。
  Widget _serverBlock(
      L10n l10n, ColorScheme scheme, RwkvConcurrencyController conc) {
    final RwkvCloudServerSummary? s = _server;
    final List<Widget> rows = <Widget>[];

    rows.add(_kv(
      l10n.t('AIH.Server.Engine', '引擎'),
      s == null
          ? (l10n.t('AIH.Server.Unknown', '未知（未取到）'))
          : '${s.engineVersion}  api=${s.apiVersion}  ${s.status}',
      scheme,
    ));

    // ⚠ 并排：服务端可用槽位 vs 客户端限流上限 —— 两个数字含义不同，别合并
    rows.add(_kv(
      l10n.t('AIH.Server.AvailableBsz', '服务端可用槽位 available_bsz'),
      s?.availableBsz?.toString() ?? '-',
      scheme,
      hint: l10n.t('AIH.Server.AvailableBszHint',
          '引擎按当前空闲显存动态计算；多节点下每次可能不同，不可缓存为常量'),
    ));
    rows.add(_kv(
      l10n.t('AIH.Server.Queued', '服务端排队请求数'),
      s?.queuedRequests?.toString() ?? '-',
      scheme,
      hint: (s?.queuedRequests ?? 0) > 0
          ? l10n.t('AIH.Server.QueuedWarn', '> 0 说明已经在排队 → 该降并发，别再加压')
          : null,
    ));
    rows.add(_kv(
      l10n.t('AIH.Server.ClientCap', '客户端限流上限（Semaphore）'),
      // ⚠ 并排两个数字的含义必须写清楚：左边是我方保守上限，
      //   括号里是服务端当前可用（两者不是一回事，别让人误当成同一个值）
      '${conc.clientHardCap}'
      '${l10n.t('AIH.Server.ClientCapServerSide', '（服务端当前可用=')}'
      '${conc.lastCapacity?.availableBsz ?? '-'}）',
      scheme,
      hint: l10n.t('AIH.Server.ClientCapHint',
          '这是我们的保守上限，不是引擎能力。真实排队由服务端 FIFO 队列决定'),
    ));
    if (s != null) {
      rows.add(_kv(
        l10n.t('AIH.Server.Vram', '显存'),
        '${s.freeVramGb?.toStringAsFixed(1) ?? '-'} / '
            '${s.totalVramGb?.toStringAsFixed(1) ?? '-'} GB',
        scheme,
      ));
      rows.add(_kv(
        l10n.t('AIH.Server.Speed', '引擎实时速度'),
        'decode ${s.lastDecodeSpeed?.toStringAsFixed(1) ?? '-'} tok/s · '
            'prefill ${s.lastPrefillSpeed?.toStringAsFixed(0) ?? '-'} tok/s',
        scheme,
      ));
      final List<String> caps = s.capabilities.entries
          .where((MapEntry<String, bool> e) => e.value)
          .map((MapEntry<String, bool> e) => e.key)
          .toList()
        ..sort();
      rows.add(_kv(
        l10n.t('AIH.Server.Caps', '引擎能力'),
        caps.isEmpty ? '-' : caps.join(', '),
        scheme,
      ));
    }
    if (_serverError != null) {
      rows.add(Padding(
        padding: const EdgeInsets.only(top: 4),
        child: SelectableText(_serverError!,
            style: TextStyle(fontSize: 11, color: scheme.error)),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  /// 客户端吞吐：QPS 折线 + 成功率 + p50/p95/p99/max（长尾）。
  Widget _throughputBlock(L10n l10n, ColorScheme scheme,
      AiStatsSnapshot snap, List<int> series) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          height: 64,
          child: CustomPaint(
            painter: _SparklinePainter(
              values: series,
              lineColor: scheme.secondary,
              fillColor: scheme.secondary.withValues(alpha: 0.18),
              gridColor: scheme.outlineVariant,
            ),
            child: const SizedBox.expand(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            l10n.t('AIH.Throughput.SeriesHint', '最近 60s 每秒请求数（1s 采样）'),
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 10),
        _kv(l10n.t('AIH.Throughput.Qps', '滚动 QPS'),
            snap.qps.toStringAsFixed(2), scheme),
        _kv(l10n.t('AIH.Throughput.Items', '条目吞吐'),
            '${snap.itemsPerSecond.toStringAsFixed(2)} /s', scheme),
        _kv(
          l10n.t('AIH.Throughput.Success', '成功 / 失败'),
          '${snap.successCalls} / ${snap.failedCalls}  '
              '（${(snap.successRate * 100).toStringAsFixed(1)}%）',
          scheme,
        ),
        _kv(
          l10n.t('AIH.Throughput.Latency', '延迟 p50 / p95 / p99 / max'),
          '${snap.latency.p50.toStringAsFixed(0)} / '
              '${snap.latency.p95.toStringAsFixed(0)} / '
              '${snap.latency.p99.toStringAsFixed(0)} / '
              '${snap.latency.max.toStringAsFixed(0)} ms',
          scheme,
          // ⚠ 长尾比才是批量工作流的命门：p50 漂亮但 p95 是它的 10 倍，
          //   说明整条流水线一直在等最慢那一次（PITFALLS §34.1 的边界知识）
          hint: snap.latency.hasData
              ? '${l10n.t('AIH.Throughput.Tail', '长尾比 p95/p50 = ')}'
                  '${snap.latency.tailRatio.toStringAsFixed(1)}'
                  '${snap.latency.tailRatio > 3 ? l10n.t('AIH.Throughput.TailWarn', '　→ 长尾严重，批量工作流会被最慢的一次拖住') : ''}'
              : null,
        ),
      ],
    );
  }

  Widget _batchBlock(L10n l10n, ColorScheme scheme, AiStatsSnapshot snap) {
    final List<MapEntry<String, int>> kinds = snap.failuresByKind.entries.toList()
      ..sort((MapEntry<String, int> a, MapEntry<String, int> b) =>
          b.value.compareTo(a.value));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _kv(l10n.t('AIH.Batch.Logical', '逻辑调用 / 实际 POST'),
            '${snap.logicalCalls} / ${snap.httpPosts}', scheme),
        _kv(
          l10n.t('AIH.Batch.ItemsPerPost', '每次 POST 处理条目'),
          snap.itemsPerPost.toStringAsFixed(2),
          scheme,
          hint: snap.itemsPerPost >= 2
              ? '${l10n.t('AIH.Batch.Saving', '攒批生效：省下 ')}'
                  '${snap.httpPostsSaved}'
                  '${l10n.t('AIH.Batch.SavingUnit', ' 次 HTTP 往返')}'
              : l10n.t('AIH.Batch.NoSaving',
                  '≈1 表示没有攒批（一条一发）；若期望攒批，检查任务是否设了 useBatch: true'),
        ),
        _kv(
          l10n.t('AIH.Batch.TotalItems', '累计条目'),
          snap.totalItems.toString(),
          scheme,
        ),
        if (kinds.isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          Text(l10n.t('AIH.Batch.Failures', '失败分类（决定处置方式）'),
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ...kinds.map((MapEntry<String, int> e) => Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('· ${_kindLabel(l10n, e.key)}  ×${e.value}',
                    style: const TextStyle(fontSize: 12)),
              )),
        ],
      ],
    );
  }

  Widget _stateBlock(L10n l10n, ColorScheme scheme, AiStatsSnapshot snap) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(l10n.t('AIH.State.Client', '客户端（本进程 state 缓存）'),
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        _kv(
          l10n.t('AIH.State.ClientHit', '命中 / 未命中'),
          '${snap.stateCacheHits} / ${snap.stateCacheMisses}  '
              '（${(snap.stateCacheHitRate * 100).toStringAsFixed(1)}%）',
          scheme,
          hint: snap.stateCacheMisses > 0 && snap.stateCacheHitRate < 0.5
              ? l10n.t('AIH.State.ClientHitWarn',
                  '命中率低 → 每轮都在重编码历史，检查会话是否被误关/被 TTL 清掉')
              : null,
        ),
        _kv(l10n.t('AIH.State.ClientBytes', '占用'),
            '${(snap.stateCacheBytes / 1048576).toStringAsFixed(2)} MB', scheme),
        const SizedBox(height: 8),
        Text(l10n.t('AIH.State.Server', '服务端（引擎三级缓存）'),
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            l10n.t('AIH.State.ServerNote',
                '服务端 L1 VRAM / L2 RAM / SQLite 是另一个进程的事，'
                '且多节点部署下 /state/status 可能问到别的节点（会显示全 0），'
                '所以两侧命中率不能混成一个数。'),
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  /// 智能体 State 分组快照：按「1 组长 + 9 写手」团队分组展示，
  /// 供开发人员判断团队 state 是否正常（组数 / 状态计数 / 每组轮次）。
  Widget _agentStateBlock(L10n l10n, ColorScheme scheme) {
    final Map<String, Object?> snap =
        ref.watch(agentStateManagerProvider).snapshot();
    final int activeGroups = (snap['activeGroups'] as num?)?.toInt() ?? 0;
    final int totalGroups = (snap['totalGroups'] as num?)?.toInt() ?? 0;
    final int activeStates = (snap['activeStates'] as num?)?.toInt() ?? 0;
    final int totalTurns = (snap['totalTurns'] as num?)?.toInt() ?? 0;
    final Map<Object?, Object?> statusCounts =
        (snap['statusCounts'] as Map?)?.cast<Object?, Object?>() ??
            const <Object?, Object?>{};
    final String statusText = statusCounts.entries
        .map((MapEntry<Object?, Object?> e) =>
            '${e.key}=${e.value}')
        .join(' · ');

    final List<Widget> rows = <Widget>[
      _kv(l10n.t('AIH.AgentState.Groups', '活跃分组 / 累计分组'),
          '$activeGroups / $totalGroups', scheme),
      _kv(l10n.t('AIH.AgentState.States', '活跃 state / 每组编制'),
          l10n.tf(
            'AIH.AgentState.StatesValueFmt',
            '{0} / 10（1 组长 + 9 写手）',
            <Object>[activeStates],
          ), scheme),
      _kv(l10n.t('AIH.AgentState.StatusCounts', '状态分布'), statusText, scheme),
      _kv(l10n.t('AIH.AgentState.Turns', '累计对话轮次'), '$totalTurns', scheme),
    ];

    final Object? groupsRaw = snap['groups'];
    if (groupsRaw is List && groupsRaw.isNotEmpty) {
      rows.add(const SizedBox(height: 6));
      rows.add(Text(
          l10n.t('AIH.AgentState.GroupList', '分组明细（并发 10 = 1 团队并行写 1 章）'),
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)));
      for (final Object? gRaw in groupsRaw) {
        if (gRaw is! Map) continue;
        final String gid = '${gRaw['groupId'] ?? '-'}';
        final String label = '${gRaw['label'] ?? ''}';
        final bool active = gRaw['active'] == true;
        final int activeMembers = (gRaw['activeMembers'] as num?)?.toInt() ?? 0;
        final int turns = (gRaw['totalTurns'] as num?)?.toInt() ?? 0;
        rows.add(Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            '· ${label.isEmpty ? gid : label}  ${active ? "🟢" : "⚪"} '
            '${l10n.tf('AIH.AgentState.GroupRowFmt', '活跃成员 {0}/10 · 轮次 {1}',
                <Object>[activeMembers, turns])}',
            style: const TextStyle(fontSize: 12),
          ),
        ));
      }
    } else {
      rows.add(Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          l10n.t('AIH.AgentState.Empty',
              '当前没有已激活的团队分组（启动「多智能体协同写书」后此处会出现分组）'),
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  String _kindLabel(L10n l10n, String kind) => switch (kind) {
        'bszOverflow' => l10n.t('AIH.Kind.Bsz', '并发超限（应拆批重试）'),
        'authFailed' => l10n.t('AIH.Kind.Auth', 'Cloudflare 认证失败（应检查 Token）'),
        'serverError' => l10n.t('AIH.Kind.Server', '服务端 5xx（应退避重试）'),
        'runtimeErrorEvent' => l10n.t('AIH.Kind.Runtime',
            'HTTP 200 但 body 报错（SSE 运行时异常）'),
        'truncated' => l10n.t('AIH.Kind.Trunc', '响应被截断（应子集重试）'),
        'statefulError' => l10n.t('AIH.Kind.Stateful', '会话续跑失败'),
        'unexpected' => l10n.t('AIH.Kind.Unknown', '未预期错误'),
        _ => kind,
      };

  Widget _kv(String k, String v, ColorScheme scheme, {String? hint}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 220,
                child: Text(k,
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
              ),
              Expanded(
                child: SelectableText(v, style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(left: 220, top: 2),
              child: Text(hint,
                  style: TextStyle(fontSize: 11, color: scheme.tertiary)),
            ),
        ],
      ),
    );
  }
}

/// 60 点迷你折线（手写，不引 charts 包 —— 引了会明显增大 Web 产物）。
class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.values,
    required this.lineColor,
    required this.fillColor,
    required this.gridColor,
  });

  final List<int> values;
  final Color lineColor;
  final Color fillColor;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty || size.width <= 0 || size.height <= 0) return;

    // 基线 + 顶线
    final Paint grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height - 1),
        Offset(size.width, size.height - 1), grid);
    canvas.drawLine(Offset(0, 0), Offset(size.width, 0), grid);

    final int maxV = values.fold<int>(0, (int a, int b) => math.max(a, b));
    // 全 0 时画一条贴底的线，而不是除以 0
    final double scale = maxV <= 0 ? 0 : size.height / maxV;
    final double dx =
        values.length <= 1 ? size.width : size.width / (values.length - 1);

    final Path line = Path();
    final Path fill = Path()..moveTo(0, size.height);
    for (int i = 0; i < values.length; i++) {
      final double x = dx * i;
      final double y = size.height - values[i] * scale;
      if (i == 0) {
        line.moveTo(x, y);
      } else {
        line.lineTo(x, y);
      }
      fill.lineTo(x, y);
    }
    fill
      ..lineTo(size.width, size.height)
      ..close();

    canvas.drawPath(fill, Paint()..color = fillColor);
    canvas.drawPath(
      line,
      Paint()
        ..color = lineColor
        ..strokeWidth = 1.6
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.values != values ||
      old.lineColor != lineColor ||
      old.fillColor != fillColor;
}
