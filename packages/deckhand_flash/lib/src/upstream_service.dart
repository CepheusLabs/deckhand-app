import 'dart:async';
import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import 'sidecar_client.dart';

/// [UpstreamService] - git clones via the sidecar, release assets over
/// HTTPS using Dio + GitHub's Releases API.
class SidecarUpstreamService implements UpstreamService {
  SidecarUpstreamService({required this.sidecar, Dio? dio})
    : _dio = dio ?? Dio();

  final SidecarClient sidecar;
  final Dio _dio;

  @override
  Future<UpstreamFetchResult> gitFetch({
    required String repoUrl,
    required String ref,
    required String destPath,
    int depth = 1,
  }) async {
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
    String? tag,
  }) async {
    final url = tag == null
        ? 'https://api.github.com/repos/$repoSlug/releases/latest'
        : 'https://api.github.com/repos/$repoSlug/releases/tags/$tag';

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

    final outPath = p.join(destPath, assetName);
    await Directory(destPath).create(recursive: true);
    await _dio.download(dlUrl, outPath);

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
  }) {
    return sidecar
        .callStreaming('os.download', {
          'url': url,
          'dest': destPath,
          if (expectedSha256 != null) 'sha256': expectedSha256,
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
