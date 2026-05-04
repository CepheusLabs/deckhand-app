// Launches the `deckhand-elevated-helper` binary with platform-native
// privilege elevation (UAC on Windows, osascript on macOS, pkexec on
// Linux) to perform raw-device writes.
//
// The sidecar itself runs unprivileged; only this helper binary needs
// admin/root. See docs/ARCHITECTURE.md for the threat model.
import 'flash_service.dart';

abstract class ElevatedHelperService {
  /// Spawn the helper with elevation and write [imagePath] to [diskId].
  /// Streams progress events parsed from the helper's line-delimited
  /// JSON stdout. Stream closes on completion or errors on failure.
  Stream<FlashProgress> writeImage({
    required String imagePath,
    required String diskId,
    required String confirmationToken,
    bool verifyAfterWrite = true,
    String? expectedSha256,
  });

  /// Spawn the helper with elevation and read [diskId] (raw block
  /// device) into [outputPath], hashing as it goes. Counterpart to
  /// [writeImage] for the "back up the eMMC before the install
  /// rewrites it" flow on platforms where the unprivileged sidecar
  /// can't open raw devices (Windows).
  ///
  /// [totalBytes] is an optional size hint. Windows raw devices
  /// (\\.\PhysicalDriveN) report 0 from both `Stat()` and
  /// `Seek(0, SeekEnd)` — without a hint the helper emits
  /// `bytes_total: 0` for every progress event and the UI can't
  /// render a percentage or a meaningful "X of Y" label. Pass the
  /// `DiskInfo.sizeBytes` you already showed the user on the
  /// upstream picker. Zero (default) means "no hint, helper guesses
  /// from the device handle."
  ///
  /// [outputRoot] optionally narrows the helper's allowed backup root
  /// for this invocation. Production uses this when the user picks a
  /// different eMMC backup destination; implementations must still
  /// enforce their own output-path policy before opening [outputPath].
  Stream<FlashProgress> readImage({
    required String diskId,
    required String outputPath,
    required String confirmationToken,
    int totalBytes = 0,
    String? outputRoot,
  });
}
