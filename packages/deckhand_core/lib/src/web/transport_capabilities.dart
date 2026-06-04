/// Browser/native transport capability gating for Deckhand flows.
///
/// This model is intentionally pure Dart: Flutter web, desktop UI, HITL tests,
/// and a future local-agent bridge can all evaluate the same profile step
/// without importing `dart:html` or platform channels.

enum DeckhandExecutionSurface { browser, localAgent, desktopApp, unavailable }

class DeckhandTransportAvailability {
  const DeckhandTransportAvailability({
    this.webUsb = false,
    this.webHid = false,
    this.webSerial = false,
    this.manualDownload = true,
    this.localAgent = false,
    this.desktopApp = false,
  });

  final bool webUsb;
  final bool webHid;
  final bool webSerial;
  final bool manualDownload;
  final bool localAgent;
  final bool desktopApp;

  DeckhandTransportAvailability copyWith({
    bool? webUsb,
    bool? webHid,
    bool? webSerial,
    bool? manualDownload,
    bool? localAgent,
    bool? desktopApp,
  }) {
    return DeckhandTransportAvailability(
      webUsb: webUsb ?? this.webUsb,
      webHid: webHid ?? this.webHid,
      webSerial: webSerial ?? this.webSerial,
      manualDownload: manualDownload ?? this.manualDownload,
      localAgent: localAgent ?? this.localAgent,
      desktopApp: desktopApp ?? this.desktopApp,
    );
  }

  bool supportsBrowserRequirement(String requirement) {
    final req = requirement.trim().toLowerCase();
    if (req.startsWith('webusb.')) return webUsb;
    if (req.startsWith('webhid.')) return webHid;
    if (req.startsWith('webserial.')) return webSerial;
    if (req == 'manual.uf2' || req == 'manual-download') {
      return manualDownload;
    }
    return false;
  }

  bool supportsLocalRequirement(String requirement) {
    final req = requirement.trim().toLowerCase();
    if (req == 'raw_disk_write' || req == 'raw-disk-write') {
      return localAgent || desktopApp;
    }
    if (req == 'ssh.lan' || req == 'moonraker.lan') {
      return localAgent || desktopApp;
    }
    if (req == 'local-agent') return localAgent;
    if (req == 'desktop-app') return desktopApp;
    return false;
  }
}

class DeckhandStepTransportGate {
  const DeckhandStepTransportGate({
    required this.surface,
    required this.requirements,
    required this.missingRequirements,
  });

  final DeckhandExecutionSurface surface;
  final List<String> requirements;
  final List<String> missingRequirements;

  bool get isAvailable => surface != DeckhandExecutionSurface.unavailable;

  bool get usesBrowser => surface == DeckhandExecutionSurface.browser;

  bool get requiresNativeFallback =>
      surface == DeckhandExecutionSurface.localAgent ||
      surface == DeckhandExecutionSurface.desktopApp;
}

DeckhandStepTransportGate gateDeckhandStepTransport({
  required Map<String, dynamic> step,
  required DeckhandTransportAvailability availability,
}) {
  final requirements = transportRequirementsForStep(step);
  if (requirements.isEmpty) {
    return const DeckhandStepTransportGate(
      surface: DeckhandExecutionSurface.browser,
      requirements: [],
      missingRequirements: [],
    );
  }

  final missing = <String>[];
  var hasBrowserOnly = false;
  var hasLocalOnly = false;
  for (final requirement in requirements) {
    if (_isBrowserRequirement(requirement)) {
      hasBrowserOnly = true;
      if (!availability.supportsBrowserRequirement(requirement)) {
        missing.add(requirement);
      }
      continue;
    }
    if (_isLocalRequirement(requirement)) {
      hasLocalOnly = true;
      if (!availability.supportsLocalRequirement(requirement)) {
        missing.add(requirement);
      }
      continue;
    }
    missing.add(requirement);
  }

  if (missing.isNotEmpty) {
    return DeckhandStepTransportGate(
      surface: DeckhandExecutionSurface.unavailable,
      requirements: requirements,
      missingRequirements: List.unmodifiable(missing),
    );
  }
  if (hasLocalOnly) {
    return DeckhandStepTransportGate(
      surface: availability.localAgent
          ? DeckhandExecutionSurface.localAgent
          : DeckhandExecutionSurface.desktopApp,
      requirements: requirements,
      missingRequirements: const [],
    );
  }
  if (hasBrowserOnly) {
    return DeckhandStepTransportGate(
      surface: DeckhandExecutionSurface.browser,
      requirements: requirements,
      missingRequirements: const [],
    );
  }
  return const DeckhandStepTransportGate(
    surface: DeckhandExecutionSurface.unavailable,
    requirements: [],
    missingRequirements: [],
  );
}

List<String> transportRequirementsForStep(Map<String, dynamic> step) {
  final explicit = _stringList(
    step['transport_requirements'] ?? step['transport_requirement'],
  );
  if (explicit.isNotEmpty) return explicit;

  final kind = step['kind']?.toString().trim().toLowerCase();
  switch (kind) {
    case 'disk_picker':
    case 'write_image':
    case 'flash_os':
    case 'backup_disk':
    case 'restore_backup':
      return const ['raw_disk_write'];
    case 'ssh_commands':
    case 'write_file':
    case 'wait_for_ssh':
    case 'moonraker_rpc':
      return const ['ssh.lan'];
    case 'mcu_flash':
    case 'flash_mcus':
      return const ['local-agent'];
    default:
      return const [];
  }
}

bool _isBrowserRequirement(String requirement) {
  final req = requirement.trim().toLowerCase();
  return req.startsWith('webusb.') ||
      req.startsWith('webhid.') ||
      req.startsWith('webserial.') ||
      req == 'manual.uf2' ||
      req == 'manual-download';
}

bool _isLocalRequirement(String requirement) {
  final req = requirement.trim().toLowerCase();
  return req == 'raw_disk_write' ||
      req == 'raw-disk-write' ||
      req == 'ssh.lan' ||
      req == 'moonraker.lan' ||
      req == 'local-agent' ||
      req == 'desktop-app';
}

List<String> _stringList(Object? raw) {
  if (raw == null) return const [];
  if (raw is String) {
    final trimmed = raw.trim();
    return trimmed.isEmpty ? const [] : [trimmed];
  }
  if (raw is! List) return const [];
  return List.unmodifiable([
    for (final value in raw)
      if (value is String && value.trim().isNotEmpty) value.trim(),
  ]);
}
