import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/screens/pick_printer_screen.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('PickPrinterScreen', () {
    testWidgets('renders without crashing', (tester) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const PickPrinterScreen(),
          initialLocation: '/pick-printer',
        ),
      );
      // The screen fetches the registry asynchronously; pump a few
      // frames instead of pumpAndSettle (which would block on the
      // stub's `never completes` futures).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Whatever state the screen lands in (loading, empty list,
      // error), the U+2192 right-arrow glyph must NOT appear. That
      // was a Phase 8 correctness fix; this test keeps it enforced.
      expect(find.textContaining('\u2192'), findsNothing);
    });

    testWidgets('renders registry hardware specs on printer cards', (
      tester,
    ) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const PickPrinterScreen(),
          initialLocation: '/pick-printer',
          extraOverrides: [
            profileServiceProvider.overrideWithValue(
              const _RegistryProfileService(
                ProfileRegistry(
                  entries: [
                    ProfileRegistryEntry(
                      id: 'test-printer',
                      displayName: 'Test Printer',
                      manufacturer: 'Acme',
                      model: 'Robo',
                      status: 'beta',
                      directory: 'printers/test-printer',
                      sbc: 'RK3328',
                      kinematics: 'CoreXY',
                      mcu: 'STM32F407',
                      extras: 'ChromaKit',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('RK3328'), findsOneWidget);
      expect(find.text('CoreXY'), findsOneWidget);
      expect(find.text('STM32F407'), findsOneWidget);
      expect(find.text('ChromaKit'), findsOneWidget);
    });

    testWidgets('search matches registry hardware spec fields', (
      tester,
    ) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const PickPrinterScreen(),
          initialLocation: '/pick-printer',
          extraOverrides: [
            profileServiceProvider.overrideWithValue(
              const _RegistryProfileService(
                ProfileRegistry(
                  entries: [
                    ProfileRegistryEntry(
                      id: 'test-printer',
                      displayName: 'Test Printer',
                      manufacturer: 'Acme',
                      model: 'Robo',
                      status: 'beta',
                      directory: 'printers/test-printer',
                      sbc: 'RK3328',
                      kinematics: 'CoreXY',
                      mcu: 'STM32F407',
                      extras: 'ChromaKit',
                    ),
                    ProfileRegistryEntry(
                      id: 'other-printer',
                      displayName: 'Other Printer',
                      manufacturer: 'Other',
                      model: 'Bedslinger',
                      status: 'alpha',
                      directory: 'printers/other-printer',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.enterText(find.byType(TextField), ' corexy ');
      await tester.pump();

      expect(find.text('Test Printer'), findsOneWidget);
      expect(find.text('Other Printer'), findsNothing);
    });

    testWidgets('renders useful fallback facts for sparse registry cards', (
      tester,
    ) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const PickPrinterScreen(),
          initialLocation: '/pick-printer',
          extraOverrides: [
            profileServiceProvider.overrideWithValue(
              const _RegistryProfileService(
                ProfileRegistry(
                  entries: [
                    ProfileRegistryEntry(
                      id: 'test-printer',
                      displayName: 'Test Printer',
                      manufacturer: 'Acme',
                      model: 'Robo',
                      status: 'beta',
                      directory: 'printers/test-printer',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('MODEL'), findsOneWidget);
      expect(find.text('Robo'), findsOneWidget);
      expect(find.text('STATUS'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('PROFILE'), findsOneWidget);
      expect(find.text('test-printer'), findsNWidgets(2));
      expect(find.text('REF'), findsOneWidget);
      expect(find.text('untagged'), findsNWidgets(2));
      expect(find.text('SBC'), findsNothing);
      expect(find.text('—'), findsNothing);
    });

    testWidgets('falls back when core hardware facts are incomplete', (
      tester,
    ) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const PickPrinterScreen(),
          initialLocation: '/pick-printer',
          extraOverrides: [
            profileServiceProvider.overrideWithValue(
              const _RegistryProfileService(
                ProfileRegistry(
                  entries: [
                    ProfileRegistryEntry(
                      id: 'test-printer',
                      displayName: 'Test Printer',
                      manufacturer: 'Acme',
                      model: 'Robo',
                      status: 'beta',
                      directory: 'printers/test-printer',
                      sbc: 'RK3328',
                      extras: 'ChromaKit',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('MODEL'), findsOneWidget);
      expect(find.text('Robo'), findsOneWidget);
      expect(find.text('SBC'), findsNothing);
      expect(find.text('RK3328'), findsNothing);
      expect(find.text('ChromaKit'), findsNothing);
      expect(find.text('—'), findsNothing);
    });

    testWidgets('printer cards expose semantics and keyboard activation', (
      tester,
    ) async {
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const PickPrinterScreen(),
          initialLocation: '/pick-printer',
          extraOverrides: [
            profileServiceProvider.overrideWithValue(
              const _RegistryProfileService(
                ProfileRegistry(
                  entries: [
                    ProfileRegistryEntry(
                      id: 'test-printer',
                      displayName: 'Test Printer',
                      manufacturer: 'Acme',
                      model: 'Robo',
                      status: 'beta',
                      directory: 'printers/test-printer',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final card = find.byKey(const ValueKey('profile-card-test-printer'));
      expect(card, findsOneWidget);
      expect(
        tester.getSemantics(card),
        matchesSemantics(
          label: 'Test Printer printer profile',
          isButton: true,
          hasSelectedState: true,
          hasTapAction: true,
        ),
      );
      semantics.dispose();

      final focusableCard = find.byKey(
        const ValueKey('profile-card-focus-test-printer'),
      );
      expect(focusableCard, findsOneWidget);
      final focusWidget = tester.widget<Focus>(focusableCard);
      focusWidget.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(find.text('Continue with Test Printer'), findsOneWidget);
    });

    testWidgets('search header stays usable in a narrow window', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(360, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const PickPrinterScreen(),
          initialLocation: '/pick-printer',
          extraOverrides: [
            profileServiceProvider.overrideWithValue(
              const _RegistryProfileService(
                ProfileRegistry(
                  entries: [
                    ProfileRegistryEntry(
                      id: 'test-printer',
                      displayName: 'Test Printer',
                      manufacturer: 'Acme',
                      model: 'Robo',
                      status: 'beta',
                      directory: 'printers/test-printer',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(tester.takeException(), isNull);
      expect(find.text('REGISTRY'), findsOneWidget);
      expect(find.text('1 entry'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('approves selected profile network hosts in one prompt', (
      tester,
    ) async {
      final profileJson = {
        ...testProfileJson(
          os: {
            'fresh_install_options': [
              {
                'id': 'debian',
                'display_name': 'Debian',
                'url': 'https://downloads.example.com/debian.img.xz',
                'sha256':
                    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              },
            ],
          },
        ),
        'required_hosts': ['api.github.com', 'github.com'],
      };
      final security = _RecordingSecurity();
      final controller = stubWizardController(
        profileJson: profileJson,
        security: security,
      );
      await controller.loadProfile('test-printer');
      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: const PickPrinterScreen(),
          initialLocation: '/pick-printer',
          extraOverrides: [
            profileServiceProvider.overrideWithValue(
              const _RegistryProfileService(
                ProfileRegistry(
                  entries: [
                    ProfileRegistryEntry(
                      id: 'test-printer',
                      displayName: 'Test Printer',
                      manufacturer: 'Acme',
                      model: 'Robo',
                      status: 'beta',
                      directory: 'printers/test-printer',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Test Printer'));
      await tester.pump();
      await tester.tap(find.text('Continue with Test Printer'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text('Allow profile network access?'), findsOneWidget);
      expect(find.text('api.github.com'), findsOneWidget);
      expect(find.text('downloads.example.com'), findsOneWidget);
      expect(find.text('github.com'), findsOneWidget);
      expect(security.approvedHosts, isEmpty);

      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();

      expect(security.approvedHosts, [
        'api.github.com',
        'downloads.example.com',
        'github.com',
      ]);
    });
  });
}

class _RegistryProfileService implements ProfileService {
  const _RegistryProfileService(this.registry);

  final ProfileRegistry registry;

  @override
  Future<ProfileRegistry> fetchRegistry({bool force = false}) async => registry;

  @override
  Future<ProfileCacheEntry> ensureCached({
    required String profileId,
    String? ref,
    bool force = false,
  }) async => ProfileCacheEntry(
    profileId: profileId,
    ref: ref ?? 'main',
    localPath: '.',
    resolvedSha: '',
  );

  @override
  Future<PrinterProfile> load(ProfileCacheEntry cacheEntry) async =>
      PrinterProfile.fromJson(testProfileJson());
}

class _RecordingSecurity implements SecurityService {
  final approvedHosts = <String>[];

  @override
  Future<void> approveHost(String host) async => approvedHosts.add(host);

  @override
  Future<bool> isHostAllowed(String host) async => approvedHosts.contains(host);

  @override
  Future<Map<String, bool>> requestHostApprovals(List<String> hosts) async => {
    for (final host in hosts) host: approvedHosts.contains(host),
  };

  @override
  Future<ConfirmationToken> issueConfirmationToken({
    required String operation,
    required String target,
    Duration ttl = const Duration(seconds: 60),
  }) async => ConfirmationToken(
    value: 'test-token-0123456789abcdef',
    expiresAt: DateTime.now().add(ttl),
    operation: operation,
    target: target,
  );

  @override
  bool consumeToken(String value, String operation, {required String target}) =>
      true;

  @override
  Future<void> revokeHost(String host) async => approvedHosts.remove(host);

  @override
  Future<List<String>> listApprovedHosts() async => approvedHosts.toList();

  @override
  Future<void> pinHostFingerprint({
    required String host,
    required String fingerprint,
  }) async {}

  @override
  Future<String?> pinnedHostFingerprint(String host) async => null;

  @override
  Future<void> forgetHostFingerprint(String host) async {}

  @override
  Future<Map<String, String>> listPinnedFingerprints() async => const {};

  @override
  Future<String?> getGitHubToken() async => null;

  @override
  Future<void> setGitHubToken(String? token) async {}

  @override
  Stream<EgressEvent> get egressEvents => const Stream.empty();

  @override
  void recordEgress(EgressEvent event) {}
}
