import '../models/printer_profile.dart';

/// Fetch + parse printer profiles from the deckhand-profiles repo.
abstract class ProfileService {
  /// Fetch the profile registry (tiny YAML at the repo root).
  Future<ProfileRegistry> fetchRegistry({bool force = false});

  /// Ensure a given profile tag is cached locally. Shallow-clones the
  /// deckhand-profiles repo at that tag if needed.
  ///
  /// When [force] is true, any existing cache directory is wiped
  /// before fetching — including immutable semver-tagged caches that
  /// would normally be reused indefinitely. Used by the "Refresh
  /// profile" affordance and by dev builds that need to pick up
  /// just-pushed profile edits without restarting the sidecar.
  Future<ProfileCacheEntry> ensureCached({
    required String profileId,
    String? ref,
    bool force = false,
  });

  /// Parse a cached profile.yaml into an in-memory model.
  Future<PrinterProfile> load(ProfileCacheEntry cacheEntry);
}

class ProfileRegistry {
  const ProfileRegistry({required this.entries});
  final List<ProfileRegistryEntry> entries;
}

class ProfileRegistryEntry {
  const ProfileRegistryEntry({
    required this.id,
    required this.displayName,
    required this.manufacturer,
    required this.model,
    required this.status,
    required this.directory,
    this.latestTag,
    this.sbc,
    this.kinematics,
    this.mcu,
    this.extras,
  });
  final String id;
  final String displayName;
  final String manufacturer;
  final String model;
  final String status; // stub | alpha | beta | stable | deprecated
  final String directory;
  final String? latestTag;

  /// Hardware highlights surfaced in the printer-picker spec card.
  /// All four are optional and derived (or pass-through) from the
  /// profile.yaml `hardware:` block by the registry generator.
  ///  * [sbc]        — short SoC label, e.g. "RK3328" or "Allwinner H616".
  ///  * [kinematics] — pretty-cased kinematics label, e.g. "CoreXY".
  ///  * [mcu]        — main MCU chip label, e.g. "STM32F407".
  ///  * [extras]     — designer-authored flavor text from `picker_extras`
  ///                   in profile.yaml (e.g. "ChromaKit AMS"); not derived.
  final String? sbc;
  final String? kinematics;
  final String? mcu;
  final String? extras;
}

class ProfileCacheEntry {
  const ProfileCacheEntry({
    required this.profileId,
    required this.ref,
    required this.localPath,
    required this.resolvedSha,
  });
  final String profileId;
  final String ref;
  final String localPath;
  final String resolvedSha;
}

// PrinterProfile lives in models/printer_profile.dart and is re-exported
// from the library entrypoint.
