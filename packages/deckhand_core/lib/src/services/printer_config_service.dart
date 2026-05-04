import 'ssh_service.dart';

/// Safe editing primitives for Klipper `printer.cfg`.
///
/// Deckhand edits specific keys inside known Klipper sections instead
/// of appending duplicate sections. That keeps tuning changes scoped
/// without trying to own or rewrite the user's full config file.
abstract class PrinterConfigService {
  Future<PrinterConfigDocument> read(
    SshSession session, {
    required String path,
  });

  PrinterConfigPreview previewSectionSettings({
    required String original,
    required String section,
    required Map<String, String> values,
  });

  Future<PrinterConfigApplyResult> applySectionSettings(
    SshSession session, {
    required String path,
    required String section,
    required Map<String, String> values,
  });
}

class PrinterConfigDocument {
  const PrinterConfigDocument({required this.path, required this.content});

  final String path;
  final String content;
}

class PrinterConfigPreview {
  const PrinterConfigPreview({
    required this.original,
    required this.updated,
    required this.changed,
  });

  final String original;
  final String updated;
  final bool changed;
}

class PrinterConfigApplyResult {
  const PrinterConfigApplyResult({
    required this.path,
    required this.backupPath,
    required this.changed,
  });

  final String path;
  final String? backupPath;
  final bool changed;
}

String defaultPrinterConfigPath(SshSession session) {
  return '~/printer_data/config/printer.cfg';
}

PrinterConfigPreview previewKlipperSectionSettings({
  required String original,
  required String section,
  required Map<String, String> values,
}) {
  _validateSectionPatch(section: section, values: values);
  final lines = _splitLines(original);
  final range = _findSection(lines, section);
  final updatedLines = List<String>.of(lines);

  if (range == null) {
    _appendSection(updatedLines, section: section, values: values);
  } else {
    _patchExistingSection(updatedLines, range: range, values: values);
  }

  final updated = '${updatedLines.join('\n')}\n';
  return PrinterConfigPreview(
    original: original,
    updated: updated,
    changed: updated != original,
  );
}

void _validateSectionPatch({
  required String section,
  required Map<String, String> values,
}) {
  if (!RegExp(r'^[A-Za-z0-9_ -]+$').hasMatch(section.trim())) {
    throw FormatException('invalid Klipper section: $section');
  }
  if (values.isEmpty) {
    throw const FormatException(
      'section patch must contain at least one value',
    );
  }
  for (final entry in values.entries) {
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(entry.key)) {
      throw FormatException('invalid Klipper option: ${entry.key}');
    }
    if (entry.value.trim() != entry.value ||
        entry.value.isEmpty ||
        entry.value.contains('\n') ||
        entry.value.contains('\r')) {
      throw FormatException('invalid value for ${entry.key}');
    }
  }
}

List<String> _splitLines(String original) {
  final normalized = original.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lines = normalized.split('\n');
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines;
}

_SectionRange? _findSection(List<String> lines, String section) {
  final normalized = section.trim();
  final matches = <int>[];
  for (var i = 0; i < lines.length; i++) {
    final parsed = _parseSectionHeader(lines[i]);
    if (parsed == normalized) matches.add(i);
  }
  if (matches.length > 1) {
    throw FormatException('duplicate Klipper section: $section');
  }
  if (matches.isEmpty) return null;
  final start = matches.single;
  var end = lines.length;
  for (var i = start + 1; i < lines.length; i++) {
    if (_parseSectionHeader(lines[i]) != null) {
      end = i;
      break;
    }
  }
  return _SectionRange(start: start, end: end);
}

String? _parseSectionHeader(String line) {
  final match = RegExp(r'^\s*\[([^\]]+)\]\s*(?:[#;].*)?$').firstMatch(line);
  return match?.group(1)?.trim();
}

void _patchExistingSection(
  List<String> lines, {
  required _SectionRange range,
  required Map<String, String> values,
}) {
  var insertionIndex = range.end;
  for (final entry in values.entries) {
    final existing = _findOption(lines, range: range, key: entry.key);
    final rendered = '${existing?.indent ?? ''}${entry.key}: ${entry.value}';
    if (existing == null) {
      lines.insert(insertionIndex, rendered);
      insertionIndex++;
    } else {
      lines[existing.index] = rendered;
    }
  }
}

_OptionLine? _findOption(
  List<String> lines, {
  required _SectionRange range,
  required String key,
}) {
  final keyPattern = RegExp.escape(key);
  final optionPattern = RegExp('^(\\s*)$keyPattern\\s*[:=].*\$');
  final matches = <_OptionLine>[];
  for (var i = range.start + 1; i < range.end; i++) {
    final match = optionPattern.firstMatch(lines[i]);
    if (match != null) {
      matches.add(_OptionLine(index: i, indent: match.group(1) ?? ''));
    }
  }
  if (matches.length > 1) {
    throw FormatException('duplicate Klipper option $key in section');
  }
  return matches.isEmpty ? null : matches.single;
}

void _appendSection(
  List<String> lines, {
  required String section,
  required Map<String, String> values,
}) {
  if (lines.isNotEmpty && lines.last.trim().isNotEmpty) {
    lines.add('');
  }
  lines.add('[${section.trim()}]');
  for (final entry in values.entries) {
    lines.add('${entry.key}: ${entry.value}');
  }
}

class _SectionRange {
  const _SectionRange({required this.start, required this.end});

  final int start;
  final int end;
}

class _OptionLine {
  const _OptionLine({required this.index, required this.indent});

  final int index;
  final String indent;
}
