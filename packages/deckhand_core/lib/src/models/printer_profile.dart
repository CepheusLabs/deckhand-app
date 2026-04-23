/// Strongly-typed model of a parsed `profile.yaml` from deckhand-builds.
///
/// Fields match the authoritative spec in
/// deckhand-builds/AUTHORING.md. Unknown fields are preserved in the
/// backing map (`raw`) so the app can roundtrip without data loss.
class PrinterProfile {
  const PrinterProfile({
    required this.raw,
    required this.id,
    required this.version,
    required this.displayName,
    required this.status,
    required this.manufacturer,
    required this.model,
    required this.hardware,
    required this.os,
    required this.ssh,
    required this.firmware,
    required this.stack,
    required this.mcus,
    required this.screens,
    required this.addons,
    required this.stockOs,
    required this.wizard,
    required this.flows,
    required this.verifiers,
    required this.requiredHosts,
    this.identification = const ProfileIdentification(),
    this.maintainers = const [],
  });

  final Map<String, dynamic> raw;
  final String id;
  final String version;
  final String displayName;
  final ProfileStatus status;
  final String manufacturer;
  final String model;
  final HardwareSpec hardware;
  final OsSpec os;
  final SshConfig ssh;
  final FirmwareConfig firmware;
  final StackConfig stack;
  final List<McuConfig> mcus;
  final List<ScreenConfig> screens;
  final List<AddonConfig> addons;
  final StockOsInventory stockOs;
  final WizardConfig wizard;
  final FlowConfig flows;
  final List<VerifierConfig> verifiers;
  final List<String> requiredHosts;
  final ProfileIdentification identification;
  final List<MaintainerSpec> maintainers;

  factory PrinterProfile.fromJson(Map<String, dynamic> json) {
    return PrinterProfile(
      raw: json,
      id: json['profile_id'] as String? ?? '',
      version: json['profile_version'] as String? ?? '0.0.0',
      displayName: json['display_name'] as String? ?? '',
      status: ProfileStatusX.parse(json['status'] as String? ?? 'alpha'),
      manufacturer: json['manufacturer'] as String? ?? '',
      model: json['model'] as String? ?? '',
      hardware: HardwareSpec.fromJson(_mapOr(json['hardware'])),
      os: OsSpec.fromJson(_mapOr(json['os'])),
      ssh: SshConfig.fromJson(_mapOr(json['ssh'])),
      firmware: FirmwareConfig.fromJson(_mapOr(json['firmware'])),
      stack: StackConfig.fromJson(_mapOr(json['stack'])),
      mcus: _listOfMap(json['mcus']).map(McuConfig.fromJson).toList(),
      screens: _listOfMap(json['screens']).map(ScreenConfig.fromJson).toList(),
      addons: _listOfMap(json['addons']).map(AddonConfig.fromJson).toList(),
      stockOs: StockOsInventory.fromJson(_mapOr(json['stock_os'])),
      wizard: WizardConfig.fromJson(_mapOr(json['wizard'])),
      flows: FlowConfig.fromJson(_mapOr(json['flows'])),
      verifiers: _listOfMap(
        json['verifiers'],
      ).map(VerifierConfig.fromJson).toList(),
      requiredHosts: ((json['required_hosts'] as List?) ?? const [])
          .cast<String>(),
      identification: ProfileIdentification.fromJson(
        _mapOr(json['identification']),
      ),
      maintainers: _listOfMap(
        json['maintainers'],
      ).map(MaintainerSpec.fromJson).toList(),
    );
  }
}

/// Hints the connect screen uses to pick the right discovered printer
/// out of a LAN full of similar-looking Klipper boxes. The default
/// (empty) identification matches nothing, so unconfigured profiles
/// never claim discovered hosts - the user falls back to picking
/// manually.
class ProfileIdentification {
  const ProfileIdentification({
    this.markerFile,
    this.moonrakerObjects = const [],
    this.hostnamePatterns = const [],
  });

  /// Filename under Moonraker's `config` root (typically
  /// `~/printer_data/config/`) that Deckhand writes during install to
  /// mark the printer as ours. Strongest identification signal: a
  /// printer with this file definitely went through our process.
  /// When the file content parses as JSON with `profile_id` matching
  /// the loaded profile, that's a definite match.
  final String? markerFile;

  /// Klipper object names that, if any appear in a live Moonraker
  /// `/printer/objects/list`, identify this printer model. Matched as
  /// prefix-or-exact against each registered object (so `phrozen_dev`
  /// matches `phrozen_dev`, `phrozen_dev:runout`, etc.). Used to catch
  /// stock (pre-Deckhand) printers before the marker file exists.
  final List<String> moonrakerObjects;

