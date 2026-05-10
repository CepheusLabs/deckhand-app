import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../theming/deckhand_tokens.dart';
import '../utils/json_safety.dart';
import '../widgets/wizard_scaffold.dart';

class DoneScreen extends ConsumerWidget {
  const DoneScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(wizardControllerProvider);
    final state = controller.state;
    final profile = controller.profile;

    final printerLabel = profile?.displayName ?? state.profileId;
    final firmwareDisplay = _firmwareDisplayName(state);
    final hostLabel = state.sshHost ?? '—';
    final webuiSummary = _webuiSummary(profile, state);
    final snapshotSummary = _snapshotSummary(state);
    final hasKiauh = state.decisions['kiauh'] == 'install';
    final hasSnapshot = snapshotSummary != null;

    return WizardScaffold(
      screenId: 'S910-done',
      title: t.done.title,
      body: _DoneBody(
        printerLabel: printerLabel,
        firmwareDisplay: firmwareDisplay,
        hostLabel: hostLabel,
        webuiSummary: webuiSummary,
        snapshotSummary: snapshotSummary,
        helper: t.done.helper,
        a11yLabel: t.done.a11y_success,
        hasKiauh: hasKiauh,
        hasSnapshot: hasSnapshot,
        webuiTips: _buildWebuiTips(profile, state),
      ),
      primaryAction: WizardAction(
        label: t.done.action_another,
        onPressed: () => context.go('/'),
      ),
      secondaryActions: [
        WizardAction(
          label: 'Manage this printer',
          onPressed: () => context.go('/manage'),
        ),
      ],
    );
  }

  /// Resolve the user's firmware decision to a display name. Falls back
  /// to the raw decision value when we don't have a friendlier name —
  /// better to surface "klipper" than to render an em-dash on success.
  String? _firmwareDisplayName(WizardState state) {
    final raw = state.decisions['firmware'];
    if (raw is! String || raw.isEmpty) return null;
    return switch (raw.toLowerCase()) {
      'kalico' => 'Kalico',
      'klipper' => 'Klipper',
      _ => raw,
    };
  }

  /// One-line summary of the user's webui choice for the stat tile.
  /// Mirrors the [_buildWebuiTips] derivation but compresses to a
  /// single label like "Mainsail · port 80" or "Mainsail + Fluidd"
  /// when both got installed.
  String? _webuiSummary(PrinterProfile? profile, WizardState state) {
    if (profile == null) return null;
    final webui = profile.stack.webui;
    if (webui == null) return null;
    final choices = _webuiChoices(webui);
    final selected = _selectedWebuiIds(webui, state);
    if (selected.isEmpty) return null;
    final names = <String>[];
    int? firstPort;
    for (final c in choices) {
      final id = jsonString(c['id']);
      if (id == null || !selected.contains(id)) continue;
      names.add(jsonString(c['display_name']) ?? id);
      firstPort ??= jsonInt(c['default_port']);
    }
    if (names.isEmpty) return null;
    if (names.length == 1) {
      return firstPort == null
          ? names.single
          : '${names.single} · port $firstPort';
    }
    return names.join(' + ');
  }

  Set<String> _selectedWebuiIds(
    Map<dynamic, dynamic> webui,
    WizardState state,
  ) {
    final raw = state.decisions['webui'];
    final selected = <String>{};
    if (raw is String) selected.add(raw);
    if (raw is List) selected.addAll(raw.whereType<String>());
    if (selected.isEmpty) {
      selected.addAll(jsonStringList(webui['default_choices']));
    }
    return selected;
  }

  /// "What did we do for backup?" → null means no snapshot was made,
  /// drives whether the Snapshot stat-tile and footer panel render.
  String? _snapshotSummary(WizardState state) {
    final emmcBackup = state.decisions['snapshot.emmc_backup_path'];
    if (emmcBackup is String && emmcBackup.isNotEmpty) {
      return 'eMMC image';
    }
    final paths = state.decisions['snapshot.paths'];
    if (paths is List && paths.isNotEmpty) {
      final strategy = state.decisions['snapshot.restore_strategy'];
      return switch (strategy) {
        'side_by_side' => 'side-by-side',
        'auto_merge' => 'auto-merged',
        _ => 'archived',
      };
    }
    return null;
  }

  List<String> _buildWebuiTips(PrinterProfile? profile, WizardState state) {
    if (profile == null) return const [];
    final webui = profile.stack.webui;
    if (webui == null) return const [];
    final choices = _webuiChoices(webui);
    if (choices.isEmpty) return const [];
    final selected = _selectedWebuiIds(webui, state);
    final host = state.sshHost ?? '<printer>';
    final tips = <String>[];
    for (final choice in choices) {
      final id = jsonString(choice['id']);
      if (id == null || !selected.contains(id)) continue;
      final displayName = jsonString(choice['display_name']) ?? id;
      final port = jsonInt(choice['default_port']) ?? 80;
      tips.add(t.done.tip_webui(name: displayName, host: host, port: '$port'));
    }
    return tips;
  }
}

