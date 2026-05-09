import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for [PrinterStateProbe] script-building + report-parsing.
/// We don't stand up a real SSH session here; we just synthesise the
/// stdout the probe shell script emits and verify the parser produces
/// the right PrinterState. Ensures the probe's wire protocol doesn't
/// drift between the script and the parser.
void main() {
  group('PrinterStateProbe report parsing', () {
    late PrinterStateProbe probe;
    late _StubSsh ssh;

    setUp(() {
      ssh = _StubSsh();
      probe = PrinterStateProbe(ssh: ssh);
    });

    test('parses os identity + python version from /etc/os-release', () async {
      ssh.nextStdout = [
        'os:id\t"debian"',
        'os:codename\t"trixie"',
        'os:version_id\t"13"',
        'kernel\t6.10.0-arm64',
        'python:default\t3.13.0',
        'python311\tabsent',
      ].join('\n');

      final state = await probe.probe(
        session: _fakeSession,
        profile: _minimalProfile,
      );

      expect(state.osId, 'debian');
      expect(state.osCodename, 'trixie');
      expect(state.osVersionId, '13');
      expect(state.kernelRelease, '6.10.0-arm64');
      expect(state.pythonDefaultVersion, '3.13.0');
      expect(state.python311Installed, isFalse);
      expect(state.probedAt, isNotNull);
    });

    test('parses service facets into a combined ServiceRuntimeState', () async {
      ssh.nextStdout = [
        'svc:frpc:unit_exists\t1',
        'svc:frpc:unit_active\t1',
        'svc:frpc:proc_running\t1',
        'svc:frpc:launcher_exists\t1',
        'svc:mksclient:unit_exists\t0',
        'svc:mksclient:unit_active\t0',
        'svc:mksclient:proc_running\t0',
        'svc:mksclient:launcher_exists\t0',
      ].join('\n');

      final state = await probe.probe(
        session: _fakeSession,
        profile: _minimalProfile,
      );

      final frpc = state.services['frpc']!;
      expect(frpc.unitExists, isTrue);
      expect(frpc.unitActive, isTrue);
      expect(frpc.processRunning, isTrue);
      expect(frpc.launcherScriptExists, isTrue);
      expect(frpc.present, isTrue);

      final mks = state.services['mksclient']!;
      expect(mks.present, isFalse);
    });

    test('parses stack install states + paths', () async {
      ssh.nextStdout = [
        'stack:moonraker:installed\t1',
        'stack:moonraker:path\t/home/mks/moonraker',
        'stack:moonraker:active\t1',
        'stack:kiauh:installed\t0',
        'stack:kiauh:path\t/home/mks/kiauh',
      ].join('\n');

      final state = await probe.probe(
        session: _fakeSession,
        profile: _minimalProfile,
      );

      final mr = state.stackInstalls['moonraker']!;
      expect(mr.installed, isTrue);
      expect(mr.active, isTrue);
      expect(mr.path, '/home/mks/moonraker');

      final kiauh = state.stackInstalls['kiauh']!;
      expect(kiauh.installed, isFalse);
      expect(kiauh.active, isFalse);
    });

    test('parses screen install states', () async {
      ssh.nextStdout = [
        'screen:voronFDM:installed\t1',
        'screen:voronFDM:active\t0',
        'screen:voronFDM:path\t/home/mks/voronFDM',
      ].join('\n');

      final state = await probe.probe(
        session: _fakeSession,
        profile: _minimalProfile,
      );

      final s = state.screenInstalls['voronFDM']!;
      expect(s.installed, isTrue);
      expect(s.active, isFalse);
      expect(s.path, '/home/mks/voronFDM');
    });

    test('parses file + path existence flags', () async {
      ssh.nextStdout = [
        'file:frpc_bin\t1',
        'file:stock_notes\t0',
        'path:klipper_install\t1',
      ].join('\n');

      final state = await probe.probe(
        session: _fakeSession,
        profile: _minimalProfile,
      );

      expect(state.files['frpc_bin'], isTrue);
      expect(state.files['stock_notes'], isFalse);
      expect(state.paths['klipper_install'], isTrue);
    });

    test('empty stdout gives empty state but populated probedAt', () async {
      ssh.nextStdout = '';
      final state = await probe.probe(
        session: _fakeSession,
        profile: _minimalProfile,
      );
      expect(state.services, isEmpty);
      expect(state.files, isEmpty);
      expect(state.python311Installed, isFalse);
      expect(state.probedAt, isNotNull);
    });

    test('parses .deckhand-pre-* backup entries sorted newest-first', () async {
      ssh.nextStdout = [
        // Older
        'backup\t/etc/apt/sources.list:::/etc/apt/sources.list.deckhand-pre-1776910000000:::',
        // Newer
        'backup\t/home/mks/printer.cfg:::/home/mks/printer.cfg.deckhand-pre-1776910500000:::',
      ].join('\n');
      final state = await probe.probe(
        session: _fakeSession,
        profile: _minimalProfile,
      );
      expect(state.deckhandBackups, hasLength(2));
      // Newest-first: /home/mks/printer.cfg comes before /etc/apt.
      expect(state.deckhandBackups.first.originalPath, '/home/mks/printer.cfg');
      expect(state.deckhandBackups.last.originalPath, '/etc/apt/sources.list');
    });

    test(
      'parses new profile-tagged .deckhand-pre-<profile>-<ts> naming',
      () async {
        ssh.nextStdout = [
          'backup\t/etc/apt/sources.list:::/etc/apt/sources.list.deckhand-pre-phrozen-arco-1776910000000:::',
        ].join('\n');
        final state = await probe.probe(
          session: _fakeSession,
          profile: _minimalProfile,
        );
        expect(state.deckhandBackups, hasLength(1));
        expect(state.deckhandBackups.single.createdAt, isNotNull);
      },
    );

    test('parses backup metadata sidecar when present', () async {
      final meta =
          '{"profile_id":"phrozen-arco","profile_version":"1.0.0",'
          '"step_id":"fix_apt_sources","created_at_ms":1776910000000,'
          '"created_at_iso":"2026-04-22T00:00:00.000Z"}';
      ssh.nextStdout = [
        'backup\t/etc/apt/sources.list:::'
            '/etc/apt/sources.list.deckhand-pre-phrozen-arco-1776910000000:::'
            '$meta',
      ].join('\n');
      final state = await probe.probe(
        session: _fakeSession,
        profile: _minimalProfile,
      );
      final b = state.deckhandBackups.single;
      expect(b.profileId, 'phrozen-arco');
      expect(b.profileVersion, '1.0.0');
      expect(b.stepId, 'fix_apt_sources');
      expect(b.createdAt, isNotNull);
    });

    test(
      'malformed meta sidecar JSON is tolerated, backup still usable',
      () async {
        ssh.nextStdout = [
          'backup\t/etc/apt/sources.list:::'
              '/etc/apt/sources.list.deckhand-pre-1776910000000:::'
              '{not valid json',
        ].join('\n');
        final state = await probe.probe(
          session: _fakeSession,
          profile: _minimalProfile,
        );
        expect(state.deckhandBackups, hasLength(1));
        expect(state.deckhandBackups.single.profileId, isNull);
      },
    );

    test('skips backup rows with blank paths', () async {
      ssh.nextStdout = [
        'backup\t:::/tmp/blank-original.deckhand-pre-1776910000000:::',
        'backup\t/etc/apt/sources.list::::::',
        'backup\t/etc/apt/sources.list:::/etc/apt/sources.list.deckhand-pre-1776910000000:::',
      ].join('\n');
      final state = await probe.probe(
        session: _fakeSession,
        profile: _minimalProfile,
      );

      expect(state.deckhandBackups, hasLength(1));
      expect(
        state.deckhandBackups.single.originalPath,
        '/etc/apt/sources.list',
      );
    });

    test('malformed lines are silently skipped', () async {
      ssh.nextStdout = [
        'garbage-line-no-tab',
        'os:codename\t"trixie"',
        'only-one-column',
        '', // blank
      ].join('\n');
      final state = await probe.probe(
        session: _fakeSession,
        profile: _minimalProfile,
      );
      expect(state.osCodename, 'trixie');
    });
  });

  group('PrinterStateProbe script generation', () {
    test(
      'includes probes for every service, file, path declared in profile',
      () async {
        final ssh = _StubSsh();
        final probe = PrinterStateProbe(ssh: ssh);

        final profile = PrinterProfile.fromJson({
          'profile_id': 'p',
          'stock_os': {
            'services': [
              {
                'id': 'frpc',
                'systemd_unit': 'frpc.service',
                'process_pattern': 'frpc',
                'launched_by': {
                  'kind': 'script',
                  'path': '/home/mks/klipper/extras/frp/frpc_script',
                },
              },
            ],
            'files': [
              {
                'id': 'notes',
                'paths': ['/home/mks/notes.txt'],
              },
            ],
            'paths': [
              {
                'id': 'klipper',
                'path': '/home/mks/klipper',
                'action': 'snapshot',
              },
            ],
          },
        });
        await probe.probe(session: _fakeSession, profile: profile);

        final script = ssh.lastCommand!;
        expect(script, contains('systemctl is-active'));
        expect(script, contains('pgrep -f'));
        expect(script, contains('say svc:frpc:unit_exists'));
        expect(script, contains('say file:notes'));
        expect(script, contains('say path:klipper'));
        expect(script, contains('/etc/os-release'));
      },
    );

    test(
      'tilde-prefixed install paths become "\$HOME/..." not quoted "~"',
      () async {
        final ssh = _StubSsh();
        final probe = PrinterStateProbe(ssh: ssh);
        final profile = PrinterProfile.fromJson({
          'profile_id': 'p',
          'stack': {
            'moonraker': {
              'repo': 'x',
              'ref': 'y',
              'install_path': '~/moonraker',
            },
            'kiauh': {'repo': 'x', 'ref': 'y', 'install_path': '~/kiauh'},
          },
        });
        await probe.probe(session: _fakeSession, profile: profile);

        final script = ssh.lastCommand!;
        // $HOME must expand (double-quoted or unquoted context) AND the
        // path suffix must be single-quoted so shell metacharacters in
        // it cannot be interpreted. Plain `'~/...'` would be a bug
        // because single-quoting stops tilde expansion.
        expect(
          script,
          contains(
            r'"$HOME"/'
            "'moonraker'",
          ),
        );
        expect(
          script,
          contains(
            r'"$HOME"/'
            "'kiauh'",
          ),
        );
        expect(script, isNot(contains("'~/moonraker'")));
      },
    );

    test('tilde-prefixed paths with shell metachars stay inert', () async {
      final ssh = _StubSsh();
      final probe = PrinterStateProbe(ssh: ssh);
      final profile = PrinterProfile.fromJson({
        'profile_id': 'p',
        'stack': {
          'moonraker': {
            // A malicious profile stuffs $(reboot) into the path.
            'repo': 'x', 'ref': 'y', 'install_path': r'~/$(reboot)',
          },
        },
      });
      await probe.probe(session: _fakeSession, profile: profile);
      final script = ssh.lastCommand!;
      // The $(reboot) must live inside single quotes so the remote
      // shell treats it as a literal filename, not a subshell command.
      expect(script, contains(r"'$(reboot)'"));
      expect(script, isNot(contains(r'"$HOME/$(reboot)"')));
    });
  });
}

