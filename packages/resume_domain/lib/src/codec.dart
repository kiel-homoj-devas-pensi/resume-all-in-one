import 'dart:convert';

import 'json_support.dart';
import 'migration.dart';
import 'model.dart';
import 'validation.dart';

final class CanonicalResumeCodec {
  const CanonicalResumeCodec({
    this.validator = const ResumeValidator(),
    this.migrator = const ResumeSchemaMigrator(),
  });

  final ResumeValidator validator;
  final ResumeSchemaMigrator migrator;

  ResumeData decode(String canonicalJsonText) {
    final decodedJson = decodeJsonObject(canonicalJsonText);
    final migratedJson = migrator.migrate(decodedJson);
    final decodedResume = ResumeData.fromJson(migratedJson);
    final validationResult = validator.validate(decodedResume);
    if (!validationResult.isValid) {
      throw ResumeValidationException(validationResult);
    }
    return decodedResume;
  }

  String encode(ResumeData resume) {
    // encode 同样校验，阻止内存中手工构造的非法对象绕过持久化边界。
    final validationResult = validator.validate(resume);
    if (!validationResult.isValid) {
      throw ResumeValidationException(validationResult);
    }
    return jsonEncode(resume.toJson());
  }
}
