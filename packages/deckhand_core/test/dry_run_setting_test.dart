import 'dart:convert';
import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('dryRun setting defaults to false', () async {
    final tmp = Directory.systemTemp.createTempSync('deckhand-dry-');
    try {
      final s = await DeckhandSettings.load(p.join(tmp.path, 'settings.json'));
      expect(s.dryRun, isFalse);
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  test('dryRun setting persists across reload', () async {
    final tmp = Directory.systemTemp.createTempSync('deckhand-dry-');
    final path = p.join(tmp.path, 'settings.json');
    try {
      final s = await DeckhandSettings.load(path);
      s.dryRun = true;
      await s.save();
      final reloaded = await DeckhandSettings.load(path);
      expect(reloaded.dryRun, isTrue);
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  test('developerMode setting defaults to false', () async {
    final tmp = Directory.systemTemp.createTempSync('deckhand-dev-mode-');
    try {
      final s = await DeckhandSettings.load(p.join(tmp.path, 'settings.json'));
      expect(s.developerMode, isFalse);
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  test('developerMode setting persists across reload', () async {
    final tmp = Directory.systemTemp.createTempSync('deckhand-dev-mode-');
    final path = p.join(tmp.path, 'settings.json');
    try {
      final s = await DeckhandSettings.load(path);
      s.developerMode = true;
      await s.save();
      final reloaded = await DeckhandSettings.load(path);
      expect(reloaded.developerMode, isTrue);
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  test('allowedHosts ignores malformed persisted entries', () {
    final s = DeckhandSettings(
      path: '<memory>',
      initial: {
        'allowed_hosts': [
          ' downloads.example.com ',
          'DOWNLOADS.EXAMPLE.COM',
          42,
          null,
          '',
          'github.com',
        ],
      },
    );

    expect(s.allowedHosts, {'downloads.example.com', 'github.com'});
  });

  test(
    'allowedHosts setter normalizes persisted blank and duplicate hosts',
    () async {
      final tmp = Directory.systemTemp.createTempSync('deckhand-hosts-');
      final path = p.join(tmp.path, 'settings.json');
      final s = DeckhandSettings(path: path);

      s.allowedHosts = {
        ' downloads.example.com ',
        'DOWNLOADS.EXAMPLE.COM',
        '',
        'downloads.example.com',
        ' github.com ',
      };
      await s.save();
      final raw =
          jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;

      expect(raw['allowed_hosts'], ['downloads.example.com', 'github.com']);
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    },
  );

  test('numeric retention settings clamp corrupted persisted values', () {
    final s = DeckhandSettings(
      path: '<memory>',
      initial: {'prune_older_than_days': -10, 'cache_retention_days': -20},
    );

    expect(s.pruneOlderThanDays, 1);
    expect(s.cacheRetentionDays, 0);
  });

  test('numeric retention settings ignore non-finite persisted values', () {
    final s = DeckhandSettings(
      path: '<memory>',
      initial: {
        'prune_older_than_days': double.nan,
        'cache_retention_days': double.infinity,
      },
    );

    expect(s.pruneOlderThanDays, 30);
    expect(s.cacheRetentionDays, 30);
  });

  test('lastPreflight skips malformed map keys', () {
    final s = DeckhandSettings(
      path: '<memory>',
      initial: {
        'last_preflight': <Object?, Object?>{
          'passed': true,
          42: 'bad key',
          'report': '[PASS] cached',
        },
      },
    );

    expect(s.lastPreflight, {'passed': true, 'report': '[PASS] cached'});
  });
}
