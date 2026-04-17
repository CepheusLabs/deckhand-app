import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:deckhand_core/deckhand_core.dart';

/// [DiscoveryService] backed by bonsoir for mDNS and plain Dart sockets
/// for CIDR + SSH-ready polling.
class BonsoirDiscoveryService implements DiscoveryService {
  @override
  Future<List<DiscoveredPrinter>> scanMdns({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final discovery = BonsoirDiscovery(type: '_moonraker._tcp');
    try {
      await discovery.ready;
      await discovery.start();

      final found = <String, DiscoveredPrinter>{};
      final sub = discovery.eventStream?.listen((event) {
        final svc = event.service;
        if (svc == null) return;
        switch (event.type) {
          case BonsoirDiscoveryEventType.discoveryServiceFound:
            // Ask bonsoir to resolve the hostname/port into an IP.
            svc.resolve(discovery.serviceResolver);
          case BonsoirDiscoveryEventType.discoveryServiceResolved:
            final host = svc is ResolvedBonsoirService ? svc.host : null;
            if (host != null) {
              found[host] = DiscoveredPrinter(
                host: host,
                hostname: svc.name,
                port: svc.port,
                service: svc.type,
              );
            }
          default:
            break;
        }
      });

      await Future<void>.delayed(timeout);
      await sub?.cancel();
      return found.values.toList();
    } finally {
      try {
        await discovery.stop();
      } catch (_) {}
    }
  }

  @override
  Future<List<DiscoveredPrinter>> scanCidr({
    required String cidr,
    int port = 7125,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final ips = _expandCidr(cidr);
    final futures = ips.map((ip) async {
      try {
        final sock = await Socket.connect(ip, port, timeout: timeout);
        sock.destroy();
        return DiscoveredPrinter(
          host: ip, hostname: ip, port: port, service: 'moonraker?',
        );
      } catch (_) {
        return null;
      }
    });
    final hits = await Future.wait(futures);
    return hits.whereType<DiscoveredPrinter>().toList();
  }

  @override
  Future<bool> waitForSsh({
    required String host,
    int port = 22,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final sock = await Socket.connect(host, port,
            timeout: const Duration(seconds: 3));
        sock.destroy();
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    return false;
  }

  Iterable<String> _expandCidr(String cidr) sync* {
    final parts = cidr.split('/');
    if (parts.length != 2) {
      yield cidr;
      return;
    }
    final octets = parts[0].split('.').map(int.parse).toList();
    if (octets.length != 4) return;
    final prefix = int.parse(parts[1]);
    if (prefix < 16 || prefix > 32) return;

    final hostBits = 32 - prefix;
    final count = 1 << hostBits;
    final base =
        (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3];
    final mask = (~0 << hostBits) & 0xFFFFFFFF;
    final network = base & mask;
    for (var i = 0; i < count; i++) {
      final addr = network | i;
      yield '${(addr >> 24) & 0xFF}.${(addr >> 16) & 0xFF}.${(addr >> 8) & 0xFF}.${addr & 0xFF}';
    }
  }
}
