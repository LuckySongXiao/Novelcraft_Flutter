// GPU 显存探测（Web / 非 dart:io 平台的 stub）。
//
// 固定返回空列表 = 「探不到」，调用方据此关闭显存适配提示
// （绝不能当成"显存为 0"把所有模型标成放不下）。
import 'rwkv_gpu_probe.dart';

Future<List<RwkvGpuInfo>> rwkvProbeGpusImpl() async => const <RwkvGpuInfo>[];
