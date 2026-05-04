import 'dart:async';

import 'package:deckhand_core/deckhand_core.dart';

import 'sidecar_client.dart';

/// [FlashService] that delegates every operation to the Go sidecar.
///
/// Dry-run: when [dryRun] is true every destructive side effect is
/// replaced by a synthetic progress stream that reports a realistic
/// phase sequence without touching the disk. The UI can remain
/// unchanged; only the service layer is aware.
class SidecarFlashService implements FlashService {
  SidecarFlashService(this._client, {this.dryRun = false});

  final SidecarConnection _client;
  final bool dryRun;

  @override
  Future<List<DiskInfo>> listDisks() async {
    final res = await _client.call('disks.list', const {});
    final disks = (res['disks'] as List? ?? const []).cast<Map>();
    return disks.map(_diskFromJson).toList();
  }

  @override
  Future<FlashSafetyVerdict> safetyCheck({required String diskId}) async {
    if (dryRun) {
      return FlashSafetyVerdict(diskId: diskId, allowed: true);
    }
    final disks = await listDisks();
    DiskInfo? disk;
    for (final candidate in disks) {
      if (candidate.id == diskId) {
        disk = candidate;
        break;
      }
    }
    if (disk == null) {
      throw StateError('disk not found during safety check: $diskId');
    }
    final res = await _client.call('disks.safety_check', {
      'disk': _diskToJson(disk),
    });
    return _safetyVerdictFromJson(res);
  }

  @override
  Stream<FlashProgress> writeImage({
    required String imagePath,
    required String diskId,
    required String confirmationToken,
    bool verifyAfterWrite = true,
  }) {
    if (dryRun) {
      return _simulatedProgress(label: 'DRY-RUN write $imagePath -> $diskId');
    }
    return _client
        .callStreaming('disks.write_image', {
          'image_path': imagePath,
          'disk_id': diskId,
          'confirmation_token': confirmationToken,
          'verify': verifyAfterWrite,
        })
        .transform(_flashEventTransformer);
  }

  @override
  Stream<FlashProgress> readImage({
    required String diskId,
    required String outputPath,
  }) {
    if (dryRun) {
      return _simulatedProgress(label: 'DRY-RUN read $diskId -> $outputPath');
    }
    return _client
        .callStreaming('disks.read_image', {
          'device_id': diskId,
          'output': outputPath,
        })
        .transform(_flashEventTransformer);
  }

  @override
  Future<String> sha256(String path) async {
    if (dryRun) {
      // Return a deterministic, clearly-synthetic digest so callers
      // don't branch on real vs. dry-run at the type level.
      return 'dryrun' * 10 + 'dddd';
    }
    final res = await _client.call('disks.hash', {'path': path});
    return res['sha256'] as String;
  }
}

Stream<FlashProgress> _simulatedProgress({required String label}) async* {
  yield FlashProgress(
    bytesDone: 0,
    bytesTotal: 1024 * 1024 * 1024,
    phase: FlashPhase.preparing,
    message: label,
  );
  await Future<void>.delayed(const Duration(milliseconds: 250));
  for (final pct in const [0.25, 0.5, 0.75, 1.0]) {
    final total = 1024 * 1024 * 1024;
    yield FlashProgress(
      bytesDone: (total * pct).round(),
      bytesTotal: total,
      phase: FlashPhase.writing,
      message: label,
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  yield FlashProgress(
    bytesDone: 1024 * 1024 * 1024,
    bytesTotal: 1024 * 1024 * 1024,
    phase: FlashPhase.done,
    message: '$label (simulated)',
  );
}

Map<String, dynamic> _diskToJson(DiskInfo disk) => {
  'id': disk.id,
  'path': disk.path,
  'size_bytes': disk.sizeBytes,
  'bus': disk.bus,
  'model': disk.model,
  'removable': disk.removable,
  'partitions': disk.partitions.map(_partToJson).toList(),
};

Map<String, dynamic> _partToJson(PartitionInfo part) => {
  'index': part.index,
  'filesystem': part.filesystem,
  'size_bytes': part.sizeBytes,
  if (part.mountpoint != null) 'mountpoint': part.mountpoint,
};

FlashSafetyVerdict _safetyVerdictFromJson(Map raw) => FlashSafetyVerdict(
  diskId: raw['disk_id'] as String? ?? '',
  allowed: raw['allowed'] as bool? ?? false,
  blockingReasons: ((raw['blocking_reasons'] as List?) ?? const [])
      .map((e) => e.toString())
      .toList(),
  warnings: ((raw['warnings'] as List?) ?? const [])
      .map((e) => e.toString())
      .toList(),
);

DiskInfo _diskFromJson(Map raw) {
  final parts = ((raw['partitions'] as List?) ?? const []).cast<Map>();
  return DiskInfo(
    id: raw['id'] as String,
    path: raw['path'] as String,
    sizeBytes: (raw['size_bytes'] as num).toInt(),
    bus: raw['bus'] as String? ?? 'Unknown',
    model: raw['model'] as String? ?? 'Unknown disk',
    removable: raw['removable'] as bool? ?? false,
    partitions: parts.map(_partFromJson).toList(),
  );
}

PartitionInfo _partFromJson(Map raw) => PartitionInfo(
  index: (raw['index'] as num).toInt(),
  filesystem: raw['filesystem'] as String? ?? '',
  sizeBytes: (raw['size_bytes'] as num?)?.toInt() ?? 0,
  mountpoint: raw['mountpoint'] as String?,
);

final _flashEventTransformer =
    StreamTransformer<SidecarEvent, FlashProgress>.fromHandlers(
      handleData: (event, sink) {
        switch (event) {
          case SidecarProgress(:final notification):
            final p = notification.params;
            final done = (p['bytes_done'] as num?)?.toInt() ?? 0;
            final total = (p['bytes_total'] as num?)?.toInt() ?? 0;
            final phase = _phaseFromString(p['phase'] as String?);
            sink.add(
              FlashProgress(
                bytesDone: done,
                bytesTotal: total,
                phase: phase,
                message: p['message'] as String?,
              ),
            );
          case SidecarResult(:final result):
            final done = (result['bytes'] as num?)?.toInt() ?? 0;
            sink.add(
              FlashProgress(
                bytesDone: done,
                bytesTotal: done,
                phase: FlashPhase.done,
                message: result['sha256'] as String?,
              ),
            );
        }
      },
    );

FlashPhase _phaseFromString(String? s) => switch (s) {
  'reading' || 'writing' => FlashPhase.writing,
  'verifying' || 'write-complete' || 'verified' => FlashPhase.verifying,
  'done' => FlashPhase.done,
  'failed' => FlashPhase.failed,
  _ => FlashPhase.preparing,
};
