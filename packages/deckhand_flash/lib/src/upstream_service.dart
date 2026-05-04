import 'dart:async';
import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import 'egress_interceptor.dart';
import 'github_token_interceptor.dart';
import 'sidecar_client.dart';

/// [UpstreamService] - git clones via the sidecar, release assets over
/// HTTPS using Dio + GitHub's Releases API.
///
/// Every method that issues an outbound network call gates on the
/// user's host allowlist via [requireHostApproved]. A
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
  }) : _security = security,
       _dio = (dio ?? Dio())
         // Token interceptor runs first so it sees the un-mutated
         // request and can inject the auth header before the egress
         // logger snapshots the URL/headers.
         ..interceptors.add(GitHubTokenInterceptor(security))
         ..interceptors.add(EgressLogInterceptor(security));

  final SidecarConnection sidecar;
  final SecurityService _security;
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
    return UpstreamFetchResult(
      localPath: res['local_path'] as String,
      resolvedRef: res['resolved_ref'] as String? ?? ref,
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
    final normalizedExpected = expectedSha256.trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(normalizedExpected)) {
      throw UpstreamException(
        'release asset $repoSlug/$assetPattern has invalid sha256',
      );
    }

    final url = tag == null
        ? 'https://api.github.com/repos/$repoSlug/releases/latest'
        : 'https://api.github.com/repos/$repoSlug/releases/tags/$tag';

    await requireHostApproved(_security, url);
    final relResp = await _dio.get<Map<String, dynamic>>(url);
    final rel = relResp.data ?? const {};
    final tagName = rel['tag_name'] as String? ?? tag ?? 'unknown';
    final assets = ((rel['assets'] as List?) ?? const []).cast<Map>();
    final match = assets.firstWhere(
      (a) => _matches((a['name'] as String?) ?? '', assetPattern),
      orElse: () => const <String, dynamic>{},
    );
    if (match.isEmpty) {
      throw UpstreamException(
        'no asset in $repoSlug@$tagName matches "$assetPattern"',
      );
    }
    final dlUrl = match['browser_download_url'] as String;
    final assetName = match['name'] as String;
    _validateReleaseAssetName(assetName);
    await requireHostApproved(_security, dlUrl);

    final outPath = p.join(destPath, assetName);
    await Directory(destPath).create(recursive: true);
    await _dio.download(dlUrl, outPath);
    final hashRes = await sidecar.call('disks.hash', {'path': outPath});
    final actualSha = (hashRes['sha256'] as String? ?? '').trim().toLowerCase();
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
    final normalizedExpected = expectedSha256?.trim().toLowerCase();
    if (normalizedExpected == null ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(normalizedExpected)) {
      throw UpstreamException('OS image downloads require a 64-hex sha256');
    }
    await requireHostApproved(_security, url);
    yield* sidecar
        .callStreaming('os.download', {
          'url': url,
          'dest': destPath,
          'sha256': normalizedExpected,
        })
        .transform(_osDownloadTransformer);
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
            final done = (p['bytes_done'] as num?)?.toInt() ?? 0;
            final total = (p['bytes_total'] as num?)?.toInt() ?? 0;
            final phase = _phaseFromString(p['phase'] as String?);
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
                sha256: result['sha256'] as String?,
                path: result['path'] as String?,
              ),
            );
        }
      },
    );

OsDownloadPhase _phaseFromString(String? s) => switch (s) {
  'downloading' => OsDownloadPhase.downloading,
  'done' => OsDownloadPhase.done,
  'failed' => OsDownloadPhase.failed,
  _ => OsDownloadPhase.downloading,
};
