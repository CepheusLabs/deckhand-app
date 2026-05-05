import 'dart:async';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../theming/deckhand_tokens.dart';
import '../utils/disk_display.dart';
import '../widgets/deckhand_panel.dart';
import '../widgets/host_approval_gate.dart';
import '../widgets/network_panel.dart';
import '../widgets/profile_text.dart';
import '../widgets/wizard_log_view.dart';
import '../widgets/wizard_progress_bar.dart';
import '../widgets/wizard_scaffold.dart';

class ProgressScreen extends ConsumerStatefulWidget {
  const ProgressScreen({super.key});

  @override
  ConsumerState<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends ConsumerState<ProgressScreen> {
  final _log = <String>[];
  // Distinct request IDs seen from egressEvents. The Network tab's
  // badge reads this so the count reflects actual outbound HTTP
  // traffic, not the log-line counter it used to mistakenly mirror.
  final _seenEgressIds = <String>{};
  StreamSubscription<EgressEvent>? _egressSub;
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
    final security = ref.read(securityServiceProvider);
    _egressSub = security.egressEvents.listen((e) {
      if (!mounted) return;
      setState(() => _seenEgressIds.add(e.requestId));
    });
    _startExecution();
  }

  @override
  void dispose() {
    _egressSub?.cancel();
    super.dispose();
  }

