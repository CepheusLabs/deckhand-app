import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_flash/src/process_elevated_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('readImage', () {
    test('passes the configured output root to the helper', () async {
      final svc = _CapturingElevatedHelper(
        readOutputRoot: '/deckhand/state/emmc-backups',
      );

      final events = await svc
          .readImage(
            diskId: 'PhysicalDrive3',
            outputPath: '/deckhand/state/emmc-backups/backup.img',
            confirmationToken: 'token-0123456789abcdef',
            totalBytes: 4096,
          )
          .toList();

      expect(events.single.phase, FlashPhase.done);
      expect(
        svc.capturedArgs,
        containsAllInOrder([
          'read-image',
          '--target',
          'PhysicalDrive3',
          '--output',
          '/deckhand/state/emmc-backups/backup.img',
          '--output-root',
          '/deckhand/state/emmc-backups',
        ]),
      );
      expect(svc.capturedArgs, contains('--cancel-file'));
    });

    test('refuses to launch without an output root', () async {
      final svc = _CapturingElevatedHelper();

      await expectLater(
        svc
            .readImage(
              diskId: 'PhysicalDrive3',
              outputPath: '/tmp/backup.img',
              confirmationToken: 'token-0123456789abcdef',
            )
            .toList(),
        throwsA(isA<StateError>()),
      );
      expect(svc.capturedArgs, isNull);
    });

    test('allows a call-scoped output root', () async {
      final svc = _CapturingElevatedHelper(
        readOutputRoot: '/deckhand/state/emmc-backups',
      );

      await svc
          .readImage(
            diskId: 'PhysicalDrive3',
            outputPath: '/external/emmc-backups/backup.img',
            outputRoot: '/external/emmc-backups',
            confirmationToken: 'token-0123456789abcdef',
          )
          .toList();

      expect(
        svc.capturedArgs,
        containsAllInOrder(['--output-root', '/external/emmc-backups']),
      );
    });

    test(
      'stream cancellation removes the helper cancel file promptly',
      () async {
        final svc = _BlockingElevatedHelper(
          readOutputRoot: '/deckhand/state/emmc-backups',
        );
        final sub = svc
            .readImage(
              diskId: 'PhysicalDrive3',
              outputPath: '/deckhand/state/emmc-backups/backup.img',
              confirmationToken: 'token-0123456789abcdef',
            )
            .listen((_) {});

        await svc.started.future.timeout(const Duration(seconds: 1));
        final cancelPath = svc.cancelFilePath;
        expect(cancelPath, isNotNull);
        expect(await svc.cancelFileExists(), isTrue);

        try {
          await sub.cancel().timeout(const Duration(milliseconds: 200));
          expect(await svc.cancelFileExists(), isFalse);
        } finally {
          svc.release();
        }
      },
    );
  });

  group('hashDevice', () {
    test('launches the helper with cancel and size hint', () async {
      final svc = _CapturingElevatedHelper();

      final events = await svc
          .hashDevice(
            diskId: 'PhysicalDrive3',
            confirmationToken: 'token-0123456789abcdef',
            totalBytes: 4096,
          )
          .toList();

      expect(events.single.phase, FlashPhase.done);
      expect(
        svc.capturedArgs,
        containsAllInOrder([
          'hash-device',
          '--target',
          'PhysicalDrive3',
          '--token-file',
        ]),
      );
      expect(svc.capturedArgs, contains('--cancel-file'));
      expect(svc.capturedArgs, containsAllInOrder(['--total-bytes', '4096']));
    });
  });

  group('writeImage', () {
    const sha =
        '0123456789abcdef0123456789abcdef'
        '0123456789abcdef0123456789abcdef';

    test(
      'passes a manifest that binds token, image, target, and sha',
      () async {
        final svc = _CapturingElevatedHelper();
        const token = 'token-0123456789abcdef';

        final events = await svc
            .writeImage(
              imagePath: r'C:\Deckhand\images\image.img',
              diskId: 'PhysicalDrive3',
              confirmationToken: token,
              expectedSha256: sha.toUpperCase(),
            )
            .toList();

        expect(events.single.phase, FlashPhase.done);
        expect(
          svc.capturedArgs,
          containsAllInOrder([
            'write-image',
            '--image',
            r'C:\Deckhand\images\image.img',
            '--target',
            'PhysicalDrive3',
            '--token-file',
          ]),
        );
        expect(svc.capturedArgs, contains('--cancel-file'));
        expect(svc.capturedArgs, contains('--manifest'));
        expect(svc.capturedArgs, contains('--verify=true'));
        expect(
          svc.capturedArgs,
          isNot(containsAllInOrder(['--verify', 'true'])),
        );
        expect(svc.capturedArgs, containsAllInOrder(['--sha256', sha]));

        final manifest = svc.capturedManifest;
        expect(manifest, isNotNull);
        expect(manifest!['version'], 1);
        expect(manifest['op'], 'write-image');
        expect(manifest['image_path'], r'C:\Deckhand\images\image.img');
        expect(manifest['image_sha256'], sha);
        expect(manifest['target'], 'PhysicalDrive3');
        expect(
          manifest['token_sha256'],
          sha256.convert(utf8.encode(token)).toString(),
        );
        expect(
          DateTime.parse(
            manifest['expires_at'] as String,
          ).isAfter(DateTime.now().toUtc()),
          isTrue,
        );
      },
    );

    test('refuses to launch without an expected sha256', () async {
      final svc = _CapturingElevatedHelper();

      await expectLater(
        svc
            .writeImage(
              imagePath: '/tmp/image.img',
              diskId: 'PhysicalDrive3',
              confirmationToken: 'token-0123456789abcdef',
            )
            .toList(),
        throwsA(isA<StateError>()),
      );
      expect(svc.capturedArgs, isNull);
    });
  });

  group('DryRunElevatedHelperService', () {
    test(
      'writeImage emits synthetic progress without launching a helper',
      () async {
        const svc = DryRunElevatedHelperService();

        final events = await svc
            .writeImage(
              imagePath: '/tmp/image.img',
              diskId: 'PhysicalDrive3',
              confirmationToken: 'token-0123456789abcdef',
            )
            .toList();

        expect(events.first.phase, FlashPhase.preparing);
        expect(events.last.phase, FlashPhase.done);
        expect(events.last.message, contains('DRY-RUN elevated write'));
      },
    );

    test('readImage uses the provided size hint', () async {
      const svc = DryRunElevatedHelperService();

      final events = await svc
          .readImage(
            diskId: 'PhysicalDrive3',
            outputPath: '/tmp/backup.img',
            confirmationToken: 'token-0123456789abcdef',
            totalBytes: 4096,
          )
          .toList();

      expect(events.first.bytesTotal, 4096);
      expect(events.last.bytesDone, 4096);
      expect(events.last.message, contains('DRY-RUN elevated read'));
    });

    test('hashDevice uses the provided size hint', () async {
      const svc = DryRunElevatedHelperService();

      final events = await svc
          .hashDevice(
            diskId: 'PhysicalDrive3',
            confirmationToken: 'token-0123456789abcdef',
            totalBytes: 4096,
          )
          .toList();

      expect(events.first.bytesTotal, 4096);
      expect(events.last.bytesDone, 4096);
      expect(events.last.message, contains('DRY-RUN elevated hash'));
    });
  });

  group('powerShellQuoteArg', () {
    test('events-file is injected immediately after the operation', () {
      final args = injectHelperEventsFileForTesting([
        'read-image',
        '--target',
        'PhysicalDrive3',
        '--output',
        r'C:\tmp\backup.img',
      ], r'C:\tmp\events.log');

      expect(args.take(3), [
        'read-image',
        '--events-file',
        r'C:\tmp\events.log',
      ]);
      expect(args, containsAllInOrder(['--target', 'PhysicalDrive3']));
      expect(args, containsAllInOrder(['--output', r'C:\tmp\backup.img']));
    });

    test('plain token is wrapped in double quotes', () {
      expect(powerShellQuoteArg('write-image'), '"write-image"');
      expect(powerShellQuoteArg('PhysicalDrive3'), '"PhysicalDrive3"');
    });

    test('path with spaces survives intact', () {
      expect(
        powerShellQuoteArg(r'C:\Users\someone\Image File.img'),
        r'"C:\Users\someone\Image File.img"',
      );
    });

    test('embedded double-quote is doubled per PowerShell rules', () {
      expect(powerShellQuoteArg(r'a"b'), '"a""b"');
      expect(powerShellQuoteArg(r'weird"disk"name'), '"weird""disk""name"');
    });

    test('empty arg becomes ""', () {
      expect(powerShellQuoteArg(''), '""');
    });

    test('arg with only quotes', () {
      expect(powerShellQuoteArg(r'"'), '""""');
      expect(powerShellQuoteArg(r'""'), '""""""');
    });

    test('realistic helper invocation round-trips', () {
      final args = [
        'write-image',
        '--image',
        r'C:\Users\eknof\AppData\Local\Temp\img.iso',
        '--target',
        'PhysicalDrive3',
        '--token-file',
        r'C:\Users\eknof\AppData\Local\Temp\deckhand-elevated-helper\token',
        '--manifest',
        r'C:\Users\eknof\AppData\Local\Temp\deckhand-elevated-helper\manifest',
        '--verify=true',
        '--sha256',
        '0123456789abcdef0123456789abcdef'
            '0123456789abcdef0123456789abcdef',
      ];
      final argList = args.map(powerShellQuoteArg).join(',');
      // Every arg appears verbatim between double quotes, separated
      // by a single comma (no whitespace).
      expect(argList, contains('"write-image"'));
      expect(argList, contains('"--image"'));
      expect(argList, contains(r'"C:\Users\eknof\AppData\Local\Temp\img.iso"'));
      expect(argList.split(',').length, args.length);
    });
  });

  group('windowsCommandLineQuoteArg', () {
    test('leaves simple arguments unquoted', () {
      expect(windowsCommandLineQuoteArg('write-image'), 'write-image');
      expect(windowsCommandLineQuoteArg('PhysicalDrive3'), 'PhysicalDrive3');
    });

    test('quotes paths with spaces', () {
      expect(
        windowsCommandLineQuoteArg(r'C:\Deckhand Builds\image.img'),
        r'"C:\Deckhand Builds\image.img"',
      );
    });

    test('escapes embedded quotes and trailing backslashes', () {
      expect(windowsCommandLineQuoteArg(r'a"b'), r'"a\"b"');
      expect(
        windowsCommandLineQuoteArg(r'C:\path with spaces\'),
        r'"C:\path with spaces\\"',
      );
    });
  });

  group('powerShellSingleQuoteLiteral', () {
    test('does not expand variables or apostrophes in generated scripts', () {
      expect(
        powerShellSingleQuoteLiteral(r'C:\Users\name$with$vars\events.log'),
        r"'C:\Users\name$with$vars\events.log'",
      );
      expect(powerShellSingleQuoteLiteral("owner's file"), "'owner''s file'");
    });
  });

  group('windowsPowerShellExecutable', () {
    test('prefers the trusted system32 executable over PATH lookup', () {
      final got = windowsPowerShellExecutableForTesting(
        environment: const {
          'SystemRoot': r'D:\Windows',
          'WINDIR': r'E:\Windows',
        },
        exists: (path) =>
            path ==
            r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
      );

      expect(got, r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe');
    });

    test('uses SystemRoot when Windows is not installed on C', () {
      final got = windowsPowerShellExecutableForTesting(
        environment: const {'SystemRoot': r'D:\Windows'},
        exists: (path) =>
            path ==
            r'D:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
      );

      expect(got, r'D:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe');
    });
  });

  group('Windows helper launcher', () {
    test('launches helper and lets the events file own completion', () {
      final command = buildWindowsLaunchPowerShellCommandForTesting(
        helperPath: r'C:\Deckhand\deckhand-elevated-helper.exe',
        helperArgs: ['write-image', '--target', r'PhysicalDrive$3'],
      );

      expect(command, contains('[System.Diagnostics.ProcessStartInfo]::new'));
      expect(command, contains('\$psi.UseShellExecute = \$false'));
      expect(command, contains('\$psi.CreateNoWindow = \$true'));
      expect(command, contains(r"'PhysicalDrive$3'"));
      expect(command, contains('Start-Process'));
      expect(command, contains('-Verb RunAs'));
      expect(command, contains('-PassThru'));
      expect(command, contains('helper-pid='));
      expect(command, isNot(contains('-Wait')));
      expect(command, isNot(contains('ExitCode')));
    });
  });

  group('completed read recovery', () {
    test(
      'hashes a full-size read-image output when helper events are lost',
      () async {
        final dir = await Directory.systemTemp.createTemp('deckhand-recover-');
        addTearDown(() async {
          if (await dir.exists()) await dir.delete(recursive: true);
        });
        final file = File('${dir.path}/backup.img');
        await file.writeAsBytes([1, 2, 3, 4]);

        final recovered = await recoverCompletedReadImageForTesting([
          'read-image',
          '--output',
          file.path,
          '--total-bytes',
          '4',
        ]);

        expect(recovered, isNotNull);
        expect(recovered!.phase, FlashPhase.done);
        expect(recovered.bytesDone, 4);
        expect(recovered.bytesTotal, 4);
        expect(
          recovered.message,
          '9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a',
        );
      },
    );

    test('does not recover partial read-image outputs', () async {
      final dir = await Directory.systemTemp.createTemp('deckhand-recover-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final file = File('${dir.path}/backup.img');
      await file.writeAsBytes([1, 2, 3]);

      final recovered = await recoverCompletedReadImageForTesting([
        'read-image',
        '--output',
        file.path,
        '--total-bytes',
        '4',
      ]);

      expect(recovered, isNull);
    });
  });
}

class _CapturingElevatedHelper extends ProcessElevatedHelperService {
  _CapturingElevatedHelper({super.readOutputRoot})
    : super(helperPath: '/bin/helper');

  List<String>? capturedArgs;
  Map<String, dynamic>? capturedManifest;

  @override
  Stream<FlashProgress> launchHelper(List<String> args) async* {
    capturedArgs = List<String>.of(args);
    final manifestIndex = args.indexOf('--manifest');
    if (manifestIndex >= 0 && manifestIndex + 1 < args.length) {
      capturedManifest =
          jsonDecode(File(args[manifestIndex + 1]).readAsStringSync())
              as Map<String, dynamic>;
    }
    yield const FlashProgress(
      bytesDone: 1,
      bytesTotal: 1,
      phase: FlashPhase.done,
      message: 'ok',
    );
  }
}

class _BlockingElevatedHelper extends ProcessElevatedHelperService {
  _BlockingElevatedHelper({super.readOutputRoot})
    : super(helperPath: '/bin/helper');

  final started = Completer<void>();
  final _release = Completer<void>();
  String? cancelFilePath;

  @override
  Stream<FlashProgress> launchHelper(List<String> args) async* {
    final cancelIndex = args.indexOf('--cancel-file');
    if (cancelIndex >= 0 && cancelIndex + 1 < args.length) {
      cancelFilePath = args[cancelIndex + 1];
    }
    if (!started.isCompleted) started.complete();
    yield const FlashProgress(
      bytesDone: 1,
      bytesTotal: 2,
      phase: FlashPhase.writing,
    );
    await _release.future;
  }

  Future<bool> cancelFileExists() async {
    final path = cancelFilePath;
    if (path == null) return false;
    return File(path).exists();
  }

  void release() {
    if (!_release.isCompleted) _release.complete();
  }
}
