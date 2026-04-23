import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../widgets/profile_text.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class ProgressScreen extends ConsumerStatefulWidget {
  const ProgressScreen({super.key});

  @override
  ConsumerState<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends ConsumerState<ProgressScreen> {
  final _log = <String>[];
  bool _done = false;
  bool _failed = false;
  String? _error;
  double? _currentFraction;
  String? _currentProgressMessage;
  // What step kind is live right now? Drives the title so the user
  // sees "Downloading image" during os_download, "Writing image"
  // during flash_disk, etc. - not a blanket "Installing..." even
  // when we're halfway through an eMMC write.
  String? _currentStepKind;
  String? _currentStepId;

  @override
  void initState() {
    super.initState();
    _startExecution();
  }

  Future<void> _startExecution() async {
    final controller = ref.read(wizardControllerProvider);
    final sub = controller.events.listen(_onEvent);
    try {
      await controller.startExecution();
      setState(() {
        _done = true;
        _currentStepKind = null;
        _currentStepId = null;
      });
    } catch (e) {
      setState(() {
        _failed = true;
        _error = '$e';
        _currentStepKind = null;
        _currentStepId = null;
      });
    } finally {
      await sub.cancel();
    }
  }

  void _onEvent(WizardEvent e) {
    switch (e) {
      case StepStarted(:final stepId):
        setState(() {
          _log.add('> starting $stepId');
          _currentStepId = stepId;
          _currentStepKind = _lookupStepKind(stepId);
          _currentFraction = null;
          _currentProgressMessage = null;
        });
      case StepCompleted(:final stepId):
        setState(() {
          _log.add('[ok] $stepId');
          if (_currentStepId == stepId) {
            _currentFraction = null;
            _currentProgressMessage = null;
          }
        });
      case StepFailed(:final stepId, :final error):
        setState(() => _log.add('[fail] $stepId - $error'));
      case StepLog(:final line):
        setState(() => _log.add(line));
      case StepWarning(:final stepId, :final message):
        setState(() => _log.add('[warn] $stepId - $message'));
      case StepProgress(:final percent, :final message):
        setState(() {
          _currentFraction = percent.clamp(0, 1).toDouble();
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
    return step?['kind'] as String?;
  }

  Future<void> _handleUserInput(
    String stepId,
    Map<String, dynamic> step,
  ) async {
    final kind = step['kind'] as String? ?? '';
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
    final message = step['message'] as String? ?? '';
    final rawActions = (step['actions'] as List?) ?? const [];
    final actions = rawActions.whereType<Map>().map((m) {
      final c = m.cast<String, dynamic>();
      return (id: c['id'] as String? ?? '', label: c['label'] as String? ?? '');
    }).toList();
    final buttons = actions.isEmpty
        ? [(id: 'continue', label: t.progress.prompt_default_action)]
        : actions;
    return _showFadedDialog<String>(
      barrierDismissible: false,
      child: AlertDialog(
        title: Text(
          step['title'] as String? ?? t.progress.prompt_default_title,
        ),
        content: Text(flattenProfileText(message)),
        actions: [
          for (final a in buttons)
            TextButton(
              onPressed: () => Navigator.of(context).pop(a.id),
              child: Text(a.label),
            ),
        ],
      ),
    );
  }

  Future<String?> _showChooseOneDialog(Map<String, dynamic> step) async {
    final profile = ref.read(wizardControllerProvider).profile;
    final options = _resolveChooseOneOptions(step, profile);
    if (options.isEmpty) return null;
    String? choice = options.first.id;
    return _showFadedDialog<String>(
      barrierDismissible: false,
      child: StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(
            step['title'] as String? ?? t.progress.choose_one_default_title,
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (step['question'] != null) ...[
                Text(flattenProfileText(step['question'] as String)),
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
                        subtitle:
                            o.subtitle == null ? null : Text(o.subtitle!),
                      ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(choice),
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
  List<({String id, String label, String? subtitle})>
      _resolveChooseOneOptions(
    Map<String, dynamic> step,
    PrinterProfile? profile,
  ) {
    final inline = (step['options'] as List?) ?? const [];
    if (inline.isNotEmpty) {
      return inline.whereType<Map>().map((m) {
        final c = m.cast<String, dynamic>();
        return (
          id: c['id'] as String? ?? '',
          label: c['label'] as String? ?? c['id'] as String? ?? '',
          subtitle: c['description'] as String?,
        );
      }).toList();
    }
    final from = step['options_from'] as String?;
    if (from == null || profile == null) return const [];
    switch (from) {
      case 'os.fresh_install_options':
        return profile.os.freshInstallOptions
            .map((o) => (
                  id: o.id,
                  label: o.displayName,
                  subtitle: o.notes,
                ))
            .toList();
      case 'firmware.choices':
        return profile.firmware.choices
            .map((c) => (
                  id: c.id,
                  label: c.displayName,
                  subtitle: c.description,
                ))
            .toList();
      case 'screens':
        return profile.screens
            .map((s) => (
                  id: s.id,
                  label: s.displayName ?? s.id,
                  subtitle: s.raw['description'] as String?,
                ))
            .toList();
      case 'addons':
        return profile.addons
            .map((a) => (
                  id: a.id,
                  label: a.displayName ?? a.id,
                  subtitle: a.raw['description'] as String?,
                ))
            .toList();
      case 'mcus':
        return profile.mcus
            .map((m) => (
                  id: m.id,
                  label: m.displayName ?? m.id,
                  subtitle: m.raw['description'] as String?,
                ))
            .toList();
      case 'stack.webui.choices':
        final choices = ((profile.stack.webui?['choices'] as List?) ??
            const []).cast<Map>();
        return choices.map((c) {
          final m = c.cast<String, dynamic>();
          return (
            id: m['id'] as String? ?? '',
            label: m['display_name'] as String? ?? m['id'] as String? ?? '',
            subtitle: m['description'] as String?,
          );
        }).toList();
      default:
        // Fail loud so profile authors don't get a silent empty
        // dialog. We return [] so the wizard still advances rather
        // than wedging forever, but the log tells them what's wrong.
        debugPrint(
          '[progress_screen] unknown options_from path "$from"; '
          'add a case to _resolveChooseOneOptions or declare `options: '
          '[...]` inline on the step.',
        );
        return const [];
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
              onPressed: () => Navigator.of(context).pop(),
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
              onPressed: () => Navigator.of(context).pop(),
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
            step['title'] as String? ?? t.progress.disk_picker_title,
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
                      title: Text(d.model.isEmpty ? d.id : d.model),
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
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.progress.disk_picker_cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(choice),
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
      pageBuilder: (_, __, ___) => child,
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

  /// Title text driven by the currently-running step kind. Keeps the
  /// header honest: during eMMC writes it says "Writing image", not
  /// "Installing..."
  String _titleForState() {
    if (_failed) return t.progress.title_failed;
    if (_done) return t.progress.title_done;
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

  @override
  Widget build(BuildContext context) {
    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: _titleForState(),
      helperText: _error,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_currentFraction != null || _currentProgressMessage != null) ...[
            Semantics(
              label: t.progress.semantics_progress_label,
              value: _currentFraction == null
                  ? t.progress.semantics_progress_indeterminate
                  : t.progress.semantics_progress_percent(
                      percent: ((_currentFraction ?? 0) * 100).round(),
                    ),
              child: LinearProgressIndicator(value: _currentFraction),
            ),
            if (_currentProgressMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                _currentProgressMessage!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
            const SizedBox(height: 16),
          ],
          Container(
            height: 400,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Semantics(
              label: t.progress.semantics_log_label,
              child: ListView.builder(
                itemCount: _log.length,
                itemBuilder: (_, i) => Text(
                  _log[i],
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ),
        ],
      ),
      primaryAction: WizardAction(
        label: _done
            ? t.progress.action_finish
            : (_failed
                ? t.progress.action_close
                : t.progress.action_running),
        onPressed: _done
            ? () => context.go('/done')
            : (_failed ? () => context.go('/') : null),
      ),
    );
  }
}
