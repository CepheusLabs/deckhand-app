/// Fetch upstream source (Kalico/Klipper/Moonraker) or release assets
/// (Fluidd/Mainsail) into the local cache for install.
abstract class UpstreamService {
  /// Shallow-clone [repoUrl] at [ref] into the cache.
  Future<UpstreamFetchResult> gitFetch({
    required String repoUrl,
    required String ref,
    required String destPath,
    int depth = 1,
  });

  /// Download a GitHub Releases asset matching [assetPattern] from
  /// [repoSlug] (e.g. `fluidd-core/fluidd`), optionally pinned to [tag].
  /// [expectedSha256] is required so release assets get the same
  /// artifact-integrity guarantee as OS images.
  Future<UpstreamFetchResult> releaseFetch({
    required String repoSlug,
    required String assetPattern,
    required String destPath,
    required String expectedSha256,
    String? tag,
  });

  /// Stream a full-image download (base Linux OS image) to [destPath].
  /// Implementations must require a 64-hex [expectedSha256] before
  /// issuing network traffic or returning an image path.
  Stream<OsDownloadProgress> osDownload({
    required String url,
    required String destPath,
    String? expectedSha256,
  });
}

class UpstreamFetchResult {
  const UpstreamFetchResult({
    required this.localPath,
    required this.resolvedRef,
    this.assetName,
  });
  final String localPath;
  final String resolvedRef;
  final String? assetName;
}

/// Progress event emitted while an OS image is streaming to disk.
class OsDownloadProgress {
  const OsDownloadProgress({
    required this.bytesDone,
    required this.bytesTotal,
    required this.phase,
    this.sha256,
    this.path,
    this.reused = false,
  });
  final int bytesDone;
  final int bytesTotal;
  final OsDownloadPhase phase;
  final String? sha256;
  final String? path;
  final bool reused;

  double get fraction => bytesTotal == 0 ? 0 : bytesDone / bytesTotal;
}

enum OsDownloadPhase { downloading, extracting, done, failed }
