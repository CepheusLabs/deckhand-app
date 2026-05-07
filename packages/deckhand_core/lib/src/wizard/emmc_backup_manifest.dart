import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../services/flash_service.dart';

const int emmcBackupManifestSchema = 1;

String emmcBackupManifestPath(String imagePath) => '$imagePath.manifest.json';

String emmcBackupImagePath({
  required String rootDir,
  required String profileId,
  required DateTime createdAt,
}) {
  final profileSlug = _slugSegment(profileId);
  final utc = createdAt.toUtc();
  final stamp =
      '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}T'
      '${utc.hour.toString().padLeft(2, '0')}-'
      '${utc.minute.toString().padLeft(2, '0')}-'
      '${utc.second.toString().padLeft(2, '0')}Z';
  return _pathContextForRoot(
    rootDir,
  ).join(rootDir, profileSlug, stamp, 'emmc.img');
}

class EmmcBackupManifest {
  const EmmcBackupManifest({
    required this.schemaVersion,
    required this.createdAt,
    required this.profileId,
    required this.imagePath,
    required this.imageBytes,
    required this.imageSha256,
    required this.disk,
    required this.deckhandVersion,
  });

  factory EmmcBackupManifest.create({
    required String profileId,
    required String imagePath,
    required int imageBytes,
    required String imageSha256,
    required DiskInfo disk,
    required String deckhandVersion,
    DateTime? createdAt,
  }) {
    return EmmcBackupManifest(
      schemaVersion: emmcBackupManifestSchema,
      createdAt: createdAt ?? DateTime.now().toUtc(),
      profileId: profileId,
      imagePath: imagePath,
      imageBytes: imageBytes,
      imageSha256: imageSha256,
      disk: EmmcBackupDiskIdentity.fromDisk(disk),
      deckhandVersion: deckhandVersion,
    );
  }

  factory EmmcBackupManifest.fromJson(Map<String, dynamic> json) {
    return EmmcBackupManifest(
      schemaVersion: (json['schema_version'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.parse(json['created_at'] as String),
      profileId: json['profile_id'] as String? ?? '',
      imagePath: json['image_path'] as String? ?? '',
      imageBytes: (json['image_bytes'] as num?)?.toInt() ?? 0,
      imageSha256: json['image_sha256'] as String? ?? '',
      disk: EmmcBackupDiskIdentity.fromJson(
        (json['disk'] as Map).cast<String, dynamic>(),
      ),
      deckhandVersion: json['deckhand_version'] as String? ?? '',
    );
  }

  final int schemaVersion;
  final DateTime createdAt;
  final String profileId;
  final String imagePath;
  final int imageBytes;
  final String imageSha256;
  final EmmcBackupDiskIdentity disk;
  final String deckhandVersion;

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'created_at': createdAt.toUtc().toIso8601String(),
    'profile_id': profileId,
    'image_path': imagePath,
    'image_bytes': imageBytes,
    'image_sha256': imageSha256,
    'disk': disk.toJson(),
    'deckhand_version': deckhandVersion,
  };

  bool matches({required String profileId, required DiskInfo disk}) {
    return schemaVersion == emmcBackupManifestSchema &&
        this.profileId == profileId &&
        imageBytes == disk.sizeBytes &&
        this.disk.matches(disk);
  }
}

class EmmcBackupDiskIdentity {
  const EmmcBackupDiskIdentity({
    required this.id,
    required this.path,
    required this.sizeBytes,
    required this.bus,
    required this.model,
    required this.removable,
  });

  factory EmmcBackupDiskIdentity.fromDisk(DiskInfo disk) {
    return EmmcBackupDiskIdentity(
      id: disk.id,
      path: disk.path,
      sizeBytes: disk.sizeBytes,
      bus: disk.bus,
      model: disk.model,
      removable: disk.removable,
    );
  }

  factory EmmcBackupDiskIdentity.fromJson(Map<String, dynamic> json) {
    return EmmcBackupDiskIdentity(
      id: json['id'] as String? ?? '',
      path: json['path'] as String? ?? '',
      sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
      bus: json['bus'] as String? ?? '',
      model: json['model'] as String? ?? '',
      removable: json['removable'] as bool? ?? false,
    );
  }

  final String id;
  final String path;
  final int sizeBytes;
  final String bus;
  final String model;
  final bool removable;

  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    'size_bytes': sizeBytes,
    'bus': bus,
    'model': model,
    'removable': removable,
  };

  bool matches(DiskInfo disk) {
    if (sizeBytes != disk.sizeBytes) return false;
    if (_sameStableValue(id, disk.id)) return true;
    if (_sameStableValue(path, disk.path)) return true;
    if (_isGenericUsbIdentity(model, bus) ||
        _isGenericUsbIdentity(disk.model, disk.bus)) {
      return false;
    }
    return _sameStableValue(model, disk.model) &&
        _sameStableValue(bus, disk.bus);
  }

  static bool _sameStableValue(String a, String b) {
    final left = a.trim().toLowerCase();
    final right = b.trim().toLowerCase();
    return left.isNotEmpty && left == right;
  }

