import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_flash/src/process_elevated_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseHelperLineForTesting', () {
    test('empty / whitespace lines produce no event', () {
      expect(parseHelperLineForTesting(''), isNull);
      expect(parseHelperLineForTesting('   '), isNull);
      expect(parseHelperLineForTesting('\t\n'), isNull);
    });

    test('non-JSON lines are dropped silently', () {
      // The helper sometimes emits non-JSON warnings (libtool
      // chatter, sudo prompts on misconfigured rigs). The Windows
      // PowerShell path can also emit "Process started…" headers.
      // Drop them rather than crashing the stream.
      expect(parseHelperLineForTesting('not json'), isNull);
      expect(parseHelperLineForTesting('{partial'), isNull);
      expect(parseHelperLineForTesting('Process started.'), isNull);
    });

    test('preparing event maps to FlashPhase.preparing', () {
      final ev = parseHelperLineForTesting(
        '{"event":"preparing","device":"PhysicalDrive3","image":"x.iso"}',
      );
      expect(ev, isNotNull);
      expect(ev!.phase, FlashPhase.preparing);
      expect(ev.message, 'PhysicalDrive3');
    });

    test('progress writing event carries bytes_done/total', () {
      final ev = parseHelperLineForTesting(
        '{"event":"progress","phase":"writing","bytes_done":1024,"bytes_total":2048}',
      );
      expect(ev!.phase, FlashPhase.writing);
      expect(ev.bytesDone, 1024);
      expect(ev.bytesTotal, 2048);
    });

    test('write-complete and verified phases collapse to verifying', () {
      // Both phases conceptually mean "we finished the write side
      // and are now confirming it". The UI doesn't need to
      // distinguish them; collapsing keeps the progress bar's
      // animation smooth.
      for (final phase in const ['write-complete', 'verifying', 'verified']) {
        final ev = parseHelperLineForTesting(
          '{"event":"progress","phase":"$phase","bytes_done":1,"bytes_total":1}',
        );
        expect(ev!.phase, FlashPhase.verifying, reason: phase);
      }
    });

    test('done event finalises with sha256 in message', () {
      final ev = parseHelperLineForTesting(
        '{"event":"done","bytes":2048,"sha256":"deadbeef"}',
      );
      expect(ev!.phase, FlashPhase.done);
      expect(ev.bytesDone, 2048);
      expect(ev.bytesTotal, 2048);
      expect(ev.message, 'deadbeef');
    });

    test('error event maps to FlashPhase.failed with the message', () {
      final ev = parseHelperLineForTesting(
        '{"event":"error","message":"sha mismatch"}',
      );
      expect(ev!.phase, FlashPhase.failed);
      expect(ev.message, 'sha mismatch');
    });

    test('unknown event types do not crash the stream', () {
      // Forward-compat: a future helper that adds an event type
      // shouldn't break older UIs. The parser drops what it
      // doesn't recognise rather than throwing.
      expect(
        parseHelperLineForTesting('{"event":"future","weird":true}'),
        isNull,
      );
    });

    test('windows-style trailing CRLF is tolerated', () {
      // PowerShell-redirected stdout on NTFS sometimes lands with
      // \r\n line endings; the parser sees the pre-split line
      // (which would normally have \r in it for tail-reads of a
      // partially-flushed file). Trim is implicit via the
      // jsonDecode contract — confirm it.
      final ev = parseHelperLineForTesting(
        '{"event":"done","bytes":4,"sha256":"x"}\r',
      );
      expect(ev, isNotNull);
      expect(ev!.phase, FlashPhase.done);
    });
  });

  group('helper event tails', () {
    test('detects a completed helper even when the process exits nonzero', () {
      const tail =
          '{"event":"started","op":"read-image"}\n'
          '{"event":"done","bytes":4096,"sha256":"deadbeef"}\n';

      expect(helperEventsContainDoneForTesting(tail), isTrue);
      expect(lastHelperErrorMessageForTesting(tail), isNull);
    });

    test('extracts the last helper error message', () {
      const tail =
          '{"event":"progress","phase":"reading","bytes_done":1,"bytes_total":2}\n'
          '{"event":"error","message":"read device after 4096 bytes: bad sector"}\n';

      expect(helperEventsContainDoneForTesting(tail), isFalse);
      expect(
        lastHelperErrorMessageForTesting(tail),
        'read device after 4096 bytes: bad sector',
      );
    });
  });
}
