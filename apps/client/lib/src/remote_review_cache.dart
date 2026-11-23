import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_domain/resume_domain.dart';

import 'remote_resume_ai_service.dart';

String remoteReviewId(String accountId, String operationId) => sha256
    .convert(utf8.encode(jsonEncode([accountId, operationId])))
    .toString();

final class RemoteReviewCache {
  RemoteReviewCache(this.repository, this.clock);
  final DriftRemoteReviewRepository repository;
  final DateTime Function() clock;

  Future<void> save(String accountId, PendingRemoteResumeChange change) =>
      repository.saveReview(
        accountId,
        remoteReviewId(accountId, change.operationId),
        change.documentId,
        jsonEncode({
          'schemaVersion': 1,
          'expiresAtUtc': clock()
              .toUtc()
              .add(const Duration(days: 7))
              .toIso8601String(),
          'target': change.target.name,
          'documentTitle': change.documentTitle,
          'documentId': change.documentId,
          'baseVersionId': change.baseVersionId,
          'operationId': change.operationId,
          'networkGenerated': change.networkGenerated,
          if (change.aigcMetadata != null)
            'aigcMetadata': change.aigcMetadata!.toJson(),
          'summary': change.summary,
          'baseContent': change.baseContent.toJson(),
          'proposedContent': change.proposedContent.toJson(),
          'patch': change.patch.toJson(),
          'missingInformation': change.missingInformation,
          'warnings': change.warnings,
        }),
        clock().toUtc().add(const Duration(days: 7)),
      );

  Future<PendingRemoteResumeChange?> restore(
    String accountId,
    ResumeRepository resumes,
  ) async {
    for (final record in await repository.readReviews(accountId, clock())) {
      if (await repository.hasAccepted(record.id)) {
        await repository.discardReview(record.id);
        continue;
      }
      final PendingRemoteResumeChange change;
      try {
        final json = jsonDecode(record.payload) as Map<String, dynamic>;
        if (json['schemaVersion'] != 1) throw const FormatException();
        final expiresAt = DateTime.parse(
          json['expiresAtUtc'] as String,
        ).toUtc();
        if (!expiresAt.isAfter(clock().toUtc())) throw const FormatException();
        final base = const CanonicalResumeCodec().decode(
          jsonEncode(json['baseContent']),
        );
        final proposed = const CanonicalResumeCodec().decode(
          jsonEncode(json['proposedContent']),
        );
        final patch = ResumePatch.fromJson(
          json['patch'] as Map<String, dynamic>,
        );
        if (!jsonDeepEquals(patch.apply(base).toJson(), proposed.toJson())) {
          throw const FormatException();
        }
        final target = RemoteResumeChangeTarget.values.byName(
          json['target'] as String,
        );
        final documentId = json['documentId'] as String?;
        final baseVersionId = json['baseVersionId'] as String?;
        if (target == RemoteResumeChangeTarget.newDocument &&
            (documentId != null || baseVersionId != null)) {
          throw const FormatException();
        }
        final operationId = json['operationId'] as String;
        if (remoteReviewId(accountId, operationId) != record.id) {
          throw const FormatException();
        }
        change = PendingRemoteResumeChange(
          target: target,
          documentTitle: json['documentTitle'] as String,
          documentId: documentId,
          baseVersionId: baseVersionId,
          operationId: operationId,
          // Old review caches did not distinguish local test providers from a
          // network generation. Preserve their content without inventing origin.
          networkGenerated: json['networkGenerated'] as bool? ?? false,
          aigcMetadata: json.containsKey('aigcMetadata')
              ? ResumeAigcMetadata.fromJson(json['aigcMetadata'])
              : null,
          summary: json['summary'] as String,
          baseContent: base,
          proposedContent: proposed,
          patch: patch,
          diff: ResumeDiff.fromPatch(patch),
          missingInformation: (json['missingInformation'] as List)
              .cast<String>(),
          warnings: (json['warnings'] as List).cast<String>(),
          expiresAtUtc: expiresAt,
        );
      } on Object {
        // 这里只捕获纯解析校验错误。读取 SQLite 失败不能当作损坏候选删除。
        await repository.discardReview(record.id);
        throw const FormatException('保存的候选损坏或版本不兼容，已丢弃；简历未改变');
      }
      if (change.target == RemoteResumeChangeTarget.currentDocument) {
        final version = change.documentId == null
            ? null
            : await resumes.findCurrentVersion(change.documentId!);
        if (version == null ||
            version.id != change.baseVersionId ||
            !jsonDeepEquals(
              version.content.toJson(),
              change.baseContent.toJson(),
            )) {
          await repository.discardReview(record.id);
          continue;
        }
      }
      return change;
    }
    return null;
  }
}
