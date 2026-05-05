import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../theming/deckhand_tokens.dart';
import '../widgets/deckhand_loading.dart';
import '../widgets/wizard_scaffold.dart';
import 'manage_tuning_panel.dart';

/// Post-install printer management. Reached after a wizard run
/// completes (or directly via `/manage`). The mockup design is a
/// horizontal tab strip + per-tab body — analogous to a "manage
/// device" pane in a desktop app.
///
/// Tabs:
///  * Printer status — live Klippy state from Moonraker, plus
///    quick links (copy Mainsail URL, copy SSH host).
///  * Backup — kicks the user into the existing eMMC backup
///    flow at `/emmc-backup`.
///  * Restore — placeholder; the underlying flash-from-image
///    pipeline isn't wired here yet, so the tab is honest about
///    being not-yet-implemented rather than offering a fake button.
///  * Flash MCU — same story; MCU detection + reflashing is a
///    distinct service surface that doesn't exist yet.
///  * Re-run wizard — jumps back to S40 with the printer's
///    identity preserved, so a user can repair / reconfigure
///    without losing their profile selection.
///
/// `WizardScaffold` is reused for chrome consistency. The
/// stepper auto-hides on this route (it's not a wizard step).
class ManageScreen extends ConsumerStatefulWidget {
  const ManageScreen({super.key});

  @override
  ConsumerState<ManageScreen> createState() => _ManageScreenState();
}

enum _ManageTab { status, tune, backup, restore, mcu, wizard }

class _ManageScreenState extends ConsumerState<ManageScreen> {
  _ManageTab _currentTab = _ManageTab.status;

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(wizardControllerProvider);
    final state = controller.state;
    final profile = controller.profile;

    // Title is "Manage · <printer>" when a profile is loaded; falls
    // back to plain "Manage" so the screen still renders if the user
    // navigates directly without an active session.
    final printerLabel = profile?.displayName ?? state.profileId;
    final title = printerLabel.isEmpty ? 'Manage' : 'Manage · $printerLabel';

    return WizardScaffold(
      screenId: 'MGR-manage',
      title: title,
      helperText:
          'Things Klipper, Moonraker, and KIAUH don\'t already own. '
          'Updates to those tools live in those tools — Deckhand stays '
          'out of their lane.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ManageTabStrip(
            current: _currentTab,
            onSelect: (t) => setState(() => _currentTab = t),
          ),
          const SizedBox(height: 16),
          _buildTabBody(state, profile),
        ],
      ),
      primaryAction: WizardAction(
        label: 'Done',
        onPressed: () => context.go('/'),
        isBack: true,
      ),
    );
  }

  Widget _buildTabBody(WizardState state, PrinterProfile? profile) {
    return switch (_currentTab) {
      _ManageTab.status => _StatusTab(state: state, profile: profile),
      _ManageTab.tune => const ManageTuningPanel(),
      _ManageTab.backup => const _BackupTab(),
      _ManageTab.restore => const _RestoreTab(),
      _ManageTab.mcu => const _McuTab(),
      _ManageTab.wizard => const _ReRunWizardTab(),
    };
  }
}

/// Horizontal tab strip — one row of icon+label buttons separated
/// by a hairline border, with a 2px accent underline below the
/// active tab. Matches the mockup's `borderBottom` pattern.
class _ManageTabStrip extends StatelessWidget {
  const _ManageTabStrip({required this.current, required this.onSelect});

  final _ManageTab current;
  final void Function(_ManageTab) onSelect;

  static const _items = <(_ManageTab, String, IconData)>[
    (_ManageTab.status, 'Printer status', Icons.visibility_outlined),
    (_ManageTab.tune, 'Tune', Icons.tune),
    (_ManageTab.backup, 'Backup', Icons.inventory_2_outlined),
    (_ManageTab.restore, 'Restore', Icons.restore),
    (_ManageTab.mcu, 'Flash MCU', Icons.memory),
    (_ManageTab.wizard, 'Re-run wizard', Icons.refresh),
  ];

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.line)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final (tab, label, icon) in _items)
              _TabStripButton(
                label: label,
                icon: icon,
                selected: current == tab,
                onTap: () => onSelect(tab),
              ),
          ],
        ),
      ),
    );
  }
}

