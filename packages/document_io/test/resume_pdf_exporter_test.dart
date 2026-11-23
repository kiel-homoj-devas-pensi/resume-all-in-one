import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:document_io/document_io.dart';
import 'package:resume_domain/resume_domain.dart';
import 'package:test/test.dart';

void main() {
  late ResumePdfFonts chineseFonts;
  late ResumeData fixtureResume;

  setUpAll(() {
    chineseFonts = ResumePdfFonts(
      regular: _fontData('NotoSansSC-Regular.ttf'),
      bold: _fontData('NotoSansSC-Bold.ttf'),
    );
    fixtureResume = const CanonicalResumeCodec().decode(
      File('test/fixtures/pdf_resume_input.json').readAsStringSync(),
    );
  });

  test('中文 fixture 生成固定 A4 PDF', () async {
    final pdfBytes = await const ResumePdfExporter().export(
      fixtureResume,
      fonts: chineseFonts,
    );
    final pdfStructure = latin1.decode(pdfBytes, allowInvalid: true);

    expect(ascii.decode(pdfBytes.take(5).toList()), '%PDF-');
    expect(_pageCount(pdfStructure), greaterThanOrEqualTo(2));
    expect(
      pdfStructure,
      matches(RegExp(r'/MediaBox\s*\[0 0 595\.\d+ 841\.\d+\]')),
    );
  });

  test('超长中文摘要自动跨越至少三页', () async {
    final longResume = ResumeData(
      profile: ResumeProfile(
        id: 'profile-long',
        fullName: '长内容测试',
        headline: '客户端工程师',
        email: '',
        phone: '',
        location: '',
      ),
      workExperiences: [
        WorkExperience(
          id: 'work-long',
          organization: '示例科技',
          position: '工程师',
          dateRange: DateRange(
            start: ResumeDate(year: 2020, month: 1),
            end: null,
            isCurrent: true,
          ),
          summary: List.filled(300, '负责稳定的离线简历流程，并持续验证分页边界。').join(),
        ),
      ],
    );

    final pdfBytes = await const ResumePdfExporter().export(
      longResume,
      fonts: chineseFonts,
    );

    expect(
      _pageCount(latin1.decode(pdfBytes, allowInvalid: true)),
      greaterThanOrEqualTo(3),
    );
  });

  test('validation error 在生成任何可用 PDF 前被拒绝', () async {
    final invalidResume = ResumeData(
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
      const ResumePdfExporter().export(invalidResume, fonts: chineseFonts),
      throwsA(isA<ResumeValidationException>()),
    );
  });
}

ByteData _fontData(String fileName) {
  final fontBytes = File('lib/assets/fonts/$fileName').readAsBytesSync();
  return ByteData.sublistView(fontBytes);
}

int _pageCount(String pdfStructure) {
  return RegExp(r'/Type\s*/Page\b').allMatches(pdfStructure).length;
}
