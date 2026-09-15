import 'rwkv_official_resources.dart';

RwkvOfficialResourcesBridge createRwkvOfficialResourcesBridge() =>
    const _WebRwkvOfficialResourcesBridge();

final class _WebRwkvOfficialResourcesBridge
    implements RwkvOfficialResourcesBridge {
  const _WebRwkvOfficialResourcesBridge();

  Never _unsupported() => throw UnsupportedError(
      'Web 平台不支持下载/安装本地 RWKV 资源，请使用桌面 (Windows/macOS/Linux) 版本。');

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

  // ---------- 内置推理引擎：rwkv_lightning_cuda（Web 端不支持）----------

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
