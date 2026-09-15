// 本地 RWKV 模型发现与元数据解析。
//
// 扫描项目根下 `rwkv_models/` 目录内的 `.gguf` 文件（GGUF 是 RWKV 7B 模型
// 的主流分发格式，llama.cpp / rwkv.cpp 都原生支持），解析文件名获取：
//   - 模型架构（rwkv5 / rwkv6 / rwkv7）
//   - 参数量（1.5B / 3B / 7.2B / 14B）
//   - 量化等级（Q4_0 / Q5_K_M / Q6_K 等）
//
// 本文件**不直接** `import 'dart:io'`，扫描通过条件导出的
// [RwkvModelScanner] 桥接实现（同 inference_launcher 的模式）：
//   - Native 平台：真·Directory.list 扫 `rwkv_models/`
//   - Web / stub：返回空列表或仅占位模型
library;

import '../models/provider.dart';

export 'rwkv_model_scanner_stub.dart'
    if (dart.library.io) 'rwkv_model_scanner_native.dart'
    if (dart.library.js_interop) 'rwkv_model_scanner_web.dart';

/// 本地 RWKV 模型元数据。
class RwkvLocalModel {
  /// 模型文件绝对路径。
  final String filePath;

  /// 文件名（含扩展名）。
  final String fileName;

  /// 推断出的架构版本（rwkv5 / rwkv6 / rwkv7，解析不到记为 unknown）。
  final String architecture;

  /// 推断出的参数量（字符串形式，如 7.2B）。
  final String parameterSize;

  /// 推断出的量化等级（如 Q6_K）。
  final String quantization;

  /// 文件字节数。
  final int sizeBytes;

  RwkvLocalModel({
    required this.filePath,
    required this.fileName,
    required this.architecture,
    required this.parameterSize,
    required this.quantization,
    required this.sizeBytes,
  });

  /// 展示名：`RWKV-7 G1J 7.2B Q6_K`。
  String get displayName {
    final arch = architecture.isEmpty ? 'RWKV' : 'RWKV-${architecture.replaceFirst('rwkv', '').toUpperCase()}';
    final sz = parameterSize.isEmpty ? '' : ' $parameterSize';
    final q = quantization.isEmpty ? '' : ' $quantization';
    return '$arch$sz$q'.trim();
  }

  /// 转通用 [ModelInfo] 供 UI 展示。
  ModelInfo toModelInfo() => ModelInfo(
        id: fileName,
        name: displayName,
        description: '$architecture · ${parameterSize}B · $quantization',
        size: sizeBytes,
        isDownloaded: true,
        capabilities: const ['chat', 'completion', 'state'],
        parameters: <String, dynamic>{
          'filePath': filePath,
          'architecture': architecture,
          'parameterSize': parameterSize,
          'quantization': quantization,
        },
      );
}

/// 从文件名推断架构 / 参数量 / 量化。
///
/// 示例：`rwkv7-g1j-7.2b-Q6_K.gguf` → (rwkv7, 7.2B, Q6_K)
RwkvLocalModel parseRwkvFileName(String filePath, String fileName, int sizeBytes) {
  final lower = fileName.toLowerCase();
  String arch = 'unknown';
  for (final key in const ['rwkv7', 'rwkv6', 'rwkv5']) {
    if (lower.contains(key)) {
      arch = key;
      break;
    }
  }

  String size = '';
  final sizeMatch = RegExp(r'(\d+(?:\.\d+)?)\s*b').firstMatch(lower);
  if (sizeMatch != null) {
    final raw = sizeMatch.group(1)!;
    size = raw.contains('.') ? raw : raw;
    size = '${size}B';
  }

  String quant = '';
  final quantMatch = RegExp(r'(q[2345678]\w*(?:_[kms]\w*)?|fp16|bf16|f16)').firstMatch(lower);
  if (quantMatch != null) {
    quant = quantMatch.group(0)!.toUpperCase();
  }

  return RwkvLocalModel(
    filePath: filePath,
    fileName: fileName,
    architecture: arch,
    parameterSize: size,
    quantization: quant,
    sizeBytes: sizeBytes,
  );
}
