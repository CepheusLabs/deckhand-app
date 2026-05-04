import 'package:deckhand_core/deckhand_core.dart';

import 'deckhand_wizard_stepper.dart';

/// Shared map between the wizard's S-IDs (`S15`, `S40`, …), the
/// router routes, and the design-language phase grouping.
///
/// Both [DeckhandStepper] (top of every screen) and the sidenav
/// reach into this so the two stay in sync — change a phase here and
/// both surfaces pick it up.
class WizardNavMap {
  WizardNavMap._();

  /// Canonical 5-phase grouping. Order matches the design language
  /// reference (Entry → Configure → Flash → Install → Done).
  ///
  /// `S40` (Choose path) lives in Entry rather than Configure because
  /// it gates which subsequent phases even apply: a fresh-flash run
  /// never visits `S20`/`S30` (there's no working OS to SSH into).
  /// `S20`/`S30` stay in Entry for the stock-keep flow; they're
  /// filtered out per-flow by `_stepIdsForPhase` in the chrome.
  static const phases = <WizardPhase>[
    WizardPhase(
      id: 'entry',
      label: 'Entry',
      stepIds: ['S10', 'S15', 'S40', 'S20', 'S30'],
    ),
    WizardPhase(
      id: 'configure',
      label: 'Configure',
      stepIds: [
        'S100',
        'S105',
        'S107',
        'S110',
        'S120',
        'S140',
        'S145',
        'S150',
      ],
    ),
    WizardPhase(
      id: 'flash',
      label: 'Flash',
      stepIds: ['S200', 'S210', 'S220', 'S230', 'S240', 'S250'],
    ),
    WizardPhase(
      id: 'install',
      label: 'Install',
      stepIds: ['S800', 'S900'],
    ),
    WizardPhase(
      id: 'done',
      label: 'Done',
      stepIds: ['S910'],
    ),
  ];

  static const stepLabels = <String, String>{
    'S10': 'Welcome',
    'S15': 'Pick printer',
    'S20': 'Connect',
    'S30': 'Verify',
    'S40': 'Choose path',
    'S100': 'Firmware',
    'S105': 'Web UI',
    'S107': 'KIAUH',
    'S110': 'Screen daemon',
    'S120': 'Vendor services',
    'S140': 'Files cleanup',
    'S145': 'Snapshot',
    'S150': 'Hardening',
    'S200': 'Flash target',
    'S210': 'Choose OS',
    'S220': 'Flash confirm',
    'S230': 'Flash progress',
    'S240': 'First boot',
    'S250': 'Provision OS',
    'S800': 'Review',
    'S900': 'Install progress',
    'S910': 'Done',
  };

  /// Per-flow ordering used to compute "visited" sets. Choose-path
  /// (S40) runs immediately after Pick-printer so the path-specific
  /// branches never make the user sit through irrelevant steps:
  /// fresh-flash skips Connect (S20) + Verify (S30) entirely because
  /// the eMMC is being wiped and there's no working OS to SSH into.
  /// Stock-keep keeps the Connect/Verify pair right after Choose-path.
  static List<String> orderForFlow(WizardFlow flow) {
    switch (flow) {
      case WizardFlow.stockKeep:
        return const [
          'S10', 'S15', 'S40', 'S20', 'S30',
          'S100', 'S105', 'S107', 'S110', 'S120', 'S140', 'S145', 'S150',
          'S800', 'S900', 'S910',
        ];
      case WizardFlow.freshFlash:
        return const [
          'S10', 'S15', 'S40',
          'S200', 'S210', 'S220', 'S230', 'S240', 'S250',
          'S100', 'S105', 'S107', 'S110',
          'S800', 'S900', 'S910',
        ];
      case WizardFlow.none:
        return const ['S10', 'S15', 'S40'];
    }
  }

