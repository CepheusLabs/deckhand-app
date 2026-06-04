import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Deckhand transport capability gating', () {
    test('allows WebUSB MCU flashing in browser when WebUSB is available', () {
      final gate = gateDeckhandStepTransport(
        step: const {
          'id': 'flash-main',
          'kind': 'mcu_flash',
          'transport_requirements': ['webusb.dfu'],
        },
        availability: const DeckhandTransportAvailability(webUsb: true),
      );

      expect(gate.isAvailable, isTrue);
      expect(gate.surface, DeckhandExecutionSurface.browser);
      expect(gate.usesBrowser, isTrue);
    });

    test('reports missing browser transport when WebSerial is unavailable', () {
      final gate = gateDeckhandStepTransport(
        step: const {
          'id': 'flash-toolhead',
          'transport_requirements': ['webserial.bootloader'],
        },
        availability: const DeckhandTransportAvailability(webUsb: true),
      );

      expect(gate.isAvailable, isFalse);
      expect(gate.missingRequirements, ['webserial.bootloader']);
    });

    test('routes raw disk image steps to local agent or desktop fallback', () {
      final localAgentGate = gateDeckhandStepTransport(
        step: const {'kind': 'write_image'},
        availability: const DeckhandTransportAvailability(localAgent: true),
      );
      final desktopGate = gateDeckhandStepTransport(
        step: const {'kind': 'write_image'},
        availability: const DeckhandTransportAvailability(desktopApp: true),
      );

      expect(localAgentGate.surface, DeckhandExecutionSurface.localAgent);
      expect(localAgentGate.requiresNativeFallback, isTrue);
      expect(desktopGate.surface, DeckhandExecutionSurface.desktopApp);
    });

    test(
      'routes SSH/LAN steps through native fallback rather than browser',
      () {
        final gate = gateDeckhandStepTransport(
          step: const {'kind': 'ssh_commands'},
          availability: const DeckhandTransportAvailability(
            webUsb: true,
            localAgent: true,
          ),
        );

        expect(gate.surface, DeckhandExecutionSurface.localAgent);
        expect(gate.usesBrowser, isFalse);
      },
    );

    test('manual UF2 steps are browser-capable through download handoff', () {
      final gate = gateDeckhandStepTransport(
        step: const {
          'transport_requirements': ['manual.uf2'],
        },
        availability: const DeckhandTransportAvailability(),
      );

      expect(gate.surface, DeckhandExecutionSurface.browser);
    });

    test('parses transport_requirements from profile step metadata', () {
      expect(
        transportRequirementsForStep(const {
          'transport_requirements': ['webhid.keyboard', 'manual.uf2'],
        }),
        ['webhid.keyboard', 'manual.uf2'],
      );
      expect(
        transportRequirementsForStep(const {
          'transport_requirement': 'webusb.dfu',
        }),
        ['webusb.dfu'],
      );
    });
  });
}
