import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('progress fractions', () {
    test('OS download progress clamps malformed counters', () {
      expect(
        const OsDownloadProgress(
          bytesDone: 150,
          bytesTotal: 100,
          phase: OsDownloadPhase.downloading,
        ).fraction,
        1,
      );
      expect(
        const OsDownloadProgress(
          bytesDone: -5,
          bytesTotal: 100,
          phase: OsDownloadPhase.extracting,
        ).fraction,
        0,
      );
      expect(
        const OsDownloadProgress(
          bytesDone: 5,
          bytesTotal: 0,
          phase: OsDownloadPhase.downloading,
        ).fraction,
        0,
      );
    });

    test('flash progress clamps malformed counters', () {
      expect(
        const FlashProgress(
          bytesDone: 150,
          bytesTotal: 100,
          phase: FlashPhase.writing,
        ).fraction,
        1,
      );
      expect(
        const FlashProgress(
          bytesDone: -5,
          bytesTotal: 100,
          phase: FlashPhase.verifying,
        ).fraction,
        0,
      );
      expect(
        const FlashProgress(
          bytesDone: 5,
          bytesTotal: 0,
          phase: FlashPhase.writing,
        ).fraction,
        0,
      );
    });
  });
}
