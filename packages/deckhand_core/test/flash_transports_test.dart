import 'dart:async';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Deckhand flash transports', () {
    test('manual download emits download handoff and done', () async {
      var called = false;
      final executor = DeckhandTransportExecutor(
        availability: const DeckhandTransportAvailability(),
        transports: [
          ManualDownloadTransport(
            onDownload: (_) {
              called = true;
            },
          ),
        ],
      );

      final events = await executor.executeStep(const {
        'id': 'manual',
        'transport_requirements': ['manual.uf2'],
      }, fileName: 'firmware.uf2').toList();

      expect(called, isTrue);
      expect(
        events.map((e) => e.phase),
        contains(DeckhandTransportPhase.downloadReady),
      );
      expect(events.last.phase, DeckhandTransportPhase.done);
    });

    test(
      'delegates WebUSB flashing when browser capability is available',
      () async {
        final delegate = _FakeBrowserDelegate();
        final executor = DeckhandTransportExecutor(
          availability: const DeckhandTransportAvailability(webUsb: true),
          transports: [
            DelegatedBrowserFlashTransport(
              id: 'webusb',
              prefix: 'webusb',
              delegate: delegate,
            ),
          ],
        );

        final events = await executor.executeStep(const {
          'id': 'mcu',
          'transport_requirements': ['webusb.dfu'],
        }).toList();

        expect(delegate.requirements, ['webusb.dfu']);
        expect(events.last.phase, DeckhandTransportPhase.done);
      },
    );

    test('routes local-only requirements to local agent transport', () async {
      final agent = _FakeLocalAgentClient();
      final executor = DeckhandTransportExecutor(
        availability: const DeckhandTransportAvailability(localAgent: true),
        transports: [LocalAgentFlashTransport(client: agent)],
      );

      final events = await executor.executeStep(const {
        'kind': 'write_image',
        'local_agent_method': 'disks.write_image',
      }).toList();

      expect(agent.calls.single.$1, 'disks.write_image');
      expect(events.last.phase, DeckhandTransportPhase.done);
    });

    test('throws when required browser transport is unavailable', () async {
      const executor = DeckhandTransportExecutor(
        availability: DeckhandTransportAvailability(),
        transports: <DeckhandFlashTransport>[],
      );

      expect(
        executor.executeStep(const {
          'transport_requirements': ['webserial.bootloader'],
        }).drain<void>(),
        throwsA(isA<DeckhandTransportException>()),
      );
    });
  });
}

class _FakeBrowserDelegate implements BrowserFlashDelegate {
  final requirements = <String>[];

  @override
  bool canHandle(String requirement) => true;

  @override
  Stream<DeckhandTransportEvent> execute(
    DeckhandTransportOperation operation,
  ) async* {
    requirements.add(operation.requirement);
    yield const DeckhandTransportEvent(
      phase: DeckhandTransportPhase.flashing,
      percent: 0.5,
    );
    yield const DeckhandTransportEvent(
      phase: DeckhandTransportPhase.done,
      percent: 1,
    );
  }
}

class _FakeLocalAgentClient implements LocalAgentClient {
  final calls = <(String, Map<String, Object?>)>[];

  @override
  Stream<Map<String, Object?>> callStreaming(
    String method,
    Map<String, Object?> params,
  ) async* {
    calls.add((method, params));
    yield {'phase': 'writing', 'percent': 0.4};
    yield {'phase': 'done', 'percent': 1.0};
  }
}
