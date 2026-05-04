import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('previewKlipperSectionSettings', () {
    test('updates existing keys inside a section', () {
      final preview = previewKlipperSectionSettings(
        original: [
          '[printer]',
          'kinematics: cartesian',
          '',
          '[extruder]',
          'pressure_advance: 0.030',
          'rotation_distance: 7.4000',
          '',
        ].join('\n'),
        section: 'extruder',
        values: const {
          'pressure_advance': '0.040',
          'rotation_distance': '7.5000',
        },
      );

      expect(preview.changed, isTrue);
      expect(preview.updated, contains('[extruder]\npressure_advance: 0.040'));
      expect(preview.updated, contains('rotation_distance: 7.5000'));
      expect(preview.updated, isNot(contains('pressure_advance: 0.030')));
      expect(preview.updated, contains('[printer]\nkinematics: cartesian'));
    });

    test('adds missing keys to the existing section', () {
      final preview = previewKlipperSectionSettings(
        original: '[extruder]\nstep_pin: PB3\n',
        section: 'extruder',
        values: const {'pressure_advance': '0.040'},
      );

      expect(
        preview.updated,
        '[extruder]\nstep_pin: PB3\npressure_advance: 0.040\n',
      );
    });

    test('appends the section only when it does not exist', () {
      final preview = previewKlipperSectionSettings(
        original: '[printer]\nkinematics: cartesian\n',
        section: 'extruder',
        values: const {'pressure_advance': '0.040'},
      );

      expect(
        preview.updated,
        '[printer]\nkinematics: cartesian\n\n'
        '[extruder]\npressure_advance: 0.040\n',
      );
    });

    test('reports unchanged when values already match', () {
      final original = '[extruder]\npressure_advance: 0.040\n';

      final preview = previewKlipperSectionSettings(
        original: original,
        section: 'extruder',
        values: const {'pressure_advance': '0.040'},
      );

      expect(preview.changed, isFalse);
      expect(preview.updated, original);
    });

    test('rejects ambiguous or unsafe patches', () {
      expect(
        () => previewKlipperSectionSettings(
          original: '[extruder]\n\n[extruder]\n',
          section: 'extruder',
          values: const {'pressure_advance': '0.040'},
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => previewKlipperSectionSettings(
          original: '[extruder]\n',
          section: 'extruder',
          values: const {'bad option': '1'},
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => previewKlipperSectionSettings(
          original: '[extruder]\n',
          section: 'extruder',
          values: const {'pressure_advance': '0.040\n[printer]'},
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
