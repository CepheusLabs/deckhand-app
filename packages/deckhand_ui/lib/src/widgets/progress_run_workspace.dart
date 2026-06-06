import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/forge.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../utils/disk_operation_errors.dart';
import 'network_panel.dart';

class RunStep {
  const RunStep({required this.id, required this.kind});
  final String id;
  final String kind;
}

enum RunStepStatus { queued, active, done, warning, failed }

enum RunBannerSeverity { success, warning, error }

/// Result banner shown above the run workspace. Rebuilt on forge's
/// [ClBanner]; the Deckhand [RunBannerSeverity] maps onto the forge
/// [ClBannerKind] semantics.
class RunBanner extends StatelessWidget {
  const RunBanner({
    super.key,
    required this.title,
    required this.message,
    required this.severity,
  });

  final String title;
  final String message;
  final RunBannerSeverity severity;

  @override
  Widget build(BuildContext context) {
    final kind = switch (severity) {
      RunBannerSeverity.success => ClBannerKind.good,
      RunBannerSeverity.warning => ClBannerKind.warn,
      RunBannerSeverity.error => ClBannerKind.bad,
    };
    return ClBanner(kind: kind, title: title, body: message);
  }
}

/// Maps the wizard's [WizardLogMode] preference onto the log rendering:
/// `user` shows friendly, translated copy; `developer` shows the raw
/// controller log lines.
enum WizardLogMode { user, developer }

/// Formats the session log for the clipboard. Kept as Deckhand domain
/// logic (the controller emits `[ok]`/`[fail]`/`> starting …` lines and
/// this turns them into a fixed-width, human-readable transcript).
String formatWizardLogForClipboard(List<String> lines, WizardLogMode mode) =>
    _LogLineParser.formatForClipboard(lines, mode);

class ProgressRunWorkspace extends StatelessWidget {
  const ProgressRunWorkspace({
    super.key,
    required this.steps,
    required this.statusFor,
    required this.log,
    required this.networkEvents,
  });

  final List<RunStep> steps;
  final RunStepStatus Function(RunStep step) statusFor;
  final List<String> log;
  final List<EgressEvent> networkEvents;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stepRail = _StepRail(steps: steps, statusFor: statusFor);
        final logPane = _LogNetworkPane(log: log, networkEvents: networkEvents);
        if (constraints.maxWidth < 840) {
          return Column(
            children: [
              SizedBox(height: 170, child: stepRail),
              const SizedBox(height: 12),
              Expanded(child: logPane),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 320, child: stepRail),
            const SizedBox(width: 16),
            Expanded(child: logPane),
          ],
        );
      },
    );
  }
}

/// Adapts Deckhand's [RunStep] list + [statusFor] callback onto forge's
/// [ClOperationStepRail], which owns the rail chrome, summary,
/// active-step autoscroll, and row states.
class _StepRail extends StatelessWidget {
  const _StepRail({required this.steps, required this.statusFor});

  final List<RunStep> steps;
  final RunStepStatus Function(RunStep step) statusFor;

  @override
  Widget build(BuildContext context) {
    return ClOperationStepRail(
      fillParent: true,
      steps: [
        for (var i = 0; i < steps.length; i++)
          ClOperationStep(
            id: steps[i].id,
            title: runStepTitle(steps[i].id),
            subtitle: '${(i + 1).toString().padLeft(2, '0')} · '
                '${_kindTitle(steps[i].kind)}',
            status: _railStatus(statusFor(steps[i])),
          ),
      ],
    );
  }

  ClOperationStepStatus _railStatus(RunStepStatus status) => switch (status) {
    RunStepStatus.queued => ClOperationStepStatus.queued,
    RunStepStatus.active => ClOperationStepStatus.active,
    RunStepStatus.done => ClOperationStepStatus.done,
    RunStepStatus.warning => ClOperationStepStatus.warning,
    RunStepStatus.failed => ClOperationStepStatus.failed,
  };
}

class _LogNetworkPane extends ConsumerWidget {
  const _LogNetworkPane({required this.log, required this.networkEvents});