List<Map<String, dynamic>> _webuiChoices(Map<dynamic, dynamic> webui) =>
    jsonStringKeyMapList(
      webui['choices'],
    ).where((choice) => jsonString(choice['id'])?.isNotEmpty == true).toList();

class _DoneBody extends StatelessWidget {
  const _DoneBody({
    required this.printerLabel,
    required this.firmwareDisplay,
    required this.hostLabel,
    required this.webuiSummary,
    required this.snapshotSummary,
    required this.helper,
    required this.a11yLabel,
    required this.hasKiauh,
    required this.hasSnapshot,
    required this.webuiTips,
  });

  final String printerLabel;
  final String? firmwareDisplay;
  final String hostLabel;
  final String? webuiSummary;
  final String? snapshotSummary;
  final String helper;
  final String a11yLabel;
  final bool hasKiauh;
  final bool hasSnapshot;
  final List<String> webuiTips;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Hero(
          printerLabel: printerLabel,
          firmwareDisplay: firmwareDisplay,
          hostLabel: hostLabel,
          webuiSummary: webuiSummary,
          snapshotSummary: snapshotSummary,
          helper: helper,
          a11yLabel: a11yLabel,
          mainsailUrl: hostLabel == '—' ? null : 'http://$hostLabel',
          sshUser: 'mks',
        ),
        const SizedBox(height: 18),
        _FooterPanels(
          hasSnapshot: hasSnapshot,
          snapshotSummary: snapshotSummary,
          hasKiauh: hasKiauh,
          webuiTips: webuiTips,
        ),
      ],
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({
    required this.printerLabel,
    required this.firmwareDisplay,
    required this.hostLabel,
    required this.webuiSummary,
    required this.snapshotSummary,
    required this.helper,
    required this.a11yLabel,
    required this.mainsailUrl,
    required this.sshUser,
  });

  final String printerLabel;
  final String? firmwareDisplay;
  final String hostLabel;
  final String? webuiSummary;
  final String? snapshotSummary;
  final String helper;
  final String a11yLabel;
  final String? mainsailUrl;
  final String sshUser;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final headline = firmwareDisplay == null
        ? printerLabel
        : 'Your $printerLabel is running $firmwareDisplay.';
    return Container(
      padding: const EdgeInsets.fromLTRB(32, 36, 32, 32),
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
        gradient: RadialGradient(
          center: const Alignment(0.9, -0.9),
          radius: 1.4,
          colors: [tokens.accentSoft, Colors.transparent],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.check_circle_outline,
                size: 18,
                color: tokens.ok,
                semanticLabel: a11yLabel,
              ),
              const SizedBox(width: 8),
              Text(
                'RUN COMPLETED',
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontMono,
                  fontSize: DeckhandTokens.tXs,
                  color: tokens.ok,
                  letterSpacing: 0.1 * DeckhandTokens.tXs,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            headline,
            style: TextStyle(
              fontFamily: DeckhandTokens.fontSans,
              fontSize: DeckhandTokens.t3Xl,
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
              color: tokens.text,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Text(
              helper,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontSans,
                fontSize: DeckhandTokens.tMd,
                color: tokens.text3,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 18),
          _StatGrid(
            host: hostLabel,
            firmware: firmwareDisplay ?? '—',
            webui: webuiSummary ?? '—',
            snapshot: snapshotSummary ?? '—',
          ),
          const SizedBox(height: 18),
          _HeroActions(
            mainsailUrl: mainsailUrl,
            sshHost: hostLabel == '—' ? null : hostLabel,
            sshUser: sshUser,
          ),
        ],
      ),
    );
  }
}

