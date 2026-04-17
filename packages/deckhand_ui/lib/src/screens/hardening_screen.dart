import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class HardeningScreen extends ConsumerStatefulWidget {
  const HardeningScreen({super.key});

  @override
  ConsumerState<HardeningScreen> createState() => _HardeningScreenState();
}

class _HardeningScreenState extends ConsumerState<HardeningScreen> {
  final _enabled = <String, bool>{
    'makerbase_udp': false,
    'makerbase_net_mods': false,
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
            'makerbase_udp',
            'Disable makerbase-udp (LAN file-upload service)',
            'Listens on UDP + HTTP without auth. Kills MKS slicer/phone-app discovery.',
          ),
          _toggle(
            'makerbase_net_mods',
            'Disable USB wifi provisioning',
            'Closes a physical-access takeover vector.',
          ),
          _toggle(
            'fix_timesync',
            'Fix time-sync conflict (keep chrony only)',
            'Disables redundant ntp + chronyd units.',
          ),
          _toggle(
            'change_password',
            'Change default mks SSH password',
            'Required on any printer exposed to an untrusted network.',
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
        label: 'Continue',
        onPressed: () async {
          final controller = ref.read(wizardControllerProvider);
          for (final e in _enabled.entries) {
            await controller.setDecision('hardening.${e.key}', e.value);
          }
          if (_enabled['change_password'] == true) {
            await controller.setDecision(
                'hardening.new_password', _passwordController.text);
          }
          if (context.mounted) context.go('/review');
        },
      ),
      secondaryActions: [
        WizardAction(label: 'Back', onPressed: () => context.go('/files')),
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
