import 'dart:async';
import 'dart:io';

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
        '--token',
        'token-0123456789abcdef',
        '--verify',
        'true',
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
}

class _CapturingElevatedHelper extends ProcessElevatedHelperService {
  _CapturingElevatedHelper({super.readOutputRoot})
    : super(helperPath: '/bin/helper');

  List<String>? capturedArgs;

  @override
  Stream<FlashProgress> launchHelper(List<String> args) async* {
    capturedArgs = List<String>.of(args);
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
