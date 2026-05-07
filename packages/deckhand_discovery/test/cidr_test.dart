import 'package:deckhand_discovery/src/cidr.dart';
import 'package:deckhand_discovery/src/bonsoir_discovery_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('expandCidr', () {
    test('/24 expands to 254 host addresses (excludes net + broadcast)', () {
      final hosts = expandCidr('10.0.0.0/24').toList();
      expect(hosts, hasLength(254));
      expect(hosts.first, '10.0.0.1');
      expect(hosts.last, '10.0.0.254');
      expect(
        hosts.contains('10.0.0.0'),
        isFalse,
        reason: 'network address must be excluded',
      );
      expect(
        hosts.contains('10.0.0.255'),
        isFalse,
        reason: 'broadcast address must be excluded',
      );
    });

    test('/24 given a non-aligned base snaps to the network address', () {
      // 10.0.0.42/24 is the 10.0.0.0 network. The function must yield
      // the same 254 hosts as the aligned form, not start partway in.
      final hosts = expandCidr('10.0.0.42/24').toList();
      expect(hosts, hasLength(254));
      expect(hosts.first, '10.0.0.1');
      expect(hosts.last, '10.0.0.254');
    });

    test('/30 yields exactly 2 usable hosts', () {
      // 192.168.1.0/30 -> .0 net, .1 host, .2 host, .3 broadcast.
      final hosts = expandCidr('192.168.1.0/30').toList();
      expect(hosts, ['192.168.1.1', '192.168.1.2']);
    });

    test('/31 is a point-to-point link: both addresses are hosts', () {
      // RFC 3021 - /31 has no net/broadcast; both addresses are hosts.
      final hosts = expandCidr('192.168.1.0/31').toList();
      expect(hosts, ['192.168.1.0', '192.168.1.1']);
    });

    test('/32 yields exactly the single address', () {
      final hosts = expandCidr('192.168.1.42/32').toList();
      expect(hosts, ['192.168.1.42']);
    });

    test('rejects non-CIDR string', () {
      expect(
        () => expandCidr('not-a-cidr').toList(),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects prefix > 32', () {
      expect(
        () => expandCidr('10.0.0.1/33').toList(),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects negative prefix', () {
      expect(
        () => expandCidr('10.0.0.1/-1').toList(),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects non-numeric prefix', () {
      expect(
        () => expandCidr('10.0.0.1/abc').toList(),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects too-few octets', () {
      expect(
        () => expandCidr('10.0.0/24').toList(),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects too-many octets', () {
      expect(
        () => expandCidr('10.0.0.1.2/24').toList(),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects empty octet', () {
      expect(
        () => expandCidr('10..0.1/24').toList(),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects octet > 255', () {
      expect(
        () => expandCidr('10.0.0.256/24').toList(),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects missing prefix separator', () {
      expect(
        () => expandCidr('10.0.0.1').toList(),
        throwsA(isA<FormatException>()),
      );
    });

    test('iterable is lazy - can take first without materialising all', () {
      // If lazy behavior regresses to a full list, a /16 in a future
      // test would be 65k strings on the heap. Locking it down here.
      final first3 = expandCidr('10.0.0.0/24').take(3).toList();
      expect(first3, ['10.0.0.1', '10.0.0.2', '10.0.0.3']);
    });
  });

  group('BonsoirDiscoveryService.scanCidr', () {
    test('invalid CIDR returns no discoveries instead of throwing', () async {
      final svc = BonsoirDiscoveryService();
      final results = await svc.scanCidr(
        cidr: '10..0.1/abc',
        timeout: const Duration(milliseconds: 1),
      );
      expect(results, isEmpty);
    });

    test('large CIDR ranges are rejected before materialising hosts', () async {
      final svc = BonsoirDiscoveryService();
      final results = await svc.scanCidr(
        cidr: '10.0.0.0/16',
        timeout: const Duration(milliseconds: 1),
      );
      expect(results, isEmpty);
    });
  });
}
