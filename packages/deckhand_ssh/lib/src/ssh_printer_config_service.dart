import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';

class SshPrinterConfigService implements PrinterConfigService {
  SshPrinterConfigService({required SshService ssh, DateTime Function()? clock})
    : _ssh = ssh,
      _clock = clock ?? DateTime.now;

  final SshService _ssh;
  final DateTime Function() _clock;

  @override
  Future<PrinterConfigDocument> read(
    SshSession session, {
    required String path,
  }) async {
    SshCommandResult? lastResult;
    for (final candidate in _candidatePaths(path, session)) {
      final result = await _ssh.run(
        session,
        'cat -- ${shellPathEscape(candidate)}',
        timeout: const Duration(seconds: 15),
      );
      if (result.success) {
        return PrinterConfigDocument(path: candidate, content: result.stdout);
      }
      lastResult = result;
    }
    final detail = lastResult == null
        ? 'no candidate paths'
        : lastResult.stderr.trim().isEmpty
        ? lastResult.exitCode.toString()
        : lastResult.stderr.trim();
    throw StateError('could not read $path: $detail');
  }

  @override
  PrinterConfigPreview previewSectionSettings({
    required String original,
    required String section,
    required Map<String, String> values,
  }) {
    return previewKlipperSectionSettings(
      original: original,
      section: section,
      values: values,
    );
  }

  @override
  Future<PrinterConfigApplyResult> applySectionSettings(
    SshSession session, {
    required String path,
    required String section,
    required Map<String, String> values,
  }) async {
    final document = await read(session, path: path);
    final preview = previewSectionSettings(
      original: document.content,
      section: section,
      values: values,
    );
    if (!preview.changed) {
      return PrinterConfigApplyResult(
        path: document.path,
        backupPath: null,
        changed: false,
      );
    }

    final stamp = _timestamp(_clock().toUtc());
    final backupPath = '${document.path}.deckhand-pre-$stamp';
    final remoteUpload = '/tmp/deckhand-printer-cfg-$stamp.cfg';
    final remoteTmp = '${document.path}.deckhand-tmp-$stamp';
    final localDir = await Directory.systemTemp.createTemp(
      'deckhand-printer-cfg-',
    );
    try {
      final localFile = File('${localDir.path}/printer.cfg');
      await localFile.writeAsString(preview.updated, flush: true);
      await _ssh.upload(session, localFile.path, remoteUpload, mode: 384);

      final command = [
        'set -eu',
        'cp -- ${shellPathEscape(document.path)} ${shellPathEscape(backupPath)}',
        'cat -- ${shellSingleQuote(remoteUpload)} > ${shellPathEscape(remoteTmp)}',
        'chmod 0644 -- ${shellPathEscape(remoteTmp)}',
        'mv -- ${shellPathEscape(remoteTmp)} ${shellPathEscape(document.path)}',
        'rm -f -- ${shellSingleQuote(remoteUpload)}',
      ].join('\n');
      final result = await _ssh.run(
        session,
        command,
        timeout: const Duration(seconds: 30),
      );
      if (!result.success) {
        throw StateError(
          'could not apply $path: ${result.stderr.trim().isEmpty ? result.exitCode : result.stderr.trim()}',
        );
      }
      return PrinterConfigApplyResult(
        path: document.path,
        backupPath: backupPath,
        changed: true,
      );
    } finally {
      try {
        if (await localDir.exists()) await localDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  String _timestamp(DateTime t) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  List<String> _candidatePaths(String path, SshSession session) {
    if (path != defaultPrinterConfigPath(session)) return [path];
    final candidates = <String>[
      path,
      if (session.user != 'root')
        '/home/${session.user}/printer_data/config/printer.cfg',
      '/home/mks/printer_data/config/printer.cfg',
      '/home/pi/printer_data/config/printer.cfg',
      '/root/printer_data/config/printer.cfg',
    ];
    return candidates.toSet().toList(growable: false);
  }
}
