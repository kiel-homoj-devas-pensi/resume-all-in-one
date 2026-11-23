import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:resume_domain/resume_domain.dart';

import 'database.dart';
import 'drift_resume_repository.dart';

/// 已验证候选只留在本机；确认凭据与 Canonical 写入共享事务。
class DriftRemoteReviewRepository {
  DriftRemoteReviewRepository(this.database);
  final LocalStorageDatabase database;

  Future<List<({String id, String payload})>> readReviews(
    String accountId,
    DateTime now,
  ) async {
    await database.customStatement(
      'DELETE FROM remote_review_records WHERE expires_at <= ?',
      [now.toUtc().millisecondsSinceEpoch],
    );
    final rows = await database
        .customSelect(
          'SELECT record_id, payload_json FROM remote_review_records WHERE account_id = ? ORDER BY rowid DESC',
          variables: [Variable(accountId)],
        )
        .get();
    return rows
        .map(
          (row) => (
            id: row.read<String>('record_id'),
            payload: row.read<String>('payload_json'),
          ),
        )
        .toList();
  }

  Future<void> saveReview(
    String accountId,
    String recordId,
    String? documentId,
    String payload,
    DateTime expiresAt,
  ) async {
    if (utf8.encode(payload).length > 1048576) {
      throw const FormatException('候选过大');
    }
    await database.transaction(() async {
      if (await hasAccepted(recordId)) return;
      final count = await database
          .customSelect('SELECT COUNT(*) AS n FROM remote_review_records')
          .getSingle();
      if (count.read<int>('n') >= 20) throw const FormatException('请先处理已保存候选');
      await database.customStatement(
        'INSERT OR REPLACE INTO remote_review_records VALUES (?, ?, ?, ?, ?)',
        [
          recordId,
          accountId,
          documentId,
          payload,
          expiresAt.toUtc().millisecondsSinceEpoch,
        ],
      );
    });
  }

  Future<bool> hasAccepted(String recordId) async =>
      (await database
              .customSelect(
                'SELECT record_id FROM remote_acceptance_receipts WHERE record_id = ?',
                variables: [Variable(recordId)],
              )
              .get())
          .isNotEmpty;

  Future<void> discardReview(String recordId) => database.customStatement(
    'DELETE FROM remote_review_records WHERE record_id = ?',
    [recordId],
  );

  Future<void> commitReview({
    required String recordId,
    required ResumeDocument document,
    required ResumeVersion version,
    String? expectedVersionId,
  }) => database.transaction(() async {
    if (await hasAccepted(recordId)) return;
    final repository = DriftResumeRepository(database);
    if (expectedVersionId == null) {
      await repository.createDocument(document, version);
    } else {
      await repository.saveVersion(
        document: document,
        version: version,
        expectedCurrentVersionId: expectedVersionId,
      );
    }
    // 任一步失败整个事务回滚；进程退出后不存在“版本已写、仍可确认”的窗口。
    await database.customStatement(
      'INSERT INTO remote_acceptance_receipts VALUES (?, ?, ?)',
      [recordId, document.id, version.id],
    );
    await discardReview(recordId);
  });

  Future<String?> readConversation(
    String accountId,
    String documentId,
    DateTime now,
  ) async {
    await database.customStatement(
      'DELETE FROM remote_conversations WHERE expires_at <= ?',
      [now.toUtc().millisecondsSinceEpoch],
    );
    final rows = await database
        .customSelect(
          'SELECT payload_json FROM remote_conversations WHERE account_id = ? AND document_id = ?',
          variables: [Variable(accountId), Variable(documentId)],
        )
        .get();
    return rows.isEmpty ? null : rows.single.read<String>('payload_json');
  }

  Future<void> saveConversation(
    String accountId,
    String documentId,
    String payload,
    DateTime expiresAt,
  ) async {
    // Confirmed writing material is bounded separately; keep it with the three recent rounds.
    if (utf8.encode(payload).length > 131072) {
      throw const FormatException('对话过大');
    }
    await database.customStatement(
      'INSERT OR REPLACE INTO remote_conversations VALUES (?, ?, ?, ?)',
      [
        accountId,
        documentId,
        payload,
        expiresAt.toUtc().millisecondsSinceEpoch,
      ],
    );
  }

  Future<void> removeDocument(String documentId) =>
      database.transaction(() async {
        await database.customStatement(
          'DELETE FROM remote_review_records WHERE document_id = ?',
          [documentId],
        );
        await database.customStatement(
          'DELETE FROM remote_conversations WHERE document_id = ?',
          [documentId],
        );
      });
}
