import 'dart:io';
import 'dart:typed_data';

import 'package:document_io/document_io.dart';
import 'package:resume_domain/resume_domain.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('用法：dart run tool/build_docx_fixture.dart <输出目录>');
    exitCode = 64;
    return;
  }
  final outputDirectory = Directory(arguments.single).absolute;
  await outputDirectory.create(recursive: true);
  const codec = ResumeDocxCodec();
  final resume = const CanonicalResumeCodec().decode(
    await File('test/fixtures/pdf_resume_input.json').readAsString(),
  );
  final source = codec.fromResume(resume);
  final originalFile = File('${outputDirectory.path}/original.docx');
  await originalFile.writeAsBytes(codec.encode(source), flush: true);
  final reloaded = codec.decode(await originalFile.readAsBytes());
  final edited = ResumeWordDocument(
    paragraphs: [
      for (var index = 0; index < reloaded.paragraphs.length; index++)
        ResumeWordParagraph(
          text: index == 1
              ? '修改后的 Word 正文 · DOCX to PDF 验证'
              : reloaded.paragraphs[index].text,
          style: reloaded.paragraphs[index].style,
        ),
    ],
  );
  final fonts = ResumePdfFonts(
    regular: ByteData.sublistView(
      await File('lib/assets/fonts/NotoSansSC-Regular.ttf').readAsBytes(),
    ),
    bold: ByteData.sublistView(
      await File('lib/assets/fonts/NotoSansSC-Bold.ttf').readAsBytes(),
    ),
  );
  for (final entry in {
    'edited': edited,
    'long': ResumeWordDocument(
      paragraphs: [
        const ResumeWordParagraph(text: '长文分页验证', style: ResumeWordStyle.title),
        ResumeWordParagraph(
          text: List.filled(300, '长段落必须完整跨页保留，包含中文与 English。').join(),
          style: ResumeWordStyle.body,
        ),
        ResumeWordParagraph(
          text: 'https://example.com/${'very-long-readable-token-' * 30}',
          style: ResumeWordStyle.body,
        ),
      ],
    ),
  }.entries) {
    final docxFile = File('${outputDirectory.path}/${entry.key}.docx');
    await docxFile.writeAsBytes(codec.encode(entry.value), flush: true);
    final pdf = await const ResumeDocxPdfConverter().convert(
      await docxFile.readAsBytes(),
      fonts: fonts,
    );
    await File(
      '${outputDirectory.path}/${entry.key}.pdf',
    ).writeAsBytes(pdf, flush: true);
  }
  stdout.writeln(outputDirectory.path);
}
