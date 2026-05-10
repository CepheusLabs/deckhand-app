import 'package:deckhand_core/src/platform/windows_tools.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveTrustedWindowsPowerShellExecutable', () {
    test('prefers the default Windows directory when present', () {
      final got = resolveTrustedWindowsPowerShellExecutable(
        environment: {
          'SystemRoot': r'D:\Windows',
          'WINDIR': r'E:\Windows',
        },
        exists: (path) =>
            path == windowsPowerShellPathUnder(r'C:\Windows') ||
            path == windowsPowerShellPathUnder(r'D:\Windows'),
      );

      expect(got, windowsPowerShellPathUnder(r'C:\Windows'));
    });

    test('falls back to SystemRoot when the default path is missing', () {
      final got = resolveTrustedWindowsPowerShellExecutable(
        environment: {'SystemRoot': r'D:\Windows'},
        exists: (path) => path == windowsPowerShellPathUnder(r'D:\Windows'),
      );

      expect(got, windowsPowerShellPathUnder(r'D:\Windows'));
    });

    test('returns the default path when no candidate exists', () {
      final got = resolveTrustedWindowsPowerShellExecutable(
        environment: const {},
        exists: (_) => false,
      );

      expect(got, windowsPowerShellPathUnder(r'C:\Windows'));
    });
  });
}
