import 'dart:async';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../theming/deckhand_tokens.dart';
import '../utils/user_facing_errors.dart';
import '../widgets/deckhand_loading.dart';
import '../widgets/deckhand_panel.dart';

class ManageTuningPanel extends ConsumerStatefulWidget {
  const ManageTuningPanel({super.key});

  @override
  ConsumerState<ManageTuningPanel> createState() => _ManageTuningPanelState();
}

class _ManageTuningPanelState extends ConsumerState<ManageTuningPanel> {
  final _hotendTarget = TextEditingController(text: '215');
  final _bedTarget = TextEditingController(text: '70');
  final _pressureAdvance = TextEditingController(text: '0.040');
  final _rotationCurrent = TextEditingController();
  final _rotationRequested = TextEditingController(text: '100');
  final _rotationMeasured = TextEditingController();

  Future<_TuningSnapshot>? _snapshot;
  String? _busyScript;
  PrinterConfigPreview? _managedPreview;
  String? _managedError;
  bool _managedBusy = false;

  @override
  void initState() {
    super.initState();
    for (final controller in _inputControllers) {
      controller.addListener(_onTuningInputChanged);
    }
    _refresh();
  }

  @override
  void dispose() {
    for (final controller in _inputControllers) {
      controller.removeListener(_onTuningInputChanged);
    }
    _hotendTarget.dispose();
    _bedTarget.dispose();
    _pressureAdvance.dispose();
    _rotationCurrent.dispose();
    _rotationRequested.dispose();
    _rotationMeasured.dispose();
    super.dispose();
  }

  List<TextEditingController> get _inputControllers => [
    _hotendTarget,
    _bedTarget,
    _pressureAdvance,
    _rotationCurrent,
    _rotationRequested,
    _rotationMeasured,
  ];

  void _onTuningInputChanged() {
    if (!mounted) return;
    setState(() {
      _managedPreview = null;
      _managedError = null;
    });
  }

  void _refresh() {
    final host = ref.read(wizardControllerProvider).state.sshHost;
    if (host == null || host.trim().isEmpty) {
      _snapshot = Future.value(const _TuningSnapshot.disconnected());
      return;
    }
    final moonraker = ref.read(moonrakerServiceProvider);
    setState(() {
      _snapshot = _loadSnapshot(moonraker, host.trim());
    });
  }

