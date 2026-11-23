import 'dart:io';
import 'package:test/test.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_domain/resume_domain.dart';

void main() {
  late LocalStorageDatabase database;
  late DriftRemoteReviewRepository reviews;
  setUp(() {
    database = LocalStorageDatabase.inMemory();
    reviews = DriftRemoteReviewRepository(database);
  });
  tearDown(() => database.close());

  test('v3 文件库升级并重开保留旧偏好，新增表候选可写', () async {
    final directory = await Directory.systemTemp.createTemp('review-v3-');
    final file = File('${directory.path}/v3.sqlite');
    var legacy = LocalStorageDatabase.openFile(file);
    try {
      await DriftAppSettingsRepository(legacy).setNetworkEnabled(false);
      for (final table in [
        'remote_review_records',
        'remote_conversations',
        'remote_acceptance_receipts',
      ]) {
        await legacy.customStatement('DROP TABLE $table');
      }
      await legacy.customStatement('PRAGMA user_version = 3');
      await legacy.close();
      legacy = LocalStorageDatabase.openFile(file);
      expect(
        await DriftAppSettingsRepository(legacy).getNetworkEnabled(),
        isFalse,
      );
      final repository = DriftRemoteReviewRepository(legacy);
      final now = DateTime.utc(2026, 10, 9);
      await repository.saveReview(
        'owner',
        'a',
        null,
        '{}',
        now.add(const Duration(days: 1)),
      );
      await legacy.close();
      legacy = LocalStorageDatabase.openFile(file);
      expect(
        await DriftRemoteReviewRepository(legacy).readReviews('owner', now),
        hasLength(1),
      );
      expect(
        (await legacy.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        4,
      );
    } finally {
      await legacy.close();
      await directory.delete(recursive: true);
    }
  });

  test('确认凭据与版本原子写入，重复确认不新增文档', () async {
    final time = DateTime.utc(2026, 10, 9);
    final content = ResumeData(
      profile: ResumeProfile(
        id: 'p',
        fullName: '',
        headline: '',
        email: '',
        phone: '',
        location: '',
      ),
    );
    final document = ResumeDocument(
      id: 'd',
      title: '合成',
      currentVersionId: 'v',
      createdAt: time,
      updatedAt: time,
    );
    final version = ResumeVersion(
      id: 'v',
      documentId: 'd',
      parentVersionId: null,
      schemaVersion: content.schemaVersion,
      content: content,
      source: ResumeVersionSource.aiConfirmed,
      createdAt: time,
    );
    await reviews.saveReview(
      'owner',
      'action',
      null,
      '{}',
      time.add(const Duration(days: 7)),
    );
    await reviews.commitReview(
      recordId: 'action',
      document: document,
      version: version,
    );
    await reviews.commitReview(
      recordId: 'action',
      document: document,
      version: version,
    );
    expect(await reviews.readReviews('owner', time), isEmpty);
    expect(await reviews.hasAccepted('action'), isTrue);
    expect(await DriftResumeRepository(database).listDocuments(), hasLength(1));
    expect(
      await DriftResumeRepository(database).listVersions('d'),
      hasLength(1),
    );
  });

  test('凭据写入故障回滚版本和候选清理', () async {
    final time = DateTime.utc(2026, 10, 9);
    final content = ResumeData(
      profile: ResumeProfile(
        id: 'p',
        fullName: '',
        headline: '',
        email: '',
        phone: '',
        location: '',
      ),
    );
    final document = ResumeDocument(
      id: 'd',
      title: '合成',
      currentVersionId: 'v',
      createdAt: time,
      updatedAt: time,
    );
    final version = ResumeVersion(
      id: 'v',
      documentId: 'd',
      parentVersionId: null,
      schemaVersion: content.schemaVersion,
      content: content,
      source: ResumeVersionSource.aiConfirmed,
      createdAt: time,
    );
    await reviews.saveReview(
      'owner',
      'action',
      null,
      '{}',
      time.add(const Duration(days: 7)),
    );
    await database.customStatement(
      "CREATE TRIGGER fail_receipt BEFORE INSERT ON remote_acceptance_receipts BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
    );
    await expectLater(
      reviews.commitReview(
        recordId: 'action',
        document: document,
        version: version,
      ),
      throwsA(isA<Exception>()),
    );
    expect(await DriftResumeRepository(database).listDocuments(), isEmpty);
    expect(await reviews.hasAccepted('action'), isFalse);
    expect(await reviews.readReviews('owner', time), hasLength(1));
  });

  test('账号隔离、过期清理与删除文档清理，不删除确认凭据', () async {
    final time = DateTime.utc(2026, 10, 9);
    await reviews.saveReview(
      'one',
      'a',
      'd',
      '{}',
      time.add(const Duration(days: 1)),
    );
    await reviews.saveReview(
      'two',
      'b',
      'e',
      '{}',
      time.subtract(const Duration(seconds: 1)),
    );
    expect(await reviews.readReviews('two', time), isEmpty);
    expect(await reviews.readReviews('one', time), hasLength(1));
    await reviews.removeDocument('d');
    expect(await reviews.readReviews('one', time), isEmpty);
  });
}
