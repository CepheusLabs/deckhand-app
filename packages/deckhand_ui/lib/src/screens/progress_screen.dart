import 'dart:async';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../theming/deckhand_tokens.dart';
import '../utils/disk_display.dart';
import '../utils/disk_operation_errors.dart';
import '../widgets/deckhand_prompt_card.dart';
import '../widgets/host_approval_gate.dart';
import '../widgets/profile_text.dart';
import '../widgets/progress_run_workspace.dart';
import '../widgets/wizard_progress_bar.dart';
import '../widgets/wizard_scaffold.dart';

String progressRunErrorMessage(Object? error) =>
    userFacingDiskOperationError(error);

class ProgressScreen extends ConsumerStatefulWidget {
  const ProgressScreen({super.key});

  @override
  ConsumerState<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends ConsumerState<ProgressScreen> {
  final _log = <String>[];
  final _stepStatusById = <String, RunStepStatus>{};
  // Distinct request IDs seen from egressEvents. Completion events
  // replace the corresponding start event so the Network panel can
  // render stable rows even if the user opens the tab after the
  // request finished.
  final _egressById = <String, EgressEvent>{};
  StreamSubscription<EgressEvent>? _egressSub;
  bool _done = false;
  bool _failed = false;
  bool _cancelled = false;
  bool _cancelRequested = false;
  String? _error;
  double? _currentFraction;
  bool _currentProgressIndeterminate = false;
  String? _currentProgressMessage;
  // What step kind is live right now? Drives the title so the user
  // sees "Downloading image" during os_download, "Writing image"
  // during flash_disk, etc. - not a blanket "Installing..." even
  // when we're halfway through an eMMC write.
  String? _currentStepKind;
  String? _currentStepId;
  StreamSubscription<WizardEvent>? _wizardSub;

  @override
  void initState() {
    super.initState();
    final security = ref.read(securityServiceProvider);
    _egressSub = security.egressEvents.listen((e) {
      if (!mounted) return;
      setState(() => _egressById[e.requestId] = e);
    });
    _startExecution();
  }

  @override
  void dispose() {
    _wizardSub?.cancel();
    _egressSub?.cancel();
    super.dispose();
  }

  Future<void> _startExecution() async {
    final controller = ref.read(wizardControllerProvider);
    _wizardSub = controller.events.listen(_onEvent);
    try {
      final profile = controller.profile;
      if (profile != null) {
        final approved = await HostApprovalGate.ensureHostsApproved(
          ref,
          context,
          candidates: profileNetworkHosts(profile),
        );
        if (!approved) {
          throw StepExecutionException(
            'Network access was not approved for this profile.',
          );
        }
      }
      if (!mounted) return;
      await HostApprovalGate.runGuarded(
        ref,
        context,
        action: controller.startExecution,
      );
      if (!mounted) return;
      setState(() {
        _done = true;
        _cancelled = false;
        _currentStepKind = null;
        _currentStepId = null;
        _currentProgressIndeterminate = false;
      });
    } on WizardHandoffRequiredException catch (e) {
      if (!mounted) return;
      setState(() {
        _done = false;
        _failed = false;
        _cancelled = false;
        _error = null;
        _currentStepKind = null;
        _currentStepId = null;
        _currentProgressIndeterminate = false;
      });
      context.go(e.route);
    } on WizardCancelledException catch (e) {
      if (!mounted) return;
      setState(() {
        _done = false;
        _failed = false;
        _cancelled = true;
        _cancelRequested = false;
        _error = e.reason;
        _currentStepKind = null;
        _currentStepId = null;
        _currentProgressIndeterminate = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _cancelled = false;
        _cancelRequested = false;
        _error = progressRunErrorMessage(e);
        _currentStepKind = null;
        _currentStepId = null;
        _currentProgressIndeterminate = false;
      });
    } finally {
      await _wizardSub?.cancel();
      _wizardSub = null;
    }
  }

  void _onEvent(WizardEvent e) {
    if (!mounted) return;
    switch (e) {
      case StepStarted(:final stepId):
        setState(() {
          _log.add('> starting $stepId');
          _stepStatusById[stepId] = RunStepStatus.active;
          _currentStepId = stepId;
          _currentStepKind = _lookupStepKind(stepId);
          _currentFraction = null;
          _currentProgressIndeterminate = false;
          _currentProgressMessage = null;
        });
      case StepCompleted(:final stepId):
        setState(() {
          _log.add('[ok] $stepId');
          _stepStatusById[stepId] = RunStepStatus.done;
          if (_currentStepId == stepId) {
            _currentFraction = null;
            _currentProgressIndeterminate = false;
            _currentProgressMessage = null;
          }
        });
      case StepFailed(:final stepId, :final error):
        setState(() {
          _log.add('[fail] $stepId - $error');
          _stepStatusById[stepId] = RunStepStatus.failed;
        });
      case StepLog(:final line):
        setState(() => _log.add(line));
      case StepWarning(:final stepId, :final message):
        setState(() {
          _log.add('[warn] $stepId - $message');
          _stepStatusById.putIfAbsent(stepId, () => RunStepStatus.warning);
        });
      case StepProgress(:final percent, :final message):
        setState(() {
          _currentProgressIndeterminate = percent == null;
          _currentFraction = percent?.clamp(0, 1).toDouble();
          _currentProgressMessage = message;
        });
      case UserInputRequired(:final stepId, :final step):
        _handleUserInput(stepId, step);
      case _:
        break;
    }
  }

  /// Look up the kind of the step that just started by scanning the
  /// active flow. Needed because StepStarted carries only the id, but
  /// the title we render is kind-driven ("Downloading" vs "Flashing"
  /// vs "Installing").
  String? _lookupStepKind(String stepId) {
    final controller = ref.read(wizardControllerProvider);
    final profile = controller.profile;
    if (profile == null) return null;
    final flow = controller.state.flow == WizardFlow.stockKeep
        ? profile.flows.stockKeep
        : profile.flows.freshFlash;
    final step = flow?.steps.firstWhere(
      (s) => s['id'] == stepId,
      orElse: () => const <String, dynamic>{},
    );
    return _jsonString(step?['kind']);
  }

  Future<void> _handleUserInput(
    String stepId,
    Map<String, dynamic> step,
  ) async {
    final kind = _jsonString(step['kind']) ?? '';
    final controller = ref.read(wizardControllerProvider);
    switch (kind) {
      case 'prompt':
        final result = await _showPromptDialog(step);
        if (!mounted) return;
        controller.resolveUserInput(stepId, result);
      case 'choose_one':
        final result = await _showChooseOneDialog(step);
        if (!mounted) return;
        controller.resolveUserInput(stepId, result);
      case 'disk_picker':
        final result = await _showDiskPickerDialog(step);
        if (!mounted) return;
        controller.resolveUserInput(stepId, result);
      default:
        controller.resolveUserInput(stepId, null);
    }
  }

  Future<String?> _showPromptDialog(Map<String, dynamic> step) async {
    final message = _jsonString(step['message']) ?? '';
    final rawActions = _jsonList(step['actions']);
    final actions = rawActions
        .map(_stringKeyMap)
        .whereType<Map<String, dynamic>>()
        .map(
          (c) => (
            id: _jsonString(c['id']) ?? '',
            label: _jsonString(c['label']) ?? '',
          ),
        )
        .where((a) => a.id.isNotEmpty && a.label.isNotEmpty)
        .toList();
    final buttons = actions.isEmpty
        ? [(id: 'continue', label: t.progress.prompt_default_action)]
        : actions;
    final title = _jsonString(step['title']) ?? t.progress.prompt_default_title;
    return _showFadedDialog<String>(
      barrierDismissible: false,
      child: Center(
        child: DeckhandPromptCard(
          title: title,
          message: flattenProfileText(message),
          buttons: [
            for (final a in buttons)
              (id: a.id, label: a.label, severity: _severityFor(a.label)),
          ],
        ),
      ),
    );
  }

  /// Heuristic — profile authors signal hierarchy through the label
  /// suffix today (`(recommended)` / `(not recommended)`). Translating
  /// that to a [PromptSeverity] lets the dialog render a primary
  /// FilledButton for the recommended path and a warning-tinted text
  /// button for the destructive escape hatch, instead of three
  /// indistinguishable TextButtons.
  PromptSeverity _severityFor(String label) {
    final l = label.toLowerCase();
    if (l.contains('not recommended') ||
        l.contains('skip') ||
        l.contains('destructive')) {
      return PromptSeverity.destructive;
    }
    if (l.contains('recommended')) return PromptSeverity.recommended;
    return PromptSeverity.neutral;
  }

  Future<String?> _showChooseOneDialog(Map<String, dynamic> step) async {
    final profile = ref.read(wizardControllerProvider).profile;
    final options = _resolveChooseOneOptions(step, profile);
    if (options.isEmpty) return null;
    String? choice = options.first.id.isEmpty ? null : options.first.id;
    return _showFadedDialog<String>(
      barrierDismissible: false,
      child: StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(
            _jsonString(step['title']) ?? t.progress.choose_one_default_title,
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_jsonString(step['question']) case final question?) ...[
                Text(flattenProfileText(question)),
                const SizedBox(height: 16),
              ],
              RadioGroup<String>(
                groupValue: choice,
                onChanged: (v) => setLocal(() => choice = v),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final o in options)
                      RadioListTile<String>(
                        value: o.id,
                        title: Text(o.label),
                        subtitle: o.subtitle == null ? null : Text(o.subtitle!),
                      ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: choice == null || choice!.isEmpty
                  ? null
                  : () =>
                        Navigator.of(context, rootNavigator: true).pop(choice),
              child: Text(t.progress.choose_one_ok),
            ),
          ],
        ),
      ),
    );
  }

  /// Resolves choice options for a `choose_one` step. Supports four
  /// shapes the profile schema allows:
  ///   1. inline `options: [{id, label, description?}, ...]`
  ///   2. `options_from: os.fresh_install_options` (OS images)
  ///   3. `options_from: firmware.choices` (firmware variants)
  ///   4. `options_from: screens` / `addons` / `mcus` (profile-level
  ///      lists keyed by id + display_name)
  ///   5. `options_from: stack.webui.choices` (web UI choices)
  /// Unknown paths fail loud with a log line so profile authors get
  /// a usable error instead of a silent empty dialog.
  List<({String id, String label, String? subtitle})> _resolveChooseOneOptions(
    Map<String, dynamic> step,
    PrinterProfile? profile,
  ) {
    final inline = _jsonList(step['options']);
    if (inline.isNotEmpty) {
      return inline
          .map(_stringKeyMap)
          .whereType<Map<String, dynamic>>()
          .map((c) {
            final id = _jsonString(c['id']) ?? '';
            return (
              id: id,
              label: _jsonString(c['label']) ?? id,
              subtitle: _jsonString(c['description']),
            );
          })
          .where((o) => o.id.isNotEmpty && o.label.isNotEmpty)
          .toList();
    }
    final from = _jsonString(step['options_from']);
    if (from == null || profile == null) return const [];
    switch (from) {
      case 'os.fresh_install_options':
        return profile.os.freshInstallOptions
            .map((o) => (id: o.id, label: o.displayName, subtitle: o.notes))
            .toList();
      case 'firmware.choices':
        return profile.firmware.choices
            .map(
              (c) => (id: c.id, label: c.displayName, subtitle: c.description),
            )
            .toList();
      case 'screens':
        return profile.screens
            .map(
              (s) => (
                id: s.id,
                label: s.displayName ?? s.id,
                subtitle: _jsonString(s.raw['description']),
              ),
            )
            .toList();
      case 'addons':
        return profile.addons
            .map(
              (a) => (
                id: a.id,
                label: a.displayName ?? a.id,
                subtitle: _jsonString(a.raw['description']),
              ),
            )
            .toList();
      case 'mcus':
        return profile.mcus
            .map(
              (m) => (
                id: m.id,
                label: m.displayName ?? m.id,
                subtitle: _jsonString(m.raw['description']),
              ),
            )
            .toList();
      case 'stack.webui.choices':
        final choices = _jsonList(profile.stack.webui?['choices']);
        return choices
            .map(_stringKeyMap)
            .whereType<Map<String, dynamic>>()
            .map((m) {
              final id = _jsonString(m['id']) ?? '';
              return (
                id: id,
                label: _jsonString(m['display_name']) ?? id,
                subtitle: _jsonString(m['description']),
              );
            })
            .where((o) => o.id.isNotEmpty && o.label.isNotEmpty)
            .toList();
      default:
        // Fail loud but visibly. Previously this logged via
        // debugPrint (no-op in release), leaving the user with an
        // empty options dialog and no explanation. Surface a single
        // pseudo-option that explains the problem in plain English;
        // the Continue button stays disabled because there's nothing
        // real to select.
        return [
          (
            id: '',
            label: t.progress.choose_one_unknown_label,
            subtitle: t.progress.choose_one_unknown_subtitle(field: from),
          ),
        ];
    }
  }

  /// Present a list of the host's local disks and let the user pick
  /// one. Reads from [FlashService.listDisks] so the dialog surfaces
  /// the same data the flash_target_screen pre-wizard step uses.
  Future<String?> _showDiskPickerDialog(Map<String, dynamic> step) async {
    final flash = ref.read(flashServiceProvider);
    List<DiskInfo> disks;
    try {
      disks = await flash.listDisks();
    } catch (e) {
      if (!mounted) return null;
      await _showFadedDialog<void>(
        child: AlertDialog(
          title: Text(t.progress.disk_picker_list_error_title),
          content: Text('$e'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
              child: Text(t.progress.choose_one_ok),
            ),
          ],
        ),
      );
      return null;
    }
    final removable = disks.where((d) => d.removable).toList();
    if (removable.isEmpty) {
      if (!mounted) return null;
      await _showFadedDialog<void>(
        child: AlertDialog(
          title: Text(t.progress.disk_picker_no_disks_title),
          content: Text(t.progress.disk_picker_no_disks_body),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
              child: Text(t.progress.choose_one_ok),
            ),
          ],
        ),
      );
      return null;
    }
    String? choice = removable.first.id;
    if (!mounted) return null;
    return _showFadedDialog<String>(
      barrierDismissible: false,
      child: StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(
            _jsonString(step['title']) ?? t.progress.disk_picker_title,
          ),
          content: SizedBox(
            width: 480,
            child: RadioGroup<String>(
              groupValue: choice,
              onChanged: (v) => setLocal(() => choice = v),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final d in removable)
                    RadioListTile<String>(
                      value: d.id,
                      title: Text(diskDisplayName(d)),
                      subtitle: Text(
                        '${(d.sizeBytes / (1 << 30)).toStringAsFixed(1)} GB * '
                        '${d.bus}',
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
              child: Text(t.progress.disk_picker_cancel),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context, rootNavigator: true).pop(choice),
              child: Text(t.progress.disk_picker_confirm),
            ),
          ],
        ),
      ),
    );
  }

  /// Wrap [showDialog] so the modal fades in and out at the same pace
  /// as route transitions. Default Material showDialog scales the
  /// dialog abruptly, which breaks the calm wizard cadence.
  Future<T?> _showFadedDialog<T>({
    required Widget child,
    bool barrierDismissible = true,
  }) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, _, _) => child,
      transitionBuilder: (context, anim, secondary, child) => FadeTransition(
        opacity: CurvedAnimation(
          parent: anim,
          curve: Curves.easeOut,
          reverseCurve: Curves.easeIn,
        ),
        child: child,
      ),
    );
  }

  Future<void> _requestCancel() async {
    if (_cancelRequested || _done || _failed || _cancelled) return;
    final confirmed = await _showFadedDialog<bool>(
      child: AlertDialog(
        icon: const Icon(Icons.warning_amber_outlined),
        title: Text(t.progress.cancel_title),
        content: Text(t.progress.cancel_body),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).pop(false),
            child: Text(t.progress.cancel_keep_running),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).pop(true),
            child: Text(t.progress.cancel_confirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    ref
        .read(wizardControllerProvider)
        .cancelExecution(reason: 'Canceled by user.');
    if (!mounted) return;
    setState(() {
      _cancelRequested = true;
      _currentProgressMessage = t.progress.helper_cancelled;
    });
  }

  /// Title text driven by the currently-running step kind. Keeps the
  /// header honest: during eMMC writes it says "Writing image", not
  /// "Installing..."
  String _titleForState() {
    if (_failed) return t.progress.title_failed;
    if (_cancelled) return t.progress.title_cancelled;
    if (_done) return t.progress.title_done;
    if (_currentStepKind == 'os_download' &&
        (_currentProgressMessage?.startsWith('extracting image') ?? false)) {
      return 'Extracting image';
    }
    return switch (_currentStepKind) {
      'os_download' => t.progress.phase_os_download,
      'flash_disk' => t.progress.phase_flash_disk,
      'wait_for_ssh' => t.progress.phase_wait_for_ssh,
      'install_firmware' => t.progress.phase_install_firmware,
      'install_stack' => t.progress.phase_install_stack,
      'link_extras' => t.progress.phase_link_extras,
      'install_screen' => t.progress.phase_install_screen,
      'flash_mcus' => t.progress.phase_flash_mcus,
      'apply_services' => t.progress.phase_apply_services,
      'apply_files' => t.progress.phase_apply_files,
      'snapshot_paths' => t.progress.phase_snapshot_paths,
      'write_file' => t.progress.phase_write_file,
      'install_marker' => t.progress.phase_install_marker,
      'verify' => t.progress.phase_verify,
      'script' => t.progress.phase_script,
      'ssh_commands' => t.progress.phase_ssh_commands,
      'conditional' => t.progress.phase_conditional,
      _ => t.progress.title_working,
    };
  }

  List<RunStep> _flowSteps() {
    final controller = ref.read(wizardControllerProvider);
    final profile = controller.profile;
    if (profile == null) return const [];
    final flow = controller.state.flow == WizardFlow.stockKeep
        ? profile.flows.stockKeep
        : profile.flows.freshFlash;
    final rawSteps = flow?.steps ?? const <Map<String, dynamic>>[];
    return [
      for (final step in rawSteps)
        RunStep(
          id: _jsonString(step['id']) ?? '',
          kind: _jsonString(step['kind']) ?? '',
        ),
    ].where((step) => step.id.isNotEmpty).toList();
  }

  RunStepStatus _statusForStep(RunStep step) =>
      _stepStatusById[step.id] ?? RunStepStatus.queued;

  double _overallProgressFraction(List<RunStep> steps) {
    if (steps.isEmpty) return 0;
    var completedUnits = 0.0;
    for (final step in steps) {
      final status = _statusForStep(step);
      if (status == RunStepStatus.done) {
        completedUnits += 1;
      } else if (status == RunStepStatus.active) {
        completedUnits += _currentFraction?.clamp(0, 1).toDouble() ?? 0;
      }
    }
    return (completedUnits / steps.length).clamp(0, 1).toDouble();
  }

  int? _activeStepNumber(List<RunStep> steps) {
    final stepId = _currentStepId;
    if (stepId == null) return null;
    final index = steps.indexWhere((step) => step.id == stepId);
    return index < 0 ? null : index + 1;
  }

  double _workspaceHeight(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context).height;
    final target = viewport - 380;
    return target.clamp(420, 680).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final flowSteps = _flowSteps();
    // The header used to be conditional on `(fraction != null ||
    // message != null)`, which made the entire `STEP · <id>` strip
    // disappear during steps that don't emit StepProgress (most SSH
    // commands, snapshot, link_extras). The user read this as a UI
    // glitch ("the top bar randomly disappears"). The strip now stays
    // visible whenever a step is active so the user always knows
    // what's running. The progress bar + percentage are still
    // optional — they fall back to an indeterminate bar when the
    // active step isn't reporting a fraction.
    final hasActiveStep = _currentStepId != null && !_done && !_failed;
    final progressFraction = hasActiveStep
        ? (_currentProgressIndeterminate
              ? null
              : (_currentFraction ?? _overallProgressFraction(flowSteps)))
        : null;
    final activeStepNumber = _activeStepNumber(flowSteps);
    return WizardScaffold(
      screenId: 'S900-progress',
      title: _titleForState(),
      helperText: _failed
          ? 'The run stopped before Deckhand changed anything further. Review the failed step below.'
          : (_cancelled ? t.progress.helper_cancelled : null),
      maxContentWidth: 1440,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasActiveStep) ...[
            _ProgressHeader(
              fraction: progressFraction,
              message: _currentProgressMessage,
              stepId: _currentStepId,
              activeStepNumber: activeStepNumber,
              totalSteps: flowSteps.length,
            ),
            const SizedBox(height: 16),
            Semantics(
              label: t.progress.semantics_progress_label,
              value: t.progress.semantics_progress_percent(
                percent: ((progressFraction ?? 0) * 100).round(),
              ),
              child: WizardProgressBar(
                fraction: progressFraction,
                animateStripes: false,
              ),
            ),
            const SizedBox(height: 18),
          ],
          if (_failed) ...[
            RunBanner(
              title: 'Run stopped',
              message: _error ?? 'Unknown error',
              severity: RunBannerSeverity.error,
            ),
            const SizedBox(height: 16),
          ] else if (_cancelled) ...[
            RunBanner(
              title: t.progress.banner_cancelled_title,
              message: _error ?? t.progress.helper_cancelled,
              severity: RunBannerSeverity.warning,
            ),
            const SizedBox(height: 16),
          ] else if (_done) ...[
            const RunBanner(
              title: 'Run complete',
              message: 'Deckhand finished every queued step.',
              severity: RunBannerSeverity.success,
            ),
            const SizedBox(height: 16),
          ],
          SizedBox(
            height: _workspaceHeight(context),
            child: ProgressRunWorkspace(
              steps: flowSteps,
              statusFor: _statusForStep,
              log: _log,
              networkEvents: _egressById.values.toList(growable: false),
            ),
          ),
        ],
      ),
      primaryAction: WizardAction(
        label: _done
            ? t.progress.action_finish
            : ((_failed || _cancelled)
                  ? t.progress.action_close
                  : t.progress.action_running),
        onPressed: _done
            ? () => context.go('/done')
            : ((_failed || _cancelled) ? () => context.go('/') : null),
      ),
      secondaryActions: [
        if (!_done && !_failed && !_cancelled)
          WizardAction(
            label: _cancelRequested
                ? t.progress.action_cancel_requested
                : t.progress.action_cancel,
            onPressed: _cancelRequested ? null : _requestCancel,
          ),
      ],
    );
  }
}

