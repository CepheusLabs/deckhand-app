import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/forge.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';

class HardeningScreen extends ConsumerStatefulWidget {
  const HardeningScreen({super.key});

  @override
  ConsumerState<HardeningScreen> createState() => _HardeningScreenState();
}

class _HardeningScreenState extends ConsumerState<HardeningScreen> {
  // makerbase_udp / makerbase_net_mods are asked on the Services
  // screen; this page is for cross-cutting hardening that isn't tied
  // to a single stock service.
  final _enabled = <String, bool>{
    'fix_timesync': false,
    'change_password': false,
  };
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _passwordObscured = true;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    return ClWizardPageScaffold(
      title: 'Optional hardening.',
      helperText:
          'All defaults off. Tick what makes sense for your network — '
          'each row explains the threat it mitigates and the cost of '
          'enabling it.',
      preHeader: const ClPageHeader(
        icon: Icons.shield_outlined,
        title: 'Hardening',
      ),
      body: Container(
        decoration: BoxDecoration(
          color: brand.bgAlt,
          border: Border.all(color: brand.borderStrong),
          borderRadius: BorderRadius.circular(context.radii.md),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            _HardeningRow(
              id: 'fix_timesync',
              title: 'Fix time-sync conflict',
              body:
                  'The stock image runs two clock-sync daemons at once '
                  '(chrony + systemd-timesyncd) which fight each other, '
                  'and points them at NTP pools that can be unreachable '
                  'outside China. Enabling this disables timesyncd so '
                  'chrony is the sole owner of the clock, and switches '
                  'its pool to pool.ntp.org.',
              checked: _enabled['fix_timesync']!,
              onChanged: (v) => setState(() => _enabled['fix_timesync'] = v),
              isLast: false,
            ),
            _HardeningRow(
              id: 'change_password',
              title: 'Change default mks SSH password',
              body:
                  'The default mks / makerbase credentials are documented '
                  'publicly and identical on every unit out of the box. '
                  'Strongly recommended before exposing the printer to '
                  'any network you don\'t fully trust (LAN with guests, '
                  'shared IoT VLAN).',
              checked: _enabled['change_password']!,
              onChanged: (v) =>
                  setState(() => _enabled['change_password'] = v),
              isLast: !_enabled['change_password']!,
              expanded: _enabled['change_password']!
                  ? _PasswordFields(
                      passwordController: _passwordController,
                      confirmController: _confirmController,
                      obscured: _passwordObscured,
                      onToggleObscured: () => setState(
                        () => _passwordObscured = !_passwordObscured,
                      ),
                      onChanged: () => setState(() {}),
                    )
                  : null,
            ),
          ],
        ),
      ),
      primaryAction: ClWizardAction(
        label: t.common.action_continue,
        onPressed: () async {
          final controller = ref.read(wizardControllerProvider);
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
        ClWizardAction(
          label: t.common.action_back,
          onPressed: () => context.go('/files'),
          isBack: true,
        ),
      ],
    );
  }
}

class _HardeningRow extends StatelessWidget {
  const _HardeningRow({
    required this.id,
    required this.title,
    required this.body,
    required this.checked,
    required this.onChanged,
    required this.isLast,
    this.expanded,
  });

  final String id;
  final String title;
  final String body;
  final bool checked;
  final void Function(bool) onChanged;
  final bool isLast;
  final Widget? expanded;

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    return Column(
      children: [
        InkWell(
          onTap: () => onChanged(!checked),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            decoration: BoxDecoration(
              border: (isLast && expanded == null)
                  ? null
                  : Border(bottom: BorderSide(color: brand.borderSubtle)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: Checkbox(
                    value: checked,
                    onChanged: (v) => onChanged(v ?? false),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: context.clBodyMedium.copyWith(
                          fontWeight: FontWeight.w500,
                          color: brand.ink,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        body,
                        style: context.clBodySmall.copyWith(
                          color: brand.ink3,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.shield_outlined, size: 16, color: brand.ink4),
              ],
            ),
          ),
        ),
        if (expanded != null)
          Container(
            decoration: BoxDecoration(
              color: brand.surface,
              border: isLast
                  ? null
                  : Border(bottom: BorderSide(color: brand.borderSubtle)),
            ),
            padding: const EdgeInsets.fromLTRB(42, 12, 14, 16),
            child: expanded!,
          ),
      ],
    );
  }
}

class _PasswordFields extends StatelessWidget {
  const _PasswordFields({
    required this.passwordController,
    required this.confirmController,
    required this.obscured,
    required this.onToggleObscured,
    required this.onChanged,
  });

  final TextEditingController passwordController;
  final TextEditingController confirmController;
  final bool obscured;
  final VoidCallback onToggleObscured;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final pw = passwordController.text;
    final confirm = confirmController.text;
    final mismatch = confirm.isNotEmpty && pw != confirm;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final twoCol = constraints.maxWidth >= 520;
            final pwField = TextField(
              controller: passwordController,
              obscureText: obscured,
              onChanged: (_) => onChanged(),
              decoration: InputDecoration(
                labelText: 'New password',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    obscured ? Icons.visibility : Icons.visibility_off,
                    size: 18,
                  ),
                  tooltip: obscured ? 'Show' : 'Hide',
                  onPressed: onToggleObscured,
                ),
              ),
            );
            final confirmField = TextField(
              controller: confirmController,
              obscureText: obscured,
              onChanged: (_) => onChanged(),
              decoration: InputDecoration(
                labelText: 'Confirm',
                border: const OutlineInputBorder(),
                errorText: mismatch ? 'Passwords don\'t match' : null,
              ),
            );
            if (twoCol) {
              return Row(
                children: [
                  Expanded(child: pwField),
                  const SizedBox(width: 12),
                  Expanded(child: confirmField),
                ],
              );
            }
            return Column(
              children: [
                pwField,
                const SizedBox(height: 12),
                confirmField,
              ],
            );
          },
        ),
        const SizedBox(height: 10),
        _StrengthMeter(password: pw),
      ],
    );
  }
}

class _StrengthMeter extends StatelessWidget {
  const _StrengthMeter({required this.password});
  final String password;

  int get _level {
    final n = password.length;
    if (n == 0) return 0;
    if (n < 6) return 1;
    if (n < 10) return 2;
    if (n < 14) return 3;
    return 4;
  }

  String get _label {
    switch (_level) {
      case 0:
        return '';
      case 1:
        return 'WEAK';
      case 2:
        return 'OK';
      case 3:
        return 'STRONG';
      default:
        return 'VERY STRONG';
    }
  }

  Color _color(ClBrandColors brand, int filled) {
    if (filled <= 1) return brand.bad;
    if (filled <= 2) return brand.warn;
    return brand.good;
  }

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    return Row(
      children: [
        for (var i = 1; i <= 4; i++) ...[
          Expanded(
            child: Container(
              height: 3,
              decoration: BoxDecoration(
                color: _level >= i ? _color(brand, _level) : brand.surface2,
                borderRadius: BorderRadius.circular(context.radii.xs),
              ),
            ),
          ),
          if (i < 4) const SizedBox(width: 4),
        ],
        const SizedBox(width: 10),
        SizedBox(
          width: 96,
          child: Text(
            _label,
            style: context.labelTechnical.copyWith(
              color: brand.ink3,
              letterSpacing: 0,
            ),
          ),
        ),
      ],
    );
  }
}