  static bool _isGenericUsbIdentity(String model, String bus) {
    final m = model.trim().toLowerCase();
    final b = bus.trim().toLowerCase();
    if (b != 'usb') return false;
    return m.isEmpty ||
        m == 'generic storage device' ||
        m == 'usb storage device' ||
        m.contains('generic') ||
        m.contains('storage device');
  }
}

class EmmcBackupImageCandidate {
  const EmmcBackupImageCandidate({
    required this.imagePath,
    required this.imageBytes,
    required this.modifiedAt,
    required this.inferredProfileId,
  });

  final String imagePath;
  final int imageBytes;
  final DateTime modifiedAt;
  final String? inferredProfileId;

  bool matches({required String profileId, required DiskInfo disk}) {
    if (imageBytes != disk.sizeBytes) return false;
    final inferred = inferredProfileId;
    return inferred == null || inferred == profileId;
  }
}

class EmmcBackupOrganizeResult {
  const EmmcBackupOrganizeResult({required this.moves, required this.failures});

  final List<EmmcBackupOrganizedMove> moves;
  final List<EmmcBackupOrganizeFailure> failures;

  int get moved => moves.length;
  bool get hasFailures => failures.isNotEmpty;
}

class EmmcBackupOrganizedMove {
  const EmmcBackupOrganizedMove({
    required this.fromImagePath,
    required this.toImagePath,
    required this.toManifestPath,
  });

  final String fromImagePath;
  final String toImagePath;
  final String? toManifestPath;
}

class EmmcBackupOrganizeFailure {
  const EmmcBackupOrganizeFailure({
    required this.imagePath,
    required this.message,
  });

  final String imagePath;
  final String message;
}

Future<String> writeEmmcBackupManifest(EmmcBackupManifest manifest) async {
  final manifestPath = emmcBackupManifestPath(manifest.imagePath);
  await Directory(p.dirname(manifestPath)).create(recursive: true);
  await File(manifestPath).writeAsString(
    const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
    flush: true,
  );
  return manifestPath;
}

Future<EmmcBackupOrganizeResult> organizeLegacyEmmcBackups(String dir) async {
  final root = Directory(dir);
  if (!await root.exists()) {
    return const EmmcBackupOrganizeResult(moves: [], failures: []);
  }
  final moves = <EmmcBackupOrganizedMove>[];
  final failures = <EmmcBackupOrganizeFailure>[];
  await for (final entity in root.list(followLinks: false)) {
    if (entity is! File || !entity.path.toLowerCase().endsWith('.img')) {
      continue;
    }
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    if (type != FileSystemEntityType.file) continue;
    try {
      final moved = await _organizeLooseBackupImage(
        rootDir: dir,
        image: entity,
      );
      if (moved != null) moves.add(moved);
    } catch (e) {
      failures.add(
        EmmcBackupOrganizeFailure(imagePath: entity.path, message: '$e'),
      );
    }
  }
  return EmmcBackupOrganizeResult(moves: moves, failures: failures);
}

Future<List<EmmcBackupManifest>> scanEmmcBackupManifests(String dir) async {
  final root = Directory(dir);
  if (!await root.exists()) return const [];
  final manifests = <EmmcBackupManifest>[];
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File || !entity.path.endsWith('.manifest.json')) {
      continue;
    }
    final manifest = await _readManifest(entity);
    if (manifest == null) continue;
    final image = File(manifest.imagePath);
    if (!await image.exists()) continue;
    if (await image.length() != manifest.imageBytes) continue;
    manifests.add(manifest);
  }
  manifests.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return manifests;
}

Future<List<EmmcBackupImageCandidate>> scanEmmcBackupImageCandidates(
  String dir,
) async {
  final root = Directory(dir);
  if (!await root.exists()) return const [];
  final candidates = <EmmcBackupImageCandidate>[];
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File || !entity.path.toLowerCase().endsWith('.img')) {
      continue;
    }
    final stat = await entity.stat();
    if (stat.type != FileSystemEntityType.file || stat.size <= 0) continue;
    candidates.add(
      EmmcBackupImageCandidate(
        imagePath: entity.path,
        imageBytes: stat.size,
        modifiedAt: stat.modified,
        inferredProfileId: inferEmmcBackupProfileId(entity.path),
      ),
    );
  }
  candidates.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
  return candidates;
}