  Future<_TuningSnapshot> _loadSnapshot(
    MoonrakerService moonraker,
    String host,
  ) async {
    try {
      final status = await moonraker.queryObjects(
        host: host,
        objects: const [
          'configfile',
          'extruder',
          'gcode_move',
          'heater_bed',
          'print_stats',
          'toolhead',
        ],
      );
      final snapshot = _TuningSnapshot.fromMoonraker(host, status);
      final rotation = snapshot.rotationDistance;
      if (rotation != null && _rotationCurrent.text.trim().isEmpty) {
        _rotationCurrent.text = rotation.toStringAsFixed(4);
      }
      return snapshot;
    } catch (e) {
      return _TuningSnapshot.error(host: host, message: userFacingError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final configService = ref.watch(printerConfigServiceProvider);
    return FutureBuilder<_TuningSnapshot>(
      future: _snapshot,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const DeckhandLoadingBlock(
            kind: DeckhandLoaderKind.oscilloscope,
            title: 'Loading printer tuning',
            message: 'Reading live Klipper status before enabling controls.',
          );
        }
        final snapshot = snap.data ?? const _TuningSnapshot.disconnected();
        if (snapshot.host == null) {
          return DeckhandPanel(
            head: const DeckhandPanelHead(label: 'TUNING'),
            child: Text(
              'Connect to a printer before opening tuning controls.',
              style: TextStyle(
                fontFamily: DeckhandTokens.fontSans,
                fontSize: DeckhandTokens.tMd,
                color: tokens.text2,
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TuningHeader(snapshot: snapshot, onRefresh: _refresh),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 840;
                final controls = [
                  _PidPanel(
                    snapshot: snapshot,
                    hotendTarget: _hotendTarget,
                    bedTarget: _bedTarget,
                    busyScript: _busyScript,
                    onRun: _runScript,
                  ),
                  _MotionPanel(
                    snapshot: snapshot,
                    pressureAdvance: _pressureAdvance,
                    rotationCurrent: _rotationCurrent,
                    rotationRequested: _rotationRequested,
                    rotationMeasured: _rotationMeasured,
                    busyScript: _busyScript,
                    onRun: _runScript,
                  ),
                  _InputShaperPanel(
                    snapshot: snapshot,
                    busyScript: _busyScript,
                    onRun: _runScript,
                  ),
                ];
                if (narrow) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final panel in controls) ...[
                        panel,
                        const SizedBox(height: 12),
                      ],
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: controls[0]),
                    const SizedBox(width: 12),
                    Expanded(child: controls[1]),
                    const SizedBox(width: 12),
                    Expanded(child: controls[2]),
                  ],
                );
              },
            ),
            if (configService != null) ...[
              const SizedBox(height: 14),
              _ManagedConfigPanel(
                snapshot: snapshot,
                settingsText: _managedSettingsText(snapshot),
                preview: _managedPreview,
                error: _managedError,
                busy: _managedBusy,
                onPreview: () => _previewManagedConfig(configService),
                onApply: () => _applyManagedConfig(configService),
              ),
            ],
          ],
        );
      },
    );
  }

  Future<void> _runScript(String script) async {
    final snapshot = await _snapshot;
    final host = snapshot?.host;
    if (host == null || snapshot?.printing == true) return;
    setState(() => _busyScript = script);
    try {
      await ref
          .read(moonrakerServiceProvider)
          .runGCode(host: host, script: script);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Sent $script')));
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Tuning command failed: ${userFacingError(e)}')),
      );
    } finally {
      if (mounted) setState(() => _busyScript = null);
    }
  }

  Map<String, String> _managedSettings(_TuningSnapshot snapshot) {
    final values = <String, String>{};
    final pa = _pressureAdvance.text.trim();
    if (pa.isNotEmpty) {
      values['pressure_advance'] = pa;
    }
    final rotation = _rotationCurrent.text.trim();
    if (rotation.isNotEmpty) {
      values['rotation_distance'] = rotation;
    } else if (snapshot.rotationDistance != null) {
      values['rotation_distance'] = snapshot.rotationDistance!.toStringAsFixed(
        6,
      );
    }
    return values;
  }

  String _managedSettingsText(_TuningSnapshot snapshot) {
    final lines = <String>['[extruder]'];
    for (final entry in _managedSettings(snapshot).entries) {
      lines.add('${entry.key}: ${entry.value}');
    }
    return '${lines.join('\n')}\n';
  }

  Future<void> _previewManagedConfig(PrinterConfigService service) async {
    final snapshot = await _snapshot;
    final session = ref.read(wizardControllerProvider).sshSession;
    if (session == null || snapshot?.printing == true) return;
    setState(() {
      _managedBusy = true;
      _managedError = null;
    });
    try {
      final path = defaultPrinterConfigPath(session);
      final document = await service.read(session, path: path);
      final preview = service.previewSectionSettings(
        original: document.content,
        section: 'extruder',
        values: _managedSettings(snapshot!),
      );
      if (!mounted) return;
      setState(() => _managedPreview = preview);
    } catch (e) {
      if (!mounted) return;
      setState(() => _managedError = userFacingError(e));
    } finally {
      if (mounted) setState(() => _managedBusy = false);
    }
  }

  Future<void> _applyManagedConfig(PrinterConfigService service) async {
    final snapshot = await _snapshot;
    final session = ref.read(wizardControllerProvider).sshSession;
    if (session == null || snapshot?.printing == true) return;
    setState(() {
      _managedBusy = true;
      _managedError = null;
    });
    try {
      final path = defaultPrinterConfigPath(session);
      final result = await service.applySectionSettings(
        session,
        path: path,
        section: 'extruder',
        values: _managedSettings(snapshot!),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.changed
                ? 'Managed printer.cfg updated; backup at ${result.backupPath}'
                : 'Managed printer.cfg already up to date',
          ),
        ),
      );
      _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _managedError = userFacingError(e));
    } finally {
      if (mounted) setState(() => _managedBusy = false);
    }
  }
}

