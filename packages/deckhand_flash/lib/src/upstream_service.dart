import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import 'egress_interceptor.dart';
import 'github_token_interceptor.dart';
import 'sidecar_client.dart';

/// [UpstreamService] - git clones via the sidecar, release assets over
/// HTTPS using Dio + GitHub's Releases API.
///
/// Every method that issues an outbound network call gates on the
/// user's approved-host gate via [requireHostApproved]. A
/// [HostNotApprovedException] is the typed signal the UI uses to
/// surface a "Allow this host?" prompt and retry.
///
/// Every Dio request is logged via [EgressLogInterceptor] so the
/// S900 Network panel and debug bundles can subscribe to a single
/// stream of approved outbound traffic. Callers can label requests
/// via `Options(extra: {EgressLogInterceptor.operationLabelKey:
/// 'Profile fetch'})` to associate the row in the UI with the
/// triggering wizard step.
class SidecarUpstreamService implements UpstreamService {
  SidecarUpstreamService({
    required this.sidecar,
    required SecurityService security,
    Dio? dio,
    String? osImagesDir,
  }) : _security = security,
       _osImagesDir = osImagesDir,
       _dio = (dio ?? Dio())
         // Token interceptor runs first so it sees the un-mutated
         // request and can inject the auth header before the egress
         // logger snapshots the URL/headers.
         ..interceptors.add(GitHubTokenInterceptor(security))
         ..interceptors.add(EgressLogInterceptor(security));

  final SidecarConnection sidecar;
  final SecurityService _security;
  final String? _osImagesDir;
  final Dio _dio;

  @override
  Future<UpstreamFetchResult> gitFetch({
    required String repoUrl,
    required String ref,
    required String destPath,
    int depth = 1,
  }) async {
    await requireHostApproved(_security, repoUrl);
    final res = await sidecar.call('profiles.fetch', {
      'repo_url': repoUrl,
      'ref': ref,
      'dest': destPath,
    });
    final localPath = _jsonString(res['local_path']);
    if (localPath == null || localPath.trim().isEmpty) {
      throw UpstreamException(
        'profiles.fetch returned no local_path for $repoUrl@$ref',
      );
    }
    final resolvedRef = _jsonString(res['resolved_ref']);
    return UpstreamFetchResult(
      localPath: localPath,
      resolvedRef: resolvedRef == null || resolvedRef.trim().isEmpty
          ? ref
          : resolvedRef,
    );
  }

  @override
  Future<UpstreamFetchResult> releaseFetch({
    required String repoSlug,
    required String assetPattern,
    required String destPath,
    required String expectedSha256,
    String? tag,
  }) async {
    _validateReleaseRepoSlug(repoSlug);
    _validateAssetPattern(assetPattern);
    final normalizedExpected = _normalizedSha256(expectedSha256);
    if (normalizedExpected == null) {
      throw UpstreamException(
        'release asset $repoSlug/$assetPattern has invalid sha256',
      );
    }

    final url = tag == null
        ? 'https://api.github.com/repos/$repoSlug/releases/latest'
        : 'https://api.github.com/repos/$repoSlug/releases/tags/$tag';

    final rel = await _getReleaseJson(url);
    final tagName = _jsonString(rel['tag_name']) ?? tag ?? 'unknown';
    final assets = _releaseAssets(rel['assets']);
    final match = assets.firstWhere(
      (a) => _matches(_jsonString(a['name']) ?? '', assetPattern),
      orElse: () => const <String, dynamic>{},
    );
    if (match.isEmpty) {
      throw UpstreamException(
        'no asset in $repoSlug@$tagName matches "$assetPattern"',
      );
    }
    final dlUrl = _jsonString(match['browser_download_url']);
    final assetName = _jsonString(match['name']);
    if (dlUrl == null || assetName == null) {
      throw UpstreamException(
        'release asset metadata is missing a name or download URL',
      );
    }
    _validateReleaseAssetName(assetName);

    final outPath = p.join(destPath, assetName);
    await Directory(destPath).create(recursive: true);
    if (await File(outPath).exists()) {
      final existingSha = await _hashFile(outPath);
      if (existingSha == normalizedExpected) {
        return UpstreamFetchResult(
          localPath: outPath,
          resolvedRef: tagName,
          assetName: assetName,
        );
      }
      await File(outPath).delete();
    }
    await _downloadApproved(dlUrl, outPath);
    final actualSha = await _hashFile(outPath);
    if (actualSha != normalizedExpected) {
      try {
        await File(outPath).delete();
      } on FileSystemException {
        // Best-effort cleanup; the important behavior is that the
        // unverified file is not returned to the install flow.
      }
      throw UpstreamException(
        'sha256 mismatch for $assetName: expected '
        '$normalizedExpected, got $actualSha',
      );
    }

    return UpstreamFetchResult(
      localPath: outPath,
      resolvedRef: tagName,
      assetName: assetName,
    );
  }

