import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class DoneScreen extends ConsumerWidget {
  const DoneScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(wizardControllerProvider);
    final state = controller.state;
    final profile = controller.profile;
    final theme = Theme.of(context);

    // The profile's display_name is the right thing to show the user.
    // Falling back to the profile_id only when no profile is loaded
    // (defensive; shouldn't hit this in practice).
    final printerLabel = profile?.displayName ?? state.profileId;

    // Only surface URLs for webui choices the user actually picked.
    // Previously both Fluidd and Mainsail were listed regardless,
    // which misleads a user who chose just one.
    final webuiTips = _buildWebuiTips(profile, state);

    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: t.done.title,
      helperText: t.done.helper,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: Icon(
              Icons.check_circle_outline,
              color: theme.colorScheme.primary,
              size: 32,
              semanticLabel: t.done.a11y_success,
            ),
            title: Text(printerLabel),
            subtitle: state.sshHost != null
                ? Text(t.done.connected_host(host: state.sshHost!))
                : null,
          ),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.done.next_steps_heading,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  for (final tip in webuiTips)
                    _TipRow(icon: Icons.public, text: tip),
                  _TipRow(icon: Icons.update, text: t.done.tip_updates),
                  _TipRow(icon: Icons.settings_suggest, text: t.done.tip_tweaks),
                ],
              ),
            ),
          ),
        ],
      ),
      primaryAction: WizardAction(
        label: t.done.action_another,
        onPressed: () => context.go('/'),
      ),
    );
  }

  /// Build a per-webui tip line keyed off the user's actual decisions
  /// so we never surface a URL for something they chose not to
  /// install.
  List<String> _buildWebuiTips(dynamic profile, dynamic state) {
    if (profile == null) return const [];
    final stack = profile.stack;
    final webui = stack?.webui;
    if (webui == null) return const [];
    final choices = (webui['choices'] as List?)?.cast<Map>() ?? const [];
    if (choices.isEmpty) return const [];

    // Pull the user's list of chosen web UI ids from state.decisions.
    // Supported shapes: a single String id, a List<String>, or null.
    final raw = state.decisions['webui'];
    final selected = <String>{};
    if (raw is String) selected.add(raw);
    if (raw is List) selected.addAll(raw.whereType<String>());
    if (selected.isEmpty) {
      // No explicit choice - fall back to the profile's default_choices.
      final defaults = (webui['default_choices'] as List?)?.cast<String>() ?? const [];
      selected.addAll(defaults);
    }

    final host = state.sshHost ?? '<printer>';
    final tips = <String>[];
    for (final choice in choices) {
      final id = choice['id'] as String?;
      if (id == null || !selected.contains(id)) continue;
      final displayName = (choice['display_name'] as String?) ?? id;
      final port = (choice['default_port'] as int?) ?? 80;
      tips.add(t.done.tip_webui(name: displayName, host: host, port: '$port'));
    }
    return tips;
  }
}

class _TipRow extends StatelessWidget {
  const _TipRow({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