// -----------------------------------------------------------------

const _fakeSession = SshSession(
  id: 'test',
  host: '127.0.0.1',
  port: 22,
  user: 'mks',
);

final _minimalProfile = PrinterProfile.fromJson({
  'profile_id': 'p',
  'profile_version': '0.1.0',
});

class _StubSsh implements SshService {
  String nextStdout = '';
  String? lastCommand;

  @override
  Future<SshSession> connect({
    required String host,
    int port = 22,
    required SshCredential credential,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
  }) async => SshSession(id: 's', host: host, port: port, user: 'mks');
  @override
  Future<SshSession> tryDefaults({
    required String host,
    int port = 22,
    required List<SshCredential> credentials,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
  }) async => SshSession(id: 's', host: host, port: port, user: 'mks');
  @override
  Future<SshCommandResult> run(
    SshSession session,
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? sudoPassword,
  }) async {
    lastCommand = command;
    return SshCommandResult(stdout: nextStdout, stderr: '', exitCode: 0);
  }

  @override
  Stream<String> runStream(SshSession session, String command) =>
      const Stream.empty();
  @override
  Stream<String> runStreamMerged(SshSession session, String command) =>
      const Stream.empty();
  @override
  Future<int> upload(
    SshSession session,
    String localPath,
    String remotePath, {
    int? mode,
  }) async => 0;
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
  ) async => {for (final p in paths) p: 0};
  @override
  Future<void> disconnect(SshSession session) async {}
}