  final List<String> log;
  final List<EgressEvent> networkEvents;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final developerMode = ref.watch(deckhandSettingsProvider).developerMode;
    final logMode = developerMode
        ? WizardLogMode.developer
        : WizardLogMode.user;
    final showNetworkTab = developerMode || networkEvents.isNotEmpty;
    final tabs = [
      _PaneTab(label: 'Log', icon: ClIcons.terminal, countLabel: 'live'),
      if (showNetworkTab)
        _PaneTab(
          label: 'Downloads',
          icon: ClIcons.cloudDownload,
          countLabel: '${networkEvents.length}',
        ),
    ];
    final views = [
      Semantics(
        label: t.progress.semantics_log_label,
        child: ClLogView(
          entries: _LogLineParser.toEntries(log, logMode),
          emptyMessage: 'Waiting for the first log line...',
        ),
      ),
      if (showNetworkTab) NetworkPanel(events: networkEvents),
    ];
    return DefaultTabController(
      length: tabs.length,
      child: ClPanel(
        fillParent: true,
        body: Column(
          children: [
            _PaneTabs(
              trailingLabel: 'session.log · ${log.length} lines',
              onCopyLog: log.isEmpty
                  ? null
                  : () => _copyLog(context, log, logMode),
              tabs: tabs,
            ),
            Expanded(child: TabBarView(children: views)),
          ],
        ),
      ),
    );
  }

  Future<void> _copyLog(
    BuildContext context,
    List<String> lines,
    WizardLogMode mode,
  ) async {
    await Clipboard.setData(
      ClipboardData(text: formatWizardLogForClipboard(lines, mode)),
    );
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('Log copied')));
  }
}

class _PaneTab {
  _PaneTab({required this.label, required this.icon, required this.countLabel});
  final String label;
  final IconData icon;
  final String countLabel;
}

