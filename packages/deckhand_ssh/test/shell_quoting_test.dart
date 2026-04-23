import 'package:deckhand_ssh/src/shell_quoting.dart';
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

    test('empty string stays valid', () {
      expect(shellSingleQuote(''), "''");
    });

    test('shell metacharacters are neutralised by the single quotes', () {
      // None of these should be interpreted by the shell because the
      // whole value is inside one set of single quotes (plus the
      // escape dance for the apostrophe).
      expect(shellSingleQuote(r'$USER'), r"'$USER'");
      expect(shellSingleQuote(r'foo`bar`'), r"'foo`bar`'");
      expect(shellSingleQuote(r'a && b'), r"'a && b'");
      expect(shellSingleQuote(r'a | b'), r"'a | b'");
      expect(shellSingleQuote(r'${HOME}/config'), r"'${HOME}/config'");
    });

    test('realistic password: "p@ss w0rd!"', () {
      expect(shellSingleQuote('p@ss w0rd!'), r"'p@ss w0rd!'");
    });

    test('pathological password with every troublesome char', () {
      const pw = r"a'b`c$d|e&f;g(h)i[j]k{l}m>n<o*p?q~r#s!t";
      final q = shellSingleQuote(pw);
      // Only ' -> '\''; everything else survives unaltered inside
      // the wrapping quotes.
      expect(q, r"'a'\''b`c$d|e&f;g(h)i[j]k{l}m>n<o*p?q~r#s!t'");
    });
  });
}
