import 'dart:convert';

typedef JsonMap = Map<String, Object?>;

final class SchemaFormatException implements FormatException {
  SchemaFormatException(this.message, {this.path = r'$'});

  @override
  final String message;

  final String path;

  @override
  int? get offset => null;

  @override
  Object? get source => null;

  @override
  String toString() => 'SchemaFormatException($path): $message';
}

Never schemaError(String path, String message) {
  throw SchemaFormatException(message, path: path);
}

JsonMap expectMap(Object? value, String path) {
  if (value is! Map<String, Object?>) {
    schemaError(path, '必须是 JSON object');
  }
  return value;
}

List<Object?> expectList(Object? value, String path) {
  if (value is! List<Object?>) {
    schemaError(path, '必须是 JSON array');
  }
  return value;
}

String expectString(Object? value, String path) {
  if (value is! String) {
    schemaError(path, '必须是 string');
  }
  return value;
}

String? optionalString(Object? value, String path) {
  if (value == null) {
    return null;
  }
  return expectString(value, path);
}

int expectInt(Object? value, String path) {
  if (value is! int) {
    schemaError(path, '必须是 integer');
  }
  return value;
}

bool expectBool(Object? value, String path) {
  if (value is! bool) {
    schemaError(path, '必须是 boolean');
  }
  return value;
}

DateTime expectTimestamp(Object? value, String path) {
  final text = expectString(value, path);
  final hasTimeZone =
      text.endsWith('Z') || RegExp(r'[+-]\d{2}:\d{2}$').hasMatch(text);
  if (!hasTimeZone) {
    schemaError(path, '必须是包含时区的 ISO-8601 时间');
  }
  final parsed = DateTime.tryParse(text);
  if (parsed == null) {
    schemaError(path, '不是有效的 ISO-8601 时间');
  }
  // DateTime.tryParse 会把 2 月 31 日、24 时或溢出的偏移归一化，
  // 不能让这种修复改变不可变版本的原始时间。按原始日历分量复核。
  final parts = RegExp(
    r'^([+-]?\d{4,6})-?(\d{2})-?(\d{2})(?:[ T](\d{2})(?::?(\d{2}))?(?::?(\d{2}))?)?',
  ).firstMatch(text);
  if (parts == null) {
    schemaError(path, '不是有效的 ISO-8601 时间');
  }
  final components = List<int>.generate(
    6,
    (index) => int.parse(parts.group(index + 1) ?? '0'),
  );
  final wallClock = DateTime.utc(
    components[0],
    components[1],
    components[2],
    components[3],
    components[4],
    components[5],
  );
  final normalized = <int>[
    wallClock.year,
    wallClock.month,
    wallClock.day,
    wallClock.hour,
    wallClock.minute,
    wallClock.second,
  ];
  final zone = RegExp(r'[+-](\d{2}):(\d{2})$').firstMatch(text);
  for (var index = 0; index < components.length; index++) {
    if (components[index] != normalized[index]) {
      schemaError(path, '时间包含无效日期或时刻');
    }
  }
  if (zone != null &&
      (int.parse(zone.group(1)!) >= 24 || int.parse(zone.group(2)!) >= 60)) {
    schemaError(path, '时间包含无效时区偏移');
  }
  return parsed;
}

List<String> expectStringList(Object? value, String path) {
  final source = expectList(value, path);
  return List<String>.unmodifiable(
    source.indexed.map((entry) => expectString(entry.$2, '$path/${entry.$1}')),
  );
}

JsonMap unknownFields(JsonMap source, Set<String> knownFields) {
  final result = <String, Object?>{};
  for (final entry in source.entries) {
    if (!knownFields.contains(entry.key)) {
      result[entry.key] = deepFreezeJson(entry.value, r'$.' + entry.key);
    }
  }
  return Map<String, Object?>.unmodifiable(result);
}

JsonMap freezeJsonMap(Map<String, Object?> source) {
  return Map<String, Object?>.unmodifiable(
    source.map(
      (key, value) => MapEntry(key, deepFreezeJson(value, r'$.' + key)),
    ),
  );
}

Object? deepFreezeJson(Object? value, [String path = r'$']) {
  if (value == null || value is String || value is bool || value is num) {
    return value;
  }
  if (value is List<Object?>) {
    return List<Object?>.unmodifiable(
      value.indexed.map(
        (entry) => deepFreezeJson(entry.$2, '$path/${entry.$1}'),
      ),
    );
  }
  if (value is Map<String, Object?>) {
    return freezeJsonMap(value);
  }
  schemaError(path, '包含非 JSON 值 ${value.runtimeType}');
}

Object? deepCopyJson(Object? value) {
  if (value == null || value is String || value is bool || value is num) {
    return value;
  }
  if (value is List<Object?>) {
    return value.map(deepCopyJson).toList();
  }
  if (value is Map<String, Object?>) {
    return value.map((key, item) => MapEntry(key, deepCopyJson(item)));
  }
  schemaError(r'$', '包含非 JSON 值 ${value.runtimeType}');
}

bool jsonDeepEquals(Object? left, Object? right) {
  if (identical(left, right)) {
    return true;
  }
  if (left is List<Object?> && right is List<Object?>) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (!jsonDeepEquals(left[index], right[index])) {
        return false;
      }
    }
    return true;
  }
  if (left is Map<String, Object?> && right is Map<String, Object?>) {
    if (left.length != right.length || !left.keys.every(right.containsKey)) {
      return false;
    }
    return left.entries.every(
      (entry) => jsonDeepEquals(entry.value, right[entry.key]),
    );
  }
  return left == right;
}

JsonMap decodeJsonObject(String source) {
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException catch (error) {
    throw SchemaFormatException('JSON 解析失败：${error.message}');
  }
  return expectMap(decoded, r'$');
}
