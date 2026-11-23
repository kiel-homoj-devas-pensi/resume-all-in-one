import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:document_io/document_io.dart';
import 'package:resume_domain/resume_domain.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

void main() {
  final unmarked = const CanonicalResumeCodec().decode(
    File('test/fixtures/pdf_resume_input.json').readAsStringSync(),
  );
  final metadata = ResumeAigcMetadata.firstGeneration(
    providerName: 'Ji Ouqi',
    contentId: 'synthetic-usage-identity-20261020',
    reservedCode1: 'source-integrity-quote-"-ampersand-&',
  );
  final marked = metadata.attachTo(
    ResumeAiProvenance(
      operationId: 'synthetic-operation-only',
    ).attachTo(unmarked),
  );
  const codec = ResumeDocxCodec();
  final fonts = ResumePdfFonts(
    regular: ByteData.sublistView(
      File('lib/assets/fonts/NotoSansSC-Regular.ttf').readAsBytesSync(),
    ),
    bold: ByteData.sublistView(
      File('lib/assets/fonts/NotoSansSC-Bold.ttf').readAsBytesSync(),
    ),
  );

  test(
    'DOCX has one standard AIGC property alongside separate app provenance',
    () {
      final bytes = codec.encode(codec.fromResume(marked));
      final archive = ZipDecoder().decodeBytes(bytes);
      final xml = XmlDocument.parse(
        utf8.decode(archive.findFile('docProps/custom.xml')!.content),
      );
      final properties = xml.rootElement.childElements
          .where((p) => p.getAttribute('name') == 'AIGC')
          .toList();
      expect(properties, hasLength(1));
      expect(
        jsonDecode(properties.single.getElement('vt:lpwstr')!.innerText),
        metadata.toJson(),
      );
      final reloaded = codec.decode(bytes);
      expect(reloaded.aiProvenance!.operationId, 'synthetic-operation-only');
      expect(reloaded.aigcMetadata!.contentProducer, 'Ji Ouqi');
      final edited = ResumeWordDocument(
        paragraphs: reloaded.paragraphs,
        photo: reloaded.photo,
        aiProvenance: reloaded.aiProvenance,
        aigcMetadata: reloaded.aigcMetadata,
      );
      expect(
        codec.decode(codec.encode(edited)).aigcMetadata!.toJson(),
        metadata.toJson(),
      );
    },
  );

  test(
    'DOCX metadata-only source works and duplicates/tampering fail closed',
    () {
      final bytes = codec.encode(codec.fromResume(metadata.attachTo(unmarked)));
      expect(codec.decode(bytes).aiProvenance, isNull);
      final original = ZipDecoder().decodeBytes(bytes);
      final custom = utf8.decode(
        original.findFile('docProps/custom.xml')!.content,
      );
      final property = RegExp(
        r'<property.*?</property>',
      ).firstMatch(custom)!.group(0)!;
      for (final replacement in [
        custom.replaceFirst('</Properties>', '$property</Properties>'),
        custom.replaceFirst('Ji Ouqi', ''),
        custom.replaceFirst('&quot;1&quot;', '&quot;0&quot;'),
      ]) {
        if (replacement == custom) continue;
        expect(
          () => codec.decode(
            _replacePart(bytes, 'docProps/custom.xml', replacement),
          ),
          throwsFormatException,
        );
      }
      final source = utf8.decode(
        original.findFile('word/document.xml')!.content,
      );
      expect(
        () => codec.decode(
          _replacePart(
            bytes,
            'word/document.xml',
            source.replaceFirst(ResumeAiProvenance.notice, ''),
          ),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'PDF Info gets a single AIGC dictionary value in both export paths',
    () async {
      for (final bytes in [
        await const ResumePdfExporter().export(marked, fonts: fonts),
        await const ResumeDocxPdfConverter().convert(
          codec.encode(codec.fromResume(marked)),
          fonts: fonts,
        ),
      ]) {
        final raw = latin1.decode(bytes);
        expect(RegExp(r'/AIGC\b').allMatches(raw), hasLength(1));
        expect(raw, contains('Ji Ouqi'));
        expect(raw, contains('synthetic-usage-identity-20261020'));
      }
    },
  );

  test('MD has standard YAML and JSON preserves the standard object', () {
    final markdown = const ResumeMarkdownExporter().export(marked);
    expect(markdown, startsWith('---\nAIGC:\n'));
    for (final field in metadata.toJson().entries) {
      expect(
        markdown,
        contains('  ${field.key}: ${jsonEncode(field.value)}\n'),
      );
    }
    expect(
      ResumeAigcMetadata.fromResume(
        const CanonicalResumeCodec().decode(
          const ResumeJsonExporter().export(marked),
        ),
      )!.toJson(),
      metadata.toJson(),
    );
  });

  test(
    'unrecorded and old provenance-only files do not gain fabricated AIGC',
    () async {
      final old = ResumeAiProvenance(
        operationId: 'old-synthetic',
      ).attachTo(unmarked);
      for (final resume in [unmarked, old]) {
        final word = codec.decode(codec.encode(codec.fromResume(resume)));
        expect(word.aigcMetadata, isNull);
        final pdf = await const ResumePdfExporter().export(
          resume,
          fonts: fonts,
        );
        expect(latin1.decode(pdf), isNot(contains('/AIGC')));
        expect(
          const ResumeMarkdownExporter().export(resume),
          isNot(startsWith('---')),
        );
        expect(ResumeAigcMetadata.fromResume(resume), isNull);
      }
    },
  );
}

Uint8List _replacePart(Uint8List bytes, String name, String replacement) {
  final out = Archive();
  for (final file in ZipDecoder().decodeBytes(bytes).files) {
    final content = file.name == name ? utf8.encode(replacement) : file.content;
    out.add(
      ArchiveFile(file.name, content.length, content)
        ..compression = CompressionType.none,
    );
  }
  return Uint8List.fromList(ZipEncoder().encode(out));
}
