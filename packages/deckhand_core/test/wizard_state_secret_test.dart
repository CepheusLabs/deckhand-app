import 'dart:convert';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isSecretDecisionKey', () {
    test('matches password / passphrase decision keys by final segment', () {
      expect(isSecretDecisionKey('first_boot.password'), isTrue);
      expect(isSecretDecisionKey('hardening.new_password'), isTrue);
      expect(isSecretDecisionKey('wifi.passphrase'), isTrue);
      expect(isSecretDecisionKey('password'), isTrue);
      expect(isSecretDecisionKey('vault.secret'), isTrue);
    });

    test('does not match ordinary decision keys', () {
      expect(isSecretDecisionKey('firmware'), isFalse);
      expect(isSecretDecisionKey('hardening.disable_makerbase_udp'), isFalse);
      expect(isSecretDecisionKey('first_boot.username'), isFalse);
      expect(isSecretDecisionKey('snapshot.paths'), isFalse);
    });
  });

  group('WizardState.toJson secret stripping', () {
    test('strips secret decisions from the persisted payload', () {
      final state = WizardState(
        profileId: 'sovol_zero',
        decisions: {
          'firmware': 'kalico',
          'first_boot.username': 'mks',
          'first_boot.password': 'hunter2',
          'hardening.new_password': 'correcthorse',
        },
        currentStep: 'review',
        flow: WizardFlow.freshFlash,
      );

      final json = state.toJson();
      final decisions = json['decisions'] as Map<String, dynamic>;

      // Non-secret decisions survive.
      expect(decisions['firmware'], 'kalico');
      expect(decisions['first_boot.username'], 'mks');
      // Secrets are gone.
      expect(decisions.containsKey('first_boot.password'), isFalse);
      expect(decisions.containsKey('hardening.new_password'), isFalse);

      // Belt and suspenders: the serialized string must not contain the
      // plaintext secret anywhere (e.g. nested), enforcing the
      // "no passwords on disk" guarantee end to end.
      final encoded = jsonEncode(json);
      expect(encoded.contains('hunter2'), isFalse);
      expect(encoded.contains('correcthorse'), isFalse);
    });

    test('round-trip drops secrets so resume re-prompts for them', () {
      final state = WizardState(
        profileId: 'sovol_zero',
        decisions: {
          'firmware': 'kalico',
          'first_boot.password': 'hunter2',
        },
        currentStep: 'review',
        flow: WizardFlow.freshFlash,
      );

      final restored = WizardState.fromJson(state.toJson());
      expect(restored.decisions['firmware'], 'kalico');
      expect(restored.decisions.containsKey('first_boot.password'), isFalse);
    });

    test('in-memory decisions are untouched by serialization', () {
      final state = WizardState(
        profileId: 'sovol_zero',
        decisions: {'first_boot.password': 'hunter2'},
        currentStep: 'review',
        flow: WizardFlow.freshFlash,
      );

      // The install step interpolates from the live map, so toJson must
      // not mutate it.
      state.toJson();
      expect(state.decisions['first_boot.password'], 'hunter2');
    });
  });
}
