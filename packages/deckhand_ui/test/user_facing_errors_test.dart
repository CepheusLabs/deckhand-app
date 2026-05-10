import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/utils/user_facing_errors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats host approval errors without leaking exception type', () {
    final message = userFacingError(
      const HostNotApprovedException(
        host: 'downloads.example.com',
        reason: 'host is not approved',
      ),
    );

    expect(message, contains('downloads.example.com'));
    expect(message, contains('Retry and choose Allow'));
    expect(message, isNot(contains('HostNotApprovedException')));
  });

  test('formats profile errors without leaking exception type', () {
    final message = userFacingError(
      const ProfileFormatException('missing profile_id'),
    );

    expect(message, 'The printer profile is invalid: missing profile_id');
    expect(message, isNot(contains('ProfileFormatException')));
  });

  test('formats typed Deckhand errors without leaking exception type', () {
    final message = userFacingError(
      const ProfileUnavailableException(
        profileId: 'phrozen-arco',
        reason: 'it is marked as a stub',
      ),
    );

    expect(
      message,
      'The phrozen-arco profile cannot be used for an install yet: it is marked as a stub.',
    );
    expect(message, isNot(contains('ProfileUnavailableException')));
  });

  test('delegates disk write errors to the disk formatter', () {
    final message = userFacingError(
      r'StepExecutionException: write: write \\.\PHYSICALDRIVE3: The parameter is incorrect.',
    );

    expect(message, contains('Windows rejected the raw disk write'));
    expect(message, isNot(contains('PHYSICALDRIVE3')));
  });
}
