import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('hostFromUrl', () {
    test('https URL -> host', () {
      expect(hostFromUrl('https://github.com/CepheusLabs/deckhand'),
          'github.com');
    });
    test('http URL with port -> host (port stripped)', () {
      expect(hostFromUrl('http://example.com:8080/path'), 'example.com');
    });
    test('mixed-case host is lowercased', () {
      expect(hostFromUrl('HTTPS://GitHub.COM/x'), 'github.com');
    });
    test('garbage URL -> null', () {
      expect(hostFromUrl('not a url'), isNull);
    });
    test('URL with no host (e.g. relative) -> null', () {
      expect(hostFromUrl('/path/only'), isNull);
    });
  });

  group('requireHostApproved', () {
    test('approved host -> resolves', () async {
      final s = _StubSecurity({'github.com'});
      await requireHostApproved(s, 'https://github.com/foo');
    });
    test('unapproved host -> HostNotApprovedException', () async {
      final s = _StubSecurity({'github.com'});
      expect(
        () => requireHostApproved(s, 'https://armbian.com/img.xz'),
        throwsA(isA<HostNotApprovedException>()
            .having((e) => e.host, 'host', 'armbian.com')),
      );
    });
    test('unparseable URL -> HostNotApprovedException with the raw url',
        () async {
      final s = _StubSecurity({});
      expect(
        () => requireHostApproved(s, 'not a url'),
        throwsA(isA<HostNotApprovedException>()
            .having((e) => e.host, 'host', 'not a url')),
      );
    });
  });
}

class _StubSecurity implements SecurityService {
  _StubSecurity(this.allowed);
  final Set<String> allowed;

  @override
  Future<bool> isHostAllowed(String host) async => allowed.contains(host);

  @override
  Future<Map<String, bool>> requestHostApprovals(List<String> hosts) async =>
      {for (final h in hosts) h: allowed.contains(h)};

  @override
  Future<ConfirmationToken> issueConfirmationToken({
    required String operation,
    required String target,
    Duration ttl = const Duration(seconds: 60),
  }) async => throw UnimplementedError();

  @override
  bool consumeToken(String value, String operation) => true;

  @override
  Future<void> approveHost(String host) async {}

  @override
  Future<void> revokeHost(String host) async {}

  @override
  Future<void> pinHostFingerprint({
    required String host, required String fingerprint,
  }) async {}

  @override
  Future<String?> pinnedHostFingerprint(String host) async => null;

  @override
  Future<void> forgetHostFingerprint(String host) async {}

  @override
  Future<Map<String, String>> listPinnedFingerprints() async => const {};

  @override
  Future<List<String>> listApprovedHosts() async => allowed.toList()..sort();

  @override
  Future<String?> getGitHubToken() async => null;

  @override
  Future<void> setGitHubToken(String? token) async {}

  @override
  Stream<EgressEvent> get egressEvents => const Stream.empty();

  @override
  void recordEgress(EgressEvent event) {}
}
