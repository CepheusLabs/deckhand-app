import 'package:deckhand_flash/deckhand_flash.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SidecarFlashService', () {
    test('parses interrupted flash metadata from disks.list', () async {
      final service = SidecarFlashService(
        const _FakeConnection({
          'disks': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'PhysicalDrive3',
              'path': r'\\.\PhysicalDrive3',
              'size_bytes': 7818182656,
              'bus': 'USB',
              'model': 'Generic STORAGE DEVICE',
              'removable': true,
              'partitions': <Map<String, dynamic>>[],
              'interrupted_flash': <String, dynamic>{
                'started_at': '2026-05-04T14:30:00Z',
                'image_path': r'C:\Deckhand\images\arco.img',
                'image_sha256':
                    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              },
            },
          ],
        }),
      );

      final disks = await service.listDisks();

      expect(disks, hasLength(1));
      final interrupted = disks.single.interruptedFlash;
      expect(interrupted, isNotNull);
      expect(interrupted!.startedAt, DateTime.utc(2026, 5, 4, 14, 30));
      expect(interrupted.imagePath, r'C:\Deckhand\images\arco.img');
      expect(
        interrupted.imageSha256,
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
    });

    test('ignores malformed interrupted flash metadata', () async {
      final service = SidecarFlashService(
        const _FakeConnection({
          'disks': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'PhysicalDrive3',
              'path': r'\\.\PhysicalDrive3',
              'size_bytes': 7818182656,
              'bus': 'USB',
              'model': 'Generic STORAGE DEVICE',
              'removable': true,
              'partitions': <Map<String, dynamic>>[],
              'interrupted_flash': <String, dynamic>{
                'started_at': 'not a date',
              },
            },
          ],
        }),
      );

      final disks = await service.listDisks();

      expect(disks.single.interruptedFlash, isNull);
    });
  });
}

class _FakeConnection implements SidecarConnection {
  const _FakeConnection(this.response);

  final Map<String, dynamic> response;

  @override
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params,
  ) async {
    expect(method, 'disks.list');
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
