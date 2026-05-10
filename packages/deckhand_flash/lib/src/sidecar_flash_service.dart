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
    final rawDisks = _jsonList(res['disks']);
    final disks = <DiskInfo>[];
    for (final raw in rawDisks) {
      final disk = _diskFromJson(_stringKeyMap(raw));
      if (disk != null) disks.add(disk);
    }
    return disks;
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
    return _jsonString(res['sha256']) ?? '';
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
  'is_boot': disk.isBoot,
  'is_system': disk.isSystem,
  'is_read_only': disk.isReadOnly,
  'is_offline': disk.isOffline,
  'partitions': disk.partitions.map(_partToJson).toList(),
};

Map<String, dynamic> _partToJson(PartitionInfo part) => {
  'index': part.index,
  'filesystem': part.filesystem,
  'size_bytes': part.sizeBytes,
  if (part.mountpoint != null) 'mountpoint': part.mountpoint,
};

FlashSafetyVerdict _safetyVerdictFromJson(Map raw) {
  final json = _stringKeyMap(raw) ?? const <String, dynamic>{};
  return FlashSafetyVerdict(
    diskId: _jsonString(json['disk_id']) ?? '',
    allowed: json['allowed'] == true,
    blockingReasons: _jsonList(
      json['blocking_reasons'],
    ).map((e) => e.toString()).toList(),
    warnings: _jsonList(json['warnings']).map((e) => e.toString()).toList(),
  );
}

DiskInfo? _diskFromJson(Map<String, dynamic>? raw) {
  if (raw == null) return null;
  final id = _jsonString(raw['id']);
  final path = _jsonString(raw['path']);
  final sizeBytes = _jsonInt(raw['size_bytes']);
  if (id == null || path == null || sizeBytes == null) return null;
  final parts = <PartitionInfo>[];
  for (final rawPart in _jsonList(raw['partitions'])) {
    final part = _partFromJson(_stringKeyMap(rawPart));
    if (part != null) parts.add(part);
  }
  return DiskInfo(
    id: id,
    path: path,
    sizeBytes: sizeBytes,
    bus: _jsonString(raw['bus']) ?? 'Unknown',
    model: _jsonString(raw['model']) ?? 'Unknown disk',
    removable: raw['removable'] == true,
    isBoot: raw['is_boot'] == true,
    isSystem: raw['is_system'] == true,
    isReadOnly: raw['is_read_only'] == true,
    isOffline: raw['is_offline'] == true,
    partitions: parts,
    interruptedFlash: _interruptedFlashFromJson(raw['interrupted_flash']),
  );
}

PartitionInfo? _partFromJson(Map<String, dynamic>? raw) {
  if (raw == null) return null;
  final index = _jsonInt(raw['index']);
  if (index == null) return null;
  return PartitionInfo(
    index: index,
    filesystem: _jsonString(raw['filesystem']) ?? '',
    sizeBytes: _jsonInt(raw['size_bytes']) ?? 0,
    mountpoint: _jsonString(raw['mountpoint']),
  );
}

InterruptedFlashInfo? _interruptedFlashFromJson(Object? raw) {
  final map = _stringKeyMap(raw);
  if (map == null) return null;
  final startedRaw = _jsonString(map['started_at']);
  final imageRaw = _jsonString(map['image_path']);
  if (startedRaw == null || imageRaw == null) return null;
  final startedAt = DateTime.tryParse(startedRaw)?.toUtc();
  if (startedAt == null) return null;
  final shaRaw = _jsonString(map['image_sha256']);
  return InterruptedFlashInfo(
    startedAt: startedAt,
    imagePath: imageRaw,
    imageSha256: shaRaw != null && shaRaw.isNotEmpty ? shaRaw : null,
  );
}

final _flashEventTransformer =
    StreamTransformer<SidecarEvent, FlashProgress>.fromHandlers(
      handleData: (event, sink) {
        switch (event) {
          case SidecarProgress(:final notification):
            final p = notification.params;
            final done = _jsonInt(p['bytes_done']) ?? 0;
            final total = _jsonInt(p['bytes_total']) ?? 0;
            final phase = _phaseFromString(_jsonString(p['phase']));
            sink.add(
              FlashProgress(
                bytesDone: done,
                bytesTotal: total,
                phase: phase,
                message: _jsonString(p['message']),
              ),
            );
          case SidecarResult(:final result):
            final done = _jsonInt(result['bytes']) ?? 0;
            sink.add(
              FlashProgress(
                bytesDone: done,
                bytesTotal: done,
                phase: FlashPhase.done,
                message: _jsonString(result['sha256']),
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

String? _jsonString(Object? value) => value is String ? value : null;

int? _jsonInt(Object? value) {
  if (value is! num || !value.isFinite) return null;
  return value.toInt();
}

List<Object?> _jsonList(Object? value) => value is List ? value : const [];

Map<String, dynamic>? _stringKeyMap(Object? value) {
  if (value is! Map) return null;
  final out = <String, dynamic>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is String) out[key] = entry.value;
  }
  return out;
}
