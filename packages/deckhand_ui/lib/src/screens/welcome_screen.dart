import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../theming/deckhand_tokens.dart';
import '../widgets/deckhand_loading.dart';
import '../widgets/id_tag.dart';
import '../widgets/preflight_strip.dart';
import '../widgets/resume_gate.dart';
import '../widgets/wizard_scaffold.dart';

/// S10 — Welcome. Two-panel layout from the Deckhand Design Language
/// reference: NEW INSTALL on the left, RESUME on the right (the
/// right panel only renders when there's a saved wizard session
/// worth resuming). Replaces the prior boot-time modal flow with an
/// in-page affordance so the user isn't ambushed by a popup the
/// instant the window opens.
class WelcomeScreen extends ConsumerWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Gate the primary action on the boot-time preflight result.
    // While the future is pending we disable Start so a user can't
    // race past the checks; once it resolves (pass *or* fail) Start
    // re-enables — the design's "loud-but-non-blocking" stance for
    // failures is preserved, but starting before the result is even
    // in is just bad affordance.
    final preflight = ref.watch(preflightReportProvider);
    final ready = !preflight.isLoading;
    final primaryLabel = preflight.isLoading ? 'Checking preflight…' : 'Start';

    final tokens = DeckhandTokens.of(context);
    final saved = ref.watch(savedWizardSnapshotProvider).value;

    return WizardScaffold(
      screenId: 'S10-welcome',
      title: 'Flash, set up, and maintain Klipper-based printers.',
      helperText:
          'Local-only desktop tool. Nothing phones home; every operation '
          'runs on your machine and your printer.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _WelcomePanels(
            tokens: tokens,
            ready: ready,
            saved: saved,
            onStart: () => context.go('/pick-printer'),
          ),
          const SizedBox(height: 16),
          const _ManagedPrintersPanel(),
          const SizedBox(height: 16),
          _MaintenancePanel(tokens: tokens),
          const SizedBox(height: 18),
          const PreflightStrip(),
        ],
      ),
      primaryAction: WizardAction(
        label: primaryLabel,
        onPressed: ready ? () => context.go('/pick-printer') : null,
      ),
    );
  }
}

class _WelcomePanels extends StatelessWidget {
  const _WelcomePanels({
    required this.tokens,
    required this.ready,
    required this.saved,
    required this.onStart,
  });

  final DeckhandTokens tokens;
  final bool ready;
  final SavedWizardSnapshot? saved;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final newInstall = _NewInstallPanel(
      tokens: tokens,
      ready: ready,
      onStart: onStart,
    );
    if (saved == null) {
      // No saved session: keep the layout symmetrical with the
      // mockup's grid by letting the NEW INSTALL panel claim the
      // full row, rather than centering an awkward half-width card.
      return newInstall;
    }
    // IntrinsicHeight lets `CrossAxisAlignment.stretch` work in a
    // vertically-unbounded parent (the WizardScaffold body Column).
    // Without it, Row tries to size children to the full
    // cross-axis (which is +infinity here) and Flutter asserts
    // "BoxConstraints forces an infinite height". With it, the
    // Row's height is the taller of the two panels' natural
    // heights and both Expanded children get matched-height
    // constraints — exactly what the mockup shows.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: newInstall),
          const SizedBox(width: 16),
          Expanded(
            child: _ResumePanel(tokens: tokens, saved: saved!),
          ),
        ],
      ),
    );
  }
}

class _NewInstallPanel extends StatelessWidget {
  const _NewInstallPanel({
    required this.tokens,
    required this.ready,
    required this.onStart,
  });

  final DeckhandTokens tokens;
  final bool ready;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return _PanelShell(
      tokens: tokens,
      eyebrow: 'NEW INSTALL',
      headline: 'Set up a printer from scratch.',
      body:
          'Walks you through identification, connection, firmware choice, '
          'and install — one decision at a time.',
      action: FilledButton.icon(
        onPressed: ready ? onStart : null,
        icon: const Icon(Icons.arrow_forward, size: 14),
        label: const Text('Start a new install'),
      ),
    );
  }
}

