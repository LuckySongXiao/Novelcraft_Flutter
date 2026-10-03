// 粘性选区 —— 修复「章节预览 AI 助手激活后无法识别鼠标选中文本」。
//
// 根因：`SelectionArea` 在指针按下其子树之外（AppBar 的 AI 开关按钮、
// 面板输入框、面板操作按钮……）时会清空当前选区并回调 `onSelectionChanged(null)`。
// 若把回调直接回写状态（`_selectedText = sel?.plainText ?? ''`），
// 用户「先选中文本 → 再点 AI 助手 / 面板按钮」的经典操作序列里，
// 选区会在点击面板的瞬间被清成空串，润色/扩写/续写随即报「请先选中一段文字」。
//
// 方案：选区粘性化 —— 只有**非空**的新选区才覆盖旧值；null / 空串不清空。
// 真正的清除只有两个入口：
//   1. 用户开始框选新的内容（新选区非空 → 覆盖）；
//   2. 用户在面板里点「重新选择」按钮（显式 clear）。
// 纯 Dart 逻辑，无 Flutter 依赖，便于单测。
library;

/// 粘性选区持有器。
class StickySelection {
  String _text = '';

  /// 当前粘住的选区纯文本（未 trim，展示层自行处理）。
  String get text => _text;

  /// 是否持有非空选区。
  bool get hasSelection => _text.trim().isNotEmpty;

  /// 字数（trim 后；UI 展示用）。
  int get charCount => _text.trim().length;

  /// SelectionArea.onSelectionChanged 的粘性回写：
  /// 非空才更新，null / 空串不清空（见文件头注释的根因说明）。
  void update(String? plainText) {
    final String incoming = (plainText ?? '').trim();
    if (incoming.isEmpty) return; // 粘性：选区被外部清空时保留旧值
    _text = plainText!;
  }

  /// 显式清除（面板「重新选择」按钮）。
  void clear() {
    _text = '';
  }
}
