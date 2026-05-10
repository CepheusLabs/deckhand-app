import 'package:flutter/material.dart';

import '../theming/deckhand_tokens.dart';
import '../utils/disk_operation_errors.dart';

/// Diff-style log view — the right pane on the install progress
/// screen. Renders raw log lines as `[time] [tag] [message]` rows,
/// color-coding the tag based on prefix conventions used by the
/// wizard controller (`[ok]`, `[fail]`, `[warn]`, `> starting …`).
///
/// The log line is the design's signature data treatment — a mono
/// gutter with a tag column that turns the screen into something
/// resembling a developer console rather than a generic install
/// progress bar.
class WizardLogView extends StatefulWidget {
  const WizardLogView({
    super.key,
    required this.lines,
    this.mode = WizardLogMode.user,
  });

  final List<String> lines;
  final WizardLogMode mode;

  @override
  State<WizardLogView> createState() => _WizardLogViewState();
}

enum WizardLogMode { user, developer }

String formatWizardLogForClipboard(List<String> lines, WizardLogMode mode) =>
    _LogLine.formatForClipboard(lines, mode);

class _WizardLogViewState extends State<WizardLogView> {
  final _verticalController = ScrollController();

  @override
  void didUpdateWidget(covariant WizardLogView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.lines.length != oldWidget.lines.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_verticalController.hasClients) return;
        _verticalController.animateTo(
          _verticalController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
        );
      });
    }
  }

  @override
  void dispose() {
    _verticalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    if (widget.lines.isEmpty) {
      return Center(
        child: Text(
          'Waiting for the first log line...',
          style: TextStyle(
            fontFamily: DeckhandTokens.fontMono,
            fontSize: DeckhandTokens.tSm,
            color: tokens.text3,
          ),
        ),
      );
    }
    return Scrollbar(
      controller: _verticalController,
      child: SelectionArea(
        child: ListView.builder(
          controller: _verticalController,
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: widget.lines.length,
          itemBuilder: (context, i) => _LogLine(
            raw: widget.lines[i],
            mode: widget.mode,
            tokens: tokens,
            // Approximate "now-ish" timestamp ordinal. The controller
            // does not emit timestamps yet, so keep a stable index-based
            // marker for visual rhythm.
            ordinal: i,
          ),
        ),
      ),
    );
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine({
    required this.raw,
    required this.mode,
    required this.tokens,
    required this.ordinal,
  });
  final String raw;
  final WizardLogMode mode;
  final DeckhandTokens tokens;
  final int ordinal;

  @override
  Widget build(BuildContext context) {
    final parsed = _parse(raw, mode);
    final tagColor = switch (parsed.kind) {
      _LogKind.ok => tokens.ok,
      _LogKind.fail => tokens.bad,
      _LogKind.warn => tokens.warn,
      _LogKind.exec => tokens.accent,
      _LogKind.info => tokens.info,
      _LogKind.input => tokens.text3,
      _LogKind.dim => tokens.text4,
    };
    final rowBg = switch (parsed.kind) {
      _LogKind.fail => tokens.bad.withValues(alpha: 0.06),
      _LogKind.warn => tokens.warn.withValues(alpha: 0.06),
      _ => Colors.transparent,
    };
    final rowBorder = switch (parsed.kind) {
      _LogKind.fail => tokens.bad,
      _LogKind.warn => tokens.warn,
      _ => Colors.transparent,
    };
    return Container(
      decoration: BoxDecoration(
        color: rowBg,
        border: Border(left: BorderSide(color: rowBorder, width: 2)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              _ordinalLabel(ordinal),
              style: TextStyle(
                fontFamily: DeckhandTokens.fontMono,
                fontSize: DeckhandTokens.tXs,
                color: tokens.text4,
                height: 1.6,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 64,
            child: Text(
              parsed.tag,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontMono,
                fontSize: DeckhandTokens.tXs,
                color: tagColor,
                height: 1.6,
                letterSpacing: 0,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              parsed.msg,
              softWrap: true,
              overflow: TextOverflow.visible,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontMono,
                fontSize: DeckhandTokens.tXs,
                color: tokens.text2,
                height: 1.6,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String formatForClipboard(List<String> lines, WizardLogMode mode) {
    return [
      'Deckhand session log (${mode == WizardLogMode.developer ? 'developer' : 'standard'})',
      'TIME       TAG     MESSAGE',
      '---------  ------  ----------------------------------------',
      for (var i = 0; i < lines.length; i++)
        _formatClipboardLine(i, _parse(lines[i], mode)),
    ].join('\n');
  }

  static String _formatClipboardLine(int ordinal, _Parsed parsed) =>
      '${_ordinalLabel(ordinal).padRight(9)}  '
      '${parsed.tag.padRight(6)}  '
      '${parsed.msg}';

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
      'flash_mcus' => 'Reject unsupported MCU flash step',
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
