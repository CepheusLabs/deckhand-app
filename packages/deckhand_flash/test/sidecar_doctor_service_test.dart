import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_flash/src/sidecar_client.dart';
import 'package:deckhand_flash/src/sidecar_doctor_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SidecarDoctorService', () {
    test('decodes sidecar doctor results', () async {
      final service = SidecarDoctorService(
        sidecar: _FakeSidecar({
          'passed': true,
          'report': '[PASS] runtime ok',
          'results': [
            {'name': 'runtime', 'status': 'pass', 'detail': 'ok'},
          ],
        }),
      );

      final report = await service.run();

      expect(report.passed, isTrue);
      expect(report.report, '[PASS] runtime ok');
      expect(report.results.single.name, 'runtime');
      expect(report.results.single.status, DoctorStatus.pass);
      expect(report.results.single.detail, 'ok');
    });

    test('drops malformed doctor fields instead of crashing', () async {
      final service = SidecarDoctorService(
        sidecar: _FakeSidecar({
          'passed': 'yes',
          'report': ['not', 'a', 'string'],
          'results': [
            {'name': 'runtime', 'status': 7, 'detail': false},
            'not a map',
            {
              1: 'bad key',
              'name': 'github_rate_limit',
              'status': 'warn',
              'detail': 'low remaining requests',
            },
          ],
        }),
      );

      final report = await service.run();

      expect(report.passed, isFalse);
      expect(report.report, '');
      expect(report.results, hasLength(2));
      expect(report.results.first.name, 'runtime');
      expect(report.results.first.status, DoctorStatus.unknown);
      expect(report.results.first.detail, '');
      expect(report.results.last.name, 'github_rate_limit');
      expect(report.results.last.status, DoctorStatus.warn);
      expect(report.results.last.detail, 'low remaining requests');
    });
  });
}

class _FakeSidecar implements SidecarConnection {
  _FakeSidecar(this.response);

  final Map<String, dynamic> response;

  @override
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params,
  ) async {
    expect(method, 'doctor.run');
    expect(params, isEmpty);
    return response;
  }

  @override
  Stream<SidecarEvent> callStreaming(
    String method,
    Map<String, dynamic> params,
  ) => const Stream.empty();

  @override
  Stream<SidecarNotification> get notifications => const Stream.empty();

  @override
  Stream<SidecarNotification> subscribeToOperation(String operationId) =>
      const Stream.empty();

  @override
  Future<void> shutdown() async {}
}
