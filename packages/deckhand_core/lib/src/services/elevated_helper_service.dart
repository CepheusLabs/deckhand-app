/// Launches the `deckhand-elevated-helper` binary with platform-native
/// privilege elevation (UAC on Windows, osascript on macOS, pkexec on
/// Linux) to perform raw-device writes.
///
/// The sidecar itself runs unprivileged; only this helper binary needs
/// admin/root. See [docs/ARCHITECTURE.md] for the threat model.
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
}
