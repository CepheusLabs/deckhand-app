import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_flash/deckhand_flash.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// [ProfileService] that:
///   - Fetches `registry.yaml` over HTTPS from a configured repo URL, OR
///     reads it from a local directory if [localProfilesDir] is set.
///   - Uses the Go sidecar to shallow-clone individual profile tags
///     (go-git from the sidecar), bypassed when [localProfilesDir] is set.
///   - Parses profile.yaml into an in-memory map keyed lookup model.
///
/// **Local-dir override.** If the environment variable
/// `DECKHAND_PROFILES_LOCAL` is set (or [localProfilesDir] is passed
/// directly), the service reads `registry.yaml` and `printers/<id>/` from
/// that directory and skips all network fetches. Intended for profile
/// authoring and local testing before a deckhand-builds release is cut.
class SidecarProfileService implements ProfileService {
  SidecarProfileService({
    required this.sidecar,
    required this.paths,
    this.registryUrl =
        'https://raw.githubusercontent.com/CepheusLabs/deckhand-builds/main/registry.yaml',
    this.profilesRepo = 'https://github.com/CepheusLabs/deckhand-builds.git',
    String? localProfilesDir,
    Dio? dio,
  }) : _dio = dio ?? Dio(),
       localProfilesDir =
           localProfilesDir ?? Platform.environment['DECKHAND_PROFILES_LOCAL'];

  final SidecarClient sidecar;
  final DeckhandPaths paths;
  final String registryUrl;
  final String profilesRepo;
  final String? localProfilesDir;
  final Dio _dio;

  @override
  Future<ProfileRegistry> fetchRegistry({bool force = false}) async {
    final local = localProfilesDir;
    final String yamlText;
    if (local != null) {
      final f = File(p.join(local, 'registry.yaml'));
      if (!await f.exists()) {
        throw StateError(
          'DECKHAND_PROFILES_LOCAL is set to "$local" but '
          '${f.path} was not found',
        );
      }
      yamlText = await f.readAsString();
    } else {
      final res = await _dio.get<String>(
        registryUrl,
        options: Options(responseType: ResponseType.plain),
      );
      yamlText = res.data ?? '';
    }
    final yaml = loadYaml(yamlText) as YamlMap;
    final entries = (yaml['profiles'] as YamlList? ?? YamlList())
        .map((e) => (e as YamlMap))
        .map(
          (e) => ProfileRegistryEntry(
            id: e['id'] as String,
            displayName: e['display_name'] as String,
            manufacturer: e['manufacturer'] as String? ?? '',
            model: e['model'] as String? ?? '',
            status: e['status'] as String? ?? 'alpha',
            directory: e['directory'] as String? ?? 'printers/${e['id']}',
            latestTag: e['latest_tag'] as String?,
          ),
        )
        .toList();
    return ProfileRegistry(entries: entries);
  }

  @override
  Future<ProfileCacheEntry> ensureCached({
    required String profileId,
    String? ref,
  }) async {
    final local = localProfilesDir;
    if (local != null) {
      final printerDir = p.join(local, 'printers', profileId);
      if (!await Directory(printerDir).exists()) {
        throw StateError(
          'DECKHAND_PROFILES_LOCAL is set to "$local" but '
          '$printerDir was not found',
        );
      }
      return ProfileCacheEntry(
        profileId: profileId,
        ref: 'local',
        localPath: printerDir,
        resolvedSha: 'local',
      );
    }

    final resolvedRef = ref ?? 'main';
    final dest = p.join(paths.cacheDir, 'profiles', resolvedRef);

    // If already present and not forced, reuse it.
    if (await Directory(dest).exists()) {
      return ProfileCacheEntry(
        profileId: profileId,
        ref: resolvedRef,
        localPath: p.join(dest, 'printers', profileId),
        resolvedSha: '',
      );
    }

    final res = await sidecar.call('profiles.fetch', {
      'repo_url': profilesRepo,
      'ref': resolvedRef,
      'dest': dest,
    });
    return ProfileCacheEntry(
      profileId: profileId,
      ref: resolvedRef,
      localPath: p.join(res['local_path'] as String, 'printers', profileId),
      resolvedSha: res['resolved_sha'] as String? ?? '',
    );
  }

  @override
  Future<PrinterProfile> load(ProfileCacheEntry cacheEntry) async {
    final file = File(p.join(cacheEntry.localPath, 'profile.yaml'));
    final text = await file.readAsString();
    final yaml = loadYaml(text);
    final raw = _deepConvert(yaml) as Map<String, dynamic>;
    return PrinterProfile.fromJson(raw);
  }
}

// yaml's YamlMap/YamlList aren't directly serializable; convert into
// pure Dart Map/List for downstream models.
Object? _deepConvert(Object? node) {
  if (node is YamlMap) {
    return Map<String, dynamic>.fromEntries(
      node.entries.map(
        (e) => MapEntry(e.key.toString(), _deepConvert(e.value)),
      ),
    );
  }
  if (node is YamlList) {
    return node.map(_deepConvert).toList();
  }
  return node;
}
