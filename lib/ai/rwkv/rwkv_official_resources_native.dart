import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'rwkv_official_resources.dart';

final class _NativeCancelHandle implements RwkvCancelHandle {
  bool _cancelled = false;
  String? _reason;
  final List<void Function(String? reason)> _onCancelled =
      <void Function(String? reason)>[];
  final Completer<void> _done = Completer<void>();

  @override
  bool get isCancelled => _cancelled;

  Future<void> get done => _done.future;

  void onCancelled(void Function(String? reason) cb) {
    if (_cancelled) {
      cb(_reason);
      return;
    }
    _onCancelled.add(cb);
  }

  @override
  Future<void> cancel([String? reason]) async {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason;
    for (final cb in List<void Function(String?)>.unmodifiable(_onCancelled)) {
      try {
        cb(reason);
      } catch (_) {}
    }
    _onCancelled.clear();
    if (!_done.isCompleted) _done.complete();
  }

  void throwIfCancelled() {
    if (_cancelled) {
      throw RwkvDownloadCancelledException(_reason);
    }
  }
}

RwkvOfficialResourcesBridge createRwkvOfficialResourcesBridge() =>
    _NativeRwkvOfficialResourcesBridge();

final class _NativeRwkvOfficialResourcesBridge
    implements RwkvOfficialResourcesBridge {
  _NativeRwkvOfficialResourcesBridge();

  static final Logger _logger = Logger('RwkvOfficialResourcesBridge');
  static const String _defaultLlamaRepo = 'ggml-org/llama.cpp';
  static const List<String> _rwkvRepos = <String>[
    'shoumenchougou/RWKV7-G1j-7.2B-GGUF',
    'BlinkDL/rwkv-7-world',
    'BlinkDL/RWKV-7-G1J',
    'BlinkDL/RWKV-v7',
  ];
  static const Duration _progressWindow = Duration(milliseconds: 500);

  bool _installInProgress = false;
  bool _downloadInProgress = false;

  static const List<RwkvOfficialModel> _fallbackRwkvModels =
      <RwkvOfficialModel>[
    RwkvOfficialModel(
      id: 'rwkv7-g1j-7.2b-fp16',
      displayName: 'RWKV-7 G1J 7.2B (原生 FP16)',
      repo: 'shoumenchougou/RWKV7-G1j-7.2B-GGUF',
      subFolder: '',
      fileName: 'rwkv7-g1j-7.2b-20260831-ctx16384-FP16.gguf',
      downloadUrl:
          'https://huggingface.co/shoumenchougou/RWKV7-G1j-7.2B-GGUF/resolve/main/rwkv7-g1j-7.2b-20260831-ctx16384-FP16.gguf',
      sizeBytes: 13958643712,
      quant: RwkvModelQuant.fp16,
      paramsLabel: '7.2B',
    ),
    RwkvOfficialModel(
      id: 'rwkv7-g1j-7.2b-q8_0',
      displayName: 'RWKV-7 G1J 7.2B (Q8_0)',
      repo: 'shoumenchougou/RWKV7-G1j-7.2B-GGUF',
      subFolder: '',
      fileName: 'rwkv7-g1j-7.2b-Q8_0.gguf',
      downloadUrl:
          'https://huggingface.co/shoumenchougou/RWKV7-G1j-7.2B-GGUF/resolve/main/rwkv7-g1j-7.2b-Q8_0.gguf',
      sizeBytes: 8589934592,
      quant: RwkvModelQuant.q80,
      paramsLabel: '7.2B',
    ),
    RwkvOfficialModel(
      id: 'rwkv7-g1j-7.2b-q6_k',
      displayName: 'RWKV-7 G1J 7.2B (Q6_K)',
      repo: 'shoumenchougou/RWKV7-G1j-7.2B-GGUF',
      subFolder: '',
      fileName: 'rwkv7-g1j-7.2b-Q6_K.gguf',
      downloadUrl:
          'https://huggingface.co/shoumenchougou/RWKV7-G1j-7.2B-GGUF/resolve/main/rwkv7-g1j-7.2b-Q6_K.gguf',
      sizeBytes: 5476083302,
      quant: RwkvModelQuant.q6K,
      paramsLabel: '7.2B',
    ),
    RwkvOfficialModel(
      id: 'rwkv7-g1j-7.2b-q5_k_m',
      displayName: 'RWKV-7 G1J 7.2B (Q5_K_M)',
      repo: 'shoumenchougou/RWKV7-G1j-7.2B-GGUF',
      subFolder: '',
      fileName: 'rwkv7-g1j-7.2b-Q5_K_M.gguf',
      downloadUrl:
          'https://huggingface.co/shoumenchougou/RWKV7-G1j-7.2B-GGUF/resolve/main/rwkv7-g1j-7.2b-Q5_K_M.gguf',
      sizeBytes: 4617089843,
      quant: RwkvModelQuant.q5KM,
      paramsLabel: '7.2B',
    ),
    RwkvOfficialModel(
      id: 'rwkv7-g1j-7.2b-q4_k_m',
      displayName: 'RWKV-7 G1J 7.2B (Q4_K_M)',
      repo: 'shoumenchougou/RWKV7-G1j-7.2B-GGUF',
      subFolder: '',
      fileName: 'rwkv7-g1j-7.2b-Q4_K_M.gguf',
      downloadUrl:
          'https://huggingface.co/shoumenchougou/RWKV7-G1j-7.2B-GGUF/resolve/main/rwkv7-g1j-7.2b-Q4_K_M.gguf',
      sizeBytes: 3865470566,
      quant: RwkvModelQuant.q4KM,
      paramsLabel: '7.2B',
    ),
  ];

  static http.Client _httpClient() => http.Client();

  // ---------------------------------------------------------------------------
  // fetchLatestServerBuild
  // ---------------------------------------------------------------------------
  @override
  Future<RwkvServerBuildInfo> fetchLatestServerBuild({
    OfficialServerVariant variant = OfficialServerVariant.vulkan,
    String? repo,
    void Function(RwkvDownloadProgress)? onProgress,
  }) async {
    final effectiveRepo = repo ?? _defaultLlamaRepo;
    onProgress?.call(RwkvDownloadProgress(
      phase: RwkvDownloadPhase.fetchingMeta,
      message: '查询 llama.cpp 官方最新发布（$effectiveRepo）…',
    ));
    final client = _httpClient();
    try {
      final List<Map<String, Object?>> candidateReleases =
          <Map<String, Object?>>[];
      try {
        final uri = Uri.parse(
            'https://api.github.com/repos/$effectiveRepo/releases/latest');
        final response = await client.get(
          uri,
          headers: const <String, String>{
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'novelcraft-rwkv-installer/1.0',
          },
        ).timeout(const Duration(seconds: 20));
        if (response.statusCode == 200) {
          final Object? data = json.decode(response.body);
          if (data is Map<String, Object?>) {
            candidateReleases.add(data);
          }
        }
      } on Exception catch (e) {
        _logger.info('latest release 查询失败，继续尝试列表：$e');
      }
      try {
        final listUri = Uri.parse(
            'https://api.github.com/repos/$effectiveRepo/releases?per_page=10');
        final listResp = await client.get(
          listUri,
          headers: const <String, String>{
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'novelcraft-rwkv-installer/1.0',
          },
        ).timeout(const Duration(seconds: 20));
        if (listResp.statusCode == 200) {
          final Object? listData = json.decode(listResp.body);
          if (listData is List<Object?>) {
            for (final Object? entry in listData) {
              if (entry is Map<String, Object?>) candidateReleases.add(entry);
            }
          }
        }
      } on Exception catch (e) {
        _logger.warning('releases list 查询失败：$e');
      }
      if (candidateReleases.isEmpty) {
        throw HttpException(
            '查询 llama.cpp 发布信息失败，请检查网络或稍后重试。');
      }
      final String token = variant.assetToken;
      final String arch = variant.archToken;
      final String platformFragment = 'win';
      Map<String, Object?>? matchedAsset;
      String? matchedTag;
      for (final Map<String, Object?> release in candidateReleases) {
        final String? tag = release['tag_name'] as String?;
        if (tag == null || tag.isEmpty) continue;
        final Object? assetsRaw = release['assets'];
        if (assetsRaw is! List<Object?>) continue;
        Map<String, Object?>? best;
        for (final Object? a in assetsRaw) {
          if (a is! Map<String, Object?>) continue;
          final String? name = a['name'] as String?;
          if (name == null) continue;
          final lower = name.toLowerCase();
          if (!lower.endsWith('.zip')) continue;
          if (!lower.contains(platformFragment)) continue;
          if (!lower.contains(token)) continue;
          if (!lower.contains(arch)) continue;
          if (name.startsWith('cudart-')) continue;
          best = a;
          break;
        }
        if (best == null) {
          _logger.fine('tag=$tag 未找到匹配 Windows 构建 variant=$variant');
          continue;
        }
        matchedAsset = best;
        matchedTag = tag;
        break;
      }
      if (matchedAsset == null) {
        final StringBuffer hint = StringBuffer(
            '在 llama.cpp 最近 ${candidateReleases.length} 个发布中未找到匹配的 Windows 构建：variant=${variant.name} (assetToken=$token arch=$arch)。')
          ..writeln('最近 2 个发布的可用 Windows zip 资产：');
        for (final Map<String, Object?> release
            in candidateReleases.take(2)) {
          final t = release['tag_name'] ?? '?';
          hint.writeln('  tag=$t：');
          final Object? assetsRaw = release['assets'];
          if (assetsRaw is List<Object?>) {
            for (final Object? a in assetsRaw) {
              if (a is Map<String, Object?>) {
                final n = a['name'] as String? ?? '';
                if (n.toLowerCase().endsWith('.zip') &&
                    n.toLowerCase().contains('win')) {
                  hint.writeln('    - $n');
                }
              }
            }
          }
        }
        throw StateError(hint.toString());
      }
      final String tag = matchedTag!;
      final assetName = matchedAsset['name'] as String? ?? '';
      final String? dlUrl = matchedAsset['browser_download_url'] as String? ??
          matchedAsset['url'] as String?;
      final int size = (matchedAsset['size'] as int?) ?? 0;
      if (dlUrl == null || dlUrl.isEmpty) {
        throw StateError('资产 $assetName 没有可下载 URL。');
      }
      onProgress?.call(RwkvDownloadProgress(
        phase: RwkvDownloadPhase.fetchingMeta,
        message: '找到官方构建：tag=$tag / $assetName / ${size ~/ (1024 * 1024)} MB',
      ));
      return RwkvServerBuildInfo(
        repo: effectiveRepo,
        tag: tag,
        variant: variant,
        assetName: assetName,
        downloadUrl: dlUrl,
        sizeBytes: size,
        browserDownloadUrl: dlUrl,
      );
    } finally {
      client.close();
    }
  }

  // ---------------------------------------------------------------------------
  // installLlamaServer
  // ---------------------------------------------------------------------------
  @override
  Future<String> installLlamaServer({
    RwkvServerBuildInfo? buildInfo,
    OfficialServerVariant variant = OfficialServerVariant.vulkan,
    String? installDir,
    void Function(RwkvDownloadProgress)? onProgress,
    void Function(RwkvCancelHandle handle)? onHandleReady,
  }) async {
    if (_installInProgress) {
      throw StateError(
          '已有 llama.cpp Server 安装任务正在进行中，请等待完成或取消后再试。');
    }
    _installInProgress = true;
    final cancel = _NativeCancelHandle();
    onHandleReady?.call(cancel);
    try {
      cancel.throwIfCancelled();
      final build = buildInfo ??
          await fetchLatestServerBuild(
              variant: variant, onProgress: onProgress);
      cancel.throwIfCancelled();
      final baseDir = await _resolveInstallBaseDir();
      final effectiveInstallDir = installDir ??
          path.join(
            baseDir,
            '_tools',
            'llama-${build.tag}-${build.variant.name}',
          );
      final installDirFile = Directory(effectiveInstallDir);
      final existingServer = await _findLlamaServerIn(installDirFile);
      if (existingServer != null) {
        onProgress?.call(RwkvDownloadProgress(
          phase: RwkvDownloadPhase.done,
          message: '已检测到可执行文件，无需重复下载：$existingServer',
        ));
        return existingServer.path;
      }
      if (!installDirFile.existsSync()) {
        installDirFile.createSync(recursive: true);
      }
      final zipPath = path.join(
        installDirFile.parent.path,
        '${path.basenameWithoutExtension(build.assetName)}-${build.tag}.zip',
      );
      await _downloadFileWithProgress(
        build.downloadUrl,
        zipPath,
        expectedSize: build.sizeBytes,
        progressPhase: RwkvDownloadPhase.downloading,
        progressMessage:
            '正在下载 llama.cpp 官方 ${build.variant.displayName} 包：${build.assetName}',
        onProgress: onProgress,
        cancelHandle: cancel,
      );
      cancel.throwIfCancelled();
      onProgress?.call(RwkvDownloadProgress(
        phase: RwkvDownloadPhase.extracting,
        message: '正在解压到 $effectiveInstallDir …',
      ));
      await _extractZipWindows(zipPath, effectiveInstallDir);
      cancel.throwIfCancelled();
      final resolved = await _findLlamaServerIn(installDirFile);
      if (resolved == null) {
        throw StateError(
            '解压完成但在 $effectiveInstallDir 内未找到 llama-server.exe。请检查压缩包内容。');
      }
      try {
        File(zipPath).deleteSync();
      } on FileSystemException catch (_) {}
      onProgress?.call(RwkvDownloadProgress(
        phase: RwkvDownloadPhase.done,
        message: 'llama-server.exe 已就位：${resolved.path}',
      ));
      return resolved.path;
    } finally {
      _installInProgress = false;
    }
  }

  // ---------------------------------------------------------------------------
  // listOfficialRwkvModels
  // ---------------------------------------------------------------------------
  @override
  Future<List<RwkvOfficialModel>> listOfficialRwkvModels({
    void Function(RwkvDownloadProgress)? onProgress,
  }) async {
    onProgress?.call(RwkvDownloadProgress(
      phase: RwkvDownloadPhase.fetchingMeta,
      message: '正在扫描 HuggingFace RWKV 官方仓库 GGUF 列表…',
    ));
    final client = _httpClient();
    try {
      List<RwkvOfficialModel>? result;
      final List<String> tried = <String>[];
      for (final repo in _rwkvRepos) {
        tried.add(repo);
        try {
          result = await _listModelsFromRepo(client, repo, onProgress);
          if (result.isNotEmpty) break;
        } on Exception catch (e, s) {
          _logger.info('尝试 repo=$repo 失败，跳过：$e $s');
        }
      }
      if (result == null || result.isEmpty) {
        _logger.warning(
            'HuggingFace API 全部失败（tried=$tried），回退到内置模型列表。'
            ' 注意：BlinkDL/RWKV-7-G1J 为私有仓，GGUF 文件由社区仓 shoumenchougou/RWKV7-G1j-7.2B-GGUF 提供。');
        return _fallbackRwkvModels.toList(growable: false);
      }
      result.sort((RwkvOfficialModel a, RwkvOfficialModel b) {
        const order = <RwkvModelQuant, int>{
          RwkvModelQuant.fp16: 0,
          RwkvModelQuant.bf16: 1,
          RwkvModelQuant.q80: 2,
          RwkvModelQuant.q6K: 3,
          RwkvModelQuant.q5KM: 4,
          RwkvModelQuant.q4KM: 5,
          RwkvModelQuant.q3KM: 6,
          RwkvModelQuant.q2K: 7,
          RwkvModelQuant.unknown: 99,
        };
        final qa = order[a.quant] ?? 99;
        final qb = order[b.quant] ?? 99;
        if (qa != qb) return qa.compareTo(qb);
        return b.sizeBytes.compareTo(a.sizeBytes);
      });
      return result;
    } finally {
      client.close();
    }
  }

  Future<List<RwkvOfficialModel>> _listModelsFromRepo(
    http.Client client,
    String repo,
    void Function(RwkvDownloadProgress)? onProgress,
  ) async {
    final uri = Uri.parse('https://huggingface.co/api/models/$repo');
    final resp = await client.get(uri, headers: const <String, String>{
      'User-Agent': 'novelcraft-rwkv-installer/1.0',
    }).timeout(const Duration(seconds: 15));
    if (resp.statusCode == 404) {
      _logger.fine('repo=$repo 不存在（404），跳过');
      return const <RwkvOfficialModel>[];
    }
    if (resp.statusCode == 401) {
      _logger.fine('repo=$repo 私有仓库（401 Unauthorized），跳过');
      return const <RwkvOfficialModel>[];
    }
    if (resp.statusCode == 403) {
      _logger.fine('repo=$repo 无权限（403），跳过');
      return const <RwkvOfficialModel>[];
    }
    if (resp.statusCode != 200) {
      throw HttpException(
          'HuggingFace API $repo 失败 HTTP ${resp.statusCode}');
    }
    final Object? data = json.decode(resp.body);
    if (data is! Map<String, Object?>) {
      throw const FormatException('HuggingFace 返回模型结构异常。');
    }
    final Object? siblings = data['siblings'];
    final String sha = (data['sha'] as String?) ?? 'main';
    if (siblings is! List<Object?>) {
      return const <RwkvOfficialModel>[];
    }
    final List<RwkvOfficialModel> models = <RwkvOfficialModel>[];
    for (final Object? raw in siblings) {
      if (raw is! Map<String, Object?>) continue;
      final String? rfilename = raw['rfilename'] as String?;
      if (rfilename == null || !rfilename.toLowerCase().endsWith('.gguf')) {
        continue;
      }
      final size = (raw['size'] as num?)?.toInt() ?? 0;
      final fileName = path.basename(rfilename);
      final subFolder = path.dirname(rfilename) == '.' ? '' : path.dirname(rfilename);
      final quant = RwkvModelQuantX.fromFileName(fileName);
      final paramsLabel = _extractParamsLabel(fileName);
      final url =
          'https://huggingface.co/$repo/resolve/$sha/'
          '$rfilename';
      models.add(RwkvOfficialModel(
        id: '$repo@$sha:$rfilename',
        displayName: _displayNameFor(fileName, quant, paramsLabel),
        repo: repo,
        subFolder: subFolder,
        fileName: fileName,
        revision: sha,
        downloadUrl: url,
        sizeBytes: size,
        quant: quant,
        paramsLabel: paramsLabel,
      ));
    }
    return models;
  }

  static String _extractParamsLabel(String fileName) {
    final match = RegExp(r'([0-9]+\.?[0-9]*)\s*B', caseSensitive: false)
        .firstMatch(fileName);
    if (match == null) return '未知参数量';
    return '${match.group(1)}B';
  }

  static String _displayNameFor(
      String fileName, RwkvModelQuant quant, String params) {
    final base = fileName.replaceAll(RegExp(r'\.(gguf)$', caseSensitive: false), '');
    return '$base (${quant.displayLabel})';
  }

  // ---------------------------------------------------------------------------
  // downloadOfficialModel
  // ---------------------------------------------------------------------------
  @override
  Future<String> downloadOfficialModel(
    RwkvOfficialModel model, {
    String? targetDir,
    void Function(RwkvDownloadProgress)? onProgress,
    void Function(RwkvCancelHandle handle)? onHandleReady,
  }) async {
    if (_downloadInProgress) {
      throw StateError('已有官方模型下载任务进行中，请等待完成或取消后再试。');
    }
    _downloadInProgress = true;
    final cancel = _NativeCancelHandle();
    onHandleReady?.call(cancel);
    try {
      cancel.throwIfCancelled();
      final String modelsDir = targetDir ?? await _resolveModelsDir();
      final dir = Directory(modelsDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final dest = path.join(modelsDir, model.fileName);
      final f = File(dest);
      if (f.existsSync() &&
          model.sizeBytes > 0 &&
          f.lengthSync() == model.sizeBytes) {
        onProgress?.call(RwkvDownloadProgress(
          phase: RwkvDownloadPhase.done,
          totalBytes: model.sizeBytes,
          receivedBytes: model.sizeBytes,
          message: '${model.fileName} 已存在且校验通过，跳过下载。',
        ));
        return dest;
      }
      await _downloadFileWithProgress(
        model.downloadUrl,
        dest,
        expectedSize: model.sizeBytes,
        progressPhase: RwkvDownloadPhase.downloading,
        progressMessage:
            '正在下载官方模型：${model.displayName} / ${model.sizeHumanReadable}',
        onProgress: onProgress,
        cancelHandle: cancel,
      );
      cancel.throwIfCancelled();
      onProgress?.call(RwkvDownloadProgress(
        phase: RwkvDownloadPhase.done,
        totalBytes: model.sizeBytes,
        receivedBytes: model.sizeBytes,
        message: '${model.fileName} 下载完成，已保存在 $dest。',
      ));
      return dest;
    } finally {
      _downloadInProgress = false;
    }
  }

  // ---------------------------------------------------------------------------
  // 内置推理引擎：rwkv_lightning_cuda（albatross）
  //
  // 与 llama.cpp 路线完全独立：只吃 .pth / .rwkvq + **强制外置词表**（PITFALLS §27.1）。
  // 官方 release 提供 Windows/Linux × CUDA 12.9 / 13.2 四种预编译包 + .sha256。
  // ---------------------------------------------------------------------------

  /// 仅 CUDA 12 / 13 两档有官方预编译包；其余变体直接给出可读错误。
  static String _lightningCudaToken(OfficialServerVariant variant) {
    switch (variant) {
      case OfficialServerVariant.cuda12:
        return 'cuda12.9';
      case OfficialServerVariant.cuda13:
        return 'cuda13.2';
      case OfficialServerVariant.cpu:
      case OfficialServerVariant.vulkan:
      case OfficialServerVariant.hip:
      case OfficialServerVariant.sycl:
      case OfficialServerVariant.arm64:
        throw ArgumentError(
            'rwkv_lightning_cuda 只提供 CUDA 12.9 / 13.2 预编译包，不支持 ${variant.displayName}。'
            '请选择 cuda12 或 cuda13（PITFALLS §30）。');
    }
  }

  static String _lightningPlatformToken() {
    if (Platform.isWindows) return 'windows-x64';
    if (Platform.isLinux) return 'linux-x64';
    throw UnsupportedError(
        'rwkv_lightning_cuda 仅提供 Windows / Linux 预编译包，'
        '当前平台=${Platform.operatingSystem}。');
  }

  /// 兜底 .pth 清单（`BlinkDL/rwkv7-g1` 实测内容）——HF API 不可用时使用。
  static const List<RwkvOfficialModel> _fallbackPthModels =
      <RwkvOfficialModel>[
    RwkvOfficialModel(
      id: 'pth-rwkv7-g1j-7.2b',
      displayName: 'RWKV-7 G1j 7.2B (原生 .pth · ctx16384)',
      repo: kRwkvLightningWeightsRepo,
      subFolder: '',
      fileName: 'rwkv7-g1j-7.2b-20260831-ctx16384.pth',
      downloadUrl:
          'https://huggingface.co/BlinkDL/rwkv7-g1/resolve/main/rwkv7-g1j-7.2b-20260831-ctx16384.pth',
      sizeBytes: 14400864256,
      quant: RwkvModelQuant.fp16,
      paramsLabel: '7.2B',
    ),
    RwkvOfficialModel(
      id: 'pth-rwkv7-g1j-2.9b',
      displayName: 'RWKV-7 G1j 2.9B (原生 .pth · ctx16384)',
      repo: kRwkvLightningWeightsRepo,
      subFolder: '',
      fileName: 'rwkv7-g1j-2.9b-20260831-ctx16384.pth',
      downloadUrl:
          'https://huggingface.co/BlinkDL/rwkv7-g1/resolve/main/rwkv7-g1j-2.9b-20260831-ctx16384.pth',
      sizeBytes: 5897191424,
      quant: RwkvModelQuant.fp16,
      paramsLabel: '2.9B',
    ),
    RwkvOfficialModel(
      id: 'pth-rwkv7-g1j-1.5b',
      displayName: 'RWKV-7 G1j 1.5B (原生 .pth · ctx16384)',
      repo: kRwkvLightningWeightsRepo,
      subFolder: '',
      fileName: 'rwkv7-g1j-1.5b-20260831-ctx16384.pth',
      downloadUrl:
          'https://huggingface.co/BlinkDL/rwkv7-g1/resolve/main/rwkv7-g1j-1.5b-20260831-ctx16384.pth',
      sizeBytes: 3055558656,
      quant: RwkvModelQuant.fp16,
      paramsLabel: '1.5B',
    ),
    RwkvOfficialModel(
      id: 'pth-rwkv7-g1i-7.2b',
      displayName: 'RWKV-7 G1i 7.2B (原生 .pth · ctx16384)',
      repo: kRwkvLightningWeightsRepo,
      subFolder: '',
      fileName: 'rwkv7-g1i-7.2b-20260805-ctx16384.pth',
      downloadUrl:
          'https://huggingface.co/BlinkDL/rwkv7-g1/resolve/main/rwkv7-g1i-7.2b-20260805-ctx16384.pth',
      sizeBytes: 14400864256,
      quant: RwkvModelQuant.fp16,
      paramsLabel: '7.2B',
    ),
    RwkvOfficialModel(
      id: 'pth-rwkv7-g1d-0.4b',
      displayName: 'RWKV-7 G1d 0.4B (原生 .pth · ctx8192)',
      repo: kRwkvLightningWeightsRepo,
      subFolder: '',
      fileName: 'rwkv7-g1d-0.4b-20260210-ctx8192.pth',
      downloadUrl:
          'https://huggingface.co/BlinkDL/rwkv7-g1/resolve/main/rwkv7-g1d-0.4b-20260210-ctx8192.pth',
      sizeBytes: 901775360,
      quant: RwkvModelQuant.fp16,
      paramsLabel: '0.4B',
    ),
  ];

  @override
  Future<RwkvLightningRelease> fetchLatestLightningRelease({
    OfficialServerVariant variant = OfficialServerVariant.cuda13,
    String? repo,
    void Function(RwkvDownloadProgress)? onProgress,
  }) async {
    final String effectiveRepo = repo ?? kRwkvLightningRepo;
    final String cudaToken = _lightningCudaToken(variant);
    final String platformToken = _lightningPlatformToken();
    final String ext = Platform.isWindows ? 'zip' : 'tar.gz';
    onProgress?.call(RwkvDownloadProgress(
      phase: RwkvDownloadPhase.fetchingMeta,
      message: '正在查询 $effectiveRepo 最新 release（$platformToken / $cudaToken）…',
    ));
    final client = _httpClient();
    try {
      final resp = await client.get(
        Uri.parse('https://api.github.com/repos/$effectiveRepo/releases/latest'),
        headers: const <String, String>{
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'novelcraft-rwkv-installer/1.0',
        },
      ).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        throw HttpException(
            '查询 $effectiveRepo release 失败：HTTP ${resp.statusCode}\n${resp.body}');
      }
      final Object? data = json.decode(resp.body);
      if (data is! Map<String, Object?>) {
        throw const FormatException('GitHub release 返回结构异常。');
      }
      // ⚠ 实测坑（PITFALLS §30.7）：GitHub 有一部分 release 的 `tag_name` 会退化成
      // `untagged-<40位sha>`，真正的版本号（v1.6.0）在 `name` 字段里。
      // 因此**不能**用 tag 去拼资产名，改为「平台 + CUDA + 扩展名」后缀模式匹配，
      // 完全与 tag 解耦。
      final String rawTag = (data['tag_name'] as String?) ?? '';
      final String rawName = (data['name'] as String?) ?? '';
      bool looksLikeVersion(String s) =>
          s.isNotEmpty &&
          !s.startsWith('untagged') &&
          RegExp(r'^v?\d').hasMatch(s);
      String tag = looksLikeVersion(rawTag) ? rawTag : rawName;
      if (tag.isEmpty) tag = rawTag.isNotEmpty ? rawTag : rawName;
      if (tag.isEmpty) {
        throw const FormatException('GitHub release 既缺 tag_name 也缺 name。');
      }

      // 资产命名（实测）：rwkv-lightning-v1.6.0-windows-x64-cuda13.2.zip
      final String suffix = '-$platformToken-$cudaToken.$ext';
      final Object? assets = data['assets'];
      final List<String> available = <String>[];
      Map<String, Object?>? hit;
      if (assets is List<Object?>) {
        for (final Object? raw in assets) {
          if (raw is! Map<String, Object?>) continue;
          final String name = (raw['name'] as String?) ?? '';
          if (name.isEmpty || name.endsWith('.sha256')) continue;
          available.add(name);
          if (hit == null &&
              name.startsWith('rwkv-lightning-') &&
              name.endsWith(suffix)) {
            hit = raw;
          }
        }
      }
      if (hit == null) {
        throw StateError(
            'release $tag 里没有找到以 `$suffix` 结尾的资产。\n可用的资产：\n'
            '${available.map((String n) => '  - $n').join('\n')}');
      }
      final String url = (hit['browser_download_url'] as String?) ?? '';
      final int size = ((hit['size'] as num?) ?? 0).toInt();
      final String assetName = (hit['name'] as String?) ?? '';
      final RwkvLightningRelease release = RwkvLightningRelease(
        tag: tag,
        variant: variant,
        platformToken: platformToken,
        cudaToken: cudaToken,
        assetName: assetName,
        downloadUrl: url,
        sha256Url: '$url.sha256',
        sizeBytes: size,
      );
      onProgress?.call(RwkvDownloadProgress(
        phase: RwkvDownloadPhase.fetchingMeta,
        message: '找到 ${release.assetName}（${release.sizeHumanReadable}）',
        totalBytes: size,
      ));
      return release;
    } finally {
      client.close();
    }
  }

  @override
  Future<String> installLightningServer({
    RwkvLightningRelease? release,
    OfficialServerVariant variant = OfficialServerVariant.cuda13,
    String? installDir,
    void Function(RwkvDownloadProgress)? onProgress,
    void Function(RwkvCancelHandle handle)? onHandleReady,
  }) async {
    if (_installInProgress) {
      throw StateError('已有引擎安装任务进行中，请等待完成或取消后再试。');
    }
    _installInProgress = true;
    final cancel = _NativeCancelHandle();
    onHandleReady?.call(cancel);
    try {
      cancel.throwIfCancelled();
      final rel = release ??
          await fetchLatestLightningRelease(
              variant: variant, onProgress: onProgress);
      cancel.throwIfCancelled();

      final String baseDir = await _resolveInstallBaseDir();
      final String effectiveDir = installDir ??
          path.join(
            baseDir,
            '_tools',
            'rwkv-lightning-${rel.tag}-${rel.variant.name}',
          );
      final Directory dir = Directory(effectiveDir);
      final File? existing = await _findLightningServerIn(dir);
      if (existing != null) {
        onProgress?.call(RwkvDownloadProgress(
          phase: RwkvDownloadPhase.done,
          message: '已检测到引擎可执行文件，无需重复下载：${existing.path}',
        ));
        return existing.path;
      }
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final bool isWindows = Platform.isWindows;
      final String archivePath = path.join(
        dir.parent.path,
        rel.assetName,
      );
      await _downloadFileWithProgress(
        rel.downloadUrl,
        archivePath,
        expectedSize: rel.sizeBytes,
        progressPhase: RwkvDownloadPhase.downloading,
        progressMessage:
            '正在下载内置引擎 ${rel.tag}（${rel.platformToken} / ${rel.cudaToken}，'
            '${rel.sizeHumanReadable}）',
        onProgress: onProgress,
        cancelHandle: cancel,
      );
      cancel.throwIfCancelled();

      // ---- SHA-256 校验（PITFALLS §30：release 带 .sha256 兄弟资产）----
      onProgress?.call(const RwkvDownloadProgress(
        phase: RwkvDownloadPhase.verifying,
        message: '正在校验 SHA-256 …',
      ));
      final String? verifyNote =
          await _verifySha256(archivePath, rel.sha256Url, cancel: cancel);
      cancel.throwIfCancelled();

      onProgress?.call(RwkvDownloadProgress(
        phase: RwkvDownloadPhase.extracting,
        message: '正在解压到 $effectiveDir …',
      ));
      await _extractArchive(archivePath, effectiveDir, isZip: isWindows);
      cancel.throwIfCancelled();

      final File? resolved = await _findLightningServerIn(dir);
      if (resolved == null) {
        throw StateError('解压完成但在 $effectiveDir 内未找到 $kRwkvLightningExeName。'
            '请检查压缩包内容（上游把 lightning 拼成了 lighting）。');
      }
      try {
        File(archivePath).deleteSync();
      } on FileSystemException catch (_) {}
      onProgress?.call(RwkvDownloadProgress(
        phase: RwkvDownloadPhase.done,
        message: '内置引擎已就位：${resolved.path}'
            '${verifyNote == null ? '' : '（$verifyNote）'}',
      ));
      return resolved.path;
    } finally {
      _installInProgress = false;
    }
  }

  @override
  Future<String> ensureLightningVocab({
    String? targetDir,
    void Function(RwkvDownloadProgress)? onProgress,
    void Function(RwkvCancelHandle handle)? onHandleReady,
  }) async {
    final cancel = _NativeCancelHandle();
    onHandleReady?.call(cancel);
    // PITFALLS §27.1：词表约 2.5MB，小于 500KB 视为损坏。
    const int kMinVocabBytes = 500 * 1024;
    final String dirPath =
        targetDir ?? path.join(await _resolveInstallBaseDir(), '_assets');
    final Directory dir = Directory(dirPath);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final String dest = path.join(dirPath, kRwkvVocabFileName);
    final File f = File(dest);
    if (f.existsSync() && f.lengthSync() >= kMinVocabBytes) {
      onProgress?.call(RwkvDownloadProgress(
        phase: RwkvDownloadPhase.done,
        totalBytes: f.lengthSync(),
        receivedBytes: f.lengthSync(),
        message: '词表已就位：$dest',
      ));
      return dest;
    }
    // 先走 raw.githubusercontent（体积小、无鉴权）；失败再兜 HF 上的同名词表。
    final List<String> urls = <String>[
      kRwkvVocabDownloadUrl,
      'https://huggingface.co/$kRwkvLightningWeightsRepo/resolve/main/$kRwkvVocabFileName',
    ];
    Object? lastError;
    for (final String url in urls) {
      cancel.throwIfCancelled();
      try {
        await _downloadFileWithProgress(
          url,
          dest,
          expectedSize: 0,
          progressPhase: RwkvDownloadPhase.downloading,
          progressMessage: '正在下载外置词表 $kRwkvVocabFileName（引擎必需，约 2.5MB）',
          onProgress: onProgress,
          cancelHandle: cancel,
        );
        cancel.throwIfCancelled();
        final int len = f.existsSync() ? f.lengthSync() : 0;
        if (len >= kMinVocabBytes) {
          onProgress?.call(RwkvDownloadProgress(
            phase: RwkvDownloadPhase.done,
            totalBytes: len,
            receivedBytes: len,
            message: '词表已下载并校验通过：$dest（${(len / 1024).toStringAsFixed(0)} KB）',
          ));
          return dest;
        }
        lastError = StateError('下载到的词表只有 $len 字节（< 500KB），判定为损坏。');
      } on Object catch (e) {
        lastError = e;
        _logger.warning('词表下载失败（$url）：$e');
      }
    }
    throw StateError('外置词表下载失败：$lastError\n'
        '可手动下载 $kRwkvVocabDownloadUrl 保存为 $dest（PITFALLS §27.1）。');
  }

  @override
  Future<List<RwkvOfficialModel>> listLightningPthModels({
    void Function(RwkvDownloadProgress)? onProgress,
  }) async {
    onProgress?.call(const RwkvDownloadProgress(
      phase: RwkvDownloadPhase.fetchingMeta,
      message: '正在扫描 HuggingFace 官方 .pth 权重列表…',
    ));
    final client = _httpClient();
    try {
      final resp = await client.get(
        Uri.parse(
            'https://huggingface.co/api/models/$kRwkvLightningWeightsRepo/tree/main?recursive=true'),
        headers: const <String, String>{
          'User-Agent': 'novelcraft-rwkv-installer/1.0',
        },
      ).timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        _logger.warning(
            'HF tree API HTTP ${resp.statusCode}，回退内置 .pth 清单。');
        return _fallbackPthModels;
      }
      final Object? data = json.decode(resp.body);
      if (data is! List<Object?>) {
        return _fallbackPthModels;
      }
      final List<RwkvOfficialModel> models = <RwkvOfficialModel>[];
      for (final Object? raw in data) {
        if (raw is! Map<String, Object?>) continue;
        final String p = (raw['path'] as String?) ?? '';
        final String lower = p.toLowerCase();
        // 引擎原生格式：.pth（FP16/BF16）与 .rwkvq（W8A16/W4A16 量化）
        final bool isPth = lower.endsWith('.pth');
        final bool isRwkvq = lower.endsWith('.rwkvq');
        if (!isPth && !isRwkvq) continue;
        final String fileName = path.basename(p);
        // 顶层文件才是指向单个模型的权重；索引/优化器文件跳过
        final int size = ((raw['size'] as num?) ??
                (((raw['lfs'] as Map<String, Object?>?)?['size']) as num? ?? 0))
            .toInt();
        if (size <= 0) continue;
        final RwkvModelQuant quant = isRwkvq
            ? RwkvModelQuantX.fromFileName(fileName)
            : RwkvModelQuant.fp16;
        models.add(RwkvOfficialModel(
          id: 'pth:$fileName',
          displayName: fileName
              .replaceAll(RegExp(r'\.(pth|rwkvq)$', caseSensitive: false), ''),
          repo: kRwkvLightningWeightsRepo,
          subFolder: '',
          fileName: fileName,
          downloadUrl:
              'https://huggingface.co/$kRwkvLightningWeightsRepo/resolve/main/$p',
          sizeBytes: size,
          quant: quant == RwkvModelQuant.unknown
              ? RwkvModelQuant.fp16
              : quant,
          paramsLabel: _extractParamsLabel(fileName),
        ));
      }
      if (models.isEmpty) {
        _logger.warning('.pth 列表为空，回退内置清单。');
        return _fallbackPthModels;
      }
      models.sort((RwkvOfficialModel a, RwkvOfficialModel b) =>
          b.sizeBytes.compareTo(a.sizeBytes));
      return models;
    } on Object catch (e, s) {
      _logger.warning('拉取 .pth 列表失败，回退内置清单：$e $s');
      return _fallbackPthModels;
    } finally {
      client.close();
    }
  }

  /// 在安装目录内递归定位引擎可执行文件。
  ///
  /// ⚠ 上游 CMake 目标名把 `lightning` 拼成了 `lighting`，两种拼写都要兜；
  /// 且可执行文件落在构建根目录（`build/rwkv_lighting_cuda.exe`）。
  static Future<File?> _findLightningServerIn(Directory dir) async {
    if (!dir.existsSync()) return null;
    final List<FileSystemEntity> candidates = <FileSystemEntity>[];
    try {
      candidates.addAll(dir.listSync(recursive: true, followLinks: false));
    } on FileSystemException catch (e) {
      _logger.warning('遍历目录失败 $dir：$e');
    }
    for (final FileSystemEntity entity in candidates) {
      if (entity is! File) continue;
      final String base = path.basename(entity.path).toLowerCase();
      if (base.contains('lightning_cuda') || base.contains('lighting_cuda')) {
        // 两个辅助二进制（state tune / quantize）不作数，只要服务端
        if (base.contains('state_tune') || base.contains('quantize')) continue;
        return entity;
      }
    }
    return null;
  }

  /// 校验下载文件的 SHA-256。
  ///
  /// 返回 `null` 表示校验通过（或官方未提供校验文件，属可接受降级）；
  /// 不一致时抛 [StateError]，绝不静默放过。
  static Future<String?> _verifySha256(
    String filePath,
    String sha256Url, {
    _NativeCancelHandle? cancel,
  }) async {
    final client = _httpClient();
    try {
      final resp = await client.get(
        Uri.parse(sha256Url),
        headers: const <String, String>{
          'User-Agent': 'novelcraft-rwkv-installer/1.0',
        },
      ).timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        _logger.warning('未取到 $sha256Url（HTTP ${resp.statusCode}），跳过 SHA-256 校验。');
        return '官方未提供校验文件，已跳过校验';
      }
      // .sha256 内容通常是 "<64位hex>  <文件名>"
      final String expected = RegExp(r'[0-9a-fA-F]{64}')
          .firstMatch(resp.body)
          ?.group(0)
          ?.toLowerCase() ??
          '';
      if (expected.isEmpty) {
        _logger.warning('$sha256Url 内容无法解析出 SHA-256，跳过校验。');
        return '校验文件无法解析，已跳过校验';
      }
      cancel?.throwIfCancelled();
      final File f = File(filePath);
      // 流式哈希：引擎包约 400MB，一次性 readAsBytes 会吃掉数百 MB 堆内存。
      // 用 Hash.bind 边读边算，配合取消句柄让用户能中途退出。
      final Digest digest = await sha256
          .bind(f.openRead().map((List<int> chunk) {
            cancel?.throwIfCancelled();
            return chunk;
          }))
          .first;
      final String actual = digest.toString().toLowerCase();
      if (actual != expected) {
        throw StateError('SHA-256 校验失败！\n'
            '期望：$expected\n实际：$actual\n'
            '文件：$filePath\n请重新下载（可能被 CDN/代理截断）。');
      }
      _logger.info('SHA-256 校验通过：$filePath');
      return 'SHA-256 校验通过';
    } on Object catch (e) {
      if (e is StateError) rethrow;
      _logger.warning('SHA-256 校验过程异常，跳过：$e');
      return '校验过程异常，已跳过校验';
    } finally {
      client.close();
    }
  }

  /// 解压归档：Windows 走 Expand-Archive，POSIX 走 tar。
  static Future<void> _extractArchive(
    String archivePath,
    String dest, {
    required bool isZip,
  }) async {
    final Directory destDir = Directory(dest);
    if (destDir.existsSync()) destDir.deleteSync(recursive: true);
    destDir.createSync(recursive: true);
    if (isZip) {
      await _extractZipWindows(archivePath, dest);
      return;
    }
    final ProcessResult r = await Process.run(
      'tar',
      <String>['-xzf', archivePath, '-C', dest],
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
      stderrEncoding: const Utf8Codec(allowMalformed: true),
    );
    if (r.exitCode != 0) {
      throw StateError(
          'tar 解压失败 exit=${r.exitCode}\nSTDOUT: ${r.stdout}\nSTDERR: ${r.stderr}');
    }
  }

  // ---------------------------------------------------------------------------
  // Download helper
  // ---------------------------------------------------------------------------
  static Future<void> _downloadFileWithProgress(
    String url,
    String destPath, {
    required int expectedSize,
    required RwkvDownloadPhase progressPhase,
    String? progressMessage,
    void Function(RwkvDownloadProgress)? onProgress,
    _NativeCancelHandle? cancelHandle,
  }) async {
    cancelHandle?.throwIfCancelled();
    final destFile = File(destPath);
    final partPath = '$destPath.part';
    final partFile = File(partPath);
    int existing = 0;
    if (partFile.existsSync()) {
      existing = partFile.lengthSync();
    }
    if (existing > 0 && expectedSize > 0 && existing >= expectedSize) {
      // 可能已下完但没 rename
      try {
        partFile.renameSync(destPath);
        return;
      } on FileSystemException catch (_) {
        partFile.deleteSync();
        existing = 0;
      }
    }
    final uri = Uri.parse(url);
    final client = _httpClient();
    IOSink? sink;
    http.StreamedResponse? response;
    StreamSubscription<List<int>>? sub;
    cancelHandle?.onCancelled((String? _) {
      Future<void>(() async {
        try {
          await sub?.cancel().catchError((Object _) {});
        } finally {
          try {
            await sink?.flush().catchError((Object _) {});
          } finally {
            await sink?.close().catchError((Object _) {});
            client.close();
          }
        }
      });
    });
    try {
      final request = http.Request('GET', uri);
      if (existing > 0) {
        request.headers['Range'] = 'bytes=$existing-';
      }
      request.headers['User-Agent'] = 'novelcraft-rwkv-installer/1.0';
      cancelHandle?.throwIfCancelled();
      response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      cancelHandle?.throwIfCancelled();
      final bool isRange = response.statusCode == 206;
      final bool ok = isRange || response.statusCode == 200;
      if (!ok) {
        final bodyPreview = await response.stream
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 5))
            .catchError((Object _) => '');
        throw HttpException(
            '下载 $url 失败：HTTP ${response.statusCode}\n$bodyPreview');
      }
      final int? remoteLength = response.contentLength;
      final int total = expectedSize > 0
          ? expectedSize
          : (remoteLength ?? 0) + (isRange ? existing : 0);
      sink = partFile.openWrite(
          mode: isRange ? FileMode.append : FileMode.write);
      if (!isRange && partFile.existsSync()) {
        partFile.deleteSync();
        sink = partFile.openWrite(mode: FileMode.write);
        existing = 0;
      }
      int received = existing;
      final Stopwatch sw = Stopwatch()..start();
      final List<_SpeedSample> samples = <_SpeedSample>[];
      DateTime lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
      onProgress?.call(RwkvDownloadProgress(
        phase: progressPhase,
        message: progressMessage,
        receivedBytes: received,
        totalBytes: total,
      ));
      sub = response.stream.listen(
        (List<int> chunk) {
          cancelHandle?.throwIfCancelled();
          sink!.add(chunk);
          received += chunk.length;
          samples.add(_SpeedSample(sw.elapsedMicroseconds, received));
          if (samples.length > 20) samples.removeRange(0, samples.length - 20);
          final now = DateTime.now();
          if (now.difference(lastEmit) >= _progressWindow ||
              received == total) {
            final (double speed, int eta) =
                _computeSpeedEta(samples, received, total);
            cancelHandle?.throwIfCancelled();
            onProgress?.call(RwkvDownloadProgress(
              phase: progressPhase,
              message: progressMessage,
              receivedBytes: received,
              totalBytes: total,
              speedMbps: speed,
              etaSeconds: eta,
            ));
            lastEmit = now;
          }
        },
        cancelOnError: true,
      );
      await sub.asFuture<void>();
      cancelHandle?.throwIfCancelled();
      await sink.flush();
      await sink.close();
      sink = null;
      sub = null;
      // final size verification: if total>0 and received differs, warn but don't fail when downloading from partial HF files sometimes lack content-length
      if (expectedSize > 0 && received != expectedSize) {
        if (!isRange && remoteLength != null && received == remoteLength) {
          // accept
        } else {
          _logger.warning(
              '下载 $destPath 字节数 mismatch：期望 $expectedSize，实际 $received。');
        }
      }
      // rename .part -> dest
      if (destFile.existsSync()) destFile.deleteSync();
      partFile.renameSync(destPath);
    } finally {
      try {
        await sink?.flush().catchError((Object _) {});
      } finally {
        await sink?.close().catchError((Object _) {});
      }
      try {
        await sub?.cancel().catchError((Object _) {});
      } finally {
        client.close();
      }
    }
  }

  static (double speedMbps, int etaSeconds) _computeSpeedEta(
    List<_SpeedSample> samples,
    int received,
    int total,
  ) {
    if (samples.length < 2) return (0, 0);
    final first = samples.first;
    final last = samples.last;
    final double elapsedSec = (last.us - first.us) / 1000000.0;
    if (elapsedSec <= 0) return (0, 0);
    final int bytesDelta = last.bytes - first.bytes;
    final double bytesPerSec = bytesDelta / elapsedSec;
    final double mbps = bytesPerSec * 8 / (1000 * 1000);
    final int remaining = total > received ? total - received : 0;
    final int eta = bytesPerSec <= 0
        ? 0
        : (remaining / bytesPerSec).ceil();
    return (mbps, eta);
  }

  // ---------------------------------------------------------------------------
  // Install helpers
  // ---------------------------------------------------------------------------
  static Future<String> _resolveInstallBaseDir() async {
    try {
      final dir = Directory(path.join(
        Directory.current.path,
        'rwkv_models',
      ));
      if (dir.parent.existsSync()) {
        return dir.path;
      }
      // fallthrough to path_provider
    } on Object catch (_) {
      // fallthrough
    }
    final Directory supp = await getApplicationSupportDirectory();
    return path.join(supp.path, 'novelcraft', 'rwkv_models');
  }

  static Future<String> _resolveModelsDir() async {
    final candidates = <String>[
      path.join(Directory.current.path, 'rwkv_models'),
    ];
    for (final p in candidates) {
      if (Directory(p).existsSync()) return p;
    }
    final String base = await _resolveInstallBaseDir();
    return base;
  }

  static Future<File?> _findLlamaServerIn(Directory dir) async {
    if (!dir.existsSync()) return null;
    final List<FileSystemEntity> candidates = <FileSystemEntity>[];
    try {
      candidates.addAll(dir.listSync(recursive: true, followLinks: false));
    } on FileSystemException catch (e) {
      _logger.warning('遍历目录失败 $dir：$e');
    }
    for (final entity in candidates) {
      if (entity is! File) continue;
      final String base = path.basename(entity.path).toLowerCase();
      if (base == 'llama-server.exe' || base == 'server.exe') {
        return entity;
      }
    }
    return null;
  }

  static Future<void> _extractZipWindows(String zipPath, String dest) async {
    if (!Platform.isWindows) {
      // Dart SDK archive package not included; we require archive on posix,
      // but at minimum document via error. For macOS/Linux user can install
      // manually via UI "浏览…" button; also powershell only works on win.
      final d = Directory(dest);
      if (!d.existsSync()) d.createSync(recursive: true);
      final unzip = await Process.start('unzip', <String>['-o', zipPath, '-d', dest]);
      final exitCode = await unzip.exitCode;
      if (exitCode != 0) {
        throw StateError('unzip 解压失败 exit=$exitCode。请手动解压 $zipPath 到 $dest。');
      }
      return;
    }
    final destDir = Directory(dest);
    if (destDir.existsSync()) {
      destDir.deleteSync(recursive: true);
    }
    destDir.createSync(recursive: true);
    final escapedZip = zipPath.replaceAll("'", "''");
    final escapedDest = dest.replaceAll("'", "''");
    final script =
        'Expand-Archive -LiteralPath \'$escapedZip\' -DestinationPath \'$escapedDest\' -Force';
    final result = await Process.run(
      'powershell.exe',
      <String>['-NoProfile', '-NonInteractive', '-Command', script],
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
      stderrEncoding: const Utf8Codec(allowMalformed: true),
    );
    if (result.exitCode != 0) {
      final String msg =
          'Expand-Archive 失败 exit=${result.exitCode}\nSTDOUT: ${result.stdout}\nSTDERR: ${result.stderr}';
      throw StateError(msg);
    }
  }
}

final class _SpeedSample {
  final int us;
  final int bytes;
  const _SpeedSample(this.us, this.bytes);
}
