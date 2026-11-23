import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_domain/resume_domain.dart';
import 'package:resume_all_in_one_client/src/remote_review_cache.dart';
import 'package:resume_all_in_one_client/src/remote_resume_ai_service.dart';

void main() {
  late Directory root;
  late LocalStorageDatabase db;
  final now = DateTime.utc(2026, 10, 9);
  Future<void> reopen() async {
    await db.close();
    db = LocalStorageDatabase.openFile(File('${root.path}/review.sqlite'));
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('review-cache-');
    db = LocalStorageDatabase.openFile(File('${root.path}/review.sqlite'));
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  RemoteReviewCache cache() =>
      RemoteReviewCache(DriftRemoteReviewRepository(db), () => now);

  test('候选跨文件库重开恢复，拒绝后再重开不恢复；账号隔离', () async {
    await cache().save('owner', _change(standardLabel: true));
    await reopen();
    expect(await cache().restore('other', DriftResumeRepository(db)), isNull);
    final restored = await cache().restore('owner', DriftResumeRepository(db));
    expect(restored!.proposedContent.profile.headline, '合成工程师');
    expect(restored.aigcMetadata!.contentProducer, 'Ji Ouqi');
    expect(restored.aigcMetadata!.propagateId, restored.operationId);
    expect(restored.networkGenerated, isTrue);
    expect(
      restored.patch.apply(restored.baseContent).toJson(),
      restored.proposedContent.toJson(),
    );
    await DriftRemoteReviewRepository(
      db,
    ).discardReview(remoteReviewId('owner', restored.operationId));
    await reopen();
    expect(await cache().restore('owner', DriftResumeRepository(db)), isNull);
  });

  test('事务已确认但界面未更新，重开不再次恢复；删除后旧候选也不能复活', () async {
    final change = _change();
    await cache().save('owner', change);
    final document = ResumeDocument(
      id: 'd',
      title: '合成',
      currentVersionId: 'v',
      createdAt: now,
      updatedAt: now,
    );
    final version = ResumeVersion(
      id: 'v',
      documentId: 'd',
      parentVersionId: null,
      schemaVersion: change.proposedContent.schemaVersion,
      content: change.proposedContent,
      source: ResumeVersionSource.aiConfirmed,
      createdAt: now,
    );
    final reviews = DriftRemoteReviewRepository(db);
    await reviews.commitReview(
      recordId: remoteReviewId('owner', 'op'),
      document: document,
      version: version,
    );
    await reopen();
    expect(await cache().restore('owner', DriftResumeRepository(db)), isNull);
    expect(await DriftResumeRepository(db).listDocuments(), hasLength(1));
    await DriftResumeRepository(db).deleteDocument('d');
    await cache().save('owner', change);
    expect(await cache().restore('owner', DriftResumeRepository(db)), isNull);
    expect(await DriftResumeRepository(db).listDocuments(), isEmpty);
  });

  for (final corruptedLabel in [false, true]) {
    test('旧候选不补造来源；串任务标识拒绝恢复 $corruptedLabel', () async {
      await cache().save('owner', _change(standardLabel: corruptedLabel));
      final repository = DriftRemoteReviewRepository(db);
      final record = (await repository.readReviews('owner', now)).single;
      final payload = jsonDecode(record.payload) as Map<String, dynamic>;
      if (corruptedLabel) {
        (payload['aigcMetadata'] as Map)['PropagateID'] = 'other-task';
      } else {
        payload.remove('networkGenerated');
      }
      await repository.saveReview(
        'owner',
        record.id,
        null,
        jsonEncode(payload),
        now.add(const Duration(days: 7)),
      );
      await reopen();
      if (corruptedLabel) {
        await expectLater(
          cache().restore('owner', DriftResumeRepository(db)),
          throwsFormatException,
        );
      } else {
        final restored = await cache().restore(
          'owner',
          DriftResumeRepository(db),
        );
        expect(restored!.networkGenerated, isFalse);
        expect(restored.aigcMetadata, isNull);
      }
      expect(await DriftResumeRepository(db).listDocuments(), isEmpty);
    });
  }

  test('当前基础版本变化或文档删除，不恢复旧候选；未知正文保留', () async {
    final original = _change();
    final repository = DriftResumeRepository(db);
    final document = ResumeDocument(
      id: 'd',
      title: '合成',
      currentVersionId: 'v',
      createdAt: now,
      updatedAt: now,
    );
    final version = ResumeVersion(
      id: 'v',
      documentId: 'd',
      parentVersionId: null,
      schemaVersion: original.baseContent.schemaVersion,
      content: original.baseContent,
      source: ResumeVersionSource.created,
      createdAt: now,
    );
    await repository.createDocument(document, version);
    await cache().save('owner', _change(current: true));
    await repository.saveVersion(
      document: ResumeDocument(
        id: document.id,
        title: document.title,
        currentVersionId: 'v2',
        createdAt: document.createdAt,
        updatedAt: now,
      ),
      version: ResumeVersion(
        id: 'v2',
        documentId: 'd',
        parentVersionId: 'v',
        schemaVersion: version.schemaVersion,
        content: version.content,
        source: ResumeVersionSource.edited,
        createdAt: now,
      ),
      expectedCurrentVersionId: 'v',
    );
    await reopen();
    expect(await cache().restore('owner', DriftResumeRepository(db)), isNull);
    expect(await DriftResumeRepository(db).listVersions('d'), hasLength(2));
    await cache().save('owner', _change(current: true));
    final reopenedRepository = DriftResumeRepository(db);
    await reopenedRepository.deleteDocument('d');
    expect(await cache().restore('owner', reopenedRepository), isNull);
    expect(original.baseContent.extensions['future'], '保留');
  });

  for (final payload in [
    '{broken',
    '{"schemaVersion":0}',
    '{"schemaVersion":999}',
  ]) {
    test('损坏或旧 Schema $payload 明确丢弃，不写入简历', () async {
      await DriftRemoteReviewRepository(db).saveReview(
        'owner',
        'bad',
        null,
        payload,
        now.add(const Duration(days: 1)),
      );
      await expectLater(
        cache().restore('owner', DriftResumeRepository(db)),
        throwsFormatException,
      );
      expect(await DriftResumeRepository(db).listDocuments(), isEmpty);
      expect(
        await DriftRemoteReviewRepository(db).readReviews('owner', now),
        isEmpty,
      );
    });
  }

  test('七天过期和确认清空移除候选与对话', () async {
    await cache().save('owner', _change());
    final expired = RemoteReviewCache(
      DriftRemoteReviewRepository(db),
      () => now.add(const Duration(days: 7)),
    );
    expect(await expired.restore('owner', DriftResumeRepository(db)), isNull);
    await cache().save('owner', _change());
    await DriftRemoteReviewRepository(
      db,
    ).saveConversation('owner', 'd', '{}', now.add(const Duration(days: 1)));
    await DriftLocalDataRepository(db).clearAll();
    expect(await cache().restore('owner', DriftResumeRepository(db)), isNull);
    expect(
      await DriftRemoteReviewRepository(db).readConversation('owner', 'd', now),
      isNull,
    );
  });
}

PendingRemoteResumeChange _change({
  bool current = false,
  bool standardLabel = false,
}) {
  final base = ResumeData(
    profile: ResumeProfile(
      id: 'p',
      fullName: '合成',
      headline: '',
      email: '',
      phone: '',
      location: '',
    ),
    extensions: const {'future': '保留'},
  );
  final patch = ResumePatch([
    ResumePatchOperation(
      type: PatchOperationType.replace,
      path: '/profile/headline',
      oldValue: '',
      newValue: '合成工程师',
      reason: '合成审阅',
      source: 'remoteAi',
      category: ResumeChangeCategory.wording,
    ),
  ]);
  return PendingRemoteResumeChange(
    target: current
        ? RemoteResumeChangeTarget.currentDocument
        : RemoteResumeChangeTarget.newDocument,
    documentTitle: '合成',
    documentId: current ? 'd' : null,
    baseVersionId: current ? 'v' : null,
    operationId: 'op',
    aigcMetadata: standardLabel
        ? ResumeAigcMetadata.firstGeneration(
            providerName: 'Ji Ouqi',
            contentId: 'op',
          )
        : null,
    summary: '合成候选',
    baseContent: base,
    proposedContent: patch.apply(base),
    patch: patch,
    diff: ResumeDiff.fromPatch(patch),
    missingInformation: const [],
    warnings: const ['Fake'],
  );
}
