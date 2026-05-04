import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Writes and clears flash-sentinel files that record an in-flight flash
/// to a given disk. The sidecar's `disks.list` reads these to surface
/// "this disk has an interrupted Deckhand flash" warnings to the user
/// after a crash or power loss mid-write.
///
/// The contract is intentionally simple: write the sentinel **before**
/// launching the elevated helper, clear it **only** after observing
/// `event: done` from the helper. Anything else — helper crash, host
/// crash, power loss, user abort — leaves the sentinel in place. The
/// next `disks.list` call will surface it.
///
/// See [docs/ARCHITECTURE.md](../../../docs/ARCHITECTURE.md) (security
/// model — interrupted-flash detection) for the design notes.
class FlashSentinelWriter {
  FlashSentinelWriter({required this.directory});

  /// Directory where sentinels are written. Production wiring passes
  /// `<data_dir>/Deckhand/state/flash-sentinels/` from
  /// `host.info.data_dir`.
  final String directory;

  static final RegExp _safeIdRe = RegExp(r'[^A-Za-z0-9._-]');

  /// Returns the canonical sentinel path for [diskId]. Exposed for
  /// tests; production callers go through [write] / [clear].
  String sentinelPath(String diskId) {
    final safe = diskId.replaceAllMapped(
      _safeIdRe,
      (m) => '_${m.group(0)!.codeUnitAt(0).toRadixString(16).toUpperCase().padLeft(2, '0')}',
    );
    return p.join(directory, '$safe.json');
  }

  /// Persist a sentinel for [diskId] before launching the helper.
  /// Idempotent — overwrites any prior sentinel for the same disk.
  Future<void> write({
    required String diskId,
    required String imagePath,
    String? imageSha256,
  }) async {
    final dir = Directory(directory);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final payload = <String, Object>{
      'schema': 'deckhand.flash_sentinel/1',
      'disk_id': diskId,
      'started_at': DateTime.now().toUtc().toIso8601String(),
      'image_path': imagePath,
      // ignore: use_null_aware_elements
      if (imageSha256 != null) 'image_sha256': imageSha256,
    };
    final tmp = File('${sentinelPath(diskId)}.tmp');
    await tmp.writeAsString(jsonEncode(payload));
    await tmp.rename(sentinelPath(diskId));
  }

  /// Remove the sentinel for [diskId]. Best-effort: a missing file is
  /// not an error (the helper might have already cleared it, or the
  /// sentinel was never written because the directory was unwritable).
  Future<void> clear(String diskId) async {
    final f = File(sentinelPath(diskId));
    try {
      if (await f.exists()) {
        await f.delete();
      }
    } on FileSystemException {
      // Tolerate locked/perm-denied rather than poisoning the wider
      // success path. The sidecar's stale-sentinel cutoff (7 days)
      // will eventually retire the entry.
    }
  }
}
