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
      expect(
        userFacingDiskOperationError(
          'StepExecutionException: OS image "armbian-trixie-minimal" must declare a 64-hex sha256 before download',
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

    test('explains SSH wait timeouts in user terms', () {
      expect(
        userFacingDiskOperationError(
          'StepExecutionException: ssh did not come up within 600 seconds',
        ),
        'Deckhand did not see the printer come online over SSH. Make sure the eMMC is installed, the printer is powered on, and the printer is on the network, then retry.',
      );
    });

    test('explains profile network approval failures in user terms', () {
      expect(
        userFacingDiskOperationError(
          'StepExecutionException: Network access was not approved for this profile.',
        ),
        'Network access for this profile was not approved. Retry and choose Allow for each required host, or approve hosts from Settings.',
      );
    });

    test('explains adapter sector errors in user terms', () {
      expect(
        userFacingDiskOperationError(
          r'ElevatedHelperException: read device after 7818182656 of 7818182656 bytes: read \\.\PHYSICALDRIVE3: The drive cannot find the sector requested.',
        ),
        'Windows reported that Windows disk 3 ended before the advertised size. Replug the USB adapter and retry; if it repeats, use a different eMMC reader or treat this backup as incomplete.',
      );
    });

    test('explains helper launch failures without assuming UAC prompts', () {
      expect(
        userFacingDiskOperationError(
          'ElevatedHelperException: elevated helper never started. The UAC prompt may have been suppressed.',
        ),
        'Windows did not start Deckhand\'s disk helper. Deckhand cannot write raw disks until the app is running with administrator rights. Relaunch Deckhand as Administrator; if UAC prompts are disabled, start it from an elevated Administrator terminal.',
      );
    });

    test('explains helper process exits in user terms', () {
      expect(
        userFacingDiskOperationError(
          'ElevatedHelperException: elevated helper exited with code 1',
        ),
        'Deckhand\'s disk helper stopped before finishing. Reconnect the USB adapter, make sure no other app is using the drive, then retry.',
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

    test('hides spaced physical drive labels', () {
      expect(
        userFacingDiskOperationError('read PHYSICAL DRIVE 3 failed'),
        'read Windows disk 3 failed',
      );
      expect(
        hideRawDiskIds('Physical Drive 12 is busy'),
        'Windows disk 12 is busy',
      );
    });

    test('strips generic exception type prefixes', () {
      expect(
        userFacingDiskOperationError(
          'UpstreamException: OS image downloads must use https:// URLs',
        ),
        'OS image downloads must use https:// URLs',
      );
      expect(
        userFacingDiskOperationError(
          'FormatException: invalid managed printer port',
        ),
        'invalid managed printer port',
      );
    });

    test('explains Windows disk enumeration failures in user terms', () {
      expect(
        userFacingDiskOperationError(
          'SidecarError(-32603): Get-Disk failed: exit status 1',
        ),
        'Windows could not list storage devices. Reopen Deckhand as Administrator, then refresh disks; if it still fails, check that Windows Disk Management can open.',
      );
    });
  });
}
