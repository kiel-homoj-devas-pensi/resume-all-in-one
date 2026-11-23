import 'dart:io';
import 'dart:typed_data';

import 'package:document_io/document_io.dart';
import 'package:resume_domain/resume_domain.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('用法：dart run tool/build_pdf_fixture.dart <输出路径>');
    exitCode = 64;
    return;
  }

  final fixtureResume = const CanonicalResumeCodec().decode(
    await File('test/fixtures/pdf_resume_input.json').readAsString(),
  );
  final pdfBytes = await const ResumePdfExporter().export(
    fixtureResume,
    fonts: ResumePdfFonts(
      regular: await _readFont('NotoSansSC-Regular.ttf'),
      bold: await _readFont('NotoSansSC-Bold.ttf'),
    ),
  );
  final outputFile = File(arguments.single).absolute;
  await outputFile.parent.create(recursive: true);
  await outputFile.writeAsBytes(pdfBytes, flush: true);
  stdout.writeln(outputFile.path);
}

Future<ByteData> _readFont(String fileName) async {
  final fontBytes = await File('lib/assets/fonts/$fileName').readAsBytes();
  return ByteData.sublistView(fontBytes);
}
