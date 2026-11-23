import 'json_support.dart';
import 'model.dart';

final class UnsupportedSchemaVersionException implements Exception {
  const UnsupportedSchemaVersionException(this.version);

  final String? version;

  @override
  String toString() =>
      'UnsupportedSchemaVersionException: ${version ?? '缺少 schemaVersion'}';
}

final class ResumeSchemaMigrator {
  const ResumeSchemaMigrator();

  JsonMap migrate(JsonMap source) {
    final version = source['schemaVersion'];
    if (version is! String || version != currentResumeSchemaVersion) {
      throw UnsupportedSchemaVersionException(
        version is String ? version : null,
      );
    }
    return freezeJsonMap(deepCopyJson(source)! as Map<String, Object?>);
  }
}
