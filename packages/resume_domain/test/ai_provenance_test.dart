import 'dart:io';

import 'package:resume_domain/resume_domain.dart';
import 'package:test/test.dart';

void main() {
  final resume = const CanonicalResumeCodec().decode(
    File('test/fixtures/resume_v0_1.json').readAsStringSync(),
  );

  test('only explicit generation provenance marks a resume', () {
    expect(ResumeAiProvenance.fromResume(resume), isNull);
    final marked = ResumeAiProvenance(
      operationId: 'synthetic-operation-1',
    ).attachTo(resume);
    final restored = const CanonicalResumeCodec().decode(
      const CanonicalResumeCodec().encode(marked),
    );
    expect(
      ResumeAiProvenance.fromResume(restored)!.operationId,
      'synthetic-operation-1',
    );
    expect(ResumeAiProvenance.fromResume(resume), isNull);
    final editedJson = restored.toJson();
    (editedJson['profile']! as Map)['headline'] = '手工修改后的标题';
    expect(
      ResumeAiProvenance.fromResume(ResumeData.fromJson(editedJson)),
      isNotNull,
    );
  });

  test('malformed recorded provenance fails instead of losing its label', () {
    final malformed = ResumeData.fromJson({
      ...resume.toJson(),
      ResumeAiProvenance.extensionKey: {'origin': 'unknown'},
    });
    expect(
      () => ResumeAiProvenance.fromResume(malformed),
      throwsFormatException,
    );
    expect(() => ResumeAiProvenance(operationId: ''), throwsFormatException);
  });
}
