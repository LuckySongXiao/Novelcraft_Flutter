// 伏笔经纬双轴视图 —— 把伏笔的「设定 → 提醒 → 收回」摊在章节轴上。
//
// 参考 WeaveGrid 的「经纬」页：**上方是伏笔设定轴、下方是伏笔收回轴**，
// 每章一个等距刻度，连线从设定章向下连到收回章，小圆点表示途中提醒，
// 紫色刻度表示转折章；两轴旁的数量柱显示该章设定 / 收回密度。
//
// 本实现按本工程的既有视觉（Material 3 ColorScheme）重画，只依赖账本的派生数据，
// 不做任何写操作（要改结构请去改各章细纲里的「伏笔提示」）。
library;

import 'package:flutter/material.dart';

import '../../ai/utils/foreshadow_ledger.dart';

/// 每章刻度的宽度（逻辑像素）。
const double kGridChapterWidth = 26;

/// 绘图区高度（上密度柱 + 设定轴 + 连线带 + 收回轴 + 下密度柱 + 章号）。
const double kGridHeight = 250;

const double _topBarHeight = 46;
const double _setupAxisY = _topBarHeight;
const double _payoffAxisY = 168;
const double _labelTop = _payoffAxisY + 46;

/// 经纬双轴视图（自带横向滚动）。
class ForeshadowGridView extends StatelessWidget {
  const ForeshadowGridView({
    super.key,
    required this.ledger,
    this.currentOrder,
    this.onTapOrder,
    this.compact = false,
  });

  final ForeshadowLedger ledger;

  /// 当前写作位置（高亮该列）。
  final int? currentOrder;

  /// 点击某章的回调（例如跳到该章）。
  final void Function(int order)? onTapOrder;

  /// 紧凑模式（嵌在卡片里时用，去掉说明文字）。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (ledger.chapterCount <= 0) {
      return const SizedBox.shrink();
    }
    final double width = ledger.chapterCount * kGridChapterWidth;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (!compact) ...<Widget>[
          _legend(context, scheme),
          const SizedBox(height: 8),
        ],
        Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              height: kGridHeight,
              child: GestureDetector(
                onTapUp: onTapOrder == null
                    ? null
                    : (TapUpDetails d) {
                        final int order =
                            (d.localPosition.dx / kGridChapterWidth).floor() + 1;
                        if (order >= 1 && order <= ledger.chapterCount) {
                          onTapOrder!(order);
                        }
                      },
                child: CustomPaint(
                  painter: _ForeshadowGridPainter(
                    ledger: ledger,
                    currentOrder: currentOrder,
                    scheme: scheme,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        _summary(context, scheme),
      ],
    );
  }

  Widget _legend(BuildContext context, ColorScheme scheme) {
    Widget item(Color color, String label, {bool line = false}) => Padding(
          padding: const EdgeInsets.only(right: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: line ? 16 : 9,
                height: line ? 2 : 9,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(line ? 1 : 5),
                ),
              ),
              const SizedBox(width: 5),
              Text(label, style: const TextStyle(fontSize: 11)),
            ],
          ),
        );
    return Wrap(
      spacing: 0,
      runSpacing: 4,
      children: <Widget>[
        item(scheme.primary, '伏笔设定（上轴）'),
        item(scheme.tertiary, '伏笔收回（下轴）'),
        item(scheme.secondary, '途中提醒', line: true),
        item(scheme.error, '转折章（单元末章）'),
      ],
    );
  }

  Widget _summary(BuildContext context, ColorScheme scheme) {
    final ForeshadowDensity d = ledger.density;
    final List<String> parts = <String>[
      '${d.entryCount} 条伏笔',
      '全书 ${d.chapterCount} 章',
      '未回收 ${d.openCount} 条',
      '提醒 ${d.reminderCount} 处',
      '转折章 ${ledger.turningOrders.join('、')}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          parts.join(' · '),
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
        if (ledger.errors.isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          for (final ForeshadowIssue i in ledger.errors.take(6))
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                '⚠ ${i.message}',
                style: TextStyle(fontSize: 11, color: scheme.error),
              ),
            ),
        ],
      ],
    );
  }
}

class _ForeshadowGridPainter extends CustomPainter {
  _ForeshadowGridPainter({
    required this.ledger,
    required this.scheme,
    this.currentOrder,
  });

  final ForeshadowLedger ledger;
  final ColorScheme scheme;
  final int? currentOrder;

