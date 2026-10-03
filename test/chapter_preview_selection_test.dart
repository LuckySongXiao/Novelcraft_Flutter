// 粘性选区 + 选节 AI 助手选区预览契约测试。
//
// 背景：SelectionArea 在指针按下其子树之外（AI 开关按钮、面板输入框）时会
// 清空选区并回调 null，旧实现直接回写状态导致「先选中文本再点 AI 助手」
// 选区丢失、写作功能受阻。本文件验证粘性规则与面板可见性契约。
//
// 运行：flutter test test/chapter_preview_selection_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novelcraft/ui/pages/chapter_ai_panel.dart';
import 'package:novelcraft/ui/state/sticky_selection.dart';

Widget _wrap(Widget child) => ProviderScope(
      child: MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  group('StickySelection（粘性选区纯逻辑）', () {
    test('初始为空', () {
      final s = StickySelection();
      expect(s.text, '');
      expect(s.hasSelection, isFalse);
      expect(s.charCount, 0);
    });

    test('null / 空串 / 纯空白不清空旧值（修复根因）', () {
      final s = StickySelection()..update('夜色渐深，城市灯火。');
      // 用户点击面板按钮 → SelectionArea 回调 null → 旧选区必须保留
      s.update(null);
      expect(s.text, '夜色渐深，城市灯火。');
      // 拖动选区过程中闪过空串同样不清空
      s.update('');
      s.update('   \n  ');
      expect(s.hasSelection, isTrue);
    });

    test('非空新选区覆盖旧值', () {
      final s = StickySelection()
        ..update('第一段选区')
        ..update('第二段更长的选区文本');
      expect(s.text, '第二段更长的选区文本');
    });

    test('clear 显式清除', () {
      final s = StickySelection()
        ..update('片段')
        ..clear();
      expect(s.hasSelection, isFalse);
      // 清除后 null/空串仍不清空（保持空）
      s.update(null);
      expect(s.text, '');
    });

    test('charCount 按 trim 后计数', () {
      final s = StickySelection()..update('  三字选区  ');
      expect(s.charCount, 4);
    });
  });

  group('ChapterAiPanel 选区预览契约', () {
    testWidgets('有选区时显示捕获预览、字数与「重新选择」按钮', (tester) async {
      var cleared = false;
      await tester.pumpWidget(_wrap(
        ChapterAiPanel(
          selectedText: '夜色渐深，城市灯火。',
          fullContent: '夜色渐深，城市灯火。',
          onClearSelection: () => cleared = true,
        ),
      ));

      expect(find.textContaining('已捕获选区'), findsOneWidget);
      expect(find.textContaining('10 字'), findsOneWidget,
          reason: '必须展示选区字数让用户确认捕获成功');
      expect(find.text('夜色渐深，城市灯火。'), findsWidgets,
          reason: '选区预览必须回显捕获的文本');

      await tester.tap(find.text('重新选择'));
      expect(cleared, isTrue, reason: '重新选择按钮必须触发清除回调');
    });

    testWidgets('无选区时显示引导文案且不显示清除按钮', (tester) async {
      await tester.pumpWidget(_wrap(
        const ChapterAiPanel(selectedText: '', fullContent: '正文'),
      ));

      expect(find.textContaining('尚未捕获选区'), findsOneWidget);
      expect(find.textContaining('拖动鼠标选中'), findsOneWidget,
          reason: '空选区必须前置引导用户去正文框选');
      expect(find.text('重新选择'), findsNothing);
    });

    testWidgets('未传清除回调时不渲染重新选择入口', (tester) async {
      await tester.pumpWidget(_wrap(
        const ChapterAiPanel(selectedText: '片段', fullContent: '正文'),
      ));
      expect(find.text('重新选择'), findsNothing);
    });
  });
}
