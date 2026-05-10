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
      imageSha256: imageSha256.trim().toLowerCase(),
      disk: EmmcBackupDiskIdentity.fromDisk(disk),
      deckhandVersion: deckhandVersion,
    );
  }

  factory EmmcBackupManifest.fromJson(Map<String, dynamic> json) {
    return EmmcBackupManifest(
      schemaVersion: _jsonInt(json['schema_version']),
      createdAt: _jsonDateTime(json['created_at']),
      profileId: _jsonString(json['profile_id']) ?? '',
      imagePath: _jsonString(json['image_path']) ?? '',
      imageBytes: _jsonInt(json['image_bytes']),
      imageSha256: (_jsonString(json['image_sha256']) ?? '')
          .trim()
          .toLowerCase(),
      disk: EmmcBackupDiskIdentity.fromJson(
        _stringKeyMap(json['disk']) ?? const {},
      ),
      deckhandVersion: _jsonString(json['deckhand_version']) ?? '',
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
    this.isBoot = false,
    this.isSystem = false,
    this.isReadOnly = false,
    this.isOffline = false,
  });

  factory EmmcBackupDiskIdentity.fromDisk(DiskInfo disk) {
    return EmmcBackupDiskIdentity(
      id: disk.id,
      path: disk.path,
      sizeBytes: disk.sizeBytes,
      bus: disk.bus,
      model: disk.model,
      removable: disk.removable,
      isBoot: disk.isBoot,
      isSystem: disk.isSystem,
      isReadOnly: disk.isReadOnly,
      isOffline: disk.isOffline,
    );
  }

  factory EmmcBackupDiskIdentity.fromJson(Map<String, dynamic> json) {
    return EmmcBackupDiskIdentity(
      id: _jsonString(json['id']) ?? '',
      path: _jsonString(json['path']) ?? '',
      sizeBytes: _jsonInt(json['size_bytes']),
      bus: _jsonString(json['bus']) ?? '',
      model: _jsonString(json['model']) ?? '',
      removable: _jsonBool(json['removable']),
      isBoot: _jsonBool(json['is_boot']),
      isSystem: _jsonBool(json['is_system']),
      isReadOnly: _jsonBool(json['is_read_only']),
      isOffline: _jsonBool(json['is_offline']),
    );
  }

  final String id;
  final String path;
  final int sizeBytes;
  final String bus;
  final String model;
  final bool removable;
  final bool isBoot;
  final bool isSystem;
  final bool isReadOnly;
  final bool isOffline;

  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    'size_bytes': sizeBytes,
    'bus': bus,
    'model': model,
    'removable': removable,
    'is_boot': isBoot,
    'is_system': isSystem,
    'is_read_only': isReadOnly,
    'is_offline': isOffline,
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

class EmmcBackupCatalogEntry {
  EmmcBackupCatalogEntry({
    required this.imagePath,
    required this.imageBytes,
    required this.createdAt,
    required this.profileId,
    required this.indexed,
    required this.fullSize,
    required List<String> duplicatePaths,
    this.imageSha256,
    this.diskIdentity,
    this.manifest,
    this.candidate,
  }) : duplicatePaths = List.unmodifiable(duplicatePaths);

  final String imagePath;
  final int imageBytes;
  final DateTime createdAt;
  final String? profileId;
  final bool indexed;
  final bool fullSize;
  final List<String> duplicatePaths;
  final String? imageSha256;
  final EmmcBackupDiskIdentity? diskIdentity;
  final EmmcBackupManifest? manifest;
  final EmmcBackupImageCandidate? candidate;

  int get duplicateCount => duplicatePaths.length;

  EmmcBackupCatalogEntry copyWith({
    String? imagePath,
    int? imageBytes,
    DateTime? createdAt,
    String? profileId,
    bool? indexed,
    bool? fullSize,
    List<String>? duplicatePaths,
    String? imageSha256,
    EmmcBackupDiskIdentity? diskIdentity,
    EmmcBackupManifest? manifest,
    EmmcBackupImageCandidate? candidate,
  }) {
    return EmmcBackupCatalogEntry(
      imagePath: imagePath ?? this.imagePath,
      imageBytes: imageBytes ?? this.imageBytes,
      createdAt: createdAt ?? this.createdAt,
      profileId: profileId ?? this.profileId,
      indexed: indexed ?? this.indexed,
      fullSize: fullSize ?? this.fullSize,
      duplicatePaths: duplicatePaths ?? this.duplicatePaths,
      imageSha256: imageSha256 ?? this.imageSha256,
      diskIdentity: diskIdentity ?? this.diskIdentity,
      manifest: manifest ?? this.manifest,
      candidate: candidate ?? this.candidate,
    );
  }
}