class _ResumePanel extends ConsumerStatefulWidget {
  const _ResumePanel({required this.tokens, required this.saved});
  final DeckhandTokens tokens;
  final SavedWizardSnapshot saved;

  @override
  ConsumerState<_ResumePanel> createState() => _ResumePanelState();
}

class _ResumePanelState extends ConsumerState<_ResumePanel> {
  String? _busyAction;

  Future<void> _resume() async {
    final target =
        routeForResumeStep(widget.saved.state.currentStep) ?? '/pick-printer';
    await _openSavedSession(target: target, action: 'resume');
  }

  Future<void> _manage() async {
    await _openSavedSession(target: '/manage', action: 'manage');
  }

  Future<void> _openSavedSession({
    required String target,
    required String action,
  }) async {
    if (_busyAction != null) return;
    setState(() => _busyAction = action);
    try {
      await ref.read(wizardControllerProvider).restore(widget.saved.state);
    } on ResumeFailedException catch (e) {
      if (!mounted) return;
      setState(() => _busyAction = null);
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.error_outline),
          title: const Text("Couldn't restore the previous session"),
          content: Text(
            'Deckhand saved your progress on '
            '"${e.snapshot.profileId}", but the profile could not '
            'be reloaded:\n\n${e.cause}\n\n'
            'You can retry from the Pick Printer screen, or start '
            'fresh; the snapshot is kept on disk so a later launch '
            'can try again.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    if (!mounted) return;
    // Drop the cached snapshot so the panel disappears once consumed.
    // Without invalidate, navigating back to welcome would still
    // render the RESUME card pointing at state we already restored.
    ref.invalidate(savedWizardSnapshotProvider);
    if (mounted) context.go(target);
  }

  Future<void> _discard() async {
    if (_busyAction != null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: const Text('Discard saved session?'),
        content: Text(
          'The in-progress wizard for '
          '"${widget.saved.state.profileId.isEmpty ? "a printer" : widget.saved.state.profileId}" '
          'will be removed. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final store = ref.read(wizardStateStoreProvider);
    if (store != null) {
      try {
        await store.clear();
      } catch (_) {
        // best-effort; falls through to invalidate so the panel
        // disappears even if the file delete failed (next launch
        // tries again).
      }
    }
    if (!mounted) return;
    ref.invalidate(savedWizardSnapshotProvider);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = widget.tokens;
    final state = widget.saved.state;
    final busy = _busyAction != null;
    final profileLabel = state.profileId.isEmpty
        ? 'unknown printer'
        : state.profileId;
    final stepLabel = _stepIdTagLabel(state.currentStep);
    final ageLabel = _relativeTimeShort(widget.saved.savedAt);
    return _PanelShell(
      tokens: tokens,
      eyebrow: 'RESUME',
      headline: 'You have one in-progress install.',
      body:
          'Picks up where you left off; probes of the printer re-run so '
          'nothing happens without you confirming.',
      extra: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [IdTag(profileLabel), IdTag(stepLabel), IdTag(ageLabel)],
      ),
      action: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          TextButton(
            onPressed: busy ? null : _discard,
            child: const Text('Discard'),
          ),
          if (state.profileId.isNotEmpty) ...[
            OutlinedButton.icon(
              onPressed: busy ? null : _manage,
              icon: _busyAction == 'manage'
                  ? const SizedBox(
                      width: 12,
                      height: 12,
                      child: DeckhandSpinner(size: 12, strokeWidth: 1.5),
                    )
                  : const Icon(Icons.tune, size: 14),
              label: Text(_busyAction == 'manage' ? 'Opening…' : 'Manage'),
            ),
          ],
          FilledButton.icon(
            onPressed: busy ? null : _resume,
            icon: _busyAction == 'resume'
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: DeckhandSpinner(size: 12, strokeWidth: 1.5),
                  )
                : const Icon(Icons.arrow_forward, size: 14),
            label: Text(_busyAction == 'resume' ? 'Resuming…' : 'Resume'),
          ),
        ],
      ),
    );
  }
}

class _ManagedPrintersPanel extends ConsumerStatefulWidget {
  const _ManagedPrintersPanel();

