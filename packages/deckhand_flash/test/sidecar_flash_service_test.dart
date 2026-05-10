import 'package:deckhand_core/deckhand_core.dart';
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
              'is_boot': true,
              'is_system': true,
              'is_read_only': true,
              'is_offline': true,
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
      expect(disks.single.isBoot, isTrue);
      expect(disks.single.isSystem, isTrue);
      expect(disks.single.isReadOnly, isTrue);
      expect(disks.single.isOffline, isTrue);
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

    test('skips malformed disk and partition rows', () async {
      final service = SidecarFlashService(
        const _FakeConnection({
          'disks': <Object?>[
            'bad row',
            <String, dynamic>{
              'id': 'missing-size',
              'path': r'\\.\PhysicalDrive4',
            },
            <String, dynamic>{
              'id': 'PhysicalDrive3',
              'path': r'\\.\PhysicalDrive3',
              'size_bytes': 7818182656,
              'partitions': <Object?>[
                'bad partition',
                <String, dynamic>{'index': 'not numeric'},
                <String, dynamic>{
                  'index': 1,
                  'filesystem': 'FAT32',
                  'size_bytes': 1024,
                },
              ],
            },
          ],
        }),
      );

      final disks = await service.listDisks();

      expect(disks, hasLength(1));
      expect(disks.single.id, 'PhysicalDrive3');
      expect(disks.single.partitions, hasLength(1));
      expect(disks.single.partitions.single.filesystem, 'FAT32');
    });

    test('tolerates malformed streaming progress fields', () async {
      final service = SidecarFlashService(
        const _FakeConnection(
          {},
          streamEvents: [
            SidecarProgress(
              SidecarNotification(
                method: 'disks.write_image.progress',
                params: {
                  'bytes_done': 'bad',
                  'bytes_total': 'bad',
                  'phase': 42,
                  'message': 99,
                },
              ),
            ),
            SidecarResult({'bytes': 'bad', 'sha256': 99}),
          ],
        ),
      );

      final events = await service
          .writeImage(
            imagePath: r'C:\image.img',
            diskId: 'PhysicalDrive3',
            confirmationToken: 'confirmed',
          )
          .toList();

      expect(events, hasLength(2));
      expect(events.first.bytesDone, 0);
      expect(events.first.bytesTotal, 0);
      expect(events.first.phase, FlashPhase.preparing);
      expect(events.first.message, isNull);
      expect(events.last.phase, FlashPhase.done);
      expect(events.last.message, isNull);
    });
  });
}

class _FakeConnection implements SidecarConnection {
  const _FakeConnection(this.response, {this.streamEvents = const []});

  final Map<String, dynamic> response;
  final List<SidecarEvent> streamEvents;

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
  ) => Stream.fromIterable(streamEvents);

  @override
  Stream<SidecarNotification> get notifications => const Stream.empty();

  @override
  Stream<SidecarNotification> subscribeToOperation(String operationId) =>
      const Stream.empty();

  @override
  Future<void> shutdown() async {}
}
