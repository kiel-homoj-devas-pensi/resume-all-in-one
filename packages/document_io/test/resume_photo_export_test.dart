import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:document_io/document_io.dart';
import 'package:resume_domain/resume_domain.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

void main() {
  const codec = ResumeDocxCodec();
  late ResumePhoto photo;
  late ResumeData resume;
  late ResumePdfFonts fonts;
  setUpAll(() {
    photo = ResumePhoto(
      dataBase64: base64Encode(
        File('test/fixtures/resume-photo-500x700.jpg').readAsBytesSync(),
      ),
      mimeType: 'image/jpeg',
      width: 500,
      height: 700,
      extensions: {
        'future': {'preserve': true},
      },
    );
    final json =
        jsonDecode(
              File('test/fixtures/pdf_resume_input.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    (json['profile'] as Map<String, dynamic>)['photo'] = photo.toJson();
    resume = ResumeData.fromJson(json);
    fonts = ResumePdfFonts(
      regular: ByteData.sublistView(
        File('lib/assets/fonts/NotoSansSC-Regular.ttf').readAsBytesSync(),
      ),
      bold: ByteData.sublistView(
        File('lib/assets/fonts/NotoSansSC-Bold.ttf').readAsBytesSync(),
      ),
    );
  });

  test('v3照片、未知字段和文字修改经过真实DOCX字节往返，Canonical不改变', () {
    final before = const CanonicalResumeCodec().encode(resume);
    final source = codec.fromResume(resume);
    final encoded = codec.encode(source);
    final decoded = codec.decode(encoded);
    expect(decoded.photo!.toJson(), photo.toJson());
    final edited = ResumeWordDocument(
      photo: decoded.photo,
      paragraphs: [
        for (final p in decoded.paragraphs)
          ResumeWordParagraph(
            text: p.style == ResumeWordStyle.title ? '修改后的姓名' : p.text,
            style: p.style,
          ),
      ],
    );
    final saved = codec.decode(codec.encode(edited));
    expect(saved.paragraphs.first.text, '修改后的姓名');
    expect(saved.photo!.toJson(), photo.toJson());
    expect(const CanonicalResumeCodec().encode(resume), before);
  });

  test('独立XML核对首页绝对锚点、一寸尺寸、左右对称居中和固定图片关系', () {
    final bytes = codec.encode(codec.fromResume(resume));
    final package = ZipDecoder().decodeBytes(bytes);
    expect(
      package.findFile('word/media/resume-photo.jpg')!.content,
      photo.bytes,
    );
    final xml = XmlDocument.parse(
      utf8.decode(package.findFile('word/document.xml')!.content),
    );
    final table = xml.rootElement.getElement('w:body')!.getElement('w:tbl')!;
    final header = table.getElement('w:tr')!.getElement('w:tc')!;
    for (final paragraph in header.findElements('w:p')) {
      final indents = paragraph.getElement('w:pPr')!.getElement('w:ind')!;
      expect(indents.getAttribute('w:left'), '1701');
      expect(indents.getAttribute('w:right'), '1701');
    }
    final anchor = xml.descendants.whereType<XmlElement>().singleWhere(
      (e) => e.name.qualified == 'wp:anchor',
    );
    expect(
      anchor.getElement('wp:positionH')!.getAttribute('relativeFrom'),
      'page',
    );
    expect(anchor.getElement('wp:positionH')!.innerText, '6228000');
    expect(anchor.getElement('wp:positionV')!.innerText, '432000');
    expect(anchor.getElement('wp:extent')!.getAttribute('cx'), '900000');
    expect(anchor.getElement('wp:extent')!.getAttribute('cy'), '1260000');
    expect(
      xml.descendants.whereType<XmlElement>().where(
        (e) => e.name.qualified == 'w:drawing',
      ),
      hasLength(1),
    );
    expect(
      utf8.decode(package.findFile('word/styles.xml')!.content),
      contains('<w:jc w:val="center"/>'),
    );
    final relationships = utf8.decode(
      package.findFile('word/_rels/document.xml.rels')!.content,
    );
    expect(relationships, contains('Target="media/resume-photo.jpg"'));
    expect(relationships, isNot(contains('TargetMode="External"')));
  });

  test('无照片继续v2五部件模板，空岗位不生成空标题或照片框', () {
    final json = resume.toJson();
    final profile = json['profile'] as Map<String, Object?>;
    profile.remove('photo');
    profile['headline'] = '';
    final source = codec.fromResume(ResumeData.fromJson(json));
    final bytes = codec.encode(source);
    final package = ZipDecoder().decodeBytes(bytes);
    expect(package.files, hasLength(5));
    expect(source.photo, isNull);
    expect(
      source.paragraphs.where((p) => p.style == ResumeWordStyle.headline),
      isEmpty,
    );
    expect(
      utf8.decode(package.findFile('word/document.xml')!.content),
      isNot(contains('w:drawing')),
    );
    expect(codec.decode(bytes).photo, isNull);
  });

  test('图片关系、锚点、未知对象、尺寸损坏和资源超限被明确拒绝', () {
    final original = codec.encode(codec.fromResume(resume));
    for (final changes in <(String, String Function(String))>[
      (
        'word/_rels/document.xml.rels',
        (xml) => xml.replaceFirst(
          'Target="media/resume-photo.jpg"',
          'Target="https://example.com/portrait" TargetMode="External"',
        ),
      ),
      (
        'word/_rels/document.xml.rels',
        (xml) => xml.replaceFirst('media/resume-photo.jpg', '../photo.jpg'),
      ),
      (
        '[Content_Types].xml',
        (xml) => xml.replaceFirst('image/jpeg', 'image/svg+xml'),
      ),
      (
        'word/document.xml',
        (xml) =>
            xml.replaceFirst('<wp:posOffset>432000', '<wp:posOffset>999999'),
      ),
      (
        'word/document.xml',
        (xml) => xml.replaceFirst(
          '<wp:extent cx="900000"',
          '<wp:extent cx="1000000"',
        ),
      ),
      (
        'word/document.xml',
        (xml) => xml.replaceFirst('<w:sectPr>', '<w:tbl/><w:sectPr>'),
      ),
      (
        'word/document.xml',
        (xml) => xml.replaceFirst(
          '<a:blip r:embed="rIdPhoto"/>',
          '<a:blip r:link="rIdPhoto"/>',
        ),
      ),
      ('word/photo.json', (_) => '{"extensions":{},"hidden":true}'),
      (
        'word/photo.json',
        (_) => '{"extensions":{"x":${'[' * 34}0${']' * 34}}}',
      ),
      ('word/photo.json', (_) => '{"extensions":{"x":"${'a' * 65536}"}}'),
    ]) {
      final package = ZipDecoder().decodeBytes(original);
      final changed = utf8.encode(
        changes.$2(utf8.decode(package.findFile(changes.$1)!.content)),
      );
      expect(
        () => codec.decode(_replace(package, changes.$1, changed)),
        throwsFormatException,
        reason: changes.$1,
      );
    }
    final wrongDimensions = Uint8List.fromList(photo.bytes);
    final unsafeSampling = Uint8List.fromList(photo.bytes);
    final unsafeChannels = Uint8List.fromList(photo.bytes);
    for (var i = 0; i < wrongDimensions.length - 9; i++) {
      if (wrongDimensions[i] == 0xff && wrongDimensions[i + 1] == 0xc0) {
        wrongDimensions[i + 6] ^= 1;
        unsafeChannels[i + 9] = 255;
        unsafeSampling[i + 11] = 0xff;
        break;
      }
    }
    for (final badImage in [
      Uint8List(80),
      wrongDimensions,
      unsafeSampling,
      unsafeChannels,
      Uint8List.fromList([
        ...photo.bytes.take(photo.bytes.length - 2),
        0xff,
        0xda,
        0,
        2,
        0xff,
        0xd9,
      ]),
      Uint8List(512 * 1024 + 1),
      photo.bytes.sublist(0, 300),
    ]) {
      expect(
        () => codec.decode(
          _replace(
            ZipDecoder().decodeBytes(original),
            'word/media/resume-photo.jpg',
            badImage,
          ),
        ),
        throwsFormatException,
      );
    }
  });

  test('两条PDF路径照片只绘于首页，长联系信息和多页正文完整保留', () async {
    final json = resume.toJson();
    final profile = json['profile'] as Map<String, Object?>;
    profile['email'] = '${'long' * 35}@example.com';
    profile['headline'] = '';
    (json['workExperiences'] as List).first['summary'] = '多页正文完整保留。' * 800;
    final changed = ResumeData.fromJson(json);
    final documents = [
      await const ResumePdfExporter().export(changed, fonts: fonts),
      await const ResumeDocxPdfConverter().convert(
        codec.encode(codec.fromResume(changed)),
        fonts: fonts,
      ),
    ];
    for (final pdf in documents) {
      final text = latin1.decode(pdf);
      expect(
        RegExp(r'/Type\s*/Page\b').allMatches(text).length,
        greaterThan(2),
      );
      expect(RegExp(r'/Subtype\s*/Image\b').allMatches(text), hasLength(1));
      final streams = _streams(pdf);
      expect(RegExp(r'/\S+\s+Do\b').allMatches(streams), hasLength(1));
      final placement = RegExp(
        r'q ([0-9.]+) 0 0 ([0-9.]+) 0 0 cm /I\d+ Do',
      ).firstMatch(streams)!;
      expect(double.parse(placement[1]!), closeTo(25 * 72 / 25.4, 0.0001));
      expect(double.parse(placement[2]!), closeTo(35 * 72 / 25.4, 0.0001));
      expect(streams.toUpperCase().contains('<591A>'), isTrue); // 多
    }
  });

  test('仅有合法SOF尺寸不能替代像素解码，坏扫描段阻止DOCX和直接PDF导出', () async {
    final badScan = Uint8List.fromList(photo.bytes);
    for (var i = 0; i < badScan.length - 4; i++) {
      if (badScan[i] == 0xff && badScan[i + 1] == 0xda) {
        badScan[i + 2] = 0;
        badScan[i + 3] = 2;
        break;
      }
    }
    final structurallyBounded = ResumePhoto(
      dataBase64: base64Encode(badScan),
      mimeType: 'image/jpeg',
      width: 500,
      height: 700,
    );
    final bytes = codec.encode(codec.fromResume(resume));
    expect(
      () => codec.decode(
        _replace(
          ZipDecoder().decodeBytes(bytes),
          'word/media/resume-photo.jpg',
          badScan,
        ),
      ),
      throwsFormatException,
    );
    final json = resume.toJson();
    (json['profile'] as Map<String, Object?>)['photo'] = structurallyBounded
        .toJson();
    final badResume = ResumeData.fromJson(json);
    expect(() => codec.fromResume(badResume), throwsFormatException);
    await expectLater(
      const ResumePdfExporter().export(badResume, fonts: fonts),
      throwsFormatException,
    );
    final invalidHuffman = Uint8List.fromList(photo.bytes);
    for (var i = 0; i < invalidHuffman.length - 5; i++) {
      if (invalidHuffman[i] == 0xff && invalidHuffman[i + 1] == 0xc4) {
        invalidHuffman[i + 4] = 0xff;
        break;
      }
    }
    final boundedWithBadPixels = ResumePhoto(
      dataBase64: base64Encode(invalidHuffman),
      mimeType: 'image/jpeg',
      width: 500,
      height: 700,
    );
    (json['profile'] as Map<String, Object?>)['photo'] = boundedWithBadPixels
        .toJson();
    final undecodable = ResumeData.fromJson(json);
    expect(() => codec.fromResume(undecodable), throwsFormatException);
    await expectLater(
      const ResumePdfExporter().export(undecodable, fonts: fonts),
      throwsFormatException,
    );
  });
}

Uint8List _replace(Archive archive, String name, List<int> bytes) {
  archive.add(
    ArchiveFile(name, bytes.length, bytes)..compression = CompressionType.none,
  );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

String _streams(Uint8List pdf) {
  final out = StringBuffer();
  for (final match in RegExp(
    r'<<(.*?)>>\s*stream\r?\n(.*?)\r?\nendstream',
    dotAll: true,
  ).allMatches(latin1.decode(pdf))) {
    if (match[1]!.contains('/DCTDecode')) continue;
    out.writeln(
      match[1]!.contains('/FlateDecode')
          ? latin1.decode(
              const ZLibDecoder().decodeBytes(latin1.encode(match[2]!)),
            )
          : match[2],
    );
  }
  return out.toString();
}