class _ManagedConfigPanel extends StatelessWidget {
  const _ManagedConfigPanel({
    required this.snapshot,
    required this.settingsText,
    required this.preview,
    required this.error,
    required this.busy,
    required this.onPreview,
    required this.onApply,
  });

  final _TuningSnapshot snapshot;
  final String settingsText;
  final PrinterConfigPreview? preview;
  final String? error;
  final bool busy;
  final VoidCallback onPreview;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final disabled = snapshot.printing || busy;
    final status = preview == null
        ? null
        : preview!.changed
        ? 'Preview ready - pending change'
        : 'Preview ready - already up to date';
    return DeckhandPanel(
      head: const DeckhandPanelHead(label: 'MANAGED PRINTER.CFG'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            constraints: const BoxConstraints(minHeight: 96),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: tokens.ink2,
              border: Border.all(color: tokens.line),
              borderRadius: BorderRadius.circular(DeckhandTokens.r2),
            ),
            child: SelectableText(
              settingsText,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontMono,
                fontSize: DeckhandTokens.tSm,
                height: 1.45,
                color: tokens.text,
              ),
            ),
          ),
          if (status != null || error != null) ...[
            const SizedBox(height: 10),
            Text(
              error ?? status!,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontSans,
                fontSize: DeckhandTokens.tSm,
                color: error == null ? tokens.text2 : tokens.bad,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                icon: busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: DeckhandSpinner(size: 14, strokeWidth: 2),
                      )
                    : const Icon(Icons.visibility_outlined, size: 16),
                label: const Text('Preview'),
                onPressed: disabled ? null : onPreview,
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.backup_table_outlined, size: 16),
                label: const Text('Apply with backup'),
                onPressed: disabled ? null : onApply,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TuningHeader extends StatelessWidget {
  const _TuningHeader({required this.snapshot, required this.onRefresh});

  final _TuningSnapshot snapshot;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return DeckhandPanel(
      head: DeckhandPanelHead(
        label: 'LIVE PRINTER',
        trailing: IconButton(
          tooltip: 'Refresh',
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh, size: 16),
          visualDensity: VisualDensity.compact,
        ),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          _StatusChip(
            label: 'Host',
            value: snapshot.host ?? '',
            color: tokens.info,
          ),
          _StatusChip(
            label: 'State',
            value: snapshot.printing ? 'Printing' : snapshot.printState,
            color: snapshot.printing ? tokens.warn : tokens.ok,
          ),
          _StatusChip(
            label: 'Hotend',
            value: _tempLabel(snapshot.hotendTemperature),
            color: tokens.text3,
          ),
          _StatusChip(
            label: 'Bed',
            value: _tempLabel(snapshot.bedTemperature),
            color: tokens.text3,
          ),
          if (snapshot.error != null)
            _StatusChip(
              label: 'Error',
              value: snapshot.error!,
              color: tokens.bad,
            ),
        ],
      ),
    );
  }
}

class _PidPanel extends StatelessWidget {
  const _PidPanel({
    required this.snapshot,
    required this.hotendTarget,
    required this.bedTarget,
    required this.busyScript,
    required this.onRun,
  });

  final _TuningSnapshot snapshot;
  final TextEditingController hotendTarget;
  final TextEditingController bedTarget;
  final String? busyScript;
  final Future<void> Function(String script) onRun;

  @override
  Widget build(BuildContext context) {
    return DeckhandPanel(
      head: const DeckhandPanelHead(label: 'PID'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CommandRow(
            label: 'Hotend',
            controller: hotendTarget,
            suffix: 'C',
            scriptBuilder: () =>
                'PID_CALIBRATE HEATER=extruder TARGET=${hotendTarget.text.trim()}',
            enabled: !snapshot.printing,
            busyScript: busyScript,
            onRun: onRun,
          ),
          const SizedBox(height: 10),
          _CommandRow(
            label: 'Bed',
            controller: bedTarget,
            suffix: 'C',
            scriptBuilder: () =>
                'PID_CALIBRATE HEATER=heater_bed TARGET=${bedTarget.text.trim()}',
            enabled: !snapshot.printing,
            busyScript: busyScript,
            onRun: onRun,
          ),
          const SizedBox(height: 12),
          _ScriptButton(
            label: 'Save config',
            icon: Icons.save_outlined,
            script: 'SAVE_CONFIG',
            enabled: !snapshot.printing,
            busyScript: busyScript,
            onRun: onRun,
          ),
        ],
      ),
    );
  }
}