  Future<Map<String, dynamic>> _getReleaseJson(String url) async {
    var current = Uri.parse(url);
    for (var redirects = 0; redirects < 5; redirects++) {
      await requireHostApproved(_security, current.toString());
      final res = await _dio.get<Map<String, dynamic>>(
        current.toString(),
        options: Options(
          followRedirects: false,
          validateStatus: (status) =>
              status != null && (status < 400 || _isRedirect(status)),
          extra: const {
            EgressLogInterceptor.operationLabelKey: 'GitHub release metadata',
          },
        ),
      );
      if (!_isRedirect(res.statusCode)) {
        return res.data ?? const <String, dynamic>{};
      }
      current = _resolveRedirect(current, res.headers);
    }
    throw UpstreamException('too many redirects while fetching $url');
  }

  Future<void> _downloadApproved(String url, String outPath) async {
    var current = Uri.parse(url);
    for (var redirects = 0; redirects < 5; redirects++) {
      await requireHostApproved(_security, current.toString());
      final res = await _dio.download(
        current.toString(),
        outPath,
        options: Options(
          followRedirects: false,
          validateStatus: (status) =>
              status != null && (status < 400 || _isRedirect(status)),
          extra: const {
            EgressLogInterceptor.operationLabelKey: 'GitHub release asset',
          },
        ),
      );
      if (!_isRedirect(res.statusCode)) return;
      try {
        await File(outPath).delete();
      } on FileSystemException {
        // Redirect responses may not have created a file; ignore.
      }
      current = _resolveRedirect(current, res.headers);
    }
    throw UpstreamException('too many redirects while downloading $url');
  }

  Uri _resolveRedirect(Uri current, Headers headers) {
    final location = headers.value('location');
    if (location == null || location.trim().isEmpty) {
      throw UpstreamException(
        'redirect from $current did not include Location',
      );
    }
    final next = current.resolve(location);
    if (next.scheme != 'https' || next.host.isEmpty) {
      throw UpstreamException(
        'release asset redirects must stay on https URLs',
      );
    }
    return next;
  }

