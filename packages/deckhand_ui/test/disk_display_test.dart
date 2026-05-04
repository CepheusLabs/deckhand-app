import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/utils/disk_display.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('diskDisplayName', () {
    test('keeps real friendly names', () {
      expect(
        diskDisplayName(_disk(model: 'Generic STORAGE DEVICE')),
        'Generic STORAGE DEVICE',
      );
      expect(diskDisplayName(_disk(model: 'Printer eMMC')), 'Printer eMMC');
    });

    test('does not expose Windows physical-drive ids as names', () {
      for (final model in const [
        '',
        'PhysicalDrive3',
        'PHYSICAL DRIVE 3',
        r'\\.\PHYSICALDRIVE3',
        'Unknown disk',
      ]) {
        expect(diskDisplayName(_disk(model: model)), 'Generic STORAGE DEVICE');
      }
    });
  });

  group('diskTechnicalLabel', () {
    test('formats physical-drive ids without raw device spelling', () {
      expect(diskTechnicalLabel(_disk(id: 'PhysicalDrive3')), 'Windows disk 3');
    });
  });
}

DiskInfo _disk({
  String id = 'PhysicalDrive3',
  String model = '',
  bool removable = true,
  String bus = 'USB',
}) {
  return DiskInfo(
    id: id,
    path: r'\\.\PHYSICALDRIVE3',
    sizeBytes: 32 * 1024 * 1024 * 1024,
    bus: bus,
    model: model,
    removable: removable,
    partitions: const [],
  );
}
