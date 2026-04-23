import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _localDirController;
  String? _validationError;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(deckhandSettingsProvider);
    _localDirController = TextEditingController(
      text: settings.localProfilesDir ?? '',
    );
  }

  @override
  void dispose() {
    _localDirController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final raw = _localDirController.text.trim();
    if (raw.isNotEmpty) {
      // Validate: must exist, must look like a deckhand-builds checkout
      // (registry.yaml at the top + a printers/ subdir).
      final ok = await Directory(raw).exists() &&
          await File('$raw/registry.yaml').exists();
      if (!ok) {
        setState(() {
          _validationError = t.settings.profiles_local_dir_invalid;
        });
        return;
      }
    }
    final settings = ref.read(deckhandSettingsProvider);
    settings.localProfilesDir = raw.isEmpty ? null : raw;
    await settings.save();
    setState(() => _validationError = null);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Saved. Restart Deckhand for it to take effect.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(deckhandSettingsProvider);
    final activeDir = settings.localProfilesDir;
    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: t.settings.title,
      helperText:
          'Most settings live here. Anything not visible yet is on the '
          'roadmap.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.settings.section_profiles,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                activeDir != null ? Icons.folder_open : Icons.cloud,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                activeDir != null
                    ? t.settings.profiles_local_dir_active
                    : t.settings.profiles_local_dir_github,
                style: theme.textTheme.labelLarge,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            t.settings.profiles_local_dir_hint,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _localDirController,
            decoration: InputDecoration(
              labelText: t.settings.profiles_local_dir_label,
              border: const OutlineInputBorder(),
              errorText: _validationError,
              suffixIcon: _localDirController.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      tooltip: t.settings.profiles_local_dir_clear,
                      onPressed: () {
                        _localDirController.clear();
                        setState(() => _validationError = null);
                      },
                    ),
            ),
            onChanged: (_) => setState(() => _validationError = null),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.save),
                label: const Text('Save'),
                onPressed: _save,
              ),
            ],
          ),
          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 16),
          const ListTile(
            title: Text('General'),
            subtitle: Text('Default flash verification, cache retention'),
          ),
          const ListTile(
            title: Text('Connections'),
            subtitle: Text('Saved printer endpoints + fingerprints'),
          ),
          const ListTile(
            title: Text('Network allow-list'),
            subtitle: Text('Approved upstreams'),
          ),
          const ListTile(
            title: Text('Appearance'),
            subtitle: Text('Theme, density'),
          ),
        ],
      ),
      primaryAction: WizardAction(
        label: t.common.action_back,
        onPressed: () => context.go('/'),
      ),
    );
  }
}