List<EmmcBackupCatalogEntry> buildEmmcBackupCatalog({
  required List<EmmcBackupManifest> manifests,
  required List<EmmcBackupImageCandidate> candidates,
  int? referenceSizeBytes,
}) {
  final manifestPaths = <String>{};
  final entriesByHash = <String, EmmcBackupCatalogEntry>{};
  final entries = <EmmcBackupCatalogEntry>[];

  for (final manifest in manifests) {
    final keyPath = _pathKey(manifest.imagePath);
    if (!manifestPaths.add(keyPath)) continue;
    final hash = manifest.imageSha256.trim().toLowerCase();
    final entry = EmmcBackupCatalogEntry(
      imagePath: manifest.imagePath,
      imageBytes: manifest.imageBytes,
      createdAt: manifest.createdAt,
      profileId: _nonEmptyOrNull(manifest.profileId),
      indexed: true,
      fullSize:
          referenceSizeBytes == null ||
          manifest.imageBytes == referenceSizeBytes,
      duplicatePaths: const [],
      imageSha256: hash,
      diskIdentity: manifest.disk,
      manifest: manifest,
    );
    if (!_isSha256Hex(hash)) {
      entries.add(entry);
      continue;
    }
    final existing = entriesByHash[hash];
    if (existing == null) {
      entriesByHash[hash] = entry;
      continue;
    }
    final newest = entry.createdAt.isAfter(existing.createdAt)
        ? entry
        : existing;
    final older = identical(newest, entry) ? existing : entry;
    entriesByHash[hash] = newest.copyWith(
      duplicatePaths: [
        ...newest.duplicatePaths,
        older.imagePath,
        ...older.duplicatePaths,
      ],
    );
  }

  entries.addAll(entriesByHash.values);
  for (final candidate in candidates) {
    if (manifestPaths.contains(_pathKey(candidate.imagePath))) continue;
    entries.add(
      EmmcBackupCatalogEntry(
        imagePath: candidate.imagePath,
        imageBytes: candidate.imageBytes,
        createdAt: candidate.modifiedAt,
        profileId: _nonEmptyOrNull(candidate.inferredProfileId),
        indexed: false,
        fullSize:
            referenceSizeBytes == null ||
            candidate.imageBytes == referenceSizeBytes,
        duplicatePaths: const [],
        candidate: candidate,
      ),
    );
  }

  entries.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return List.unmodifiable(entries);
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
  final context = _pathContextForRoot(manifestPath);
  await Directory(context.dirname(manifestPath)).create(recursive: true);
  final manifestFile = File(manifestPath);
  final tmp = File('$manifestPath.tmp');
  await tmp.writeAsString(
    const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
    flush: true,
  );
  var published = false;
  try {
    await tmp.rename(manifestPath);
    published = true;
  } on FileSystemException {
    if (await manifestFile.exists()) await manifestFile.delete();
    await tmp.rename(manifestPath);
    published = true;
  } finally {
    if (!published && await tmp.exists()) {
      await tmp.delete();
    }
  }
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
    if (entity is! File ||
        !entity.path.toLowerCase().endsWith('.manifest.json')) {
      continue;
    }
    final manifest = await _readManifest(entity);
    if (manifest == null) continue;
    if (!_isValidIndexedManifest(manifest)) continue;
    final manifestImagePath = await _manifestImagePath(dir, manifest, entity);
    if (manifestImagePath == null) continue;
    if (!await _isRegularFile(manifestImagePath)) continue;
    if (await File(manifestImagePath).length() != manifest.imageBytes) {
      continue;
    }
    manifests.add(
      manifest.imagePath == manifestImagePath
          ? manifest
          : _copyManifestWithImagePath(manifest, manifestImagePath),
    );
  }
  manifests.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return manifests;
}

Future<String?> _manifestImagePath(
  String rootDir,
  EmmcBackupManifest manifest,
  File manifestFile,
) async {
  if (manifest.imagePath.isNotEmpty &&
      _isPathInsideRoot(rootDir, manifest.imagePath) &&
      await File(manifest.imagePath).exists()) {
    return manifest.imagePath;
  }
  final sibling = _imagePathFromManifestPath(manifestFile.path);
  if (sibling == null ||
      !_isPathInsideRoot(rootDir, sibling) ||
      !await File(sibling).exists()) {
    return null;
  }
  return sibling;
}

String? _imagePathFromManifestPath(String manifestPath) {
  const suffix = '.manifest.json';
  if (!manifestPath.toLowerCase().endsWith(suffix)) return null;
  return manifestPath.substring(0, manifestPath.length - suffix.length);
}

