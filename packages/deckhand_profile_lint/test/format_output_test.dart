import 'dart:convert';

import 'package:deckhand_profile_lint/deckhand_profile_lint.dart';
import 'package:test/test.dart';

LintReport _sample(LintFormat format) => LintReport([
  LintResult('printers/sovol_zero/profile.yaml', 'sovol_zero', [
    LintFinding(LintSeverity.error, 'flows.0.steps.1', 'missing idempotency'),
    LintFinding(LintSeverity.warning, '', 'stub status'),
  ]),
  LintResult('printers/arco/profile.yaml', 'arco', []),
], strict: false, format: format);

void main() {
  group('JSON output', () {
    test('has tool, summary counts, and findings', () {
      final json = _sample(LintFormat.json).toJson();
      expect(json['tool'], 'deckhand-profile-lint');
      expect(json['summary'], {
        'profiles': 2,
        'errors': 1,
        'warnings': 1,
        'infos': 0,
      });
      final results = json['results'] as List;
      expect(results, hasLength(2));
      final first = results.first as Map<String, dynamic>;
      expect(first['profile_id'], 'sovol_zero');
      final findings = first['findings'] as List;
      expect((findings.first as Map<String, dynamic>)['severity'], 'error');
      // Round-trips as valid JSON.
      expect(jsonDecode(jsonEncode(json)), isA<Map<String, dynamic>>());
    });
  });

  group('SARIF output', () {
    test('is valid SARIF 2.1.0 with mapped levels and locations', () {
      final sarif = _sample(LintFormat.sarif).toSarif();
      expect(sarif[r'$schema'], contains('sarif-2.1.0'));
      expect(sarif['version'], '2.1.0');
      final run = (sarif['runs'] as List).single as Map<String, dynamic>;
      expect(
        ((run['tool'] as Map<String, dynamic>)['driver'] as Map<String, dynamic>)['name'],
        'deckhand-profile-lint',
      );
      final results = run['results'] as List;
      // Two findings (the empty-findings profile contributes none).
      expect(results, hasLength(2));
      final error = results.first as Map<String, dynamic>;
      expect(error['level'], 'error');
      expect((error['message'] as Map<String, dynamic>)['text'], 'missing idempotency');
      final loc = ((error['locations'] as List).first as Map<String, dynamic>);
      final uri =
          (((loc['physicalLocation'] as Map<String, dynamic>)['artifactLocation']) as Map<String, dynamic>)['uri'];
      expect(uri, 'printers/sovol_zero/profile.yaml');
      // warning severity maps to SARIF "warning".
      expect((results[1] as Map<String, dynamic>)['level'], 'warning');
      expect(jsonDecode(jsonEncode(sarif)), isA<Map<String, dynamic>>());
    });

    test('info severity maps to SARIF note', () {
      final report = LintReport([
        LintResult('x.yaml', 'x', [
          LintFinding(LintSeverity.info, '', 'fyi'),
        ]),
      ], strict: false, format: LintFormat.sarif);
      final sarif = report.toSarif();
      final results = (sarif['runs'] as List).single as Map<String, dynamic>;
      expect(((results['results'] as List).first as Map<String, dynamic>)['level'], 'note');
    });
  });
}
