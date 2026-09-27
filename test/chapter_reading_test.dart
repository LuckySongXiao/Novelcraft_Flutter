// 章节阅读页增强功能测试：选节 AI 面板 + 智能排版。
//
// 运行：flutter test test/chapter_reading_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novelcraft/ui/pages/chapter_ai_panel.dart';
import 'package:novelcraft/ui/pages/chapter_preview_page.dart';

Widget _wrap(Widget child) => ProviderScope(
      child: MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChapterAiPanel（选节 AI 助手）', () {
    testWidgets('未选节时点击操作显示提示', (tester) async {
      await tester.pumpWidget(_wrap(
        const ChapterAiPanel(selectedText: '', fullContent: '正文内容'),
      ));

      // 三个操作按钮都在
      expect(find.text('润色'), findsOneWidget);
      expect(find.text('扩写'), findsOneWidget);
      expect(find.text('续写'), findsOneWidget);

      // 未选节点击 → 提示
      await tester.tap(find.text('润色'));
      await tester.pump();
      expect(
        find.textContaining('请先在正文中选中'),
        findsOneWidget,
        reason: '无选区时必须引导用户先选节',
      );
    });

    testWidgets('有选区时输入要求并点击（无 AI 服务时给出明确指引）', (tester) async {
      await tester.pumpWidget(_wrap(
        const ChapterAiPanel(
            selectedText: '夜色渐深，城市灯火。', fullContent: '夜色渐深，城市灯火。'),
      ));

      // 无默认 provider 的测试环境 → 明确指引而非崩溃
      await tester.enterText(
        find.byType(TextField),
        '加入雨景',
      );
      await tester.tap(find.text('润色'));
      await tester.pump();
      expect(
        find.textContaining('AI 服务'),
        findsWidgets,
        reason: '无可用服务时必须给出可操作的指引文案',
      );
    });

    testWidgets('附加要求输入框存在且可输入', (tester) async {
      await tester.pumpWidget(_wrap(
        const ChapterAiPanel(selectedText: '片段', fullContent: '整章'),
      ));
      await tester.enterText(find.byType(TextField), '更凝练');
      expect(find.text('更凝练'), findsOneWidget);
    });
  });

  group('章节阅读页智能排版', () {
    testWidgets('空正文显示占位提示', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_wrap(
        const ChapterPreviewPage(values: {
          'title': '第一章',
          'content': '',
        }),
      ));
      await tester.pump();

      expect(find.text('正文为空'), findsOneWidget);
      // 空正文时 AI 开关禁用（Tooltip 命中的是 Tooltip 本体，取其祖先 IconButton）
      final tooltip = find.byTooltip('AI 选节助手');
      expect(tooltip, findsOneWidget);
      final IconButton btn = tester.widget<IconButton>(
        find
            .ancestor(of: tooltip, matching: find.byType(IconButton))
            .first,
      );
      expect(btn.onPressed, isNull, reason: '空正文时 AI 助手开关应禁用');
    });

    testWidgets('智能排版：宽视口正文列被约束为 960，窄视口全宽', (tester) async {
      // 宽屏 1600：正文列 maxWidth 应为 960
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_wrap(
        const ChapterPreviewPage(values: {
          'title': '第一章',
          'content': '夜色渐深。\n城市灯火次第亮起。',
        }),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull, reason: '宽屏渲染不应有异常');

      // 找正文所在 ConstrainedBox（maxWidth=960）
      final boxes = tester.widgetList<ConstrainedBox>(
        find.byWidgetPredicate(
            (w) => w is ConstrainedBox && w.constraints.maxWidth == 960),
      );
      expect(boxes, isNotEmpty, reason: '≥1600 视口下正文列应为 960');

      // 切到手机竖屏 420：全宽（无 960 约束）
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      await tester.pump();
      expect(
        find.text('夜色渐深。'),
        findsOneWidget,
        reason: '窄屏下正文正常渲染',
      );
      expect(
        tester.widgetList<ConstrainedBox>(
          find.byWidgetPredicate(
              (w) => w is ConstrainedBox && w.constraints.maxWidth == 960),
        ),
        isEmpty,
        reason: '窄屏下不应出现 960 约束（全宽排版）',
      );
    });

    testWidgets('字号调节按钮生效（13-24 范围钳制）', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_wrap(
        const ChapterPreviewPage(values: {
          'title': '第一章',
          'content': '夜色渐深。',
        }),
      ));
      await tester.pump();

      for (var i = 0; i < 8; i++) {
        await tester.tap(find.byTooltip('缩小字号'));
        await tester.pump();
      }
      // 连续点 8 次（17-8=9 → 钳到 13）
      final prose = tester.widgetList<SelectableText>(
        find.byType(SelectableText),
      );
      expect(
        prose.any((t) => (t.style?.fontSize ?? 0) == 13),
        isTrue,
        reason: '字号下限钳制为 13',
      );
    });
  });
}