class _TabStripButton extends StatelessWidget {
  const _TabStripButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          // -1 bottom margin pulls the underline over the strip's
          // own border so the active accent visually replaces the
          // hairline rather than stacking on top of it.
          border: Border(
            bottom: BorderSide(
              color: selected ? tokens.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: selected ? tokens.text : tokens.text3),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontSans,
                fontSize: 13,
                fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                color: selected ? tokens.text : tokens.text3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Status tab — live Klippy state via Moonraker.
// ---------------------------------------------------------------------
class _StatusTab extends ConsumerStatefulWidget {
  const _StatusTab({required this.state, required this.profile});
  final WizardState state;
  final PrinterProfile? profile;

  @override
  ConsumerState<_StatusTab> createState() => _StatusTabState();
}

class _StatusTabState extends ConsumerState<_StatusTab> {
  Future<_StatusSnapshot>? _snapshot;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    final host = widget.state.sshHost;
    if (host == null || host.isEmpty) {
      _snapshot = Future.value(const _StatusSnapshot.disconnected());
      return;
    }
    final moonraker = ref.read(moonrakerServiceProvider);
    setState(() {
      _snapshot = _query(moonraker, host);
    });
  }

  Future<_StatusSnapshot> _query(
    MoonrakerService moonraker,
    String host,
  ) async {
    try {
      final info = await moonraker.info(host: host);
      final printing = await moonraker.isPrinting(host: host);
      return _StatusSnapshot.ok(info: info, printing: printing, host: host);
    } catch (e) {
      return _StatusSnapshot.error(host: host, message: e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final controller = ref.watch(wizardControllerProvider);
    final host = widget.state.sshHost;
    final profile = widget.profile;
    final webUiUrl = host == null || host.isEmpty
        ? null
        : _webUiUrl(host: host, profile: profile);
    final sshUser = controller.sshSession?.user ?? _defaultSshUser(profile);
    return _Panel(
      child: FutureBuilder<_StatusSnapshot>(
        future: _snapshot,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: DeckhandSpinner(size: 24, strokeWidth: 2)),
            );
          }
          final s = snap.data!;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const _MonoLabel('STATE'),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 16),
                    tooltip: 'Refresh',
                    onPressed: _refresh,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _StateDot(color: _stateColor(tokens, s)),
                  const SizedBox(width: 10),
                  Text(
                    _stateLabel(s),
                    style: TextStyle(
                      fontFamily: DeckhandTokens.fontSans,
                      fontSize: DeckhandTokens.t2Xl,
                      fontWeight: FontWeight.w500,
                      color: tokens.text,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              if (s.error != null) ...[
                Text(
                  s.error!,
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: DeckhandTokens.tSm,
                    color: tokens.bad,
                  ),
                ),
              ] else if (s.info != null) ...[
                _StatGrid(
                  stats: [
                    _Stat('HOSTNAME', s.info!.hostname),
                    _Stat('KLIPPER', s.info!.softwareVersion),
                    _Stat('KLIPPY', s.info!.klippyState),
                    _Stat('JOB', s.printing ? 'Printing' : 'Idle'),
                  ],
                ),
              ] else if (host == null || host.isEmpty) ...[
                Text(
                  'No printer connected. Run the wizard once to pin a '
                  'host, then come back here for live status.',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tSm,
                    color: tokens.text3,
                    height: 1.5,
                  ),
                ),
              ],
              if ((host ?? '').isNotEmpty) ...[
                const SizedBox(height: 18),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.copy, size: 14),
                      label: const Text('Copy Web UI URL'),
                      onPressed: () => _copyToClipboard(
                        context,
                        webUiUrl!,
                        'Web UI URL copied',
                      ),
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.terminal, size: 14),
                      label: const Text('Copy SSH command'),
                      onPressed: () => _copyToClipboard(
                        context,
                        'ssh $sshUser@$host',
                        'SSH command copied',
                      ),
                    ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Color _stateColor(DeckhandTokens tokens, _StatusSnapshot s) {
    if (s.error != null) return tokens.bad;
    if (s.info == null) return tokens.text4;
    final ks = s.info!.klippyState.toLowerCase();
    if (ks == 'ready') return tokens.ok;
    if (ks == 'error' || ks == 'shutdown') return tokens.bad;
    return tokens.warn;
  }

  String _stateLabel(_StatusSnapshot s) {
    if (s.error != null) return 'Unreachable';
    if (s.info == null) return 'Disconnected';
    final ks = s.info!.klippyState;
    if (ks.isEmpty) return s.info!.state;
    return ks[0].toUpperCase() + ks.substring(1);
  }
}

String _webUiUrl({required String host, required PrinterProfile? profile}) {
  final webui = profile?.stack.webui ?? const <String, dynamic>{};
  final scheme = (webui['scheme'] as String?)?.trim().toLowerCase();
  final port = _webUiPort(profile);
  final normalizedScheme = scheme == 'https' ? 'https' : 'http';
  final portSuffix =
      (normalizedScheme == 'http' && port == 80) ||
          (normalizedScheme == 'https' && port == 443)
      ? ''
      : ':$port';
  return '$normalizedScheme://$host$portSuffix';
}

int _webUiPort(PrinterProfile? profile) {
  final webui = profile?.stack.webui ?? const <String, dynamic>{};
  final raw = webui['port'] ?? webui['url_port'] ?? webui['http_port'];
  if (raw is num && raw >= 1 && raw <= 65535) return raw.toInt();
  if (raw is String) {
    final parsed = int.tryParse(raw.trim());
    if (parsed != null && parsed >= 1 && parsed <= 65535) return parsed;
  }
  return profile?.id == 'phrozen-arco' ? 8808 : 80;
}

String _defaultSshUser(PrinterProfile? profile) {
  final credentials = profile?.ssh.defaultCredentials ?? const [];
  return credentials.isEmpty ? 'root' : credentials.first.user;
}

class _StatusSnapshot {
  const _StatusSnapshot.disconnected()
    : info = null,
      printing = false,
      host = null,
      error = null;
  const _StatusSnapshot.ok({
    required KlippyInfo this.info,
    required this.printing,
    required this.host,
  }) : error = null;
  const _StatusSnapshot.error({required this.host, required String message})
    : info = null,
      printing = false,
      error = message;

