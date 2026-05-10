import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../theming/deckhand_tokens.dart';
import '../widgets/wizard_scaffold.dart';

class FirstBootSetupScreen extends ConsumerStatefulWidget {
  const FirstBootSetupScreen({super.key});

  @override
  ConsumerState<FirstBootSetupScreen> createState() =>
      _FirstBootSetupScreenState();
}

class _FirstBootSetupScreenState extends ConsumerState<FirstBootSetupScreen> {
  final _user = TextEditingController(text: 'mks');
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _hostname = TextEditingController();
  bool _passwordObscured = true;

  // Per the design (S250) the form also captures timezone + locale so
  // the new OS comes up matching the user's expectations on first
  // boot. "(system)" means "let armbian-firstrun pick from the host";
  // explicit options pin the printer regardless of where the host
  // happens to be when the user runs Deckhand.
  static const _timezoneSystemSentinel = '__system__';
  static const _localeSystemSentinel = '__system__';
  String _timezone = _timezoneSystemSentinel;
  String _locale = _localeSystemSentinel;

  static const _timezoneOptions = <(String value, String label)>[
    (_timezoneSystemSentinel, 'Match this computer'),
    ('UTC', 'UTC'),
    ('America/Denver', 'America/Denver'),
    ('America/New_York', 'America/New_York'),
    ('America/Los_Angeles', 'America/Los_Angeles'),
    ('Europe/Berlin', 'Europe/Berlin'),
    ('Europe/London', 'Europe/London'),
    ('Asia/Tokyo', 'Asia/Tokyo'),
  ];

  static const _localeOptions = <(String value, String label)>[
    (_localeSystemSentinel, 'Match this computer'),
    ('en_US.UTF-8', 'en_US.UTF-8'),
    ('en_GB.UTF-8', 'en_GB.UTF-8'),
    ('de_DE.UTF-8', 'de_DE.UTF-8'),
    ('fr_FR.UTF-8', 'fr_FR.UTF-8'),
    ('ja_JP.UTF-8', 'ja_JP.UTF-8'),
  ];