  /// Regex patterns the Moonraker `/printer/info.hostname` can match
  /// to strengthen identification. Contributes as a weak "probable"
  /// signal when no stronger evidence is available.
  final List<String> hostnamePatterns;

  factory ProfileIdentification.fromJson(Map<String, dynamic> j) =>
      ProfileIdentification(
        markerFile: j['marker_file'] as String?,
        moonrakerObjects:
            ((j['moonraker_objects'] as List?) ?? const []).cast<String>(),
        hostnamePatterns:
            ((j['hostname_patterns'] as List?) ?? const []).cast<String>(),
      );
}

/// The confidence bucket for a match result. Ordered so [confirmed]
/// sorts first and [miss] sorts last in lists.
enum PrinterMatchConfidence { confirmed, probable, unknown, miss }

/// Pure function: score a discovered printer against a profile's
/// identification hints. Lives in the model so both the UI and tests
/// can reach it without a Flutter context.
class PrinterMatch {
  const PrinterMatch({required this.confidence, this.reason});
  final PrinterMatchConfidence confidence;
  final String? reason;

  static const PrinterMatch unknown = PrinterMatch(
    confidence: PrinterMatchConfidence.unknown,
  );

  static PrinterMatch score({
    required ProfileIdentification hints,
    required String? markerFileContent,
    required String? hostname,
    required List<String> registeredObjects,
    required String profileId,
  }) {
    // Tier 1: marker file written by Deckhand. Strongest signal.
    if (hints.markerFile != null && markerFileContent != null) {
      // Content should be JSON with profile_id. We don't hard-require
      // that; any non-empty marker at the expected path is convincing,
      // but a matching profile_id upgrades the reason text.
      final lower = markerFileContent.trim();
      if (lower.contains('"profile_id"') &&
          lower.contains('"$profileId"')) {
        return PrinterMatch(
          confidence: PrinterMatchConfidence.confirmed,
          reason: 'installed by Deckhand as $profileId',
        );
      }
      if (lower.isNotEmpty) {
        return PrinterMatch(
          confidence: PrinterMatchConfidence.confirmed,
          reason: 'Deckhand marker file present',
        );
      }
    }
    // Tier 2: Klipper object fingerprint. Pre-install printers match
    // here; post-install printers usually match here as well since we
    // preserve vendor extras.
    for (final prefix in hints.moonrakerObjects) {
      for (final obj in registeredObjects) {
        if (obj == prefix ||
            obj.startsWith('$prefix ') ||
            obj.startsWith('$prefix:')) {
          return PrinterMatch(
            confidence: PrinterMatchConfidence.confirmed,
            reason: 'Klipper config uses `$prefix`',
          );
        }
      }
    }
    // Tier 3: hostname pattern. Weak on its own - common hostnames
    // like `mkspi` don't prove anything. Surfaced as "probable" so
    // the user knows to double-check.
    if (hostname != null) {
      for (final pat in hints.hostnamePatterns) {
        try {
          if (RegExp(pat).hasMatch(hostname)) {
            return PrinterMatch(
              confidence: PrinterMatchConfidence.probable,
              reason: 'hostname `$hostname` matches profile',
            );
          }
        } catch (_) {
          // Malformed regex - skip silently.
        }
      }
    }
    // If the profile supplies any hints at all, we can say "miss"
    // confidently. If it supplies none, we stay unknown.
    final hasAny = hints.markerFile != null ||
        hints.moonrakerObjects.isNotEmpty ||
        hints.hostnamePatterns.isNotEmpty;
    return PrinterMatch(
      confidence:
          hasAny ? PrinterMatchConfidence.miss : PrinterMatchConfidence.unknown,
    );
  }
}

enum ProfileStatus { stub, alpha, beta, stable, deprecated }

extension ProfileStatusX on ProfileStatus {
  static ProfileStatus parse(String s) => switch (s) {
    'stub' => ProfileStatus.stub,
    'alpha' => ProfileStatus.alpha,
    'beta' => ProfileStatus.beta,
    'stable' => ProfileStatus.stable,
    'deprecated' => ProfileStatus.deprecated,
    _ => ProfileStatus.alpha,
  };
}

class MaintainerSpec {
  const MaintainerSpec({required this.name, this.contact});
  final String name;
  final String? contact;
  factory MaintainerSpec.fromJson(Map<String, dynamic> j) => MaintainerSpec(
    name: j['name'] as String? ?? '',
    contact: j['contact'] as String?,
  );
}