  /// Per-flow phase ordering for the stepper. The static [phases] list
  /// is canonical (Entry → Configure → Flash → Install → Done) but
  /// the *rendered* order matters: in a fresh-flash the user does
  /// Flash BEFORE Configure (you can't configure firmware until the
  /// disk is wiped + the new OS is up), and stock-keep skips Flash
  /// entirely. Rendering the canonical order regardless made the
  /// fresh-flash UI show Configure with green checkmarks before the
  /// user had reached it — which read as "the wizard is jumping
  /// ahead." Each phase's `stepIds` is also filtered to only those
  /// visible in [orderForFlow] so a fresh-flash never displays
  /// stock-only steps like Vendor Services / Files cleanup.
  static List<WizardPhase> phasesForFlow(WizardFlow flow) {
    final visible = orderForFlow(flow).toSet();
    WizardPhase filter(WizardPhase p) => WizardPhase(
          id: p.id,
          label: p.label,
          stepIds: p.stepIds.where(visible.contains).toList(growable: false),
        );
    final byId = {for (final p in phases) p.id: filter(p)};
    final order = switch (flow) {
      WizardFlow.stockKeep => const [
          'entry',
          'configure',
          'install',
          'done',
        ],
      WizardFlow.freshFlash => const [
          'entry',
          'flash',
          'configure',
          'install',
          'done',
        ],
      WizardFlow.none => const ['entry'],
    };
    return [
      for (final id in order)
        if (byId[id] != null && byId[id]!.stepIds.isNotEmpty) byId[id]!,
    ];
  }

  /// /progress carries multiple S-IDs depending on flow + stepKind.
  /// During fresh-flash's flashing phase it's S230; during install
  /// it's S900. Kept in sync with the unified progress screen.
  static String routeToSid({
    required String location,
    required WizardFlow flow,
    required String? stepKind,
  }) {
    if (location == '/progress') {
      return switch (stepKind) {
        'os_download' || 'flash_disk' => 'S230',
        'wait_for_ssh' => 'S240',
        _ => 'S900',
      };
    }
    return _routeMap[location] ?? 'S10';
  }

  /// Inverse of [routeToSid]. Returns null when [sid] has no
  /// dedicated route (rare; defensive).
  static String? sidToRoute(String sid) => _sidRouteMap[sid];

  /// Phase id of the phase that contains [sid]. Falls back to
  /// `'entry'` for unknown ids so the chrome never crashes on a
  /// stray route during a flow transition.
  static String phaseFor(String sid) {
    for (final p in phases) {
      if (p.stepIds.contains(sid)) return p.id;
    }
    return 'entry';
  }

  /// True iff [location] is one of the wizard's step routes. Used by
  /// the chrome to decide whether to render the left-rail wizard
  /// nav: orthogonal pages like `/settings` and the error screen
  /// shouldn't show the wizard's step list, since they aren't part
  /// of any flow.
  static bool isWizardRoute(String location) =>
      _routeMap.containsKey(location);

  static const _routeMap = <String, String>{
    '/': 'S10',
    '/pick-printer': 'S15',
    '/connect': 'S20',
    '/verify': 'S30',
    '/choose-path': 'S40',
    '/firmware': 'S100',
    '/webui': 'S105',
    '/kiauh': 'S107',
    '/screen-choice': 'S110',
    '/services': 'S120',
    '/files': 'S140',
    '/snapshot': 'S145',
    '/hardening': 'S150',
    '/flash-target': 'S200',
    '/choose-os': 'S210',
    '/flash-confirm': 'S220',
    '/flash-progress': 'S230',
    '/first-boot': 'S240',
    '/first-boot-setup': 'S250',
    '/review': 'S800',
    '/done': 'S910',
  };

  static const _sidRouteMap = <String, String>{
    'S10': '/',
    'S15': '/pick-printer',
    'S20': '/connect',
    'S30': '/verify',
    'S40': '/choose-path',
    'S100': '/firmware',
    'S105': '/webui',
    'S107': '/kiauh',
    'S110': '/screen-choice',
    'S120': '/services',
    'S140': '/files',
    'S145': '/snapshot',
    'S150': '/hardening',
    'S200': '/flash-target',
    'S210': '/choose-os',
    'S220': '/flash-confirm',
    'S230': '/progress',
    'S240': '/progress',
    'S250': '/first-boot-setup',
    'S800': '/review',
    'S900': '/progress',
    'S910': '/done',
  };
}