  @override
  ConsumerState<_ManagedPrintersPanel> createState() =>
      _ManagedPrintersPanelState();
}

class _ManagedPrintersPanelState extends ConsumerState<_ManagedPrintersPanel> {
  String? _busyId;

  Future<void> _manage(ManagedPrinter printer) async {
    if (_busyId != null) return;
    setState(() => _busyId = printer.id);
    try {
      await ref
          .read(wizardControllerProvider)
          .restore(
            WizardState(
              profileId: printer.profileId,
              decisions: const {},
              currentStep: 'manage',
              flow: WizardFlow.none,
              sshHost: printer.host,
            ),
          );
      if (!mounted) return;
      context.go('/manage');
    } on ResumeFailedException catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.error_outline),
          title: const Text("Couldn't open this printer"),
          content: Text(
            'Deckhand found "${printer.displayName}", but the profile '
            '"${printer.profileId}" could not be loaded:\n\n${e.cause}',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _forget(ManagedPrinter printer) async {
    if (_busyId == printer.id) return;
    final registry = ref.read(managedPrinterRegistryProvider);
    registry.forgetManagedPrinter(printer.id);
    setState(() {});
    try {
      await registry.save();
    } catch (_) {
      // The registry is still updated in memory; a later settings
      // write can persist it if the file is temporarily unavailable.
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final printers = ref
        .watch(managedPrinterRegistryProvider)
        .listManagedPrinters();
    return _PanelShell(
      tokens: tokens,
      eyebrow: 'PRINTERS',
      headline: 'Manage known printers.',
      body: printers.isEmpty
          ? 'Printers appear here after Deckhand connects to them once.'
          : 'Open a printer directly for status, tuning, backup, restore, '
                'or maintenance work.',
      extra: printers.isEmpty
          ? null
          : Column(
              children: [
                for (var i = 0; i < printers.length && i < 4; i++)
                  _ManagedPrinterRow(
                    printer: printers[i],
                    busy: _busyId == printers[i].id,
                    onManage: () => _manage(printers[i]),
                    onForget: () => _forget(printers[i]),
                  ),
              ],
            ),
      action: printers.isEmpty
          ? OutlinedButton.icon(
              onPressed: () => context.go('/pick-printer'),
              icon: const Icon(Icons.add, size: 14),
              label: const Text('Add a printer'),
            )
          : OutlinedButton.icon(
              onPressed: () => context.go('/printers'),
              icon: const Icon(Icons.list_alt, size: 14),
              label: const Text('View all printers'),
            ),
    );
  }
}

class _ManagedPrinterRow extends StatelessWidget {
  const _ManagedPrinterRow({
    required this.printer,
    required this.busy,
    required this.onManage,
    required this.onForget,
  });

  final ManagedPrinter printer;
  final bool busy;
  final VoidCallback onManage;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: tokens.ink2,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r2),
      ),
      child: Row(
        children: [
          Icon(
            Icons.precision_manufacturing_outlined,
            size: 16,
            color: tokens.text3,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  printer.displayName,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tSm,
                    fontWeight: FontWeight.w600,
                    color: tokens.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${printer.user}@${printer.host}:${printer.port} · '
                  '${printer.profileId}',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: DeckhandTokens.tXs,
                    color: tokens.text3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Tooltip(
            message: 'Forget printer',
            child: IconButton(
              onPressed: busy ? null : onForget,
              icon: const Icon(Icons.close, size: 16),
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 4),
          OutlinedButton.icon(
            onPressed: busy ? null : onManage,
            icon: busy
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: DeckhandSpinner(size: 12, strokeWidth: 1.5),
                  )
                : const Icon(Icons.tune, size: 14),
            label: Text(busy ? 'Opening...' : 'Manage'),
          ),
        ],
      ),
    );
  }
}

class _MaintenancePanel extends StatelessWidget {
  const _MaintenancePanel({required this.tokens});

  final DeckhandTokens tokens;

