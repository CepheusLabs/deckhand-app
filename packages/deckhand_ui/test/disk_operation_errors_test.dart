import 'package:deckhand_ui/src/utils/disk_operation_errors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('userFacingDiskOperationError', () {
    test('explains missing printer connection in user terms', () {
      expect(
        userFacingDiskOperationError('StepExecutionException: no ssh host set'),
        'Deckhand does not have a printer address yet. Connect to the printer before continuing.',
      );
    });

    test('explains missing OS image checksum in user terms', () {
      expect(
        userFacingDiskOperationError(
          'StepExecutionException: validate sha256: sha256 is required and must be 64 lowercase hex characters',
        ),
        'The selected OS image is missing a valid SHA-256 checksum. Refresh profiles or choose another OS image before flashing.',
      );
    });

    test('explains missing download assets in user terms', () {
      expect(
        userFacingDiskOperationError(
          'SidecarError(-32603): unexpected status 404 for https://example.invalid/missing.img.xz',
        ),
        'Deckhand could not download the OS image because the configured URL was not found. Refresh profiles or choose another OS image.',
      );
    });

    test('hides raw disk ids behind StateError messages', () {
      expect(
        userFacingDiskOperationError(
          StateError(r'write \\.\PHYSICALDRIVE3 failed'),
        ),
        'write Windows disk 3 failed',
      );
    });
  });
}
