import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:deckhand_core/deckhand_core.dart';

import 'cidr.dart' as cidr_util;

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

  /// Maximum concurrent TCP probes during a CIDR scan. 64 is
  /// comfortably below typical per-process socket limits (~1024 on
  /// macOS/Linux by default) while still finishing a /24 scan in a
  /// few seconds over LAN.
  static const int _scanConcurrency = 64;

  @override
  Future<List<DiscoveredPrinter>> scanCidr({
    required String cidr,
    int port = 7125,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final ips = _expandCidr(cidr).toList();
    if (ips.isEmpty) return const [];
    // A /16 would be 65_536 concurrent Socket.connect calls with the
    // old implementation, which exhausted file descriptors on
    // default-limit systems. Chunk through with a small pool instead.
    final hits = <DiscoveredPrinter>[];
    for (var i = 0; i < ips.length; i += _scanConcurrency) {
      final end = (i + _scanConcurrency).clamp(0, ips.length);
      final chunk = ips.sublist(i, end);
      final results = await Future.wait(
        chunk.map((ip) async {
          try {
            final sock = await Socket.connect(ip, port, timeout: timeout);
            sock.destroy();
            return DiscoveredPrinter(
              host: ip,
              hostname: ip,
              port: port,
              service: 'moonraker?',
            );
          } catch (_) {
            return null;
          }
        }),
      );
      hits.addAll(results.whereType<DiscoveredPrinter>());
    }
    return hits;
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
        final sock = await Socket.connect(
          host,
          port,
          timeout: const Duration(seconds: 3),
        );
        sock.destroy();
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    return false;
  }

  Iterable<String> _expandCidr(String cidr) sync* {
    final slash = cidr.indexOf('/');
    if (slash < 0) {
      yield cidr;
      return;
    }
    final prefix = int.tryParse(cidr.substring(slash + 1));
    if (prefix == null) return;
    // Cap at /22 (1024 hosts). A /16 scan would enumerate 65k hosts,
    // which is both useless on a home LAN and guaranteed to exhaust
    // OS socket/descriptor limits even with concurrency throttled.
    // Users who truly need to sweep large networks should narrow the
    // CIDR before calling this API.
    if (prefix < 22 || prefix > 32) return;
    try {
      yield* cidr_util.expandCidr(cidr);
    } on FormatException {
      return;
    }
  }
}