  @override
  void dispose() {
    _user.dispose();
    _password.dispose();
    _confirm.dispose();
    _hostname.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final pw = _password.text;
    final confirm = _confirm.text;
    final mismatch = confirm.isNotEmpty && pw != confirm;
    final canContinue =
        _user.text.trim().isNotEmpty && pw.isNotEmpty && !mismatch;

    return WizardScaffold(
      screenId: 'S250-provision-os',
      title: 'Provision the new OS.',
      helperText:
          'Creates the user Deckhand and Moonraker will run as, sets a '
          'hostname, and lays down the bare minimum so the printer comes '
          'up cleanly on next boot. Defaults match the stock Phrozen '
          'convention so you can mix new-OS and stock-OS printers '
          'without credential churn.',
      body: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: tokens.ink1,
          border: Border.all(color: tokens.line),
          borderRadius: BorderRadius.circular(DeckhandTokens.r3),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final twoCol = constraints.maxWidth >= 720;
                final children = [
                  _LabeledField(
                    label: 'USERNAME',
                    child: TextField(
                      controller: _user,
                      onChanged: (_) => setState(() {}),
                      style: TextStyle(
                        fontFamily: DeckhandTokens.fontMono,
                        fontSize: DeckhandTokens.tMd,
                        color: tokens.text,
                      ),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  _LabeledField(
                    label: 'HOSTNAME (optional)',
                    child: TextField(
                      controller: _hostname,
                      style: TextStyle(
                        fontFamily: DeckhandTokens.fontMono,
                        fontSize: DeckhandTokens.tMd,
                        color: tokens.text,
                      ),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: 'arco-bench',
                      ),
                    ),
                  ),
                  _LabeledField(
                    label: 'PASSWORD',
                    child: TextField(
                      controller: _password,
                      obscureText: _passwordObscured,
                      onChanged: (_) => setState(() {}),
                      style: TextStyle(
                        fontFamily: DeckhandTokens.fontMono,
                        fontSize: DeckhandTokens.tMd,
                        color: tokens.text,
                      ),
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _passwordObscured
                                ? Icons.visibility
                                : Icons.visibility_off,
                            size: 18,
                          ),
                          tooltip: _passwordObscured ? 'Show' : 'Hide',
                          onPressed: () => setState(
                            () => _passwordObscured = !_passwordObscured,
                          ),
                        ),
                      ),
                    ),
                  ),
                  _LabeledField(
                    label: 'CONFIRM',
                    child: TextField(
                      controller: _confirm,
                      obscureText: _passwordObscured,
                      onChanged: (_) => setState(() {}),
                      style: TextStyle(
                        fontFamily: DeckhandTokens.fontMono,
                        fontSize: DeckhandTokens.tMd,
                        color: tokens.text,
                      ),
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        errorText: mismatch ? 'Passwords don\'t match' : null,
                      ),
                    ),
                  ),
                  _LabeledField(
                    label: 'TIMEZONE',
                    child: DropdownButtonFormField<String>(
                      initialValue: _timezone,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final (value, label) in _timezoneOptions)
                          DropdownMenuItem(
                            value: value,
                            child: Text(
                              label,
                              style: TextStyle(
                                fontFamily: DeckhandTokens.fontMono,
                                fontSize: DeckhandTokens.tMd,
                                color: tokens.text,
                              ),
                            ),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _timezone = v);
                      },
                    ),
                  ),
                  _LabeledField(
                    label: 'LOCALE',
                    child: DropdownButtonFormField<String>(
                      initialValue: _locale,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final (value, label) in _localeOptions)
                          DropdownMenuItem(
                            value: value,
                            child: Text(
                              label,
                              style: TextStyle(
                                fontFamily: DeckhandTokens.fontMono,
                                fontSize: DeckhandTokens.tMd,
                                color: tokens.text,
                              ),
                            ),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _locale = v);
                      },
                    ),
                  ),
                ];
                if (twoCol) {
                  // 6 fields → three rows of two when there's room. The
                  // pairing is intentional: [user, host] · [pw, confirm]
                  // · [tz, locale] groups related decisions visually.
                  return Column(
                    children: [
                      for (var i = 0; i < children.length; i += 2) ...[
                        if (i > 0) const SizedBox(height: 14),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: children[i]),
                            const SizedBox(width: 16),
                            if (i + 1 < children.length)
                              Expanded(child: children[i + 1])
                            else
                              const Spacer(),
                          ],
                        ),
                      ],
                    ],
                  );
                }
                return Column(
                  children: [
                    for (final c in children) ...[
                      c,
                      const SizedBox(height: 14),
                    ],
                  ],
                );
              },
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: tokens.ink2,
                border: Border.all(color: tokens.line),
                borderRadius: BorderRadius.circular(DeckhandTokens.r2),
              ),
              child: Row(
                children: [
                  Icon(Icons.shield_outlined, size: 16, color: tokens.text3),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Defaults match the Phrozen stock convention so you '
                      'can mix new-OS and stock-OS printers without '
                      'credential churn.',
                      style: TextStyle(
                        fontFamily: DeckhandTokens.fontSans,
                        fontSize: DeckhandTokens.tSm,
                        color: tokens.text2,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      primaryAction: WizardAction(
        label: 'Create user and continue',
        disabledReason: _disabledReason(
          user: _user.text,
          password: pw,
          mismatch: mismatch,
        ),
        onPressed: canContinue
            ? () async {
                final controller = ref.read(wizardControllerProvider);
                await controller.setDecision('first_boot.user', _user.text);
                await controller.setDecision(
                  'first_boot.password',
                  _password.text,
                );
                await controller.setDecision(
                  'first_boot.hostname',
                  _hostname.text,
                );
                // Persist as empty when the user kept "Match this
                // computer" so a downstream apply step reads "no
                // override, use armbian-firstrun's default" rather
                // than literally writing a sentinel into the OS.
                await controller.setDecision(
                  'first_boot.timezone',
                  _timezone == _timezoneSystemSentinel ? '' : _timezone,
                );
                await controller.setDecision(
                  'first_boot.locale',
                  _locale == _localeSystemSentinel ? '' : _locale,
                );
                if (context.mounted) context.go('/firmware');
              }
            : null,
      ),
      secondaryActions: [
        WizardAction(
          label: t.common.action_back,
          onPressed: () => context.go('/first-boot'),
          isBack: true,
        ),
      ],
    );
  }

  String? _disabledReason({
    required String user,
    required String password,
    required bool mismatch,
  }) {
    if (user.trim().isEmpty) return 'Enter a username first.';
    if (password.isEmpty) return 'Enter a password first.';
    if (mismatch) return 'Make the two passwords match.';
    return null;
  }
}

class _LabeledField extends StatelessWidget {
  const _LabeledField({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontFamily: DeckhandTokens.fontMono,
            fontSize: 10,
            color: tokens.text4,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}