  @override
  Widget build(BuildContext context) {
    return _PanelShell(
      tokens: tokens,
      eyebrow: 'RECOVERY',
      headline: 'Restore an eMMC backup.',
      body:
          'Writes a Deckhand full-disk backup image back to an attached '
          'eMMC adapter. Use this to roll back after a failed flash or '
          'when you need the printer returned to a known image.',
      action: OutlinedButton.icon(
        onPressed: () => context.go('/emmc-restore'),
        icon: const Icon(Icons.restore, size: 14),
        label: const Text('Restore eMMC backup'),
      ),
    );
  }
}

/// Shared chrome for the two welcome panels: small mono eyebrow,
/// headline, muted body, optional middle slot (IdTag row), action
/// row at the bottom. Mirrors the `panel` div in the mockup with
/// padding 22 and gap 14.
class _PanelShell extends StatelessWidget {
  const _PanelShell({
    required this.tokens,
    required this.eyebrow,
    required this.headline,
    required this.body,
    required this.action,
    this.extra,
  });

  final DeckhandTokens tokens;
  final String eyebrow;
  final String headline;
  final String body;
  final Widget? extra;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    return Container(
      // minHeight (no maxHeight) keeps panels visually substantial
      // when content is short. The inner Column sizes to content via
      // mainAxisSize.min — without that, a Column inside an
      // Expanded(Row) gets unbounded vertical constraints and any
      // intrinsic-height pass (CrossAxisAlignment.stretch on the
      // outer Row) crashes the render-tree assertion that surfaced
      // the original "debugCheckForParentData" stack in tests.
      constraints: const BoxConstraints(minHeight: 200),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            eyebrow,
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: 10,
              color: tokens.text3,
              letterSpacing: 0.1 * 10,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            headline,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w500,
              letterSpacing: -0.015 * 22,
              color: tokens.text,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 14),
          if (extra != null) ...[extra!, const SizedBox(height: 14)],
          Text(
            body,
            style: TextStyle(
              fontSize: DeckhandTokens.tSm,
              color: tokens.text3,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 18),
          Align(alignment: Alignment.centerLeft, child: action),
        ],
      ),
    );
  }
}

/// Map a stored `currentStep` to its design-language IdTag form,
/// e.g. `"choose-path"` → `"S40 · choose-path"`. The numbers come
/// from docs/WIZARD-FLOW.md (and the mockup's screen IDs); when a
/// step isn't in the table the tag falls back to just the step
/// name so a future step doesn't render as `?? · choose-path`.
String _stepIdTagLabel(String step) {
  const table = <String, String>{
    'welcome': 'S10',
    'pick-printer': 'S15',
    'connect': 'S20',
    'verify': 'S30',
    'choose-path': 'S40',
    'firmware': 'S100',
    'webui': 'S105',
    'kiauh': 'S107',
    'screen-choice': 'S110',
    'services': 'S120',
    'files': 'S140',
    'snapshot': 'S145',
    'emmc-backup': 'S148',
    'hardening': 'S150',
    'flash-target': 'S200',
    'choose-os': 'S210',
    'flash-confirm': 'S220',
    'progress': 'S900',
    'first-boot': 'S240',
    'first-boot-setup': 'S250',
    'review': 'S800',
    'done': 'S910',
  };
  final id = table[step];
  return id == null ? step : '$id · $step';
}

/// Compact "X ago" label for the timestamp IdTag. The mockup shows
/// strings like "2 hr ago" / "5 min ago" — keep them short so the
/// IdTag stays single-line on the panel. Anything older than a day
/// switches to a calendar date so the user gets an absolute
/// reference rather than "47 hr ago".
String _relativeTimeShort(DateTime when) {
  final delta = DateTime.now().difference(when);
  if (delta.isNegative || delta.inSeconds < 60) return 'just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
  if (delta.inHours < 24) return '${delta.inHours} hr ago';
  // Local-date fallback: strip the year unless the snapshot is from
  // last year (still readable, less noise for typical "yesterday").
  final d = when.toLocal();
  final now = DateTime.now();
  if (d.year == now.year) {
    return '${_monthShort(d.month)} ${d.day}';
  }
  return '${_monthShort(d.month)} ${d.day} ${d.year}';
}

String _monthShort(int m) => const [
  '',
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
][m];
