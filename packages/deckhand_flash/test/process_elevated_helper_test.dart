import 'package:deckhand_flash/src/process_elevated_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('powerShellQuoteArg', () {
    test('plain token is wrapped in double quotes', () {
      expect(powerShellQuoteArg('write-image'), '"write-image"');
      expect(powerShellQuoteArg('PhysicalDrive3'), '"PhysicalDrive3"');
    });

    test('path with spaces survives intact', () {
      expect(
        powerShellQuoteArg(r'C:\Users\someone\Image File.img'),
        r'"C:\Users\someone\Image File.img"',
      );
    });

    test('embedded double-quote is doubled per PowerShell rules', () {
      expect(powerShellQuoteArg(r'a"b'), '"a""b"');
      expect(powerShellQuoteArg(r'weird"disk"name'), '"weird""disk""name"');
    });

    test('empty arg becomes ""', () {
      expect(powerShellQuoteArg(''), '""');
    });

    test('arg with only quotes', () {
      expect(powerShellQuoteArg(r'"'), '""""');
      expect(powerShellQuoteArg(r'""'), '""""""');
    });

    test('realistic helper invocation round-trips', () {
      final args = [
        'write-image',
        '--image',
        r'C:\Users\eknof\AppData\Local\Temp\img.iso',
        '--target',
        'PhysicalDrive3',
        '--token',
        'token-0123456789abcdef',
        '--verify',
        'true',
      ];
      final argList = args.map(powerShellQuoteArg).join(',');
      // Every arg appears verbatim between double quotes, separated
      // by a single comma (no whitespace).
      expect(argList, contains('"write-image"'));
      expect(argList, contains('"--image"'));
      expect(
        argList,
        contains(r'"C:\Users\eknof\AppData\Local\Temp\img.iso"'),
      );
      expect(argList.split(',').length, args.length);
    });
  });
}
