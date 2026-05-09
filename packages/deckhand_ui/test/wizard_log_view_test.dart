import 'package:deckhand_ui/src/widgets/wizard_log_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  testWidgets('renders friendly wrapped log messages by default', (
    tester,
  ) async {
    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');

    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: const WizardLogView(
          lines: [
            '> starting choose_os_image',
            '[os] preparing https://github.com/armbian/community/releases/download/26.2.0-trunk.821/Armbian_community_26.2.0-trunk.821_Mkspi_trixie_current_6.18.26_minimal.img.xz -> C:/Users/test/AppData/Local/Deckhand/os-images/armbian-trixie-minimal.img',
            '[flash] writing C:/Users/test/AppData/Local/Deckhand/os-images/armbian-trixie-minimal.img -> Generic STORAGE DEVICE (verify=true)',
            '[run-state] skipping install_stack; already completed',
            '[input] using existing decision: armbian-trixie-minimal',
          ],
        ),
      ),
    );

    expect(find.text('STEP'), findsOneWidget);
    expect(find.text('OS'), findsOneWidget);
    expect(find.text('FLASH'), findsOneWidget);
    expect(find.textContaining('Choose the OS image'), findsOneWidget);
    expect(
      find.textContaining('Preparing the OS image download'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Writing the OS image to Generic STORAGE DEVICE'),
      findsOneWidget,
    );
    expect(find.textContaining('using existing decision'), findsNothing);
    final message = tester.widget<Text>(
      find.textContaining('Preparing the OS image download'),
    );
    expect(message.softWrap, isTrue);
    expect(message.overflow, TextOverflow.visible);
  });

  testWidgets('can render raw developer log strings', (tester) async {
    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');

    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: const WizardLogView(
          mode: WizardLogMode.developer,
          lines: [
            '> starting choose_target_disk',
            '[input] using existing decision: armbian-trixie-minimal',
          ],
        ),
      ),
    );

    expect(find.textContaining('starting choose_target_disk'), findsOneWidget);
    expect(
      find.textContaining('using existing decision: armbian-trixie-minimal'),
      findsOneWidget,
    );
  });

  testWidgets('user log hides raw Windows disk identifiers', (tester) async {
    final controller = stubWizardController(profileJson: testProfileJson());
    await controller.loadProfile('test-printer');

    await tester.pumpWidget(
      testHarness(
        controller: controller,
        child: const WizardLogView(
          lines: [
            '[input] using existing decision: PhysicalDrive3',
            '[flash] writing C:/Deckhand/os.img -> PhysicalDrive3 (verify=true)',
            r'[fail] flash_disk - StepExecutionException: write \\.\PHYSICALDRIVE3: The parameter is incorrect.',
          ],
        ),
      ),
    );

    expect(find.textContaining('Windows disk 3'), findsWidgets);
    expect(find.textContaining('PhysicalDrive3'), findsNothing);
    expect(find.textContaining('PHYSICALDRIVE3'), findsNothing);
    expect(find.textContaining('StepExecutionException'), findsNothing);
    expect(
      find.textContaining('Windows rejected the raw disk write'),
      findsOneWidget,
    );
  });

  test('clipboard log uses visible fixed-width separators', () {
    final text = formatWizardLogForClipboard([
      '> starting choose_os_image',
      '[ok] choose_os_image',
    ], WizardLogMode.user);

    expect(text, contains('00:00.000  STEP    Choose the OS image'));
    expect(text, contains('00:01.017  OK      Finished Choose the OS image'));
    expect(text, isNot(contains('\t')));
  });
}
