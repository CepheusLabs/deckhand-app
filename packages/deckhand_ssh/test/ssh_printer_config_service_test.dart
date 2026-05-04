import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ssh/src/ssh_printer_config_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _session = SshSession(
  id: 's1',
  host: '192.168.1.50',
  port: 22,
  user: 'mks',
);

void main() {
  test(
    'applySectionSettings uploads a preview and backs up printer.cfg',
    () async {
      final ssh = _FakeSshService({
        '~/printer_data/config/printer.cfg': '[extruder]\nstep_pin: PB3\n',
      });
      final service = SshPrinterConfigService(
        ssh: ssh,
        clock: () => DateTime.utc(2026, 5, 4, 12, 30, 45),
      );

      final result = await service.applySectionSettings(
        _session,
        path: defaultPrinterConfigPath(_session),
        section: 'extruder',
        values: const {'pressure_advance': '0.040'},
      );

      expect(result.changed, isTrue);
      expect(
        result.backupPath,
        '~/printer_data/config/printer.cfg.deckhand-pre-20260504-123045',
      );
      expect(ssh.uploadedContent, contains('[extruder]\nstep_pin: PB3'));
      expect(ssh.uploadedContent, contains('pressure_advance: 0.040'));
      expect(ssh.commands.last, contains('cp --'));
      expect(ssh.commands.last, contains('.deckhand-pre-20260504-123045'));
      expect(ssh.commands.last, contains('mv --'));
    },
  );

  test('applySectionSettings skips remote writes when unchanged', () async {
    final ssh = _FakeSshService({
      '~/printer_data/config/printer.cfg':
          '[extruder]\npressure_advance: 0.040\n',
    });
    final service = SshPrinterConfigService(
      ssh: ssh,
      clock: () => DateTime.utc(2026, 5, 4, 12, 30, 45),
    );

    final result = await service.applySectionSettings(
      _session,
      path: defaultPrinterConfigPath(_session),
      section: 'extruder',
      values: const {'pressure_advance': '0.040'},
    );

    expect(result.changed, isFalse);
    expect(result.backupPath, isNull);
    expect(ssh.uploadedContent, isNull);
    expect(ssh.commands, hasLength(1));
  });

  test('read falls back to common printer users for default path', () async {
    final rootSession = SshSession(
      id: 's2',
      host: _session.host,
      port: _session.port,
      user: 'root',
    );
    final ssh = _FakeSshService({
      '/home/mks/printer_data/config/printer.cfg': '[extruder]\n',
    });
    final service = SshPrinterConfigService(ssh: ssh);

    final document = await service.read(
      rootSession,
      path: defaultPrinterConfigPath(rootSession),
    );

    expect(document.path, '/home/mks/printer_data/config/printer.cfg');
    expect(ssh.commands, hasLength(2));
    expect(ssh.commands.first, contains(r'"$HOME"/'));
    expect(ssh.commands.last, contains('/home/mks/printer_data/config'));
  });
}

class _FakeSshService implements SshService {
  _FakeSshService(this.files);

  final Map<String, String> files;
  final commands = <String>[];
  String? uploadedContent;

  @override
  Future<SshCommandResult> run(
    SshSession session,
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? sudoPassword,
  }) async {
    commands.add(command);
    if (command.startsWith('cat -- ')) {
      for (final entry in files.entries) {
        if (command.contains(shellPathEscape(entry.key))) {
          return SshCommandResult(stdout: entry.value, stderr: '', exitCode: 0);
        }
      }
      return const SshCommandResult(
        stdout: '',
        stderr: 'No such file',
        exitCode: 1,
      );
    }
    return const SshCommandResult(stdout: '', stderr: '', exitCode: 0);
  }

  @override
  Future<int> upload(
    SshSession session,
    String localPath,
    String remotePath, {
    int? mode,
  }) async {
    uploadedContent = await File(localPath).readAsString();
    return uploadedContent!.length;
  }

  @override
  Future<SshSession> connect({
    required String host,
    int port = 22,
    required SshCredential credential,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
  }) async => _session;

  @override
  Future<void> disconnect(SshSession session) async {}

  @override
  Future<int> download(
    SshSession session,
    String remotePath,
    String localPath,
  ) async => 0;

  @override
  Future<Map<String, int>> duPaths(
    SshSession session,
    List<String> paths,
  ) async => const {};

  @override
  Future<SshSession> tryDefaults({
    required String host,
    int port = 22,
    required List<SshCredential> credentials,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
  }) async => _session;

  @override
  Stream<String> runStream(SshSession session, String command) =>
      const Stream.empty();

  @override
  Stream<String> runStreamMerged(SshSession session, String command) =>
      const Stream.empty();
}
