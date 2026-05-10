import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  List<File> dartSources() {
    final roots = [Directory('lib'), Directory('test')];
    return [
      for (final root in roots.where((d) => d.existsSync()))
        for (final entity in root.listSync(recursive: true, followLinks: false))
          if (entity is File && entity.path.endsWith('.dart')) entity,
    ];
  }

  test('Dart source files do not contain NUL bytes', () {
    final offenders = <String>[];

    for (final file in dartSources()) {
      final bytes = file.readAsBytesSync();
      if (bytes.contains(0)) offenders.add(file.path);
    }

    expect(offenders, isEmpty);
  });

  test('UI text styles do not use custom letter spacing', () {
    final pattern = RegExp(r'letterSpacing\s*:\s*([^,\n)]+)');
    final offenders = <String>[];

    for (final file in dartSources()) {
      final source = file.readAsStringSync();
      for (final match in pattern.allMatches(source)) {
        final value = match.group(1)?.trim();
        if (value != '0' && value != '0.0') {
          offenders.add('${file.path}: $value');
        }
      }
    }

    expect(offenders, isEmpty);
  });
}