  bool _isRedirect(int? status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  Future<String> _hashFile(String outPath) async {
    final hashRes = await sidecar.call('disks.hash', {'path': outPath});
    final sha = _normalizedSha256(_jsonString(hashRes['sha256']));
    if (sha == null) {
      throw UpstreamException(
        'disks.hash returned an invalid sha256 for $outPath',
      );
    }
    return sha;
  }

  @override
  Stream<OsDownloadProgress> osDownload({
    required String url,
    required String destPath,
    String? expectedSha256,
  }) async* {
    final parsed = Uri.tryParse(url);
    if (parsed == null || parsed.scheme != 'https' || parsed.host.isEmpty) {
      throw UpstreamException('OS image downloads must use https:// URLs');
    }
    final normalizedExpected = _normalizedSha256(expectedSha256);
    if (normalizedExpected == null) {
      throw UpstreamException('OS image downloads require a 64-hex sha256');
    }
    final safeDestPath = _validateManagedOsImageDest(destPath);
    await _clearStaleOsImagePart('$safeDestPath.part');
    final cachedSha = await _tryReuseOrClearLocalOsImage(
      safeDestPath,
      normalizedExpected,
      url,
    );
    if (cachedSha != null) {
      await _clearStaleOsImagePart('$safeDestPath.download.part');
      await _writeDownloadManifest(
        url: url,
        destPath: safeDestPath,
        expectedSha256: normalizedExpected,
        actualSha256: cachedSha,
        reused: true,
      );
      yield OsDownloadProgress(
        bytesDone: 0,
        bytesTotal: 0,
        phase: OsDownloadPhase.done,
        sha256: cachedSha,
        path: safeDestPath,
        reused: true,
      );
      return;
    }
    await requireHostApproved(_security, url);
    final host = parsed.host.toLowerCase();
    String? requestId;
    DateTime? startedAt;
    void recordDownloadStartIfNeeded() {
      if (requestId != null) return;
      requestId = _newEgressRequestId('os-download');
      startedAt = DateTime.now().toUtc();
      _security.recordEgress(
        EgressEvent(
          requestId: requestId!,
          host: host,
          url: url,
          method: 'GET',
          operationLabel: 'OS image download',
          startedAt: startedAt!,
        ),
      );
    }

    var bytesSeen = 0;
    var completed = false;
    try {
      await for (final progress
          in sidecar
              .callStreaming('os.download', {
                'url': url,
                'dest': safeDestPath,
                'sha256': normalizedExpected,
              })
              .transform(_osDownloadTransformer)) {
        if (progress.phase == OsDownloadPhase.downloading) {
          recordDownloadStartIfNeeded();
        }
        if (progress.bytesDone > bytesSeen) bytesSeen = progress.bytesDone;
        if (progress.phase == OsDownloadPhase.done) {
          final actualSha = _normalizedSha256(progress.sha256);
          if (actualSha == null) {
            throw UpstreamException(
              'os.download returned an invalid sha256 for $safeDestPath',
            );
          }
          final resultPath = progress.path == null
              ? safeDestPath
              : _validateSidecarResultPath(progress.path!);
          if (!_samePath(resultPath, safeDestPath)) {
            throw UpstreamException(
              'os.download returned unexpected path: $resultPath',
            );
          }
          await _writeDownloadManifest(
            url: url,
            destPath: resultPath,
            expectedSha256: normalizedExpected,
            actualSha256: actualSha,
            reused: progress.reused,
          );
          completed = true;
          if (requestId != null && startedAt != null) {
            _security.recordEgress(
              EgressEvent(
                requestId: requestId!,
                host: host,
                url: url,
                method: 'GET',
                operationLabel: 'OS image download',
                startedAt: startedAt!,
                completedAt: DateTime.now().toUtc(),
                bytes: bytesSeen == 0 ? null : bytesSeen,
                status: 200,
              ),
            );
          }
          yield OsDownloadProgress(
            bytesDone: progress.bytesDone,
            bytesTotal: progress.bytesTotal,
            phase: progress.phase,
            sha256: actualSha,
            path: resultPath,
            reused: progress.reused,
          );
          continue;
        }
        yield progress;
      }
    } catch (e) {
      if (!completed && requestId != null && startedAt != null) {
        _security.recordEgress(
          EgressEvent(
            requestId: requestId!,
            host: host,
            url: url,
            method: 'GET',
            operationLabel: 'OS image download',
            startedAt: startedAt!,
            completedAt: DateTime.now().toUtc(),
            bytes: bytesSeen == 0 ? null : bytesSeen,
            error: '$e',
          ),
        );
      }
      rethrow;
    }
  }

  Future<void> _writeDownloadManifest({
    required String url,
    required String destPath,
    required String expectedSha256,
    required String actualSha256,
    required bool reused,
  }) async {
    final manifest = File(_manifestPath(destPath));
    await manifest.parent.create(recursive: true);
    final manifestType = await FileSystemEntity.type(
      manifest.path,
      followLinks: false,
    );
    if (manifestType == FileSystemEntityType.link ||
        manifestType == FileSystemEntityType.directory) {
      throw UpstreamException(
        'download manifest path must be a regular file: ${manifest.path}',
      );
    }
    final downloadedAt = reused
        ? await _existingDownloadManifestDownloadedAt(manifest)
        : null;
    final now = DateTime.now().toUtc().toIso8601String();
    final body = const JsonEncoder.withIndent('  ').convert({
      'schema_version': 1,
      'url': url,
      'path': destPath,
      'expected_sha256': expectedSha256,
      'actual_sha256': actualSha256,
      'downloaded_at': ?downloadedAt,
      if (reused) 'reused_at': now else 'downloaded_at': now,
    });
    final tmp = File('${manifest.path}.tmp');
    final tmpType = await FileSystemEntity.type(tmp.path, followLinks: false);
    if (tmpType == FileSystemEntityType.link ||
        tmpType == FileSystemEntityType.directory) {
      throw UpstreamException(
        'download manifest temp path must be a regular file: ${tmp.path}',
      );
    }
    if (tmpType == FileSystemEntityType.file) {
      await tmp.delete();
    }
    await tmp.writeAsString(body, flush: true);
    try {
      await tmp.rename(manifest.path);
    } on FileSystemException {
      if (await manifest.exists()) await manifest.delete();
      await tmp.rename(manifest.path);
    }
  }

  String _manifestPath(String destPath) => '$destPath.deckhand-download.json';

  Future<String?> _existingDownloadManifestDownloadedAt(File manifest) async {
    final type = await FileSystemEntity.type(manifest.path, followLinks: false);
    if (type != FileSystemEntityType.file) return null;
    try {
      final decoded = _stringKeyMap(jsonDecode(await manifest.readAsString()));
      final downloadedAt = _jsonString(decoded?['downloaded_at']);
      if (downloadedAt == null || DateTime.tryParse(downloadedAt) == null) {
        return null;
      }
      return downloadedAt;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _tryReuseOrClearLocalOsImage(
    String destPath,
    String expectedSha256,
    String url,
  ) async {
    final type = await FileSystemEntity.type(destPath, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type == FileSystemEntityType.link ||
        type == FileSystemEntityType.directory) {
      throw UpstreamException(
        'cached OS image path must be a regular file: $destPath',
      );
    }
    if (_isXzUrl(url)) {
      if (await _hasXzMagic(destPath)) {
        await File(destPath).delete();
        return null;
      }
      final manifestSha = await _localManifestImageSha(
        destPath: destPath,
        expectedSha256: expectedSha256,
        url: url,
      );
      if (manifestSha == null) {
        await File(destPath).delete();
        return null;
      }
      final actual = await _hashLocalFile(destPath);
      if (actual == manifestSha) return actual;
      await File(destPath).delete();
      return null;
    }
    final actual = await _hashLocalFile(destPath);
    if (actual == expectedSha256) return actual;
    await File(destPath).delete();
    return null;
  }

  Future<void> _clearStaleOsImagePart(String partPath) async {
    final type = await FileSystemEntity.type(partPath, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type == FileSystemEntityType.link ||
        type == FileSystemEntityType.directory) {
      throw UpstreamException(
        'cached OS image partial path must be a regular file: $partPath',
      );
    }
    await File(partPath).delete();
  }

  bool _isXzUrl(String url) {
    final parsed = Uri.tryParse(url);
    return parsed != null && parsed.path.toLowerCase().endsWith('.xz');
  }

  Future<bool> _hasXzMagic(String path) async {
    final file = File(path);
    final stream = file.openRead(0, 6);
    final bytes = <int>[];
    await for (final chunk in stream) {
      bytes.addAll(chunk);
      if (bytes.length >= 6) break;
    }
    return bytes.length >= 6 &&
        bytes[0] == 0xfd &&
        bytes[1] == 0x37 &&
        bytes[2] == 0x7a &&
        bytes[3] == 0x58 &&
        bytes[4] == 0x5a &&
        bytes[5] == 0x00;
  }

  Future<String?> _localManifestImageSha({
    required String destPath,
    required String expectedSha256,
    required String url,
  }) async {
    final manifest = File(_manifestPath(destPath));
    final type = await FileSystemEntity.type(manifest.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type == FileSystemEntityType.link ||
        type == FileSystemEntityType.directory) {
      throw UpstreamException(
        'download manifest path must be a regular file: ${manifest.path}',
      );
    }
    final Map<String, dynamic>? decoded;
    try {
      decoded = _stringKeyMap(jsonDecode(await manifest.readAsString()));
    } catch (_) {
      return null;
    }
    if (decoded == null) return null;
    if (decoded['url'] != url ||
        decoded['path'] != destPath ||
        decoded['expected_sha256'] != expectedSha256) {
      return null;
    }
    final actualSha = _jsonString(decoded['actual_sha256']);
    final normalizedActualSha = _normalizedSha256(actualSha);
    if (normalizedActualSha == null) {
      return null;
    }
    return normalizedActualSha;
  }

  Future<String> _hashLocalFile(String path) async {
    final digest = await sha256.bind(File(path).openRead()).first;
    return digest.toString();
  }

  bool _matches(String name, String pattern) {
    // Very simple glob: `*.zip` / `*fluidd*.zip`. No regex surface.
    if (!pattern.contains('*')) return name == pattern;
    final parts = pattern.split('*');
    var pos = 0;
    for (final part in parts) {
      if (part.isEmpty) continue;
      final idx = name.indexOf(part, pos);
      if (idx < 0) return false;
      pos = idx + part.length;
    }
    return true;
  }

  List<Map<String, dynamic>> _releaseAssets(Object? value) {
    if (value is! List) return const [];
    final out = <Map<String, dynamic>>[];
    for (final item in value) {
      final map = _stringKeyMap(item);
      if (map != null) out.add(map);
    }
    return out;
  }

  String? _jsonString(Object? value) => value is String ? value : null;

  Map<String, dynamic>? _stringKeyMap(Object? value) {
    if (value is! Map) return null;
    final out = <String, dynamic>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is String) out[key] = entry.value;
    }
    return out;
  }

  void _validateReleaseRepoSlug(String repoSlug) {
    if (!RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(repoSlug)) {
      throw UpstreamException(
        'release repo slug must be "owner/repo" with no URL syntax',
      );
    }
  }

  void _validateAssetPattern(String pattern) {
    if (pattern.isEmpty ||
        pattern.contains('/') ||
        pattern.contains('\\') ||
        pattern == '.' ||
        pattern == '..') {
      throw UpstreamException('release asset pattern must be a file name glob');
    }
  }

  void _validateReleaseAssetName(String name) {
    if (name.isEmpty ||
        name.contains('/') ||
        name.contains('\\') ||
        name == '.' ||
        name == '..' ||
        p.basename(name) != name) {
      throw UpstreamException('unsafe release asset name: $name');
    }
  }

  String _validateManagedOsImageDest(String destPath) {
    final raw = destPath.trim();
    if (raw.isEmpty) {
      throw UpstreamException('OS image destination is required');
    }
    final normalizedSeparators = raw.replaceAll('\\', '/');
    if (normalizedSeparators.startsWith('//./') ||
        normalizedSeparators.startsWith('/dev/')) {
      throw UpstreamException(
        'OS image destination must be a regular file path',
      );
    }
    final parts = p.split(raw);
    if (parts.any((part) => part == '..')) {
      throw UpstreamException('OS image destination must not use traversal');
    }
    final clean = p.normalize(p.absolute(raw));
    if (p.extension(clean).toLowerCase() != '.img') {
      throw UpstreamException('OS image destination must end in .img');
    }
    if (p.basename(clean).isEmpty ||
        p.basename(clean) == '.' ||
        p.basename(clean) == '..') {
      throw UpstreamException('OS image destination must be a file name');
    }

    final configuredRoot =
        _osImagesDir ?? p.join(Directory.systemTemp.path, 'deckhand-os-images');
    if (configuredRoot.trim().isEmpty) {
      throw UpstreamException('Deckhand managed OS image cache is unset');
    }
    final managedRoot = p.normalize(p.absolute(configuredRoot));
    if (!_samePath(p.dirname(clean), managedRoot)) {
      throw UpstreamException(
        'OS image destination must be in Deckhand managed OS image cache',
      );
    }
    final rootType = FileSystemEntity.typeSync(managedRoot, followLinks: false);
    if (rootType == FileSystemEntityType.link ||
        (rootType != FileSystemEntityType.notFound &&
            rootType != FileSystemEntityType.directory)) {
      throw UpstreamException(
        'Deckhand managed OS image cache must be a real directory',
      );
    }
    return clean;
  }

  bool _samePath(String a, String b) {
    final left = p.normalize(p.absolute(a));
    final right = p.normalize(p.absolute(b));
    if (Platform.isWindows) {
      return left.toLowerCase() == right.toLowerCase();
    }
    return left == right;
  }

  String _validateSidecarResultPath(String path) {
    try {
      return _validateManagedOsImageDest(path);
    } on UpstreamException catch (e) {
      throw UpstreamException(
        'os.download returned unexpected path: $path (${e.message})',
      );
    }
  }

  String _newEgressRequestId(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}';
}

class UpstreamException implements Exception {
  UpstreamException(this.message);
  final String message;
  @override
  String toString() => 'UpstreamException: $message';
}

final _osDownloadTransformer =
    StreamTransformer<SidecarEvent, OsDownloadProgress>.fromHandlers(
      handleData: (event, sink) {
        switch (event) {
          case SidecarProgress(:final notification):
            final p = notification.params;
            final done = _eventInt(p['bytes_done']);
            final total = _eventInt(p['bytes_total']);
            final phase = _phaseFromString(_eventString(p['phase']));
            sink.add(
              OsDownloadProgress(
                bytesDone: done,
                bytesTotal: total,
                phase: phase,
              ),
            );
          case SidecarResult(:final result):
            sink.add(
              OsDownloadProgress(
                bytesDone: 0,
                bytesTotal: 0,
                phase: OsDownloadPhase.done,
                sha256: _eventString(result['sha256']),
                path: _eventString(result['path']),
                reused: _eventBool(result['reused']),
              ),
            );
        }
      },
    );

final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

String? _normalizedSha256(String? value) {
  final normalized = value?.trim().toLowerCase();
  if (normalized == null || !_sha256Pattern.hasMatch(normalized)) return null;
  return normalized;
}

String? _eventString(Object? value) => value is String ? value : null;

bool _eventBool(Object? value) => value is bool && value;

int _eventInt(Object? value) {
  if (value is! num || !value.isFinite || value <= 0) return 0;
  return value.toInt();
}

OsDownloadPhase _phaseFromString(String? s) => switch (s) {
  'downloading' => OsDownloadPhase.downloading,
  'extracting' => OsDownloadPhase.extracting,
  'done' => OsDownloadPhase.done,
  'failed' => OsDownloadPhase.failed,
  _ => OsDownloadPhase.downloading,
};
