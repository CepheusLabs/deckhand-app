import 'dart:convert';

import 'package:deckhand/deckhand_product_platform.dart';
import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/deckhand_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registers Deckhand module with the shared product runtime', () async {
    final container = ProviderContainer(
      overrides: [
        doctorServiceProvider.overrideWithValue(_PassingDoctorService()),
        flashServiceProvider.overrideWithValue(_FakeFlashService()),
      ],
    );
    addTearDown(container.dispose);

    final runtime = await container.read(deckhandProductRuntimeProvider.future);
    final capabilityIds = runtime
        .listCapabilities()
        .map((capability) => capability.id)
        .toSet();

    expect(
      capabilityIds,
      containsAll(<String>{'deckhand.host.diagnose', 'deckhand.image.apply'}),
    );
  });

  test('hosts Deckhand module through the shared JSON-RPC protocol', () async {
    final container = ProviderContainer(
      overrides: [
        doctorServiceProvider.overrideWithValue(_PassingDoctorService()),
        flashServiceProvider.overrideWithValue(_FakeFlashService()),
      ],
    );
    addTearDown(container.dispose);

    final server = container.read(deckhandProductModuleServerProvider);
    final response = await server.handleLine(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': 'describe',
        'method': 'module.describe',
      }),
      send: (_) {},
    );
    final decoded = jsonDecode(response!) as Map<String, Object?>;
    final module = (decoded['result'] as Map)['module'] as Map;

    expect(module['id'], 'deckhand');
    expect(
      (module['capabilities'] as List).map((capability) => capability['id']),
      containsAll(<String>{'deckhand.host.diagnose', 'deckhand.image.apply'}),
    );
  });
}

final class _PassingDoctorService implements DoctorService {
  @override
  Future<DoctorReport> run() async {
    return const DoctorReport(
      passed: true,
      results: <DoctorResult>[
        DoctorResult(
          name: 'sidecar',
          status: DoctorStatus.pass,
          detail: 'ready',
        ),
      ],
      report: 'PASS sidecar ready',
    );
  }
}

final class _FakeFlashService implements FlashService {
  @override
  Future<List<DiskInfo>> listDisks() async => const <DiskInfo>[];

  @override
  Stream<FlashProgress> readImage({
    required String diskId,
    required String outputPath,
  }) {
    return const Stream<FlashProgress>.empty();
  }

  @override
  Future<FlashSafetyVerdict> safetyCheck({required String diskId}) async {
    return FlashSafetyVerdict(diskId: diskId, allowed: true);
  }

  @override
  Future<String> sha256(String path) async => '0' * 64;

  @override
  Stream<FlashProgress> writeImage({
    required String imagePath,
    required String diskId,
    required String confirmationToken,
    bool verifyAfterWrite = true,
  }) {
    return const Stream<FlashProgress>.empty();
  }
}
