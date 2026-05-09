import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late String settingsPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('deckhand-window-');
    settingsPath = p.join(tmp.path, 'settings.json');
  });

  tearDown(() {
    try { tmp.deleteSync(recursive: true); } catch (_) {}
  });

  test('null geometry is the default and round-trips as null', () async {
    final s = await DeckhandSettings.load(settingsPath);
    expect(s.windowGeometry, isNull);
    await s.save();
    final reloaded = await DeckhandSettings.load(settingsPath);
    expect(reloaded.windowGeometry, isNull);
  });

  test('size-only geometry round-trips', () async {
    final s = await DeckhandSettings.load(settingsPath);
    s.windowGeometry = const WindowGeometry(width: 1280, height: 800);
    await s.save();
    final reloaded = await DeckhandSettings.load(settingsPath);
    expect(reloaded.windowGeometry, isNotNull);
    expect(reloaded.windowGeometry!.width, 1280);
    expect(reloaded.windowGeometry!.height, 800);
    expect(reloaded.windowGeometry!.x, isNull);
    expect(reloaded.windowGeometry!.y, isNull);
  });

  test('full geometry round-trips', () async {
    final s = await DeckhandSettings.load(settingsPath);
    s.windowGeometry = const WindowGeometry(
      width: 1440, height: 900, x: 120.5, y: 64.0,
    );
    await s.save();
    final reloaded = await DeckhandSettings.load(settingsPath);
    expect(reloaded.windowGeometry!.width, 1440);
    expect(reloaded.windowGeometry!.height, 900);
    expect(reloaded.windowGeometry!.x, 120.5);
    expect(reloaded.windowGeometry!.y, 64.0);
  });

  test('assigning null clears the persisted value', () async {
    final s = await DeckhandSettings.load(settingsPath);
    s.windowGeometry = const WindowGeometry(width: 800, height: 600);
    await s.save();
    expect((await DeckhandSettings.load(settingsPath)).windowGeometry, isNotNull);
    s.windowGeometry = null;
    await s.save();
    expect((await DeckhandSettings.load(settingsPath)).windowGeometry, isNull);
  });

  test('corrupted geometry shape returns null (no exception)', () async {
    // Hand-author a settings.json with broken `window_geometry`.
    await File(settingsPath).writeAsString('''
{
  "window_geometry": "not-an-object"
}
''');
    final s = await DeckhandSettings.load(settingsPath);
    expect(s.windowGeometry, isNull);
  });

  test('corrupted geometry values return null (no exception)', () {
    final s = DeckhandSettings(
      path: '<memory>',
      initial: {
        'window_geometry': {'width': 'wide', 'height': 800},
      },
    );

    expect(s.windowGeometry, isNull);
  });
}
