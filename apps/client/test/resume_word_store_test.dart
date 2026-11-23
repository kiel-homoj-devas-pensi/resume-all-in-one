import 'dart:convert';
import 'dart:io';

import 'package:document_io/document_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resume_all_in_one_client/src/resume_word_store.dart';
import 'package:resume_domain/resume_domain.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ResumeWordStore store;
  const codec = ResumeDocxCodec();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('resume-word-test-');
    store = ResumeWordStore(rootDirectory: () async => root);
  });
  tearDown(() async => root.delete(recursive: true));

  test('新文稿保存后重新打开仍是修改稿，旧文件与简历版本保持不变', () async {
    final version = _version();
    final original = await store.open(version);
    final originalBytes = await File(original.path).readAsBytes();
    final revision = await store.save(version, _word('已修改的中文文稿'));
    final reopened = await store.open(version);

    expect(revision.path, isNot(original.path));
    expect(reopened.path, revision.path);
    expect(reopened.content.paragraphs.single.text, '已修改的中文文稿');
    expect(await File(original.path).readAsBytes(), originalBytes);
    expect(version.content.profile.fullName, '原始姓名');
    expect(revision.path, isNot(contains('原始姓名')));
    expect(revision.path, isNot(contains('敏感版本')));
    expect(
      await root
          .list(recursive: true)
          .where((file) => file.path.endsWith('.pending'))
          .isEmpty,
      isTrue,
    );
  });

  test('不同简历版本不复用上一版本的修改稿', () async {
    await store.save(_version(), _word('旧版本修改稿'));
    final next = await store.open(_version(id: '另一版本'));
    expect(next.content.paragraphs.first.text, '原始姓名');
  });

  test(
    'known AI provenance follows Word revisions and cannot be dropped by saving',
    () async {
      final original = _version();
      final aiVersion = ResumeVersion(
        id: original.id,
        documentId: original.documentId,
        parentVersionId: original.parentVersionId,
        schemaVersion: original.schemaVersion,
        content:
            ResumeAigcMetadata.firstGeneration(
              providerName: 'Ji Ouqi',
              contentId: 'synthetic-ai-word',
            ).attachTo(
              ResumeAiProvenance(
                operationId: 'synthetic-ai-word',
              ).attachTo(original.content),
            ),
        source: ResumeVersionSource.aiConfirmed,
        createdAt: original.createdAt,
      );
      final saved = await store.save(aiVersion, _word('用户修改的正文'));
      expect(saved.content.aiProvenance!.operationId, 'synthetic-ai-word');
      expect(saved.content.aigcMetadata!.contentProducer, 'Ji Ouqi');
      expect(saved.content.paragraphs.single.text, '用户修改的正文');
      expect((await store.open(aiVersion)).content.aiProvenance, isNotNull);
      expect(
        (await store.open(aiVersion)).content.aigcMetadata!.propagateId,
        'synthetic-ai-word',
      );
      expect(
        codec.decode(await File(saved.path).readAsBytes()).aiProvenance,
        isNotNull,
      );
      await expectLater(
        store.save(
          aiVersion,
          ResumeWordDocument(
            paragraphs: saved.content.paragraphs,
            aigcMetadata: ResumeAigcMetadata.firstGeneration(
              providerName: 'different-provider',
              contentId: 'different-task',
            ),
          ),
        ),
        throwsFormatException,
      );
      expect((await store.open(aiVersion)).path, saved.path);
    },
  );

  test('超限文稿在创建文件前被拒绝，原副本和简历版本仍可读取', () async {
    final canonicalVersion = _version();
    final savedWord = await store.open(canonicalVersion);
    final originalBytes = await File(savedWord.path).readAsBytes();
    final oversizedDraft = _word('字' * (ResumeDocxCodec.maxTextCharacters + 1));

    await expectLater(
      store.save(canonicalVersion, oversizedDraft),
      throwsFormatException,
    );
    expect(await File(savedWord.path).readAsBytes(), originalBytes);
    expect((await store.open(canonicalVersion)).path, savedWord.path);
    expect(canonicalVersion.content.profile.fullName, '原始姓名');
    final files = await root
        .list(recursive: true)
        .where((entry) => entry is File)
        .toList();
    expect(files.map((file) => file.path), [savedWord.path]);
    expect(
      oversizedDraft.paragraphs.single.text.length,
      ResumeDocxCodec.maxTextCharacters + 1,
    );
  });

  test('损坏的最新Word报错而不重建或覆盖旧文件', () async {
    final saved = await store.open(_version());
    await File(saved.path).writeAsString('损坏的文稿');
    await expectLater(store.open(_version()), throwsFormatException);
    expect(await File(saved.path).readAsString(), '损坏的文稿');
  });

  test('转换读取磁盘上最新字节而非传入对象中的旧正文', () async {
    final saved = await store.save(_version(), _word('甲'));
    // 模拟保存对象仍持有旧内容：转换必须重新读文件，而不是使用该内存快照。
    await File(saved.path).writeAsBytes(codec.encode(_word('乙')));
    final pdfBytes = await store.convertToPdf(saved);
    final pdfText = _pdfStreams(pdfBytes);
    expect(pdfText, contains('<4E59>'));
    expect(pdfText, isNot(contains('<7532>')));
    final pdf = await store.savePdf(saved.path, pdfBytes);
    expect(await pdf.readAsBytes(), pdfBytes);
    final secondPdf = await store.savePdf(saved.path, pdfBytes);
    expect(secondPdf.path, isNot(pdf.path));
    expect(await pdf.readAsBytes(), pdfBytes);
  });

  test('转换损坏文稿失败时保留原文件且不产生PDF', () async {
    final saved = await store.open(_version());
    await File(saved.path).writeAsBytes([1, 2, 3]);
    await expectLater(store.convertToPdf(saved), throwsFormatException);
    expect(await File(saved.path).readAsBytes(), [1, 2, 3]);
    expect(
      await root
          .list(recursive: true)
          .where((entry) => entry.path.endsWith('.pdf'))
          .isEmpty,
      isTrue,
    );
  });

  test('拒绝目录外同名文稿及超限文件', () async {
    final saved = await store.open(_version());
    final outside = await File(saved.path).copy(
      '${root.path}${Platform.pathSeparator}${File(saved.path).uri.pathSegments.last}',
    );
    await expectLater(
      store.convertToPdf(
        SavedResumeWord(path: outside.path, content: saved.content),
      ),
      throwsFormatException,
    );
    final handle = await File(saved.path).open(mode: FileMode.write);
    await handle.truncate(ResumeDocxCodec.maxFileBytes + 1);
    await handle.close();
    await expectLater(store.convertToPdf(saved), throwsFormatException);
  });

  test('写入目录不可用时报告失败且不改变已有文稿', () async {
    final saved = await store.open(_version());
    final bytes = await File(saved.path).readAsBytes();
    final blockedRoot = File('${root.path}${Platform.pathSeparator}blocked');
    await blockedRoot.writeAsString('阻止目录创建');
    final failingStore = ResumeWordStore(
      rootDirectory: () async => Directory(blockedRoot.path),
    );
    await expectLater(
      failingStore.save(_version(), _word('无法保存')),
      throwsA(isA<FileSystemException>()),
    );
    expect(await File(saved.path).readAsBytes(), bytes);
  });
}

ResumeWordDocument _word(String text) => ResumeWordDocument(
  paragraphs: [ResumeWordParagraph(text: text, style: ResumeWordStyle.body)],
);

String _pdfStreams(List<int> bytes) {
  final text = latin1.decode(bytes);
  return RegExp(r'<<(.*?)>>\s*stream\r?\n(.*?)\r?\nendstream', dotAll: true)
      .allMatches(text)
      .map(
        (match) => match[1]!.contains('/FlateDecode')
            ? latin1.decode(zlib.decode(latin1.encode(match[2]!)))
            : match[2]!,
      )
      .join('\n');
}

ResumeVersion _version({String id = '敏感版本'}) => ResumeVersion(
  id: id,
  documentId: '../敏感文档',
  parentVersionId: null,
  schemaVersion: currentResumeSchemaVersion,
  content: ResumeData(
    profile: ResumeProfile(
      id: 'profile',
      fullName: '原始姓名',
      headline: '',
      email: '',
      phone: '',
      location: '',
    ),
  ),
  source: ResumeVersionSource.created,
  createdAt: DateTime.utc(2026, 10, 5),
);
