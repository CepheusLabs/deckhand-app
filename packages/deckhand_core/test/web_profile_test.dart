import 'package:deckhand_core/deckhand_web_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Deckhand web profile planning', () {
    test('parses profile YAML and gates real flow steps', () {
      final profile = parseDeckhandWebProfileYaml('''
schema_version: 1
profile_id: web-test
profile_version: 1.2.3
display_name: Web Test Printer
status: beta
flows:
  fresh_flash:
    enabled: true
    steps:
      - id: toolhead
        kind: flash_mcus
        display_name: Toolhead MCU
        transport_requirements: [webusb.dfu]
        firmware_url: https://firmware.example/toolhead.bin
        webusb:
          chunk_size: 2048
      - id: emmc
        kind: flash_os
        transport_requirements: [raw_disk_write]
''');

      expect(profile.id, 'web-test');
      final flows = deckhandWebFlowsForProfile(profile);
      expect(flows.single.id, 'fresh_flash');
      expect(flows.single.steps, hasLength(2));

      final plans = planDeckhandWebFlow(
        profile: profile,
        flowId: 'fresh_flash',
        availability: const DeckhandTransportAvailability(webUsb: true),
      );
      expect(plans, hasLength(2));
      expect(plans.first.id, 'toolhead');
      expect(plans.first.label, 'Toolhead MCU');
      expect(plans.first.runnableInBrowser, isTrue);
      expect(plans.first.gate.requirements, ['webusb.dfu']);
      expect(plans.last.requiresNativeFallback, isFalse);
      expect(plans.last.gate.isAvailable, isFalse);
      expect(plans.last.gate.missingRequirements, ['raw_disk_write']);
    });

    test('discovers firmware URLs and file names from supported shapes', () {
      final direct = <String, dynamic>{
        'firmware_url': 'https://example.test/a.uf2',
        'firmware_file_name': 'a.uf2',
      };
      expect(
        firmwareUriForDeckhandStep(direct).toString(),
        'https://example.test/a.uf2',
      );
      expect(firmwareFileNameForDeckhandStep(direct), 'a.uf2');

      final nested = <String, dynamic>{
        'firmware': {'url': 'firmware/b.bin', 'file_name': 'b.bin'},
      };
      expect(
        firmwareUriForDeckhandStep(
          nested,
          baseUri: Uri.parse('https://profiles.example/printers/p/'),
        ).toString(),
        'https://profiles.example/printers/p/firmware/b.bin',
      );
      expect(firmwareFileNameForDeckhandStep(nested), 'b.bin');
    });

    test('throws profile format errors for invalid YAML roots', () {
      expect(
        () => parseDeckhandWebProfileYaml('- nope'),
        throwsA(isA<ProfileFormatException>()),
      );
      expect(
        () => parseDeckhandWebProfileYaml('schema_version: 1'),
        throwsA(isA<ProfileFormatException>()),
      );
    });
  });
}
