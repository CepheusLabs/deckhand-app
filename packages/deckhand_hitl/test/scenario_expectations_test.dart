import 'package:deckhand_hitl/deckhand_hitl.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const base = '''
scenario_version: 1
profile: sovol_zero
flow: stock_keep
printer:
  host: 192.0.2.40
  ssh:
    user: mks
    password_env: PRINTER_PASS
decisions:
  firmware: kalico
''';

  group('Scenario.declaresOutcomeExpectations', () {
    test('is false when the scenario declares no outcome expectations', () {
      final scenario = Scenario.fromYaml(base);
      expect(scenario.declaresOutcomeExpectations, isFalse);
    });

    test('is true when step statuses are declared', () {
      final scenario = Scenario.fromYaml('''
$base
expectations:
  step_status:
    stock_keep.firmware_clone: completed
''');
      expect(scenario.declaresOutcomeExpectations, isTrue);
    });

    test('is true when only ports are declared', () {
      final scenario = Scenario.fromYaml('''
$base
expectations:
  ports:
    7125: open
''');
      expect(scenario.declaresOutcomeExpectations, isTrue);
    });

    test('is true when only remote files are declared', () {
      final scenario = Scenario.fromYaml('''
$base
expectations:
  remote_files:
    - path: ~/klipper/klippy/klippy.py
      must_exist: true
''');
      expect(scenario.declaresOutcomeExpectations, isTrue);
    });
  });

  test('acceptHostKey defaults to false (matches the field doc)', () {
    expect(Scenario.fromYaml(base).acceptHostKey, isFalse);
  });
}