class HardwareSpec {
  const HardwareSpec({
    this.architecture,
    this.sbc,
    this.kinematics,
    this.buildVolumeMm,
    this.steppers = const [],
    this.sensors = const [],
    this.features = const [],
  });
  final String? architecture;
  final SbcSpec? sbc;
  final String? kinematics;
  final BuildVolume? buildVolumeMm;
  final List<Map<String, dynamic>> steppers;
  final List<Map<String, dynamic>> sensors;
  final List<String> features;

  factory HardwareSpec.fromJson(Map<String, dynamic> j) => HardwareSpec(
    architecture: j['architecture'] as String?,
    sbc: j['sbc'] is Map ? SbcSpec.fromJson((j['sbc'] as Map).cast()) : null,
    kinematics: j['kinematics'] as String?,
    buildVolumeMm: j['build_volume_mm'] is Map
        ? BuildVolume.fromJson((j['build_volume_mm'] as Map).cast())
        : null,
    steppers: _listOfMap(j['steppers']),
    sensors: _listOfMap(j['sensors']),
    features: ((j['features'] as List?) ?? const []).cast<String>(),
  );
}

class SbcSpec {
  const SbcSpec({this.soc, this.board, this.emmcSizeBytes});
  final String? soc;
  final String? board;
  final int? emmcSizeBytes;
  factory SbcSpec.fromJson(Map<String, dynamic> j) => SbcSpec(
    soc: j['soc'] as String?,
    board: j['board'] as String?,
    emmcSizeBytes: (j['emmc_size_bytes'] as num?)?.toInt(),
  );
}

class BuildVolume {
  const BuildVolume({required this.x, required this.y, required this.z});
  final int x;
  final int y;
  final int z;
  factory BuildVolume.fromJson(Map<String, dynamic> j) => BuildVolume(
    x: (j['x'] as num).toInt(),
    y: (j['y'] as num).toInt(),
    z: (j['z'] as num).toInt(),
  );
}

class OsSpec {
  const OsSpec({
    this.stock,
    this.freshInstallOptions = const [],
    this.bootMode,
  });
  final OsStockSpec? stock;
  final List<OsImageOption> freshInstallOptions;
  final String? bootMode;

  factory OsSpec.fromJson(Map<String, dynamic> j) => OsSpec(
    stock: j['stock'] is Map
        ? OsStockSpec.fromJson((j['stock'] as Map).cast())
        : null,
    freshInstallOptions: _listOfMap(
      j['fresh_install_options'],
    ).map(OsImageOption.fromJson).toList(),
    bootMode: j['boot_mode'] as String?,
  );
}

class OsStockSpec {
  const OsStockSpec({
    this.distro,
    this.version,
    this.codename,
    this.python,
    this.notes,
  });
  final String? distro;
  final String? version;
  final String? codename;
  final String? python;
  final String? notes;
  factory OsStockSpec.fromJson(Map<String, dynamic> j) => OsStockSpec(
    distro: j['distro'] as String?,
    version: j['version'] as String?,
    codename: j['codename'] as String?,
    python: j['python'] as String?,
    notes: j['notes'] as String?,
  );
}

class OsImageOption {
  const OsImageOption({
    required this.id,
    required this.displayName,
    required this.url,
    this.sha256,
    this.sizeBytesApprox,
    this.recommended = false,
    this.architecture,
    this.notes,
  });
  final String id;
  final String displayName;
  final String url;
  final String? sha256;
  final int? sizeBytesApprox;
  final bool recommended;
  final String? architecture;
  final String? notes;
  factory OsImageOption.fromJson(Map<String, dynamic> j) => OsImageOption(
    id: j['id'] as String,
    displayName: j['display_name'] as String? ?? j['id'] as String,
    url: j['url'] as String? ?? '',
    sha256: j['sha256'] as String?,
    sizeBytesApprox: (j['size_bytes_approx'] as num?)?.toInt(),
    recommended: j['recommended'] as bool? ?? false,
    architecture: j['architecture'] as String?,
    notes: j['notes'] as String?,
  );
}

class SshConfig {
  const SshConfig({
    this.defaultPort = 22,
    this.defaultCredentials = const [],
    this.recommendedUserAfterInstall,
  });
  final int defaultPort;
  final List<SshDefaultCredential> defaultCredentials;
  final String? recommendedUserAfterInstall;
  factory SshConfig.fromJson(Map<String, dynamic> j) => SshConfig(
    defaultPort: (j['default_port'] as num?)?.toInt() ?? 22,
    defaultCredentials: _listOfMap(
      j['default_credentials'],
    ).map(SshDefaultCredential.fromJson).toList(),
    recommendedUserAfterInstall: j['recommended_user_after_install'] as String?,
  );
}

