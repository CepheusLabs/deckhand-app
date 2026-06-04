import 'package:yaml/yaml.dart';

import '../models/printer_profile.dart';
import 'transport_capabilities.dart';

PrinterProfile parseDeckhandWebProfileYaml(String yamlText) {
  final yaml = _loadYaml(yamlText, 'profile.yaml');
  if (yaml is! YamlMap) {
    throw const ProfileFormatException('profile.yaml root must be a mapping');
  }
  final raw = _deepConvert(yaml) as Map<String, dynamic>;
  if (!raw.containsKey('schema_version')) {
    throw const ProfileFormatException(
      'profile.yaml is missing required field `schema_version`',
    );
  }
  final profileId = raw['profile_id'];
  if (profileId is! String || profileId.trim().isEmpty) {
    throw const ProfileFormatException(
      'profile.yaml is missing required field `profile_id`',
    );
  }
  try {
    return PrinterProfile.fromJson(raw);
  } on ProfileFormatException {
    rethrow;
  } catch (error) {
    throw ProfileFormatException('profile.yaml has invalid structure: $error');
  }
}

class DeckhandWebProfileFlow {
  const DeckhandWebProfileFlow({
    required this.id,
    required this.label,
    required this.spec,
  });

  final String id;
  final String label;
  final FlowSpec spec;

  List<Map<String, dynamic>> get steps => spec.steps;
}

class DeckhandWebStepPlan {
  const DeckhandWebStepPlan({required this.step, required this.gate});

  final Map<String, dynamic> step;
  final DeckhandStepTransportGate gate;

  String get id => _nonEmpty(step['id']) ?? kind;

  String get kind => _nonEmpty(step['kind']) ?? 'step';

  String get label => _nonEmpty(step['display_name']) ?? _humanize(kind);

  bool get runnableInBrowser => gate.surface == DeckhandExecutionSurface.browser;

  bool get requiresNativeFallback => gate.requiresNativeFallback;
}

List<DeckhandWebProfileFlow> deckhandWebFlowsForProfile(
  PrinterProfile profile,
) {
  final flows = <DeckhandWebProfileFlow>[];
  final stockKeep = profile.flows.stockKeep;
  if (stockKeep != null && stockKeep.enabled) {
    flows.add(
      DeckhandWebProfileFlow(
        id: 'stock_keep',
        label: 'Keep Stock OS',
        spec: stockKeep,
      ),
    );
  }
  final freshFlash = profile.flows.freshFlash;
  if (freshFlash != null && freshFlash.enabled) {
    flows.add(
      DeckhandWebProfileFlow(
        id: 'fresh_flash',
        label: 'Fresh Flash',
        spec: freshFlash,
      ),
    );
  }
  return List.unmodifiable(flows);
}

DeckhandWebProfileFlow? deckhandWebFlowById(
  PrinterProfile profile,
  String flowId,
) {
  for (final flow in deckhandWebFlowsForProfile(profile)) {
    if (flow.id == flowId) {
      return flow;
    }
  }
  return null;
}

List<DeckhandWebStepPlan> planDeckhandWebFlow({
  required PrinterProfile profile,
  required String flowId,
  required DeckhandTransportAvailability availability,
}) {
  final flow = deckhandWebFlowById(profile, flowId);
  if (flow == null) {
    return const [];
  }
  return List.unmodifiable([
    for (final step in flow.steps)
      DeckhandWebStepPlan(
        step: step,
        gate: gateDeckhandStepTransport(
          step: step,
          availability: availability,
        ),
      ),
  ]);
}

Uri? firmwareUriForDeckhandStep(
  Map<String, dynamic> step, {
  Uri? baseUri,
}) {
  final candidates = <Object?>[
    step['firmware_url'],
    step['firmwareUrl'],
    _nested(step, 'firmware', 'url'),
    _nested(step, 'asset', 'url'),
    _nested(step, 'download', 'url'),
  ];
  for (final candidate in candidates) {
    final text = _nonEmpty(candidate);
    if (text == null) {
      continue;
    }
    final parsed = Uri.tryParse(text);
    if (parsed == null) {
      continue;
    }
    if (parsed.hasScheme) {
      return parsed;
    }
    if (baseUri != null) {
      return baseUri.resolveUri(parsed);
    }
  }
  return null;
}

String? firmwareFileNameForDeckhandStep(Map<String, dynamic> step) {
  return _nonEmpty(step['firmware_file_name']) ??
      _nonEmpty(step['file_name']) ??
      _nonEmpty(_nested(step, 'firmware', 'file_name')) ??
      _nonEmpty(_nested(step, 'asset', 'file_name')) ??
      _nonEmpty(_nested(step, 'download', 'file_name'));
}

Object? _loadYaml(String yamlText, String label) {
  try {
    return loadYaml(yamlText);
  } catch (error) {
    throw ProfileFormatException('$label is not valid YAML: $error');
  }
}

Object? _deepConvert(Object? node) {
  if (node is YamlMap) {
    final out = <String, dynamic>{};
    for (final entry in node.entries) {
      final key = entry.key;
      if (key is! String) {
        throw const ProfileFormatException(
          'profile.yaml mapping keys must be strings',
        );
      }
      out[key] = _deepConvert(entry.value);
    }
    return out;
  }
  if (node is YamlList) {
    return node.map(_deepConvert).toList();
  }
  return node;
}

Object? _nested(Map<String, dynamic> map, String first, String second) {
  final child = map[first];
  if (child is Map) {
    return child[second];
  }
  return null;
}

String? _nonEmpty(Object? value) {
  if (value is! String) {
    return null;
  }
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String _humanize(String value) {
  final words = value
      .replaceAll('-', '_')
      .split('_')
      .where((word) => word.isNotEmpty)
      .toList();
  if (words.isEmpty) {
    return 'Step';
  }
  return [
    for (final word in words)
      '${word[0].toUpperCase()}${word.length == 1 ? '' : word.substring(1)}',
  ].join(' ');
}