String? _jsonString(Object? value) => value is String ? value : null;

List<Object?> _jsonList(Object? value) => value is List ? value : const [];

Map<String, dynamic>? _stringKeyMap(Object? value) {
  if (value is! Map) return null;
  final out = <String, dynamic>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is String) {
      out[key] = entry.value;
    }
  }
  return out;
}

class _ProgressHeader extends StatelessWidget {
  const _ProgressHeader({
    required this.fraction,
    required this.message,
    required this.stepId,
    required this.activeStepNumber,
    required this.totalSteps,
  });
  final double? fraction;
  final String? message;
  final String? stepId;
  final int? activeStepNumber;
  final int totalSteps;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final pct = fraction == null ? null : (fraction! * 100).toStringAsFixed(1);
    final stepLabel = switch ((stepId, activeStepNumber)) {
      (final id?, final stepNumber?) when totalSteps > 0 =>
        'STEP $stepNumber/$totalSteps · ${runStepTitle(id)}',
      (final id?, _) => 'STEP · ${runStepTitle(id)}',
      _ => '',
    };
    return Row(
      children: [
        Expanded(
          child: Text(
            stepLabel,
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: 10,
              color: tokens.text3,
              letterSpacing: 0,
            ),
          ),
        ),
        if (pct != null)
          Text(
            '$pct%',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: 10,
              color: tokens.text3,
              letterSpacing: 0,
            ),
          ),
        if (message != null) ...[
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              message!,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontMono,
                fontSize: 10,
                color: tokens.text4,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
