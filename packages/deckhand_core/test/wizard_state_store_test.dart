import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late String sessionPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('deckhand-wizard-state-');
    sessionPath = p.join(tmp.path, 'wizard_session.json');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('WizardState JSON round-trip', () {
    test('initial state round-trips identically', () {
      final s = WizardState.initial();
      final encoded = s.toJson();
      final decoded = WizardState.fromJson(encoded);
      expect(decoded.profileId, s.profileId);
      expect(decoded.currentStep, s.currentStep);
      expect(decoded.flow, s.flow);
      expect(decoded.decisions, isEmpty);
    });

    test('decisions + flow + host round-trip', () {
      final s = const WizardState(
        profileId: 'sovol-zero',
        decisions: {
          'firmware': 'kalico',
          'kiauh': true,
          'flash.disk': 'mmcblk0',
        },
        currentStep: 's200-choose-os',
        flow: WizardFlow.freshFlash,
        sshHost: '10.0.0.42',
        sshPort: 2222,
        sshUser: 'mks',
      );
      final json = s.toJson();
      final decoded = WizardState.fromJson(json);
      expect(decoded.profileId, 'sovol-zero');
      expect(decoded.decisions, s.decisions);
      expect(decoded.currentStep, 's200-choose-os');
      expect(decoded.flow, WizardFlow.freshFlash);
      expect(decoded.sshHost, '10.0.0.42');
      expect(decoded.sshPort, 2222);
      expect(decoded.sshUser, 'mks');
    });

    test('unknown flow name degrades to WizardFlow.none', () {
      final decoded = WizardState.fromJson({
        'schema': 'deckhand.wizard_state/1',
        'profileId': 'x',
        'decisions': <String, dynamic>{},
        'currentStep': 'welcome',
        'flow': 'time-travel',
      });
      expect(decoded.flow, WizardFlow.none);
    });

    test('malformed optional fields degrade to safe defaults', () {
      final decoded = WizardState.fromJson({
        'schema': 'deckhand.wizard_state/1',
        'profileId': 42,
        'decisions': <String, dynamic>{},
        'currentStep': false,
        'flow': 'stockKeep',
        'sshHost': ['192.168.1.50'],
        'sshPort': '22',
        'sshUser': 7,
      });

      expect(decoded.profileId, '');
      expect(decoded.currentStep, 'welcome');
      expect(decoded.flow, WizardFlow.stockKeep);
      expect(decoded.sshHost, isNull);
      expect(decoded.sshPort, isNull);
      expect(decoded.sshUser, isNull);
    });

    test('malformed decision keys and flow degrade to safe defaults', () {
      final decoded = WizardState.fromJson({
        'schema': 'deckhand.wizard_state/1',
        'profileId': 'phrozen-arco',
        'decisions': {
          1: 'bad key',
          'flash.disk': 'PhysicalDrive3',
          'ignored': null,
        },
        'currentStep': 's220-confirm',
        'flow': 99,
      });

      expect(decoded.decisions, {'flash.disk': 'PhysicalDrive3'});
      expect(decoded.flow, WizardFlow.none);
    });

    test('copyWith can clear optional SSH fields', () {
      const state = WizardState(
        profileId: 'phrozen-arco',
        decisions: {},
        currentStep: 'connect',
        flow: WizardFlow.stockKeep,
        sshHost: '192.168.1.50',
        sshPort: 2222,
        sshUser: 'mks',
      );

      final cleared = state.copyWith(
        sshHost: null,
        sshPort: null,
        sshUser: null,
      );

      expect(cleared.sshHost, isNull);
      expect(cleared.sshPort, isNull);
      expect(cleared.sshUser, isNull);
    });
  });

  group('WizardStateStore', () {
    test('load returns null when no file exists', () async {
      final store = WizardStateStore(path: sessionPath);
      expect(await store.load(), isNull);
    });

    test('save -> load round-trips', () async {
      final store = WizardStateStore(path: sessionPath);
      final s = const WizardState(
        profileId: 'phrozen-arco',
        decisions: {'probe.os_id': 'armbian'},
        currentStep: 's40-choose-path',
        flow: WizardFlow.stockKeep,
      );
      await store.save(s);
      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.profileId, 'phrozen-arco');
      expect(loaded.flow, WizardFlow.stockKeep);
      expect(loaded.decisions['probe.os_id'], 'armbian');
    });

    test(
      'save is atomic — corrupted tmp does not poison prior snapshot',
      () async {
        final store = WizardStateStore(path: sessionPath);
        await store.save(
          const WizardState(
            profileId: 'a',
            decisions: {},
            currentStep: 'x',
            flow: WizardFlow.none,
          ),
        );
        expect(await File(sessionPath).exists(), isTrue);
        final before = await File(sessionPath).readAsString();
        // Drop a broken tmp to simulate an interrupted write.
        await File('$sessionPath.tmp').writeAsString('{not: valid');
        // A fresh save should still succeed (rename replaces the good
        // file; tmp gets reused).
        await store.save(
          const WizardState(
            profileId: 'b',
            decisions: {},
            currentStep: 'y',
            flow: WizardFlow.none,
          ),
        );
        final after = await File(sessionPath).readAsString();
        expect(after, isNot(equals(before)));
        expect(after, contains('"profileId": "b"'));
      },
    );

    test('load returns null on unknown schema', () async {
      await File(sessionPath).writeAsString('{"schema":"other/1"}');
      final store = WizardStateStore(path: sessionPath);
      expect(await store.load(), isNull);
    });

    test('load returns null on corrupt JSON', () async {
      await File(sessionPath).writeAsString('{broken');
      final store = WizardStateStore(path: sessionPath);
      expect(await store.load(), isNull);
    });

    test('clear removes the session file', () async {
      final store = WizardStateStore(path: sessionPath);
      await store.save(WizardState.initial());
      expect(await File(sessionPath).exists(), isTrue);
      await store.clear();
      expect(await File(sessionPath).exists(), isFalse);
    });

    test('save failures route through errorSink, not throw', () async {
      // Pointing the store at a path whose parent is itself a regular
      // file forces _writeAtomically to fail. The save() future must
      // still resolve cleanly so the wizard doesn't crash, and the
      // error callback must fire with the underlying exception.
      final blocker = File(p.join(tmp.path, 'blocker'));
      await blocker.writeAsString('not a dir');
      final badPath = p.join(blocker.path, 'wedged', 'session.json');

      final captured = <Object>[];
      final store = WizardStateStore(
        path: badPath,
        errorSink: (e, _) => captured.add(e),
      );

      await store.save(WizardState.initial());

      expect(
        captured,
        isNotEmpty,
        reason: 'errorSink must fire when the FS rejects the write',
      );
      expect(captured.first, isA<FileSystemException>());
    });

    test('rapid consecutive saves coalesce to the last state', () async {
      // Regression: the provider fires `unawaited(store.save(state))`
      // once per controller event. Two such calls racing on rename()
      // could produce stale state on disk. With coalesce-to-latest,
      // only the final state wins regardless of how many intermediates
      // came through.
      final store = WizardStateStore(path: sessionPath);
      const a = WizardState(
        profileId: 'a',
        decisions: {},
        currentStep: 's1',
        flow: WizardFlow.none,
      );
      const b = WizardState(
        profileId: 'b',
        decisions: {},
        currentStep: 's2',
        flow: WizardFlow.none,
      );
      const c = WizardState(
        profileId: 'c',
        decisions: {},
        currentStep: 's3',
        flow: WizardFlow.none,
      );

      // Fire three saves without awaiting the first two — the third
      // should win regardless of completion order.
      final f1 = store.save(a);
      final f2 = store.save(b);
      final f3 = store.save(c);

      await Future.wait([f1, f2, f3]);

      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(
        loaded!.profileId,
        'c',
        reason: 'coalesced save must land on the most-recent state',
      );
    });
  });
}
