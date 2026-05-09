String? jsonString(Object? value) => value is String ? value : null;

int? jsonInt(Object? value) => value is int ? value : null;

List<String> jsonStringList(Object? value) {
  if (value is! Iterable) return const [];
  return value.whereType<String>().where((s) => s.isNotEmpty).toList();
}

Map<String, dynamic>? jsonStringKeyMap(Object? value) {
  if (value is! Map) return null;
  final out = <String, dynamic>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is String) {
      out[key] = entry.value;
    }
  }
  return out;
}

List<Map<String, dynamic>> jsonStringKeyMapList(Object? value) {
  if (value is! Iterable) return const [];
  return value.map(jsonStringKeyMap).whereType<Map<String, dynamic>>().toList();
}