  Future<void> _startExecution() async {
    final controller = ref.read(wizardControllerProvider);
    final sub = controller.events.listen(_onEvent);
    try {
      await HostApprovalGate.runGuarded(
        ref,
        context,
        action: controller.startExecution,
      );
      if (!mounted) return;
      setState(() {
        _done = true;
        _currentStepKind = null;
        _currentStepId = null;
      });
    } catch (e) {
      if (!mounted) return;
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
    final title = step['title'] as String? ?? t.progress.prompt_default_title;
    return _showFadedDialog<String>(
      barrierDismissible: false,
      child: Center(
        child: _DeckhandPromptCard(
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
  /// that to a [_PromptSeverity] lets the dialog render a primary
  /// FilledButton for the recommended path and a warning-tinted text
  /// button for the destructive escape hatch, instead of three
  /// indistinguishable TextButtons.
  _PromptSeverity _severityFor(String label) {
    final l = label.toLowerCase();
    if (l.contains('not recommended') ||
        l.contains('skip') ||
        l.contains('destructive')) {
      return _PromptSeverity.destructive;
    }
    if (l.contains('recommended')) return _PromptSeverity.recommended;
    return _PromptSeverity.neutral;
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
                        subtitle: o.subtitle == null ? null : Text(o.subtitle!),
                      ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () =>
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
                subtitle: s.raw['description'] as String?,
              ),
            )
            .toList();
      case 'addons':
        return profile.addons
            .map(
              (a) => (
                id: a.id,
                label: a.displayName ?? a.id,
                subtitle: a.raw['description'] as String?,
              ),
            )
            .toList();
      case 'mcus':
        return profile.mcus
            .map(
              (m) => (
                id: m.id,
                label: m.displayName ?? m.id,
                subtitle: m.raw['description'] as String?,
              ),
            )
            .toList();
      case 'stack.webui.choices':
        final choices = ((profile.stack.webui?['choices'] as List?) ?? const [])
            .cast<Map>();
        return choices.map((c) {
          final m = c.cast<String, dynamic>();
          return (
            id: m['id'] as String? ?? '',
            label: m['display_name'] as String? ?? m['id'] as String? ?? '',
            subtitle: m['description'] as String?,
          );
        }).toList();
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
          title: Text(step['title'] as String? ?? t.progress.disk_picker_title),
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
    final tokens = DeckhandTokens.of(context);
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
    return WizardScaffold(
      screenId: 'S900-progress',
      title: _titleForState(),
      helperText: _error,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasActiveStep) ...[
            _ProgressHeader(
              fraction: _currentFraction,
              message: _currentProgressMessage,
              stepId: _currentStepId,
            ),
            const SizedBox(height: 16),
            Semantics(
              label: t.progress.semantics_progress_label,
              value: _currentFraction == null
                  ? t.progress.semantics_progress_indeterminate
                  : t.progress.semantics_progress_percent(
                      percent: ((_currentFraction ?? 0) * 100).round(),
                    ),
              child: WizardProgressBar(fraction: _currentFraction),
            ),
            const SizedBox(height: 18),
          ],
          SizedBox(
            height: 380,
            child: DefaultTabController(
              length: 2,
              child: DeckhandPanel.flush(
                child: Column(
                  children: [
                    _PaneTabs(
                      tokens: tokens,
                      tabs: [
                        _PaneTab(
                          label: 'Log',
                          icon: Icons.terminal,
                          countLabel: 'live',
                        ),
                        _PaneTab(
                          label: 'Network',
                          icon: Icons.wifi,
                          countLabel: '${_seenEgressIds.length}',
                        ),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          Semantics(
                            label: t.progress.semantics_log_label,
                            child: WizardLogView(lines: _log),
                          ),
                          const NetworkPanel(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      primaryAction: WizardAction(
        label: _done
            ? t.progress.action_finish
            : (_failed ? t.progress.action_close : t.progress.action_running),
        onPressed: _done
            ? () => context.go('/done')
            : (_failed ? () => context.go('/') : null),
      ),
    );
  }
}

class _ProgressHeader extends StatelessWidget {
  const _ProgressHeader({
    required this.fraction,
    required this.message,
    required this.stepId,
  });
  final double? fraction;
  final String? message;
  final String? stepId;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final pct = fraction == null ? null : (fraction! * 100).toStringAsFixed(1);
    return Row(
      children: [
        Expanded(
          child: Text(
            stepId == null ? '' : 'STEP · $stepId',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: 10,
              color: tokens.text3,
              letterSpacing: 0.04 * 10,
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
              letterSpacing: 0.04 * 10,
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

class _PaneTab {
  _PaneTab({required this.label, required this.icon, required this.countLabel});
  final String label;
  final IconData icon;
  final String countLabel;
}

class _PaneTabs extends StatelessWidget {
  const _PaneTabs({required this.tokens, required this.tabs});
  final DeckhandTokens tokens;
  final List<_PaneTab> tabs;

  @override
  Widget build(BuildContext context) {
    final controller = DefaultTabController.of(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Container(
          decoration: BoxDecoration(
            color: tokens.ink2,
            border: Border(bottom: BorderSide(color: tokens.line)),
          ),
          child: Row(
            children: [
              for (var i = 0; i < tabs.length; i++)
                _PaneTabCell(
                  tab: tabs[i],
                  isActive: controller.index == i,
                  tokens: tokens,
                  onTap: () => controller.animateTo(i),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _PaneTabCell extends StatelessWidget {
  const _PaneTabCell({
    required this.tab,
    required this.isActive,
    required this.tokens,
    required this.onTap,
  });
  final _PaneTab tab;
  final bool isActive;
  final DeckhandTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? tokens.ink1 : Colors.transparent,
          border: Border(
            top: BorderSide(
              color: isActive ? tokens.accent : Colors.transparent,
              width: 2,
            ),
            right: BorderSide(color: tokens.line),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              tab.icon,
              size: 14,
              color: isActive ? tokens.text : tokens.text3,
            ),
            const SizedBox(width: 8),
            Text(
              tab.label,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontSans,
                fontSize: DeckhandTokens.tSm,
                color: isActive ? tokens.text : tokens.text3,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: isActive ? tokens.accent : tokens.ink3,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                tab.countLabel,
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontMono,
                  fontSize: 9,
                  color: isActive ? tokens.accentFg : tokens.text2,
                  letterSpacing: 0.04 * 9,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _PromptSeverity { recommended, neutral, destructive }

typedef _PromptOption = ({String id, String label, _PromptSeverity severity});

/// Custom prompt-dialog card. Replaces Material's [AlertDialog] —
/// AlertDialog runs its action row through [OverflowBar] which wraps
/// to a vertical stack as soon as the labels won't fit horizontally,
/// which they reliably don't with three confirmation choices like
/// "Back up now (recommended)". The vertically-stacked button list
/// reads as a chaotic menu, not a confirmation prompt.
///
/// This card lays the actions out as an explicit two-group row:
/// destructive escape hatches on the left, neutral + primary on the
/// right. The primary (recommended) action is rendered as a filled
/// accent button so the user's eye lands on it first. Falls back to
/// [Wrap] only when the row genuinely overflows (very long labels +
/// narrow window) — the rare case is graceful, not the default.
class _DeckhandPromptCard extends StatelessWidget {
  const _DeckhandPromptCard({
    required this.title,
    required this.message,
    required this.buttons,
  });

  final String title;
  final String message;
  final List<_PromptOption> buttons;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    // Order: destructive first, neutral middle, recommended last.
    // [OverflowBar] preserves this order as left-to-right when the row
    // fits, and as top-to-bottom when it has to stack — so the
    // recommended action ends up bottom-right (closest to the user's
    // dominant-hand thumb) in both layouts. Severity colors carry the
    // hierarchy when "Skip" sits visually next to the primary instead
    // of being far-left.
    final ordered = [
      ...buttons.where((b) => b.severity == _PromptSeverity.destructive),
      ...buttons.where((b) => b.severity == _PromptSeverity.neutral),
      ...buttons.where((b) => b.severity == _PromptSeverity.recommended),
    ];
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 600),
      child: Material(
        color: tokens.ink1,
        elevation: 8,
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: tokens.line),
            borderRadius: BorderRadius.circular(DeckhandTokens.r3),
          ),
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontSans,
                  fontSize: DeckhandTokens.tXl,
                  fontWeight: FontWeight.w600,
                  color: tokens.text,
                  letterSpacing: -0.01 * DeckhandTokens.tXl,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                message,
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontSans,
                  fontSize: DeckhandTokens.tMd,
                  color: tokens.text2,
                  height: 1.55,
                ),
              ),
              const SizedBox(height: 24),
              // OverflowBar gracefully falls back to a vertical stack
              // when the action labels don't fit on one row. A bare
              // Row would overflow with the bright yellow-and-black
              // "RIGHT OVERFLOWED BY N PIXELS" debug stripe.
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8,
                overflowSpacing: 8,
                overflowAlignment: OverflowBarAlignment.end,
                children: [
                  for (final b in ordered)
                    _PromptButton(
                      label: b.label,
                      severity: b.severity,
                      tokens: tokens,
                      onPressed: () =>
                          Navigator.of(context, rootNavigator: true).pop(b.id),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Internal button wrapper — keeps the three styles co-located.
class _PromptButton extends StatelessWidget {
  const _PromptButton({
    required this.label,
    required this.severity,
    required this.tokens,
    required this.onPressed,
  });

  final String label;
  final _PromptSeverity severity;
  final DeckhandTokens tokens;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // All three styles are real buttons (with a border or fill) so
    // the user can immediately see "this is clickable" — the previous
    // mix of FilledButton + TextButton made the non-recommended
    // options read as plain links and lost the affordance for
    // anything except the primary path.
    const padding = EdgeInsets.symmetric(horizontal: 16, vertical: 12);
    switch (severity) {
      case _PromptSeverity.recommended:
        return FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: tokens.accent,
            foregroundColor: tokens.accentFg,
            padding: padding,
          ),
          child: Text(label),
        );
      case _PromptSeverity.destructive:
        return OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: tokens.bad,
            side: BorderSide(color: tokens.bad.withValues(alpha: 0.55)),
            padding: padding,
          ),
          child: Text(label),
        );
      case _PromptSeverity.neutral:
        return OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: tokens.text,
            side: BorderSide(color: tokens.line),
            padding: padding,
          ),
          child: Text(label),
        );
    }
  }
}
