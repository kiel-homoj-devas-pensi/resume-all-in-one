import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:document_io/document_io.dart';
import 'package:resume_domain/resume_domain.dart';

/// 使用合成人像，复现证件照三条导出路径、空岗位及多页边界。
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('用法：dart run tool/build_photo_fixtures.dart <输出目录>');
    exitCode = 64;
    return;
  }
  final output = Directory(arguments.single).absolute;
  await output.create(recursive: true);
  final source = const CanonicalResumeCodec().decode(
    await File('test/fixtures/pdf_resume_input.json').readAsString(),
  );
  final photo = ResumePhoto(
    dataBase64: base64Encode(
      await File('test/fixtures/resume-photo-500x700.jpg').readAsBytes(),
    ),
    mimeType: 'image/jpeg',
    width: 500,
    height: 700,
    extensions: {'syntheticFixture': true},
  );
  final short = ResumeData(
    profile: ResumeProfile(
      id: 'photo-layout-short',
      fullName: '合成排版示例',
      headline: '软件工程师',
      email: 'layout@example.com',
      phone: '13800000000',
      location: '杭州',
      photo: photo,
    ),
    workExperiences: [source.workExperiences.first],
    educations: [source.educations.first],
  );
  final noHeadline = short.toJson();
  (noHeadline['profile'] as JsonMap)['headline'] = '';
  final longContact = short.toJson();
  (longContact['profile'] as JsonMap)['email'] = '${'long' * 35}@example.com';
  final multiPage = short.toJson();
  ((multiPage['workExperiences'] as List).first as JsonMap)['summary'] =
      '多页正文完整保留。' * 800;
  final noPhoto = short.toJson();
  (noPhoto['profile'] as JsonMap).remove('photo');
  final fonts = ResumePdfFonts(
    regular: ByteData.sublistView(
      await File('lib/assets/fonts/NotoSansSC-Regular.ttf').readAsBytes(),
    ),
    bold: ByteData.sublistView(
      await File('lib/assets/fonts/NotoSansSC-Bold.ttf').readAsBytes(),
    ),
  );
  const codec = ResumeDocxCodec();
  for (final entry in {
    'photo-short': short,
    'photo-no-headline': ResumeData.fromJson(noHeadline),
    'photo-long-contact': ResumeData.fromJson(longContact),
    'photo-multipage': ResumeData.fromJson(multiPage),
    'no-photo': ResumeData.fromJson(noPhoto),
  }.entries) {
    final canonical = const CanonicalResumeCodec().encode(entry.value);
    final bytes = codec.encode(codec.fromResume(entry.value));
    await File(
      '${output.path}/${entry.key}.docx',
    ).writeAsBytes(bytes, flush: true);
    await File('${output.path}/${entry.key}-direct.pdf').writeAsBytes(
      await const ResumePdfExporter().export(entry.value, fonts: fonts),
      flush: true,
    );
    await File('${output.path}/${entry.key}-converted.pdf').writeAsBytes(
      await const ResumeDocxPdfConverter().convert(bytes, fonts: fonts),
      flush: true,
    );
    if (const CanonicalResumeCodec().encode(entry.value) != canonical) {
      throw StateError('照片导出改变了Canonical事实');
    }
  }
  final original = codec.decode(codec.encode(codec.fromResume(short)));
  final edited = ResumeWordDocument(
    photo: original.photo,
    paragraphs: [
      for (final p in original.paragraphs)
        ResumeWordParagraph(
          text: p.style == ResumeWordStyle.title ? '已修改姓名示例' : p.text,
          style: p.style,
        ),
    ],
  );
  final editedBytes = codec.encode(edited);
  await File(
    '${output.path}/photo-edited.docx',
  ).writeAsBytes(editedBytes, flush: true);
  await File('${output.path}/photo-edited-converted.pdf').writeAsBytes(
    await const ResumeDocxPdfConverter().convert(editedBytes, fonts: fonts),
    flush: true,
  );
  stdout.writeln(output.path);
}
