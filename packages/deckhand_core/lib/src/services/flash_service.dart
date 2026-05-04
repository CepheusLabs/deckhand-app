/// Local disk enumeration and image flashing.
///
/// Implementations: `SidecarFlashService` (Go sidecar adapter) for the
/// Deckhand desktop app. Tests wire fakes.
abstract class FlashService {
  /// Enumerate local disks. USB/removable first.
  Future<List<DiskInfo>> listDisks();

  /// Re-probe [diskId] and return the sidecar's destructive-write
  /// safety verdict for the live disk currently attached at that id.
  Future<FlashSafetyVerdict> safetyCheck({required String diskId});

  /// Stream progress events while writing [imagePath] to [diskId].
  /// [confirmationToken] is the UI-flow nonce issued by [SecurityService].
  /// Callers must run [safetyCheck] immediately before invoking this path.
  Stream<FlashProgress> writeImage({
    required String imagePath,
    required String diskId,
    required String confirmationToken,
    bool verifyAfterWrite = true,
  });

  /// Stream progress events while dd-ing [diskId] into a file at [outputPath].
  Stream<FlashProgress> readImage({
    required String diskId,
    required String outputPath,
  });

  /// Streaming SHA-256 of a local file. Used for integrity verification.
  Future<String> sha256(String path);
}

class DiskInfo {
  const DiskInfo({
    required this.id,
    required this.path,
    required this.sizeBytes,
    required this.bus,
    required this.model,
    required this.removable,
    required this.partitions,
  });

  final String id;
  final String path;
  final int sizeBytes;
  final String bus;
  final String model;
  final bool removable;
  final List<PartitionInfo> partitions;
}

class FlashSafetyVerdict {
  const FlashSafetyVerdict({
    required this.diskId,
    required this.allowed,
    this.blockingReasons = const [],
    this.warnings = const [],
  });

  final String diskId;
  final bool allowed;
  final List<String> blockingReasons;
  final List<String> warnings;
}

class PartitionInfo {
  const PartitionInfo({
    required this.index,
    required this.filesystem,
    required this.sizeBytes,
    this.mountpoint,
  });
  final int index;
  final String filesystem;
  final int sizeBytes;
  final String? mountpoint;
}

class FlashProgress {
  const FlashProgress({
    required this.bytesDone,
    required this.bytesTotal,
    required this.phase,
    this.message,
  });
  final int bytesDone;
  final int bytesTotal;
  final FlashPhase phase;
  final String? message;
  double get fraction => bytesTotal == 0 ? 0 : bytesDone / bytesTotal;
}

enum FlashPhase { preparing, writing, verifying, done, failed }
