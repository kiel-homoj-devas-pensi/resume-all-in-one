import 'model.dart';

/// 简历与不可变版本的持久化契约。
abstract interface class ResumeRepository {
  Future<void> createDocument(
    ResumeDocument document,
    ResumeVersion initialVersion,
  );

  Future<ResumeDocument?> findDocument(String documentId);

  Future<List<ResumeDocument>> listDocuments();

  Future<ResumeVersion?> findVersion(String versionId);

  Future<ResumeVersion?> findCurrentVersion(String documentId);

  Future<List<ResumeVersion>> listVersions(String documentId);

  /// 追加版本并原子更新文档的当前版本指针。
  Future<void> saveVersion({
    required ResumeDocument document,
    required ResumeVersion version,
    required String expectedCurrentVersionId,
  });

  Future<bool> deleteDocument(String documentId);
}

/// 当前版本已被其他写入推进，调用方应重新读取后再决定如何处理。
final class ResumeWriteConflict implements Exception {
  const ResumeWriteConflict({
    required this.documentId,
    required this.expectedVersionId,
    required this.actualVersionId,
  });

  final String documentId;
  final String? expectedVersionId;
  final String? actualVersionId;

  @override
  String toString() =>
      'ResumeWriteConflict(documentId: $documentId, '
      'expectedVersionId: $expectedVersionId, '
      'actualVersionId: $actualVersionId)';
}

final class ResumeNotFound implements Exception {
  const ResumeNotFound(this.documentId);

  final String documentId;

  @override
  String toString() => 'ResumeNotFound(documentId: $documentId)';
}