class SshDefaultCredential {
  const SshDefaultCredential({required this.user, this.password, this.keyPath});
  final String user;
  final String? password;
  final String? keyPath;
  factory SshDefaultCredential.fromJson(Map<String, dynamic> j) =>
      SshDefaultCredential(
        user: j['user'] as String,
        password: j['password'] as String?,
        keyPath: j['key_path'] as String?,
      );
}

class FirmwareConfig {
  const FirmwareConfig({
    this.choices = const [],
    this.defaultChoice,
    this.replaceStockInPlace = true,
    this.snapshotBeforeReplace = true,
  });
  final List<FirmwareChoice> choices;
  final String? defaultChoice;
  final bool replaceStockInPlace;
  final bool snapshotBeforeReplace;
  factory FirmwareConfig.fromJson(Map<String, dynamic> j) => FirmwareConfig(
    choices: _listOfMap(j['choices']).map(FirmwareChoice.fromJson).toList(),
    defaultChoice: j['default_choice'] as String?,
    replaceStockInPlace: j['replace_stock_in_place'] as bool? ?? true,
    snapshotBeforeReplace: j['snapshot_before_replace'] as bool? ?? true,
  );
}

class FirmwareChoice {
  const FirmwareChoice({
    required this.id,
    required this.displayName,
    required this.repo,
    required this.ref,
    this.description,
    this.installPath,
    this.venvPath,
    this.pythonMin,
    this.recommended = false,
  });
  final String id;
  final String displayName;
  final String repo;
  final String ref;
  final String? description;
  final String? installPath;
  final String? venvPath;
  final String? pythonMin;
  final bool recommended;
  factory FirmwareChoice.fromJson(Map<String, dynamic> j) => FirmwareChoice(
    id: j['id'] as String,
    displayName: j['display_name'] as String? ?? j['id'] as String,
    repo: j['repo'] as String? ?? '',
    ref: j['ref'] as String? ?? 'main',
    description: j['description'] as String?,
    installPath: j['install_path'] as String?,
    venvPath: j['venv_path'] as String?,
    pythonMin: j['python_min'] as String?,
    recommended: j['recommended'] as bool? ?? false,
  );
}

class StackConfig {
  const StackConfig({this.moonraker, this.webui, this.kiauh, this.crowsnest});
  final Map<String, dynamic>? moonraker;
  final Map<String, dynamic>? webui;
  final Map<String, dynamic>? kiauh;
  final Map<String, dynamic>? crowsnest;
  factory StackConfig.fromJson(Map<String, dynamic> j) => StackConfig(
    moonraker: _mapOrNull(j['moonraker']),
    webui: _mapOrNull(j['webui']),
    kiauh: _mapOrNull(j['kiauh']),
    crowsnest: _mapOrNull(j['crowsnest']),
  );
}

class McuConfig {
  const McuConfig({required this.id, required this.raw, this.displayName});
  final String id;
  final String? displayName;
  final Map<String, dynamic> raw;
  factory McuConfig.fromJson(Map<String, dynamic> j) => McuConfig(
    id: j['id'] as String,
    displayName: j['display_name'] as String?,
    raw: j,
  );
}

class ScreenConfig {
  const ScreenConfig({
    required this.id,
    required this.raw,
    this.displayName,
    this.status,
    this.recommended = false,
  });
  final String id;
  final String? displayName;
  final String? status;
  final bool recommended;
  final Map<String, dynamic> raw;
  factory ScreenConfig.fromJson(Map<String, dynamic> j) => ScreenConfig(
    id: j['id'] as String,
    displayName: j['display_name'] as String?,
    status: j['status'] as String?,
    recommended: j['recommended'] as bool? ?? false,
    raw: j,
  );
}

class AddonConfig {
  const AddonConfig({
    required this.id,
    required this.raw,
    this.kind,
    this.displayName,
  });
  final String id;
  final String? kind;
  final String? displayName;
  final Map<String, dynamic> raw;
  factory AddonConfig.fromJson(Map<String, dynamic> j) => AddonConfig(
    id: j['id'] as String,
    kind: j['kind'] as String?,
    displayName: j['display_name'] as String?,
    raw: j,
  );
}

class StockOsInventory {
  const StockOsInventory({
    this.detections = const [],
    this.services = const [],
    this.files = const [],
    this.paths = const [],
  });
  final List<DetectionRule> detections;
  final List<StockService> services;
  final List<StockFile> files;
  final List<StockPath> paths;

