import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ssh/deckhand_ssh.dart' show MoonrakerHttpService;
// The headless stubs are intentionally not in the public barrel — see
// lib/deckhand_hitl.dart. Tests inside the package reach into src/.
// ignore: implementation_imports
import 'package:deckhand_hitl/src/headless_services.dart';
import 'package:flutter_test/flutter_test.dart';

/// T194 — verify [StubMoonrakerService] is the intentional HITL
/// headless stub: throwing action methods carry the documented
/// message, read-only probes return their safe defaults, and the HITL
/// service graph wires the stub rather than the real Moonraker client.
void main() {
  const stub = StubMoonrakerService();
  const host = '192.0.2.40';

  group('StubMoonrakerService throwing action methods', () {
    test('info throws _StubUnavailable with the documented message', () {
      expect(
        () => stub.info(host: host),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'toString',
            'moonraker stub: moonraker.info not implemented for HITL',
          ),
        ),
      );
    });

    test(
      'queryObjects throws _StubUnavailable with the documented message',
      () {
        expect(
          () => stub.queryObjects(host: host, objects: const ['extruder']),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'toString',
              'moonraker stub: moonraker.queryObjects not implemented for HITL',
            ),
          ),
        );
      },
    );

    test('runGCode throws _StubUnavailable with the documented message', () {
      expect(
        () => stub.runGCode(host: host, script: 'G28'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'toString',
            'moonraker stub: moonraker.runGCode not implemented for HITL',
          ),
        ),
      );
    });
  });

  group('StubMoonrakerService trivial-return methods', () {
    test('listObjects returns an empty list', () async {
      expect(await stub.listObjects(host: host), isEmpty);
    });

    test('fetchConfigFile returns null', () async {
      expect(
        await stub.fetchConfigFile(host: host, filename: 'printer.cfg'),
        isNull,
      );
    });

    test('isPrinting returns false', () async {
      expect(await stub.isPrinting(host: host), isFalse);
    });
  });

  group('StubMoonrakerService interface conformance', () {
    test('is a MoonrakerService but not the real HTTP client', () {
      expect(stub, isA<MoonrakerService>());
      // The stub must never be confused with the real-printer client.
      expect(stub, isNot(isA<MoonrakerHttpService>()));
    });
  });

  group('HITL service graph wiring', () {
    // The runner injects `const StubMoonrakerService()` into the
    // WizardController. This guards that wiring at the source level so a
    // future refactor cannot silently swap in the real Moonraker client
    // (which would make HITL try to talk to a live printer). A pure
    // source assertion avoids booting a sidecar just to read one field.
    final runnerSource = File(
      'lib/src/scenario_runner.dart',
    ).readAsStringSync();

    test('scenario_runner wires the stub, not the real Moonraker client', () {
      expect(
        runnerSource,
        contains('moonraker: const StubMoonrakerService()'),
        reason: 'HITL must inject the headless stub into WizardController',
      );
      expect(
        runnerSource,
        isNot(contains('MoonrakerHttpService')),
        reason: 'HITL must never wire the real-printer Moonraker client',
      );
    });
  });
}
