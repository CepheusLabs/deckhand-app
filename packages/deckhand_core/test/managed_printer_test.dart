import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SavedHost', () {
    test('normalizes malformed persisted ports', () {
      final saved = SavedHost.fromJson({
        'host': ' 192.168.1.50 ',
        'user': ' mks ',
        'port': 70000,
      });

      expect(saved.host, '192.168.1.50');
      expect(saved.user, 'mks');
      expect(saved.port, 22);
    });

    test('does not record incomplete saved hosts', () {
      final settings = DeckhandSettings(path: '<memory>');

      settings.recordSavedHost(
        const SavedHost(host: ' ', port: 22, user: 'mks'),
      );
      settings.recordSavedHost(
        const SavedHost(host: '192.168.1.50', port: 22, user: ''),
      );

      expect(settings.savedHosts, isEmpty);
    });

    test('forgets saved hosts with normalized input', () {
      final settings = DeckhandSettings(path: '<memory>');
      settings.recordSavedHost(
        SavedHost(
          host: '192.168.1.50',
          port: 22,
          user: 'mks',
          lastUsed: DateTime.utc(2026, 5, 4, 12),
        ),
      );

      settings.forgetSavedHost(host: ' 192.168.1.50 ', user: ' MKS ');

      expect(settings.savedHosts, isEmpty);
    });
  });

  group('ManagedPrinter', () {
    test('rejects invalid connection ports', () {
      expect(
        () => ManagedPrinter.fromConnection(
          profileId: 'phrozen-arco',
          displayName: 'Phrozen Arco',
          host: '192.168.1.50',
          port: 0,
          user: 'mks',
        ),
        throwsFormatException,
      );
    });

    test('rejects incomplete connection identities', () {
      expect(
        () => ManagedPrinter.fromConnection(
          profileId: '',
          displayName: 'Phrozen Arco',
          host: '192.168.1.50',
          port: 22,
          user: 'mks',
        ),
        throwsFormatException,
      );
      expect(
        () => ManagedPrinter.fromConnection(
          profileId: 'phrozen-arco',
          displayName: 'Phrozen Arco',
          host: ' ',
          port: 22,
          user: 'mks',
        ),
        throwsFormatException,
      );
      expect(
        () => ManagedPrinter.fromConnection(
          profileId: 'phrozen-arco',
          displayName: 'Phrozen Arco',
          host: '192.168.1.50',
          port: 22,
          user: '',
        ),
        throwsFormatException,
      );
    });

    test('normalizes connection labels', () {
      final printer = ManagedPrinter.fromConnection(
        profileId: 'phrozen-arco',
        displayName: 'Phrozen Arco',
        host: '192.168.1.50',
        port: 22,
        user: 'mks',
        labels: const {
          ' source ': ' deckhand ',
          'blank-value': ' ',
          ' ': 'ignored',
        },
      );

      expect(printer.labels, {'source': 'deckhand'});
    });

    test('normalizes persisted labels', () {
      final printer = ManagedPrinter.fromJson({
        'id': 'local:phrozen-arco:mks@192.168.1.50:22',
        'profile_id': 'phrozen-arco',
        'display_name': 'Phrozen Arco',
        'host': '192.168.1.50',
        'port': 22,
        'user': 'mks',
        'labels': {
          ' source ': ' deckhand ',
          'blank-value': ' ',
          'number-value': 42,
          ' ': 'ignored',
        },
      });

      expect(printer.labels, {'source': 'deckhand'});
    });

    test('round trips through settings json', () {
      final settings = DeckhandSettings(path: '<memory>');
      settings.recordManagedPrinter(
        ManagedPrinter(
          id: 'local:phrozen-arco:mks@192.168.1.50:22',
          profileId: 'phrozen-arco',
          displayName: 'Phrozen Arco',
          host: '192.168.1.50',
          port: 22,
          user: 'mks',
          machineKind: 'fdm_printer',
          connectionMode: 'ssh_moonraker',
          lastSeen: DateTime.utc(2026, 5, 4, 12),
        ),
      );

      final entries = settings.managedPrinters;

      expect(entries, hasLength(1));
      expect(entries.single.id, 'local:phrozen-arco:mks@192.168.1.50:22');
      expect(entries.single.profileId, 'phrozen-arco');
      expect(entries.single.displayName, 'Phrozen Arco');
      expect(entries.single.host, '192.168.1.50');
      expect(entries.single.port, 22);
      expect(entries.single.user, 'mks');
      expect(entries.single.machineKind, 'fdm_printer');
      expect(entries.single.connectionMode, 'ssh_moonraker');
      expect(entries.single.lastSeen, DateTime.utc(2026, 5, 4, 12));
    });

    test('dedupes by id and keeps most recent first', () {
      final settings = DeckhandSettings(path: '<memory>');
      settings.recordManagedPrinter(
        ManagedPrinter.fromConnection(
          profileId: 'sovol-zero',
          displayName: 'Sovol Zero',
          host: '192.168.1.41',
          port: 22,
          user: 'root',
          lastSeen: DateTime.utc(2026, 5, 4, 11),
        ),
      );
      settings.recordManagedPrinter(
        ManagedPrinter.fromConnection(
          profileId: 'phrozen-arco',
          displayName: 'Phrozen Arco',
          host: '192.168.1.50',
          port: 22,
          user: 'mks',
          lastSeen: DateTime.utc(2026, 5, 4, 12),
        ),
      );
      settings.recordManagedPrinter(
        ManagedPrinter.fromConnection(
          profileId: 'sovol-zero',
          displayName: 'Sovol Zero',
          host: '192.168.1.41',
          port: 22,
          user: 'root',
          lastSeen: DateTime.utc(2026, 5, 4, 13),
        ),
      );

      final entries = settings.managedPrinters;

      expect(entries.map((e) => e.profileId), ['sovol-zero', 'phrozen-arco']);
      expect(entries.first.lastSeen, DateTime.utc(2026, 5, 4, 13));
    });

    test('skips malformed persisted rows', () {
      final settings = DeckhandSettings(
        path: '<memory>',
        initial: {
          'managed_printers': [
            {'host': '192.168.1.50'},
            ManagedPrinter.fromConnection(
              profileId: 'phrozen-arco',
              displayName: 'Phrozen Arco',
              host: '192.168.1.50',
              port: 22,
              user: 'mks',
            ).toJson(),
          ],
        },
      );

      expect(settings.managedPrinters, hasLength(1));
      expect(settings.managedPrinters.single.profileId, 'phrozen-arco');
    });

    test('records a connected printer as saved host and managed printer', () {
      final settings = DeckhandSettings(path: '<memory>');

      settings.recordConnectedPrinter(
        profileId: 'phrozen-arco',
        profileDisplayName: 'Phrozen Arco',
        host: '192.168.1.50',
        port: 22,
        sessionUser: 'mks',
        preferredUser: 'root',
        now: DateTime.utc(2026, 5, 4, 12),
      );

      expect(settings.savedHosts, hasLength(1));
      expect(settings.savedHosts.single.host, '192.168.1.50');
      expect(settings.savedHosts.single.user, 'mks');
      expect(settings.managedPrinters, hasLength(1));
      expect(settings.managedPrinters.single.profileId, 'phrozen-arco');
      expect(settings.managedPrinters.single.displayName, 'Phrozen Arco');
      expect(settings.managedPrinters.single.host, '192.168.1.50');
      expect(settings.managedPrinters.single.user, 'mks');
      expect(
        settings.managedPrinters.single.lastSeen,
        DateTime.utc(2026, 5, 4, 12),
      );
    });

    test('settings-backed registry exposes the managed printer contract', () {
      final settings = DeckhandSettings(path: '<memory>');
      final registry = SettingsManagedPrinterRegistry(settings);
      final printer = ManagedPrinter.fromConnection(
        profileId: 'phrozen-arco',
        displayName: 'Phrozen Arco',
        host: '192.168.1.50',
        port: 22,
        user: 'mks',
        lastSeen: DateTime.utc(2026, 5, 4, 12),
        labels: const {'source': 'deckhand'},
      );

      registry.recordManagedPrinter(printer);

      expect(registry.listManagedPrinters(), hasLength(1));
      expect(registry.listManagedPrinters().single.id, printer.id);
      expect(registry.listManagedPrinters().single.machineKind, 'fdm_printer');
      expect(
        registry.listManagedPrinters().single.connectionMode,
        'ssh_moonraker',
      );
      expect(registry.listManagedPrinters().single.labels, {
        'source': 'deckhand',
      });

      registry.forgetManagedPrinter(printer.id);

      expect(registry.listManagedPrinters(), isEmpty);
    });

    test('does not record impossible managed printer rows', () {
      final settings = DeckhandSettings(path: '<memory>');

      settings.recordManagedPrinter(
        const ManagedPrinter(
          id: ' ',
          profileId: 'phrozen-arco',
          displayName: 'Phrozen Arco',
          host: '192.168.1.50',
          port: 22,
          user: 'mks',
        ),
      );

      expect(settings.managedPrinters, isEmpty);
    });

    test('forgets managed printers with normalized id', () {
      final settings = DeckhandSettings(path: '<memory>');
      final printer = ManagedPrinter.fromConnection(
        profileId: 'phrozen-arco',
        displayName: 'Phrozen Arco',
        host: '192.168.1.50',
        port: 22,
        user: 'mks',
        lastSeen: DateTime.utc(2026, 5, 4, 12),
      );
      settings.recordManagedPrinter(printer);

      settings.forgetManagedPrinter(' ${printer.id.toUpperCase()} ');

      expect(settings.managedPrinters, isEmpty);
    });
  });
}