Future<EmmcBackupOrganizedMove?> _organizeLooseBackupImage({
  required String rootDir,
  required File image,
}) async {
  final stat = await image.stat();
  if (stat.type != FileSystemEntityType.file || stat.size <= 0) return null;

  final oldManifestFile = File(emmcBackupManifestPath(image.path));
  final oldManifestExists = await oldManifestFile.exists();
  final oldManifest = oldManifestExists
      ? await _readManifest(oldManifestFile)
      : null;
  final profileId =
      _nonEmptyOrNull(oldManifest?.profileId) ??
      inferEmmcBackupProfileId(image.path) ??
      'unknown-profile';
  final createdAt =
      oldManifest?.createdAt ??
      _inferLegacyBackupCreatedAt(image.path) ??
      stat.modified.toUtc();
  final target = await _availableOrganizedImagePath(
    rootDir: rootDir,
    profileId: profileId,
    createdAt: createdAt,
  );
  await Directory(p.dirname(target)).create(recursive: true);
  await image.rename(target);

  String? newManifestPath;
  if (oldManifest != null) {
    final updated = EmmcBackupManifest(
      schemaVersion: oldManifest.schemaVersion,
      createdAt: oldManifest.createdAt,
      profileId: oldManifest.profileId,
      imagePath: target,
      imageBytes: oldManifest.imageBytes,
      imageSha256: oldManifest.imageSha256,
      disk: oldManifest.disk,
      deckhandVersion: oldManifest.deckhandVersion,
    );
    newManifestPath = await writeEmmcBackupManifest(updated);
    if (oldManifestFile.path != newManifestPath &&
        await oldManifestFile.exists()) {
      await oldManifestFile.delete();
    }
  } else if (oldManifestExists) {
    newManifestPath = emmcBackupManifestPath(target);
    await oldManifestFile.rename(newManifestPath);
  }

  return EmmcBackupOrganizedMove(
    fromImagePath: image.path,
    toImagePath: target,
    toManifestPath: newManifestPath,
  );
}

Future<String> _availableOrganizedImagePath({
  required String rootDir,
  required String profileId,
  required DateTime createdAt,
}) async {
  final base = emmcBackupImagePath(
    rootDir: rootDir,
    profileId: profileId,
    createdAt: createdAt,
  );
  if (!await File(base).exists() &&
      !await File(emmcBackupManifestPath(base)).exists()) {
    return base;
  }
  final context = _pathContextForRoot(rootDir);
  final parent = context.dirname(context.dirname(base));
  final stamp = context.basename(context.dirname(base));
  for (var i = 2; i < 10000; i++) {
    final candidate = context.join(parent, '$stamp-$i', 'emmc.img');
    if (!await File(candidate).exists() &&
        !await File(emmcBackupManifestPath(candidate)).exists()) {
      return candidate;
    }
  }
  throw StateError('Could not find an available backup folder for $base');
}

String? _nonEmptyOrNull(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

DateTime? _inferLegacyBackupCreatedAt(String imagePath) {
  final base = p.basename(imagePath);
  final dashed = RegExp(
    r'(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})(?:-\d+)?Z',
  ).firstMatch(base);
  if (dashed != null) {
    return DateTime.utc(
      int.parse(dashed.group(1)!),
      int.parse(dashed.group(2)!),
      int.parse(dashed.group(3)!),
      int.parse(dashed.group(4)!),
      int.parse(dashed.group(5)!),
      int.parse(dashed.group(6)!),
    );
  }
  final compact = RegExp(
    r'(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z',
  ).firstMatch(base);
  if (compact != null) {
    return DateTime.utc(
      int.parse(compact.group(1)!),
      int.parse(compact.group(2)!),
      int.parse(compact.group(3)!),
      int.parse(compact.group(4)!),
      int.parse(compact.group(5)!),
      int.parse(compact.group(6)!),
    );
  }
  return null;
}

EmmcBackupManifest? findMatchingEmmcBackup({
  required List<EmmcBackupManifest> manifests,
  required String profileId,
  required DiskInfo disk,
}) {
  for (final manifest in manifests) {
    if (manifest.matches(profileId: profileId, disk: disk)) {
      return manifest;
    }
  }
  return null;
}

EmmcBackupImageCandidate? findMatchingEmmcBackupImageCandidate({
  required List<EmmcBackupImageCandidate> candidates,
  required String profileId,
  required DiskInfo disk,
}) {
  for (final candidate in candidates) {
    if (candidate.matches(profileId: profileId, disk: disk)) {
      return candidate;
    }
  }
  return null;
}

String? inferEmmcBackupProfileId(String imagePath) {
  final base = p.basename(imagePath);
  final lower = base.toLowerCase();
  if (lower == 'emmc.img') {
    final profile = p.basename(p.dirname(p.dirname(imagePath)));
    if (profile.isNotEmpty && profile != 'emmc-backups') return profile;
  }
  const marker = '-emmc-';
  final markerIndex = lower.indexOf(marker);
  if (markerIndex <= 0 || !lower.endsWith('.img')) return null;
  return base.substring(0, markerIndex);
}

String _slugSegment(String raw) {
  final lower = raw.trim().toLowerCase();
  final slug = lower
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return slug.isEmpty ? 'printer' : slug;
}

p.Context _pathContextForRoot(String rootDir) {
  final trimmed = rootDir.trim();
  if (RegExp(r'^[A-Za-z]:[/\\]').hasMatch(trimmed) ||
      trimmed.startsWith(r'\\') ||
      trimmed.startsWith('//')) {
    return p.windows;
  }
  if (trimmed.startsWith('/')) return p.posix;
  return p.context;
}

Future<EmmcBackupManifest?> _readManifest(File file) async {
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return null;
    return EmmcBackupManifest.fromJson(decoded.cast<String, dynamic>());
  } catch (_) {
    return null;
  }
}
