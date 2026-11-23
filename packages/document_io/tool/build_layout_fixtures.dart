import 'dart:io';
import 'dart:typed_data';

import 'package:document_io/document_io.dart';
import 'package:resume_domain/resume_domain.dart';

/// 仅使用既有合成事实，生成排版、分页及内容保真的可复现验收样例。
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('用法：dart run tool/build_layout_fixtures.dart <输出目录>');
    exitCode = 64;
    return;
  }
  final output = Directory(arguments.single).absolute;
  await output.create(recursive: true);
  final fonts = ResumePdfFonts(
    regular: ByteData.sublistView(
      await File('lib/assets/fonts/NotoSansSC-Regular.ttf').readAsBytes(),
    ),
    bold: ByteData.sublistView(
      await File('lib/assets/fonts/NotoSansSC-Bold.ttf').readAsBytes(),
    ),
  );
  final source = const CanonicalResumeCodec().decode(
    await File('test/fixtures/pdf_resume_input.json').readAsString(),
  );
  final boundary = source.toJson();
  final boundaryWork =
      (boundary['workExperiences']! as List).first as Map<String, Object?>;
  boundaryWork['organization'] = '单位' * 17;
  boundaryWork['position'] = '岗位' * 13;
  final longBullet = source.toJson();
  final bulletWork =
      (longBullet['workExperiences']! as List).first as Map<String, Object?>;
  bulletWork['highlights'] = [
    '长要点起点。${List.filled(180, '长要点必须完整跨页，继续使用悬挂缩进，不重复或丢失任何原文。').join()}长要点终点。',
  ];
  final short = ResumeData(
    profile: ResumeProfile(
      id: 'layout-short',
      fullName: '合成排版示例',
      headline: '软件工程师',
      email: 'layout@example.com',
      phone: '13800000000',
      location: '杭州',
    ),
    workExperiences: [source.workExperiences.first],
    educations: [source.educations.first],
  );
  for (final entry in {
    'short': short,
    'wide-header': ResumeData.fromJson(boundary),
    'long-bullet': ResumeData.fromJson(longBullet),
  }.entries) {
    final canonical = const CanonicalResumeCodec().encode(entry.value);
    final docx = const ResumeDocxCodec().encode(
      const ResumeDocxCodec().fromResume(entry.value),
    );
    final converted = await const ResumeDocxPdfConverter().convert(
      docx,
      fonts: fonts,
    );
    final direct = await const ResumePdfExporter().export(
      entry.value,
      fonts: fonts,
    );
    if (const CanonicalResumeCodec().encode(entry.value) != canonical) {
      throw StateError('排版改变了事实源');
    }
    await File(
      '${output.path}/${entry.key}.json',
    ).writeAsString(canonical, flush: true);
    await File(
      '${output.path}/${entry.key}.docx',
    ).writeAsBytes(docx, flush: true);
    await File(
      '${output.path}/${entry.key}-converted.pdf',
    ).writeAsBytes(converted, flush: true);
    await File(
      '${output.path}/${entry.key}-direct.pdf',
    ).writeAsBytes(direct, flush: true);
  }
  stdout.writeln(output.path);
}
