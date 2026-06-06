import 'package:deckhand_ui/src/widgets/progress_run_workspace.dart';
import 'package:flutter_test/flutter_test.dart';

// The bespoke `WizardLogView` widget was deleted in the forge migration;
// its rendering is now handled by forge's `ClLogView` (exercised through
// progress_run_workspace_test.dart). The session-log clipboard formatter
// moved to progress_run_workspace.dart and keeps its own coverage here.
void main() {
  test('clipboard log uses visible fixed-width separators', () {
    final text = formatWizardLogForClipboard([
      '> starting choose_os_image',
      '[ok] choose_os_image',
    ], WizardLogMode.user);

    expect(text, startsWith('Deckhand session log (standard)'));
    expect(
      text,
      contains('---------  ------  ----------------------------------------'),
    );
    expect(text, contains('00:00.000  STEP    Choose the OS image'));
    expect(text, contains('00:01.017  OK      Finished Choose the OS image'));
    expect(text, isNot(contains('\t')));
  });

  test('clipboard log wraps long messages with continuation rows', () {
    final text = formatWizardLogForClipboard([
      '[fail] flash_disk - StepExecutionException: prepare target: lock volume \\\\?\\Volume{81442efe-49a7-11f1-bd05-4c23380248b8}\\ after dismounting busy filesystem: Access is denied.',
    ], WizardLogMode.user);

    final body = text.split('\n').skip(3).toList();

    expect(body.first, startsWith('00:00.000  FAIL    '));
    expect(body.skip(1), isNotEmpty);
    expect(body.skip(1).every((line) => line.startsWith(' ' * 19)), isTrue);
    expect(body.every((line) => line.length <= 115), isTrue);
    expect(text, isNot(contains('\t')));
  });
}
