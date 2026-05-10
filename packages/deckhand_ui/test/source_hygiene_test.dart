import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Dart source files do not contain NUL bytes', () {
    final roots = [Directory('lib'), Directory('test')];
    final offenders = <String>[];

    for (final root in roots.where((d) => d.existsSync())) {
      for (final entity in root.listSync(recursive: true, followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final bytes = entity.readAsBytesSync();
        if (bytes.contains(0)) offenders.add(entity.path);
      }
    }

    expect(offenders, isEmpty);
  });
}