  factory StockOsInventory.fromJson(Map<String, dynamic> j) => StockOsInventory(
    detections: _listOfMap(
      j['detections'],
    ).map(DetectionRule.fromJson).toList(),
    services: _listOfMap(j['services']).map(StockService.fromJson).toList(),
    files: _listOfMap(j['files']).map(StockFile.fromJson).toList(),
    paths: _listOfMap(j['paths']).map(StockPath.fromJson).toList(),
  );
}

class DetectionRule {
  const DetectionRule({
    required this.kind,
    required this.raw,
    this.required = true,
  });
  final String kind;
  final bool required;
  final Map<String, dynamic> raw;
  factory DetectionRule.fromJson(Map<String, dynamic> j) => DetectionRule(
    kind: j['kind'] as String,
    required: j['required'] as bool? ?? true,
    raw: j,
  );
}

class StockService {
  const StockService({
    required this.id,
    required this.displayName,
    required this.defaultAction,
    required this.raw,
  });
  final String id;
  final String displayName;
  final String defaultAction;
  final Map<String, dynamic> raw;
  factory StockService.fromJson(Map<String, dynamic> j) => StockService(
    id: j['id'] as String,
    displayName: j['display_name'] as String? ?? j['id'] as String,
    defaultAction: j['default_action'] as String? ?? 'keep',
    raw: j,
  );
}

class StockFile {
  const StockFile({
    required this.id,
    required this.displayName,
    required this.paths,
    required this.defaultAction,
    required this.raw,
  });
  final String id;
  final String displayName;
  final List<String> paths;
  final String defaultAction;
  final Map<String, dynamic> raw;
  factory StockFile.fromJson(Map<String, dynamic> j) => StockFile(
    id: j['id'] as String,
    displayName: j['display_name'] as String? ?? j['id'] as String,
    paths: ((j['paths'] as List?) ?? const []).cast<String>(),
    defaultAction: j['default_action'] as String? ?? 'delete',
    raw: j,
  );
}

class StockPath {
  const StockPath({
    required this.id,
    required this.path,
    required this.action,
    this.snapshotTo,
    this.role,
  });
  final String id;
  final String path;
  final String action;
  final String? snapshotTo;
  final String? role;
  factory StockPath.fromJson(Map<String, dynamic> j) => StockPath(
    id: j['id'] as String,
    path: j['path'] as String,
    action: j['action'] as String? ?? 'preserve',
    snapshotTo: j['snapshot_to'] as String?,
    role: j['role'] as String?,
  );
}

class WizardConfig {
  const WizardConfig({
    this.title,
    this.stepsOverride,
    this.extraSteps = const [],
  });
  final String? title;
  final Map<String, dynamic>? stepsOverride;
  final List<Map<String, dynamic>> extraSteps;
  factory WizardConfig.fromJson(Map<String, dynamic> j) => WizardConfig(
    title: j['title'] as String?,
    stepsOverride: _mapOrNull(j['steps_override']),
    extraSteps: _listOfMap(j['extra_steps']),
  );
}

class FlowConfig {
  const FlowConfig({this.stockKeep, this.freshFlash});
  final FlowSpec? stockKeep;
  final FlowSpec? freshFlash;
  factory FlowConfig.fromJson(Map<String, dynamic> j) => FlowConfig(
    stockKeep: j['stock_keep'] is Map
        ? FlowSpec.fromJson((j['stock_keep'] as Map).cast())
        : null,
    freshFlash: j['fresh_flash'] is Map
        ? FlowSpec.fromJson((j['fresh_flash'] as Map).cast())
        : null,
  );
}

class FlowSpec {
  const FlowSpec({
    this.enabled = false,
    this.preconditions = const [],
    this.steps = const [],
  });
  final bool enabled;
  final List<Map<String, dynamic>> preconditions;
  final List<Map<String, dynamic>> steps;
  factory FlowSpec.fromJson(Map<String, dynamic> j) => FlowSpec(
    enabled: j['enabled'] as bool? ?? false,
    preconditions: _listOfMap(j['preconditions']),
    steps: _listOfMap(j['steps']),
  );
}

class VerifierConfig {
  const VerifierConfig({required this.id, required this.raw});
  final String id;
  final Map<String, dynamic> raw;
  factory VerifierConfig.fromJson(Map<String, dynamic> j) =>
      VerifierConfig(id: j['id'] as String, raw: j);
}

// -----------------------------------------------------------------
// small helpers

Map<String, dynamic> _mapOr(Object? v) =>
    (v is Map) ? v.cast<String, dynamic>() : <String, dynamic>{};

Map<String, dynamic>? _mapOrNull(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : null;

List<Map<String, dynamic>> _listOfMap(Object? v) {
  if (v is! List) return const [];
  return v.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
}
