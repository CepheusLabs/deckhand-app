import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class HardeningScreen extends ConsumerStatefulWidget {
  const HardeningScreen({super.key});

  @override
  ConsumerState<HardeningScreen> createState() => _HardeningScreenState();
}

class _HardeningScreenState extends ConsumerState<HardeningScreen> {
  // makerbase_udp and makerbase_net_mods are already asked on the
  // Services screen; don't duplicate them here. This page is for
  // cross-cutting hardening that isn't tied to a single stock service.
  final _enabled = <String, bool>{
    'fix_timesync': false,
    'change_password': false,
  };
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Security hardening (optional)',
      helperText:
          'Everything here is opt-in. Defaults are "leave it alone." Enable '
          'what matches your threat model.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _toggle(
            'fix_timesync',
            'Fix time-sync conflict',
            'The stock image runs two clock-sync daemons at once '
                '(chrony + systemd-timesyncd), which fight each other, and '
                'points them at NTP pools that can be unreachable outside '
                'China. Enabling this disables timesyncd so chrony is the '
                'sole owner of the clock, and switches its pool to '
                'pool.ntp.org. Fixes the "clock jumps on boot" behavior '
                'some users see.',
          ),
          _toggle(
            'change_password',
            'Change default mks SSH password',
            'The default `mks` / `makerbase` credentials are documented '
                'publicly and identical on every unit out of the box. '
                'Strongly recommended before exposing the printer to any '
                'network you don\'t fully trust (LAN with guests, shared '
                'IoT VLAN, etc.).',
          ),
          if (_enabled['change_password'] == true) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'New password'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _confirmController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirm password'),
            ),
          ],
        ],
      ),
      primaryAction: WizardAction(
        label: t.common.action_continue,
        onPressed: () async {
          final controller = ref.read(wizardControllerProvider);
          // Snapshot values and the router BEFORE awaits. Previously
          // this used context.mounted only at the very end, which
          // left multiple per-await gaps where context could have
          // been torn down mid-loop.
          final router = GoRouter.of(context);
          for (final e in _enabled.entries) {
            if (!mounted) return;
            await controller.setDecision('hardening.${e.key}', e.value);
          }
          if (!mounted) return;
          if (_enabled['change_password'] == true) {
            await controller.setDecision(
              'hardening.new_password',
              _passwordController.text,
            );
          }
          if (!mounted) return;
          router.go('/review');
        },
      ),
      secondaryActions: [
        WizardAction(
          label: t.common.action_back,
          onPressed: () => context.go('/files'),
        ),
      ],
    );
  }

  Widget _toggle(String key, String title, String subtitle) => SwitchListTile(
    value: _enabled[key]!,
    onChanged: (v) => setState(() => _enabled[key] = v),
    title: Text(title),
    subtitle: Text(subtitle),
  );
}
