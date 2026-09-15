import 'rwkv_official_resources.dart';

RwkvOfficialResourcesBridge createRwkvOfficialResourcesBridge() =>
    const _StubRwkvOfficialResourcesBridge();

final class _StubRwkvOfficialResourcesBridge
    implements RwkvOfficialResourcesBridge {
  const _StubRwkvOfficialResourcesBridge();

  Never _unsupported() => throw UnsupportedError(
      '当前平台不支持下载/安装官方 RWKV 资源，仅支持桌面 (Windows/macOS/Linux) 原生平台。');

  @override
  Future<RwkvServerBuildInfo> fetchLatestServerBuild({
    OfficialServerVariant variant = OfficialServerVariant.vulkan,
    String? repo,
    void Function(RwkvDownloadProgress)? onProgress,
  }) =>
      Future<RwkvServerBuildInfo>.error(_unsupported());

  @override
  Future<String> installLlamaServer({
    RwkvServerBuildInfo? buildInfo,
    OfficialServerVariant variant = OfficialServerVariant.vulkan,
    String? installDir,
    void Function(RwkvDownloadProgress)? onProgress,
    void Function(RwkvCancelHandle handle)? onHandleReady,
  }) =>
      Future<String>.error(_unsupported());

  @override
  Future<List<RwkvOfficialModel>> listOfficialRwkvModels({
    void Function(RwkvDownloadProgress)? onProgress,
  }) =>
      Future<List<RwkvOfficialModel>>.error(_unsupported());

  @override
  Future<String> downloadOfficialModel(
    RwkvOfficialModel model, {
    String? targetDir,
    void Function(RwkvDownloadProgress)? onProgress,
    void Function(RwkvCancelHandle handle)? onHandleReady,
  }) =>
      Future<String>.error(_unsupported());

  // ---------- 内置推理引擎：rwkv_lightning_cuda（仅桌面原生可用）----------

  @override
  Future<RwkvLightningRelease> fetchLatestLightningRelease({
    OfficialServerVariant variant = OfficialServerVariant.cuda13,
    String? repo,
    void Function(RwkvDownloadProgress)? onProgress,
  }) =>
      Future<RwkvLightningRelease>.error(_unsupported());

  @override
  Future<String> installLightningServer({
    RwkvLightningRelease? release,
    OfficialServerVariant variant = OfficialServerVariant.cuda13,
    String? installDir,
    void Function(RwkvDownloadProgress)? onProgress,
    void Function(RwkvCancelHandle handle)? onHandleReady,
  }) =>
      Future<String>.error(_unsupported());

  @override
  Future<String> ensureLightningVocab({
    String? targetDir,
    void Function(RwkvDownloadProgress)? onProgress,
    void Function(RwkvCancelHandle handle)? onHandleReady,
  }) =>
      Future<String>.error(_unsupported());

  @override
  Future<List<RwkvOfficialModel>> listLightningPthModels({
    void Function(RwkvDownloadProgress)? onProgress,
  }) =>
      Future<List<RwkvOfficialModel>>.error(_unsupported());
}
