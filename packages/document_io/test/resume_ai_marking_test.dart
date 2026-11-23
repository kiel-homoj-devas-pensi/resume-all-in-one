import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:document_io/document_io.dart';
import 'package:resume_domain/resume_domain.dart';
import 'package:test/test.dart';

void main() {
  final manual = const CanonicalResumeCodec().decode(
    File('test/fixtures/pdf_resume_input.json').readAsStringSync(),
  );
  final ai = ResumeAiProvenance(
    operationId: 'synthetic-generation-20261020',
  ).attachTo(manual);
  const docx = ResumeDocxCodec();
  final fonts = ResumePdfFonts(
    regular: ByteData.sublistView(
      File('lib/assets/fonts/NotoSansSC-Regular.ttf').readAsBytesSync(),
    ),
    bold: ByteData.sublistView(
      File('lib/assets/fonts/NotoSansSC-Bold.ttf').readAsBytesSync(),
    ),
  );

  test(
    'known AI is labelled in markdown/JSON and unrecorded is not mislabelled',
    () {
      expect(
        const ResumeMarkdownExporter().export(ai),
        startsWith(ResumeAiProvenance.notice),
      );
      expect(
        const ResumeMarkdownExporter().export(manual),
        isNot(contains(ResumeAiProvenance.notice)),
      );
      expect(
        ResumeAiProvenance.fromResume(
          const CanonicalResumeCodec().decode(
            const ResumeJsonExporter().export(ai),
          ),
        )!.operationId,
        'synthetic-generation-20261020',
      );
    },
  );

  test(
    'DOCX stores provenance and a mandatory visible label through edits',
    () {
      final bytes = docx.encode(docx.fromResume(ai));
      final archive = ZipDecoder().decodeBytes(bytes);
      final metadata = utf8.decode(
        archive.findFile('docProps/custom.xml')!.content,
      );
      expect(metadata, contains('synthetic-generation-20261020'));
      expect(metadata, contains('ResumeAllInOneAiProvenance'));
      expect(
        utf8.decode(archive.findFile('word/document.xml')!.content),
        contains(ResumeAiProvenance.notice),
      );
      final decoded = docx.decode(bytes);
      expect(
        decoded.aiProvenance!.operationId,
        'synthetic-generation-20261020',
      );
      expect(
        decoded.paragraphs.any((p) => p.text == ResumeAiProvenance.notice),
        isFalse,
        reason: 'the required label is outside editable paragraphs',
      );
      final edited = ResumeWordDocument(
        paragraphs: decoded.paragraphs.skip(1).toList(),
        aiProvenance: decoded.aiProvenance,
      );
      expect(docx.decode(docx.encode(edited)).aiProvenance, isNotNull);
      expect(
        ZipDecoder()
            .decodeBytes(docx.encode(docx.fromResume(manual)))
            .findFile('docProps/custom.xml'),
        isNull,
      );
    },
  );

  test('DOCX with removed visible label is rejected', () {
    final bytes = docx.encode(docx.fromResume(ai));
    final original = ZipDecoder().decodeBytes(bytes);
    final tampered = Archive();
    for (final file in original.files) {
      final content = file.name == 'word/document.xml'
          ? utf8.encode(
              utf8
                  .decode(file.content)
                  .replaceFirst(ResumeAiProvenance.notice, ''),
            )
          : file.content;
      tampered.add(
        ArchiveFile(file.name, content.length, content)
          ..compression = CompressionType.none,
      );
    }
    expect(
      () => docx.decode(Uint8List.fromList(ZipEncoder().encode(tampered))),
      throwsFormatException,
    );
  });

  test(
    'canonical and Word-derived PDF keep the same structured source',
    () async {
      final pdf = await const ResumePdfExporter().export(ai, fonts: fonts);
      final wordPdf = await const ResumeDocxPdfConverter().convert(
        docx.encode(docx.fromResume(ai)),
        fonts: fonts,
      );
      for (final bytes in [pdf, wordPdf]) {
        final structure = latin1.decode(bytes);
        expect(structure, contains('synthetic-generation-20261020'));
        expect(structure, contains('remoteResumeGeneration'));
      }
      final plain = await const ResumePdfExporter().export(
        manual,
        fonts: fonts,
      );
      expect(latin1.decode(plain), isNot(contains('remoteResumeGeneration')));
    },
  );
}
