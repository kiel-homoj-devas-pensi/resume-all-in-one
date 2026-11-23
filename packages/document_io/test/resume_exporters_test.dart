import 'dart:io';

import 'package:document_io/document_io.dart';
import 'package:resume_domain/resume_domain.dart';
import 'package:test/test.dart';

void main() {
  late ResumeData resume;

  setUpAll(() {
    final source = File('test/fixtures/resume_input.json').readAsStringSync();
    resume = const CanonicalResumeCodec().decode(source);
  });

  test('Canonical JSON 导出与 fixture 一致并保留未知字段', () {
    final expected = File(
      'test/fixtures/resume_expected.json',
    ).readAsStringSync();

    expect(const ResumeJsonExporter().export(resume), expected);
  });

  test('Markdown 导出与 fixture 一致', () {
    final expected = File(
      'test/fixtures/resume_expected.md',
    ).readAsStringSync();

    expect(const ResumeMarkdownExporter().export(resume), expected);
  });

  test('存在阻断问题时两种导出均被拒绝', () {
    final invalid = ResumeData(
      profile: ResumeProfile(
        id: 'profile-invalid',
        fullName: '张三',
        headline: '',
        email: 'invalid-email',
        phone: '',
        location: '',
      ),
    );

    expect(
      () => const ResumeJsonExporter().export(invalid),
      throwsA(isA<ResumeValidationException>()),
    );
    expect(
      () => const ResumeMarkdownExporter().export(invalid),
      throwsA(isA<ResumeValidationException>()),
    );
  });
}