EmmcBackupManifest _copyManifestWithImagePath(
  EmmcBackupManifest manifest,
  String imagePath,
) => EmmcBackupManifest(
  schemaVersion: manifest.schemaVersion,
  createdAt: manifest.createdAt,
  profileId: manifest.profileId,
  imagePath: imagePath,
  imageBytes: manifest.imageBytes,
  imageSha256: manifest.imageSha256,
  disk: manifest.disk,
  deckhandVersion: manifest.deckhandVersion,
);

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
        modifiedAt:
            _inferOrganizedBackupCreatedAt(entity.path) ??
            _inferLegacyBackupCreatedAt(entity.path) ??
            stat.modified,
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
  final context = _pathContextForRoot(target);
  await Directory(context.dirname(target)).create(recursive: true);
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
    final quarantinedPath = await _availableInvalidManifestPath(
      emmcBackupManifestPath(target),
    );
    await oldManifestFile.rename(quarantinedPath);
  }

  return EmmcBackupOrganizedMove(
    fromImagePath: image.path,
    toImagePath: target,
    toManifestPath: newManifestPath,
  );
}

Future<String> _availableInvalidManifestPath(String manifestPath) async {
  final base = '$manifestPath.invalid';
  if (!await File(base).exists()) return base;
  for (var i = 2; i < 10000; i++) {
    final candidate = '$base-$i';
    if (!await File(candidate).exists()) return candidate;
  }
  throw StateError('Could not find an available quarantine path for $base');
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

final _sha256Re = RegExp(r'^[0-9a-f]{64}$');

bool _isSha256Hex(String value) => _sha256Re.hasMatch(value);

Future<bool> _isRegularFile(String path) async {
  final type = await FileSystemEntity.type(path, followLinks: false);
  return type == FileSystemEntityType.file;
}

bool _isPathInsideRoot(String rootDir, String candidate) {
  final context = _pathContextForRoot(rootDir);
  if (!context.isAbsolute(candidate)) return false;
  final root = context.normalize(rootDir);
  final child = context.normalize(candidate);
  final windows = _usesWindowsPathSemantics(rootDir);
  final rootCompare = windows ? root.toLowerCase() : root;
  final childCompare = windows ? child.toLowerCase() : child;
  return childCompare == rootCompare ||
      context.isWithin(rootCompare, childCompare);
}

DateTime? _inferLegacyBackupCreatedAt(String imagePath) {
  final context = _pathContextForRoot(imagePath);
  return _parseBackupTimestamp(context.basename(imagePath));
}

DateTime? _inferOrganizedBackupCreatedAt(String imagePath) {
  final context = _pathContextForRoot(imagePath);
  if (context.basename(imagePath).toLowerCase() != 'emmc.img') return null;
  return _parseBackupTimestamp(context.basename(context.dirname(imagePath)));
}

DateTime? _parseBackupTimestamp(String value) {
  final dashed = RegExp(
    r'(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})(?:-\d+)?Z(?:-\d+)?',
  ).firstMatch(value);
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
    r'(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z(?:-\d+)?',
  ).firstMatch(value);
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
  final context = _pathContextForRoot(imagePath);
  final base = context.basename(imagePath);
  final lower = base.toLowerCase();
  if (lower == 'emmc.img') {
    final profile = context.basename(
      context.dirname(context.dirname(imagePath)),
    );
    if (profile.isNotEmpty && profile.toLowerCase() != 'emmc-backups') {
      return profile;
    }
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
  if (_usesWindowsPathSemantics(trimmed)) {
    return p.windows;
  }
  if (trimmed.startsWith('/')) return p.posix;
  return p.context;
}

bool _usesWindowsPathSemantics(String path) {
  final trimmed = path.trim();
  return RegExp(r'^[A-Za-z]:[/\\]').hasMatch(trimmed) ||
      trimmed.startsWith(r'\\') ||
      trimmed.startsWith('//');
}

String _pathKey(String path) {
  final context = _pathContextForRoot(path);
  return context.normalize(path).toLowerCase();
}

Future<EmmcBackupManifest?> _readManifest(File file) async {
  try {
    final decoded = jsonDecode(await file.readAsString());
    final parsed = _stringKeyMap(decoded);
    if (parsed == null) return null;
    return EmmcBackupManifest.fromJson(parsed);
  } catch (_) {
    return null;
  }
}

bool _isValidIndexedManifest(EmmcBackupManifest manifest) {
  return manifest.schemaVersion == emmcBackupManifestSchema &&
      manifest.imageBytes > 0 &&
      _isSha256Hex(manifest.imageSha256);
}

String? _jsonString(Object? value) => value is String ? value : null;

int _jsonInt(Object? value) {
  if (value is! num || !value.isFinite) return 0;
  return value.toInt();
}

bool _jsonBool(Object? value) => value is bool && value;

DateTime _jsonDateTime(Object? value) {
  final raw = _jsonString(value)?.trim();
  if (raw == null || raw.isEmpty) {
    return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }
  return DateTime.tryParse(raw)?.toUtc() ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}

Map<String, dynamic>? _stringKeyMap(Object? value) {
  if (value is! Map) return null;
  final out = <String, dynamic>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is String) out[key] = entry.value;
  }
  return out;
}