  @override
  void paint(Canvas canvas, Size size) {
    final List<ForeshadowTick> ticks = ledger.ticks;
    final int maxSetup = ticks.fold<int>(0,
        (int a, ForeshadowTick t) => t.setupCount > a ? t.setupCount : a);
    final int maxPayoff = ticks.fold<int>(0,
        (int a, ForeshadowTick t) => t.payoffCount > a ? t.payoffCount : a);
    final int maxBar = maxSetup > maxPayoff ? maxSetup : maxPayoff;
    final double barUnit = maxBar <= 0 ? 0 : (_topBarHeight - 12) / maxBar;

    final Paint axis = Paint()
      ..color = scheme.outlineVariant
      ..strokeWidth = 1;
    final Paint setupBar = Paint()..color = scheme.primary.withValues(alpha: 0.75);
    final Paint payoffBar =
        Paint()..color = scheme.tertiary.withValues(alpha: 0.75);
    final Paint link = Paint()
      ..color = scheme.primary.withValues(alpha: 0.28)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final Paint linkStrong = Paint()
      ..color = scheme.primary.withValues(alpha: 0.55)
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;

    // ---- 转折章底色带 ----
    final Paint turnBand = Paint()..color = scheme.error.withValues(alpha: 0.10);
    for (final int order in ledger.turningOrders) {
      if (order < 1 || order > ledger.chapterCount) continue;
      canvas.drawRect(
        Rect.fromLTWH(
          (order - 1) * kGridChapterWidth,
          _setupAxisY,
          kGridChapterWidth,
          _payoffAxisY - _setupAxisY,
        ),
        turnBand,
      );
    }

    // ---- 当前写作位置高亮 ----
    final int? cur = currentOrder;
    if (cur != null && cur >= 1 && cur <= ledger.chapterCount) {
      canvas.drawRect(
        Rect.fromLTWH(
          (cur - 1) * kGridChapterWidth,
          0,
          kGridChapterWidth,
          _labelTop,
        ),
        Paint()..color = scheme.primary.withValues(alpha: 0.12),
      );
    }

    // ---- 两条轴 ----
    canvas.drawLine(
        Offset(0, _setupAxisY), Offset(size.width, _setupAxisY), axis);
    canvas.drawLine(
        Offset(0, _payoffAxisY), Offset(size.width, _payoffAxisY), axis);

    // ---- 每条伏笔的连线（设定章 → 回收章）+ 提醒点 ----
    for (final ForeshadowEntry e in ledger.entries) {
      if (e.setupOrder < 1 || e.setupOrder > ledger.chapterCount) continue;
      if (e.payoffOrder < 1 || e.payoffOrder > ledger.chapterCount) continue;
      final double x1 = (e.setupOrder - 1) * kGridChapterWidth +
          kGridChapterWidth / 2;
      final double x2 = (e.payoffOrder - 1) * kGridChapterWidth +
          kGridChapterWidth / 2;
      // 用二次贝塞尔把两端连成一条弧，弧高随跨度增长（跨度越大越显眼）。
      final double span = (e.payoffOrder - e.setupOrder).toDouble();
      final double bulge = (span * 1.6).clamp(6, 40);
      final Path p = Path()
        ..moveTo(x1, _setupAxisY)
        ..quadraticBezierTo(
            (x1 + x2) / 2, _setupAxisY + (_payoffAxisY - _setupAxisY) * 0.5 - bulge,
            x2,
            _payoffAxisY);
      canvas.drawPath(p, span >= 16 ? linkStrong : link);

      // 途中提醒：小圆点
      for (final int r in e.reminderOrders) {
        if (r < 1 || r > ledger.chapterCount) continue;
        final double xr =
            (r - 1) * kGridChapterWidth + kGridChapterWidth / 2;
        canvas.drawCircle(
          Offset(xr, (_setupAxisY + _payoffAxisY) / 2),
          2.6,
          Paint()..color = scheme.secondary,
        );
      }
    }

    // ---- 密度柱 + 章号 ----
    final TextPainter? labelPainter = null;
    for (final ForeshadowTick t in ticks) {
      final double left = (t.order - 1) * kGridChapterWidth;
      final double cx = left + kGridChapterWidth / 2;
      if (t.setupCount > 0 && barUnit > 0) {
        final double h = t.setupCount * barUnit;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(left + 4, _setupAxisY - h, kGridChapterWidth - 8, h),
            const Radius.circular(2),
          ),
          setupBar,
        );
      }
      if (t.payoffCount > 0 && barUnit > 0) {
        final double h = t.payoffCount * barUnit;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(left + 4, _payoffAxisY, kGridChapterWidth - 8, h),
            const Radius.circular(2),
          ),
          payoffBar,
        );
      }
      // 每 5 章（或末章）标一个章号，避免刻度过密看不清。
      final bool showLabel = t.order == 1 ||
          t.order == ledger.chapterCount ||
          t.order % 5 == 0;
      if (showLabel) {
        final TextPainter tp = TextPainter(
          text: TextSpan(
            text: '${t.order}',
            style: TextStyle(
              fontSize: 9,
              color: t.order == cur ? scheme.primary : scheme.onSurfaceVariant,
              fontWeight:
                  t.order == cur ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(cx - tp.width / 2, _labelTop));
        labelPainter?.dispose();
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ForeshadowGridPainter old) =>
      old.ledger != ledger ||
      old.currentOrder != currentOrder ||
      old.scheme != scheme;
}