  final KlippyInfo? info;
  final bool printing;
  final String? host;
  final String? error;
}

class _StateDot extends StatelessWidget {
  const _StateDot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.25),
            blurRadius: 6,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Backup tab — defers to the existing /emmc-backup flow.
// ---------------------------------------------------------------------
class _BackupTab extends StatelessWidget {
  const _BackupTab();

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _MonoLabel('FULL DISK BACKUP'),
          const SizedBox(height: 8),
          Text(
            'Pull a complete byte-for-byte image of the printer\'s eMMC '
            'over SSH. SHA256-verified on completion. Recommended before '
            'any destructive change — flash, reconfigure, or migrate.',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontSans,
              fontSize: DeckhandTokens.tMd,
              color: tokens.text2,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              icon: const Icon(Icons.inventory_2_outlined, size: 16),
              label: const Text('Open backup flow'),
              onPressed: () => context.go('/emmc-backup'),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Restore tab — explicit "not implemented yet" panel rather than a
// fake button. Per the project's principle, half-wired UI is worse
// than honest scoping.
// ---------------------------------------------------------------------
class _RestoreTab extends StatelessWidget {
  const _RestoreTab();
  @override
  Widget build(BuildContext context) {
    return const _ComingSoonPanel(
      label: 'RESTORE FROM BACKUP',
      body:
          'Reverse of fresh-flash using a previously-captured .img. '
          'Not yet wired in the desktop client — the underlying '
          'image-write pipeline exists but the picker and dry-run '
          'preview around it are still TODO. Use the backup tab to '
          'capture an image; restore will land in a follow-up.',
    );
  }
}

// ---------------------------------------------------------------------
// Flash MCU tab — same honest stance.
// ---------------------------------------------------------------------
class _McuTab extends StatelessWidget {
  const _McuTab();
  @override
  Widget build(BuildContext context) {
    return const _ComingSoonPanel(
      label: 'FLASH MCU',
      body:
          'Per-MCU reflashing (toolhead, Z, accelerometer boards) needs '
          'a service abstraction Deckhand doesn\'t ship yet — DFU / CAN '
          'enumeration plus klipper-build orchestration. The wizard '
          'flashes the main board today; per-MCU flashing will arrive '
          'when the service exists. Tracking this rather than mocking '
          'fake rows.',
    );
  }
}

// ---------------------------------------------------------------------
// Re-run wizard tab — re-enters at choose-path with state preserved.
// ---------------------------------------------------------------------
class _ReRunWizardTab extends StatelessWidget {
  const _ReRunWizardTab();
  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _MonoLabel('RE-RUN WIZARD'),
          const SizedBox(height: 8),
          Text(
            'Jump back to choose-path with this printer\'s identity '
            'preserved. Use to repair, reconfigure, or migrate — the '
            'profile and host pin stay intact, you just re-pick the '
            'flow (stock-keep vs. fresh-flash).',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontSans,
              fontSize: DeckhandTokens.tMd,
              color: tokens.text2,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Re-run wizard'),
              onPressed: () => context.go('/choose-path'),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      child: child,
    );
  }
}

class _ComingSoonPanel extends StatelessWidget {
  const _ComingSoonPanel({required this.label, required this.body});
  final String label;
  final String body;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _MonoLabel(label),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: tokens.ink2,
                  border: Border.all(color: tokens.line),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  'NOT YET WIRED',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: 9,
                    color: tokens.text3,
                    letterSpacing: 0.1 * 9,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: TextStyle(
              fontFamily: DeckhandTokens.fontSans,
              fontSize: DeckhandTokens.tMd,
              color: tokens.text2,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _MonoLabel extends StatelessWidget {
  const _MonoLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Text(
      text,
      style: TextStyle(
        fontFamily: DeckhandTokens.fontMono,
        fontSize: 10,
        letterSpacing: 0.1 * 10,
        color: tokens.text4,
      ),
    );
  }
}

class _Stat {
  const _Stat(this.k, this.v);
  final String k;
  final String v;
}

/// 2x2 grid of mono key/value pairs — the mockup's `done-stat-grid`
/// pattern. Used in the Status tab to lay out hostname, klippy
/// state, etc.
class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.stats});
  final List<_Stat> stats;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return GridView.count(
      crossAxisCount: 2,
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 4,
      children: [
        for (final s in stats)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: tokens.ink2,
              border: Border.all(color: tokens.line),
              borderRadius: BorderRadius.circular(DeckhandTokens.r2),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _MonoLabel(s.k),
                const SizedBox(height: 4),
                Text(
                  s.v.isEmpty ? '—' : s.v,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: DeckhandTokens.tMd,
                    color: tokens.text,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

Future<void> _copyToClipboard(
  BuildContext context,
  String value,
  String message,
) async {
  await Clipboard.setData(ClipboardData(text: value));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
