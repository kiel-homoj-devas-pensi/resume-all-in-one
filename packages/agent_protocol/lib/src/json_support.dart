import 'dart:collection';

typedef JsonObject = Map<String, Object?>;

final class AgentProtocolFormatException implements FormatException {
  const AgentProtocolFormatException(this.path, this.message);

  final String path;

  @override
  final String message;

  @override
  int? get offset => null;

  @override
  String? get source => null;

  @override
  String toString() => 'AgentProtocolFormatException($path): $message';
}

Never protocolError(String path, String message) {
  throw AgentProtocolFormatException(path, message);
}

Object? freezeProtocolJson(Object? value, [String path = r'$']) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is List<Object?>) {
    return List<Object?>.unmodifiable(
      value.indexed.map(
        (entry) => freezeProtocolJson(entry.$2, '$path/${entry.$1}'),
      ),
    );
  }
  if (value is Map<String, Object?>) {
    return UnmodifiableMapView<String, Object?>({
      for (final entry in value.entries)
        entry.key: freezeProtocolJson(entry.value, '$path/${entry.key}'),
    });
  }
  protocolError(path, '只允许 JSON 值');
}

JsonObject freezeProtocolObject(JsonObject value, [String path = r'$']) {
  return freezeProtocolJson(value, path)! as JsonObject;
}

Object? deepCopyProtocolJson(Object? value) {
  if (value is List<Object?>) {
    return value.map(deepCopyProtocolJson).toList();
  }
  if (value is Map<String, Object?>) {
    return {
      for (final entry in value.entries)
        entry.key: deepCopyProtocolJson(entry.value),
    };
  }
  return value;
}

void requireProtocolFields(
  JsonObject json,
  String path, {
  required Set<String> required,
  Set<String> optional = const {},
}) {
  final allowed = {...required, ...optional};
  for (final key in required) {
    if (!json.containsKey(key)) {
      protocolError(path, '缺少字段：$key');
    }
  }
  for (final key in json.keys) {
    if (!allowed.contains(key)) {
      protocolError('$path/$key', '未声明字段');
    }
  }
}

String readProtocolString(
  Object? value,
  String path, {
  bool allowEmpty = false,
}) {
  if (value is! String) {
    protocolError(path, '必须是字符串');
  }
  if (!allowEmpty && value.trim().isEmpty) {
    protocolError(path, '不能为空');
  }
  return value;
}

String? readOptionalProtocolString(Object? value, String path) {
  if (value == null) {
    return null;
  }
  return readProtocolString(value, path);
}

bool readProtocolBool(Object? value, String path) {
  if (value is! bool) {
    protocolError(path, '必须是布尔值');
  }
  return value;
}

int readProtocolInt(Object? value, String path) {
  if (value is! int) {
    protocolError(path, '必须是整数');
  }
  return value;
}

JsonObject readProtocolObject(Object? value, String path) {
  if (value is! Map<String, Object?>) {
    protocolError(path, '必须是对象');
  }
  return value;
}

List<Object?> readProtocolList(Object? value, String path) {
  if (value is! List<Object?>) {
    protocolError(path, '必须是数组');
  }
  return value;
}

List<String> readProtocolStringList(Object? value, String path) {
  final source = readProtocolList(value, path);
  return List<String>.unmodifiable(
    source.indexed.map(
      (entry) => readProtocolString(entry.$2, '$path/${entry.$1}'),
    ),
  );
}

DateTime readProtocolTimestamp(Object? value, String path) {
  final source = readProtocolString(value, path);
  final parsed = DateTime.tryParse(source);
  if (parsed == null ||
      !(source.endsWith('Z') || RegExp(r'[+-]\d{2}:\d{2}$').hasMatch(source))) {
    protocolError(path, '必须是带时区的 ISO-8601 时间');
  }
  return parsed.toUtc();
}

T readProtocolEnum<T extends Enum>(Object? value, String path, List<T> values) {
  final name = readProtocolString(value, path);
  for (final candidate in values) {
    if (candidate.name == name) {
      return candidate;
    }
  }
  protocolError(path, '未知枚举值：$name');
}