class _PaneTabs extends StatelessWidget {
  const _PaneTabs({
    required this.tabs,
    required this.trailingLabel,
    required this.onCopyLog,
  });
  final List<_PaneTab> tabs;
  final String trailingLabel;
  final VoidCallback? onCopyLog;

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    final controller = DefaultTabController.of(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Container(
          decoration: BoxDecoration(
            color: brand.surface,
            border: Border(bottom: BorderSide(color: brand.borderStrong)),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final showTrailing = constraints.maxWidth >= 460;
              return Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < tabs.length; i++)
                            _PaneTabCell(
                              tab: tabs[i],
                              isActive: controller.index == i,
                              onTap: () => controller.animateTo(i),
                            ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy log',
                    icon: const ClIcon(ClIcons.copy, size: 14),
                    color: brand.ink3,
                    disabledColor: brand.ink4.withValues(alpha: 0.5),
                    onPressed: onCopyLog,
                  ),
                  if (showTrailing)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 180),
                        child: Text(
                          trailingLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.dataTiny,
                        ),
                      ),
                    ),
                ],
              );
            },
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
    required this.onTap,
  });
  final _PaneTab tab;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? brand.bgAlt : Colors.transparent,
          border: Border(
            top: BorderSide(
              color: isActive ? brand.primary : Colors.transparent,
              width: 2,
            ),
            right: BorderSide(color: brand.borderStrong),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClIcon(
              tab.icon,
              size: 14,
              color: isActive ? brand.ink : brand.ink3,
            ),
            const SizedBox(width: 8),
            Text(
              tab.label,
              style: context.clBodySmall.copyWith(
                color: isActive ? brand.ink : brand.ink3,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: isActive ? brand.primary : brand.surface3,
                borderRadius: BorderRadius.circular(context.radii.lg),
              ),
              child: Text(
                tab.countLabel,
                style: context.dataTiny.copyWith(
                  fontSize: 9,
                  color: isActive ? brand.onPrimary : brand.ink2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String runStepTitle(String id) {
  final mapped = switch (id) {
    'choose_os_image' => 'Choose OS image',
    'choose_target_disk' => 'Check selected disk',
    'download_os' => 'Prepare OS image',
    'flash_disk' => 'Write OS image',
    'flash_done_prompt' => 'Confirm flash',
    'wait_for_ssh' => 'Wait for printer',
    'first_boot_setup' => 'Run first-boot setup',
    'install_firmware' => 'Install firmware',
    'install_stack' => 'Install Klipper services',
    'link_extras' => 'Install profile extras',
    'install_screen' => 'Install touchscreen UI',
    'flash_mcus' => 'Flash printer MCUs',
    'apply_services' => 'Clean up stock services',
    'apply_files' => 'Clean up stock files',
    'snapshot_paths' => 'Back up stock files',
    'write_file' => 'Write config',
    'install_marker' => 'Mark printer as managed',
    'verify' => 'Verify install',
    'script' => 'Run setup script',
    'ssh_commands' => 'Run remote commands',
    'conditional' => 'Evaluate condition',
    _ => null,
  };
  if (mapped != null) return mapped;
  final spaced = id.replaceAll('_', ' ').replaceAll('-', ' ').trim();
  if (spaced.isEmpty) return id;
  return spaced[0].toUpperCase() + spaced.substring(1);
}

String _kindTitle(String kind) {
  final mapped = switch (kind) {
    'choose_one' => 'choice',
    'disk_picker' => 'disk picker',
    'os_download' => 'OS image',
    'flash_disk' => 'disk write',
    'prompt' => 'confirmation',
    'wait_for_ssh' => 'printer wait',
    'ssh_commands' => 'SSH commands',
    'install_firmware' => 'firmware',
    'install_stack' => 'Klipper services',
    'link_extras' => 'profile extras',
    'install_screen' => 'screen UI',
    'flash_mcus' => 'MCU flashing',
    'apply_services' => 'service cleanup',
    'apply_files' => 'file cleanup',
    'snapshot_archive' => 'config backup',
    'snapshot_paths' => 'config backup',
    'hardening' => 'system hardening',
    'write_file' => 'config write',
    'install_marker' => 'managed marker',
    'verify' => 'verification',
    'script' => 'remote script',
    'conditional' => 'condition',
    _ => null,
  };
  if (mapped != null) return mapped;
  if (kind.isEmpty) return 'step';
  return kind.replaceAll('_', ' ');
}

/// Parses raw controller log lines into [ClLogEntry] rows (time gutter +
/// tag + message + tone) and into a fixed-width clipboard transcript.
///
/// This is Deckhand domain logic: it understands the controller's
/// `[ok]`/`[fail]`/`[warn]`/`> starting …`/`[source] …` line grammar and
/// rewrites it into either raw developer text or friendly user copy.
/// [ClLogView] only renders the resulting rows.
class _LogLineParser {
  const _LogLineParser._();

  static const _clipboardMessageWidth = 96;
  static const _clipboardContinuationIndent = 19;

  /// Build the [ClLogEntry] list rendered by [ClLogView]. Each line gets a
  /// synthesized monotonic time marker so the gutter has visual rhythm
  /// (the controller does not emit timestamps yet).
  static List<ClLogEntry> toEntries(List<String> lines, WizardLogMode mode) {
    return [
      for (var i = 0; i < lines.length; i++)
        _entry(_ordinalLabel(i), _parse(lines[i], mode)),
    ];
  }

  static ClLogEntry _entry(String time, _Parsed parsed) => ClLogEntry(
    time: time,
    tag: parsed.tag,
    message: parsed.msg,
    tone: _tone(parsed.kind),
  );

  static ClLogTone _tone(_LogKind kind) => switch (kind) {
    _LogKind.ok => ClLogTone.success,
    _LogKind.fail => ClLogTone.danger,
    _LogKind.warn => ClLogTone.warning,
    _LogKind.exec => ClLogTone.accent,
    _LogKind.info => ClLogTone.info,
    _LogKind.input => ClLogTone.input,
    _LogKind.dim => ClLogTone.muted,
  };

  static String formatForClipboard(List<String> lines, WizardLogMode mode) {
    return [
      'Deckhand session log (${mode == WizardLogMode.developer ? 'developer' : 'standard'})',
      'TIME       TAG     MESSAGE',
      '---------  ------  ----------------------------------------',
      for (var i = 0; i < lines.length; i++)
        ..._formatClipboardLines(i, _parse(lines[i], mode)),
    ].join('\n');
  }

  static List<String> _formatClipboardLines(int ordinal, _Parsed parsed) {
    final chunks = _wrapClipboardMessage(
      parsed.msg,
      width: _clipboardMessageWidth,
    );
    final prefix = _formatClipboardPrefix(ordinal, parsed);
    if (chunks.isEmpty) return [prefix];
    return [
      '$prefix${chunks.first}',
      for (final chunk in chunks.skip(1))
        '${' ' * _clipboardContinuationIndent}$chunk',
    ];
  }

  static String _formatClipboardPrefix(int ordinal, _Parsed parsed) =>
      '${_ordinalLabel(ordinal).padRight(9)}  ${parsed.tag.padRight(6)}  ';

  static List<String> _wrapClipboardMessage(
    String message, {
    required int width,
  }) {
    final normalized = message.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) return const [];
    final lines = <String>[];
    var current = '';
    for (final token in normalized.split(' ')) {
      var remaining = token;
      while (remaining.length > width) {
        if (current.isNotEmpty) {
          lines.add(current);
          current = '';
        }
        lines.add(remaining.substring(0, width));
        remaining = remaining.substring(width);
      }
      if (remaining.isEmpty) continue;
      if (current.isEmpty) {
        current = remaining;
      } else if (current.length + 1 + remaining.length <= width) {
        current = '$current $remaining';
      } else {
        lines.add(current);
        current = remaining;
      }
    }
    if (current.isNotEmpty) lines.add(current);
    return lines;
  }

  /// Synthesize a `mm:ss.frac`-shaped marker from the line index.
  static String _ordinalLabel(int n) {
    final m = (n ~/ 60).toString().padLeft(2, '0');
    final s = (n % 60).toString().padLeft(2, '0');
    return '$m:$s.${(n * 17 % 1000).toString().padLeft(3, '0')}';
  }

  static _Parsed _parse(String raw, WizardLogMode mode) {
    final parsed = _parseDeveloper(raw);
    if (mode == WizardLogMode.developer) return parsed;
    return _Parsed(parsed.kind, parsed.tag, _friendlyMessage(raw, parsed));
  }

  static _Parsed _parseDeveloper(String raw) {
    if (raw.startsWith('[ok] ')) {
      return _Parsed(_LogKind.ok, 'OK', raw.substring(5));
    }
    if (raw.startsWith('[fail] ')) {
      return _Parsed(_LogKind.fail, 'FAIL', raw.substring(7));
    }
    if (raw.startsWith('[warn] ')) {
      return _Parsed(_LogKind.warn, 'WARN', raw.substring(7));
    }
    if (raw.startsWith('> starting ')) {
      return _Parsed(_LogKind.exec, 'STEP', raw.substring(2));
    }
    if (raw.startsWith('> ')) {
      return _Parsed(_LogKind.info, 'EXEC', raw.substring(2));
    }
    final bracket = RegExp(r'^\[([a-z0-9_-]+)\]\s*(.*)$').firstMatch(raw);
    if (bracket != null) {
      final source = bracket.group(1)!;
      final message = bracket.group(2)!;
      return _Parsed(_kindForSource(source), _tagForSource(source), message);
    }
    return _Parsed(_LogKind.dim, '...', raw);
  }

  static String _friendlyMessage(String raw, _Parsed parsed) {
    if (raw.startsWith('> starting ')) {
      return _friendlyStepAction(raw.substring('> starting '.length));
    }
    if (raw.startsWith('[ok] ')) {
      return 'Finished ${_friendlyStepName(raw.substring(5))}';
    }
    if (raw.startsWith('[fail] ')) {
      return 'Stopped during ${_friendlyFailure(raw.substring(7))}';
    }
    if (raw.startsWith('[warn] ')) {
      return _friendlyWarning(raw.substring(7));
    }
    final bracket = RegExp(r'^\[([a-z0-9_-]+)\]\s*(.*)$').firstMatch(raw);
    if (bracket == null) return parsed.msg;
    final source = bracket.group(1)!;
    final message = bracket.group(2)!;
    return switch (source) {
      'input' => _friendlyInput(message),
      'os' => _friendlyOs(message),
      'flash' => _friendlyFlash(message),
      'run-state' => _friendlyRunState(message),
      _ => message,
    };
  }

  static String _friendlyInput(String message) {
    const prefix = 'using existing decision: ';
    if (message.startsWith(prefix)) {
      return 'Using saved answer: ${_friendlyValue(message.substring(prefix.length))}';
    }
    return message;
  }

  static String _friendlyOs(String message) {
    if (message.startsWith('preparing ')) {
      return 'Preparing the OS image download and checking the local cache';
    }
    if (message.startsWith('using cached image ')) {
      return 'Using the cached OS image';
    }
    if (message.startsWith('ready at ')) {
      return 'OS image is ready';
    }
    return message;
  }

  static String _friendlyFlash(String message) {
    final write = RegExp(
      r'^writing\s+(.+)\s+->\s+(.+?)\s+\(verify=(true|false)\)$',
    ).firstMatch(message);
    if (write != null) {
      final target = _friendlyValue(write.group(2)!);
      final verify = write.group(3) == 'true';
      return verify
          ? 'Writing the OS image to $target, then verifying it'
          : 'Writing the OS image to $target';
    }
    if (message == 'done') return 'Flash complete';
    if (message.startsWith('safety warning acknowledged: ')) {
      return 'Safety warning acknowledged';
    }
    return message;
  }

  static String _friendlyRunState(String message) {
    final skip = RegExp(
      r'^skipping\s+([^;]+);\s+already completed$',
    ).firstMatch(message);
    if (skip != null) {
      return 'Already completed: ${_friendlyStepName(skip.group(1)!)}';
    }
    return message;
  }

  static String _friendlyWarning(String message) {
    final dash = message.indexOf(' - ');
    if (dash <= 0) return _friendlyError(message);
    return '${_friendlyStepName(message.substring(0, dash))}: '
        '${_friendlyError(message.substring(dash + 3))}';
  }

  static String _friendlyFailure(String message) {
    final dash = message.indexOf(' - ');
    if (dash <= 0) return _friendlyStepName(message);
    return '${_friendlyStepName(message.substring(0, dash))}: '
        '${_friendlyError(message.substring(dash + 3))}';
  }

  static String _friendlyStepAction(String stepId) {
    return switch (stepId) {
      'choose_os_image' => 'Choose the OS image',
      'choose_target_disk' => 'Check the selected disk',
      'download_os' => 'Prepare the OS image',
      'flash_disk' => 'Write the OS image',
      'flash_done_prompt' => 'Confirm the flash completed',
      'wait_for_ssh' => 'Wait for the printer to come online',
      'first_boot_setup' => 'Run first-boot setup',
      'install_firmware' => 'Install firmware',
      'install_stack' => 'Install Klipper services',
      'link_extras' => 'Install profile extras',
      'install_screen' => 'Install the screen package',
      'flash_mcus' => 'Flash printer MCUs',
      'apply_services' => 'Clean up stock services',
      'apply_files' => 'Clean up stock files',
      'snapshot_paths' => 'Back up stock files',
      'write_file' => 'Write config',
      'install_marker' => 'Mark printer as managed',
      'verify' => 'Verify install',
      'script' => 'Run setup script',
      'ssh_commands' => 'Run remote commands',
      'conditional' => 'Evaluate condition',
      _ => _titleCaseIdentifier(stepId),
    };
  }

  static String _friendlyStepName(String stepId) => _friendlyStepAction(stepId);

  static String _friendlyValue(String value) {
    final trimmed = value.trim();
    final physicalDrive = _friendlyPhysicalDrive(trimmed);
    if (physicalDrive != null) return physicalDrive;
    if (_looksLikePath(trimmed)) return trimmed;
    if (!trimmed.contains('-') && !trimmed.contains('_')) return trimmed;
    return _titleCaseIdentifier(trimmed);
  }

  static String _friendlyError(String message) {
    return userFacingDiskOperationError(message);
  }

  static String? _friendlyPhysicalDrive(String value) {
    final match = _windowsPhysicalDriveRe.firstMatch(value);
    if (match == null || match.group(0) != value) return null;
    return 'Windows disk ${match.group(1)!}';
  }

  static String _titleCaseIdentifier(String value) {
    final words = value
        .replaceAll(RegExp(r'[_-]+'), ' ')
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty);
    return words
        .map(
          (word) => word.length == 1
              ? word.toUpperCase()
              : '${word[0].toUpperCase()}${word.substring(1)}',
        )
        .join(' ');
  }

  static bool _looksLikePath(String value) =>
      value.contains(r'\') ||
      value.contains('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(value);

  static _LogKind _kindForSource(String source) {
    return switch (source) {
      'input' => _LogKind.input,
      'run-state' => _LogKind.dim,
      'flash' ||
      'os' ||
      'firmware' ||
      'stack' ||
      'ssh' ||
      'script' => _LogKind.info,
      'snapshot' ||
      'snapshot_archive' ||
      'services' ||
      'files' => _LogKind.info,
      _ => _LogKind.dim,
    };
  }

  static String _tagForSource(String source) {
    return switch (source) {
      'input' => 'INPUT',
      'run-state' => 'STATE',
      'os' => 'OS',
      'ssh' => 'SSH',
      'firmware' => 'FW',
      'snapshot_archive' => 'SNAP',
      _ => source.replaceAll('-', '_').toUpperCase(),
    };
  }
}

enum _LogKind { ok, fail, warn, exec, info, input, dim }

final RegExp _windowsPhysicalDriveRe = RegExp(
  r'(?:\\\\\.\\)?physical\s*drive\s*([0-9]+)',
  caseSensitive: false,
);

class _Parsed {
  _Parsed(this.kind, this.tag, this.msg);
  final _LogKind kind;
  final String tag;
  final String msg;
}