class _MotionPanel extends StatelessWidget {
  const _MotionPanel({
    required this.snapshot,
    required this.pressureAdvance,
    required this.rotationCurrent,
    required this.rotationRequested,
    required this.rotationMeasured,
    required this.busyScript,
    required this.onRun,
  });

  final _TuningSnapshot snapshot;
  final TextEditingController pressureAdvance;
  final TextEditingController rotationCurrent;
  final TextEditingController rotationRequested;
  final TextEditingController rotationMeasured;
  final String? busyScript;
  final Future<void> Function(String script) onRun;

  @override
  Widget build(BuildContext context) {
    final nextRotation = _nextRotationDistance;
    return DeckhandPanel(
      head: const DeckhandPanelHead(label: 'EXTRUSION'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CommandRow(
            label: 'Pressure advance',
            controller: pressureAdvance,
            suffix: '',
            scriptBuilder: () =>
                'SET_PRESSURE_ADVANCE ADVANCE=${pressureAdvance.text.trim()}',
            enabled: !snapshot.printing,
            busyScript: busyScript,
            onRun: onRun,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _NumberField(
                  label: 'Current',
                  controller: rotationCurrent,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _NumberField(
                  label: 'Asked',
                  controller: rotationRequested,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _NumberField(
                  label: 'Measured',
                  controller: rotationMeasured,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _ScriptButton(
            label: nextRotation == null
                ? 'Apply rotation'
                : 'Apply ${nextRotation.toStringAsFixed(4)}',
            icon: Icons.straighten,
            script: nextRotation == null
                ? ''
                : 'SET_EXTRUDER_ROTATION_DISTANCE EXTRUDER=extruder '
                      'DISTANCE=${nextRotation.toStringAsFixed(6)}',
            enabled: !snapshot.printing && nextRotation != null,
            busyScript: busyScript,
            onRun: onRun,
          ),
        ],
      ),
    );
  }

  double? get _nextRotationDistance {
    final current = double.tryParse(rotationCurrent.text.trim());
    final requested = double.tryParse(rotationRequested.text.trim());
    final measured = double.tryParse(rotationMeasured.text.trim());
    if (current == null || requested == null || measured == null) return null;
    if (current <= 0 || requested <= 0 || measured <= 0) return null;
    return current * measured / requested;
  }
}

class _InputShaperPanel extends StatelessWidget {
  const _InputShaperPanel({
    required this.snapshot,
    required this.busyScript,
    required this.onRun,
  });

  final _TuningSnapshot snapshot;
  final String? busyScript;
  final Future<void> Function(String script) onRun;

  @override
  Widget build(BuildContext context) {
    return DeckhandPanel(
      head: const DeckhandPanelHead(label: 'INPUT SHAPER'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ScriptButton(
            label: 'Auto calibrate',
            icon: Icons.graphic_eq,
            script: 'SHAPER_CALIBRATE',
            enabled: !snapshot.printing,
            busyScript: busyScript,
            onRun: onRun,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _ScriptButton(
                  label: 'Test X',
                  icon: Icons.swap_horiz,
                  script: 'TEST_RESONANCES AXIS=X',
                  enabled: !snapshot.printing,
                  busyScript: busyScript,
                  onRun: onRun,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _ScriptButton(
                  label: 'Test Y',
                  icon: Icons.swap_vert,
                  script: 'TEST_RESONANCES AXIS=Y',
                  enabled: !snapshot.printing,
                  busyScript: busyScript,
                  onRun: onRun,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _ScriptButton(
            label: 'Save config',
            icon: Icons.save_outlined,
            script: 'SAVE_CONFIG',
            enabled: !snapshot.printing,
            busyScript: busyScript,
            onRun: onRun,
          ),
        ],
      ),
    );
  }
}

class _CommandRow extends StatelessWidget {
  const _CommandRow({
    required this.label,
    required this.controller,
    required this.suffix,
    required this.scriptBuilder,
    required this.enabled,
    required this.busyScript,
    required this.onRun,
  });

  final String label;
  final TextEditingController controller;
  final String suffix;
  final String Function() scriptBuilder;
  final bool enabled;
  final String? busyScript;
  final Future<void> Function(String script) onRun;

  @override
  Widget build(BuildContext context) {
    final script = scriptBuilder();
    return Row(
      children: [
        Expanded(
          child: _NumberField(
            label: label,
            controller: controller,
            suffix: suffix,
          ),
        ),
        const SizedBox(width: 8),
        _ScriptButton(
          label: 'Run',
          icon: Icons.play_arrow,
          script: script,
          enabled: enabled && controller.text.trim().isNotEmpty,
          busyScript: busyScript,
          onRun: onRun,
        ),
      ],
    );
  }
}

class _ScriptButton extends StatelessWidget {
  const _ScriptButton({
    required this.label,
    required this.icon,
    required this.script,
    required this.enabled,
    required this.busyScript,
    required this.onRun,
  });

  final String label;
  final IconData icon;
  final String script;
  final bool enabled;
  final String? busyScript;
  final Future<void> Function(String script) onRun;

  @override
  Widget build(BuildContext context) {
    final busy = busyScript == script;
    return OutlinedButton.icon(
      icon: busy
          ? const SizedBox(
              width: 14,
              height: 14,
              child: DeckhandSpinner(size: 14, strokeWidth: 2),
            )
          : Icon(icon, size: 16),
      label: Text(label),
      onPressed: enabled && !busy && script.isNotEmpty
          ? () => unawaited(onRun(script))
          : null,
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.label,
    required this.controller,
    this.suffix = '',
  });

  final String label;
  final TextEditingController controller;
  final String suffix;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        suffixText: suffix.isEmpty ? null : suffix,
        border: const OutlineInputBorder(),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 42, minWidth: 120),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: tokens.ink2,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label.toUpperCase(),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: 10,
                    color: tokens.text4,
                  ),
                ),
                Text(
                  value.isEmpty ? '-' : value,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tSm,
                    color: tokens.text,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TuningSnapshot {
  const _TuningSnapshot({
    required this.host,
    required this.printState,
    required this.printing,
    required this.hotendTemperature,
    required this.bedTemperature,
    required this.rotationDistance,
  }) : error = null;

  const _TuningSnapshot.disconnected()
    : host = null,
      printState = 'Disconnected',
      printing = false,
      hotendTemperature = null,
      bedTemperature = null,
      rotationDistance = null,
      error = null;

  const _TuningSnapshot.error({required this.host, required String message})
    : printState = 'Unreachable',
      printing = false,
      hotendTemperature = null,
      bedTemperature = null,
      rotationDistance = null,
      error = message;

  factory _TuningSnapshot.fromMoonraker(
    String host,
    Map<String, dynamic> status,
  ) {
    final printStats = _map(status['print_stats']);
    final extruder = _map(status['extruder']);
    final bed = _map(status['heater_bed']);
    final configfile = _map(status['configfile']);
    final state = _string(printStats?['state']) ?? 'idle';
    final settings = _map(configfile?['settings']);
    final extruderSettings = _map(settings?['extruder']);
    return _TuningSnapshot(
      host: host,
      printState: state,
      printing: state == 'printing' || state == 'paused',
      hotendTemperature: _number(extruder?['temperature']),
      bedTemperature: _number(bed?['temperature']),
      rotationDistance: _number(extruderSettings?['rotation_distance']),
    );
  }

  final String? host;
  final String printState;
  final bool printing;
  final double? hotendTemperature;
  final double? bedTemperature;
  final double? rotationDistance;
  final String? error;
}

Map<String, dynamic>? _map(Object? value) {
  if (value is Map) {
    final out = <String, dynamic>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is String) out[key] = entry.value;
    }
    return out;
  }
  return null;
}

String? _string(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

double? _number(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

String _tempLabel(double? value) {
  if (value == null) return '-';
  return '${value.toStringAsFixed(1)} C';
}