/// Four stat tiles arranged in a wrap so they reflow at narrow widths.
/// Mirrors the design's "done-stat-grid" 4-up layout. Tiles render even
/// when their value is em-dash so the user sees "we tracked this, you
/// just didn't pick it" rather than a row that vanishes silently.
class _StatGrid extends StatelessWidget {
  const _StatGrid({
    required this.host,
    required this.firmware,
    required this.webui,
    required this.snapshot,
  });
  final String host;
  final String firmware;
  final String webui;
  final String snapshot;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Four equal columns when there's room (≥720px); two columns at
        // typical wizard widths; single column on the narrow end. Wrap
        // doesn't give us equal columns out of the box, so we hand-size.
        final w = constraints.maxWidth;
        final cols = w >= 720 ? 4 : (w >= 420 ? 2 : 1);
        const gap = 12.0;
        final tileWidth = (w - gap * (cols - 1)) / cols;
        final tiles = <Widget>[
          _Stat(label: 'Hostname', value: host, mono: true),
          _Stat(label: 'Firmware', value: firmware, mono: false),
          _Stat(label: 'Web UI', value: webui, mono: false),
          _Stat(label: 'Snapshot', value: snapshot, mono: false),
        ];
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final t in tiles) SizedBox(width: tileWidth, child: t),
          ],
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.mono});
  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: tokens.ink2,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: 10,
              color: tokens.text4,
              letterSpacing: 0.08 * 10,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: mono
                  ? DeckhandTokens.fontMono
                  : DeckhandTokens.fontSans,
              fontSize: mono ? DeckhandTokens.tMd : DeckhandTokens.tLg,
              fontWeight: FontWeight.w500,
              color: tokens.text,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroActions extends StatelessWidget {
  const _HeroActions({
    required this.mainsailUrl,
    required this.sshHost,
    required this.sshUser,
  });
  final String? mainsailUrl;
  final String? sshHost;
  final String sshUser;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (mainsailUrl != null)
          OutlinedButton.icon(
            icon: const Icon(Icons.open_in_browser, size: 14),
            label: const Text('Copy Mainsail URL'),
            // Browser-launch from a flutter desktop app would mean
            // adding url_launcher; manage_screen already pioneered the
            // clipboard-copy pattern so we follow it here for
            // consistency. The URL goes to the user's clipboard with a
            // snackbar receipt — one paste away from the browser.
            onPressed: () =>
                _copyToClipboard(context, mainsailUrl!, 'Mainsail URL copied'),
          ),
        if (sshHost != null)
          OutlinedButton.icon(
            icon: const Icon(Icons.terminal, size: 14),
            label: const Text('Copy SSH command'),
            onPressed: () => _copyToClipboard(
              context,
              'ssh $sshUser@$sshHost',
              'SSH command copied',
            ),
          ),
      ],
    );
  }
}

void _copyToClipboard(BuildContext context, String text, String message) {
  Clipboard.setData(ClipboardData(text: text));
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
  );
}

/// Three-up footer panel grid. Each panel renders only when its
/// underlying decision evidences it (snapshot was made, KIAUH was
/// installed). "What's next" always renders so the user is never left
/// without a forward link.
class _FooterPanels extends StatelessWidget {
  const _FooterPanels({
    required this.hasSnapshot,
    required this.snapshotSummary,
    required this.hasKiauh,
    required this.webuiTips,
  });
  final bool hasSnapshot;
  final String? snapshotSummary;
  final bool hasKiauh;
  final List<String> webuiTips;

  @override
  Widget build(BuildContext context) {
    final panels = <Widget>[
      if (hasSnapshot)
        _FooterPanel(
          icon: Icons.archive_outlined,
          title: snapshotSummary == 'eMMC image'
              ? 'eMMC image saved'
              : 'Snapshot archived',
          body: snapshotSummary == 'eMMC image'
              ? 'A full eMMC image was written to your backup folder. '
                    'Use it to roll back if anything goes sideways.'
              : snapshotSummary == 'side-by-side'
              ? 'Your stock files were archived side-by-side under '
                    'printer_data.stock-*/. Merge anything you want to keep.'
              : 'Your stock files were archived and auto-merged into the '
                    'new install. Conflicts went side-by-side.',
        ),
      if (hasKiauh)
        const _FooterPanel(
          icon: Icons.terminal,
          title: 'KIAUH ready',
          body:
              'SSH in and run ./kiauh/kiauh.sh for ongoing updates and '
              'reinstalls. Multi-MCU configs and Klipper-extras live here.',
        ),
      _FooterPanel(
        icon: Icons.menu_book_outlined,
        title: "What's next",
        body: webuiTips.isNotEmpty ? webuiTips.first : t.done.tip_updates,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final cols = w >= 720 ? panels.length.clamp(1, 3) : (w >= 420 ? 2 : 1);
        const gap = 12.0;
        final tileWidth = (w - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final p in panels) SizedBox(width: tileWidth, child: p),
          ],
        );
      },
    );
  }
}

class _FooterPanel extends StatelessWidget {
  const _FooterPanel({
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: tokens.text2),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tMd,
                    fontWeight: FontWeight.w600,
                    color: tokens.text,
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
              fontSize: DeckhandTokens.tSm,
              color: tokens.text3,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
