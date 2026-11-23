import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:resume_domain/resume_domain.dart';

import 'database.dart';

/// 表示数据库中的 Canonical JSON 已损坏或与关系字段不一致。
final class StoredResumeDataException implements Exception {
  const StoredResumeDataException({
    required this.recordId,
    required this.field,
  });

  final String recordId;
  final String field;

  @override
  String toString() =>
      'StoredResumeDataException(recordId: $recordId, field: $field)';
}

final class DriftResumeRepository implements ResumeRepository {
  DriftResumeRepository(
    this._database, {
    CanonicalResumeCodec codec = const CanonicalResumeCodec(),
  }) : _codec = codec;

  final LocalStorageDatabase _database;
  final CanonicalResumeCodec _codec;

  @override
  Future<void> createDocument(
    ResumeDocument document,
    ResumeVersion initialVersion,
  ) async {
    _validateCreate(document, initialVersion);
    final contentJson = _codec.encode(initialVersion.content);

    await _database.transaction(() async {
      final existing = await _findDocumentRow(document.id);
      if (existing != null) {
        throw ResumeWriteConflict(
          documentId: document.id,
          expectedVersionId: null,
          actualVersionId: existing.currentVersionId,
        );
      }
      if (await _findVersionRow(initialVersion.id) != null) {
        throw StateError('版本 ID 已存在：${initialVersion.id}');
      }

      await _database
          .into(_database.resumeDocuments)
          .insert(_documentCompanion(document));
      await _database
          .into(_database.resumeVersions)
          .insert(_versionCompanion(initialVersion, contentJson));
    });
  }

  @override
  Future<ResumeDocument?> findDocument(String documentId) async {
    final row = await _findDocumentRow(documentId);
    return row == null ? null : _documentFromRow(row);
  }

  @override
  Future<List<ResumeDocument>> listDocuments() async {
    final query = _database.select(_database.resumeDocuments)
      ..orderBy([
        (table) => OrderingTerm.desc(table.updatedAt),
        (table) => OrderingTerm.asc(table.id),
      ]);
    final rows = await query.get();
    return List<ResumeDocument>.unmodifiable(rows.map(_documentFromRow));
  }

  @override
  Future<ResumeVersion?> findVersion(String versionId) async {
    final row = await _findVersionRow(versionId);
    return row == null ? null : _versionFromRow(row);
  }

  @override
  Future<ResumeVersion?> findCurrentVersion(String documentId) async {
    final document = await _findDocumentRow(documentId);
    if (document == null || document.currentVersionId == null) {
      return null;
    }

    final version = await _findVersionRow(document.currentVersionId!);
    if (version == null || version.documentId != documentId) {
      throw StoredResumeDataException(
        recordId: documentId,
        field: 'current_version_id',
      );
    }
    return _versionFromRow(version);
  }

  @override
  Future<List<ResumeVersion>> listVersions(String documentId) async {
    final query = _database.select(_database.resumeVersions)
      ..where((table) => table.documentId.equals(documentId))
      ..orderBy([
        (table) => OrderingTerm.desc(table.createdAt),
        (table) => OrderingTerm.desc(table.id),
      ]);
    final rows = await query.get();
    return List<ResumeVersion>.unmodifiable(rows.map(_versionFromRow));
  }

  @override
  Future<void> saveVersion({
    required ResumeDocument document,
    required ResumeVersion version,
    required String expectedCurrentVersionId,
  }) async {
    _validateUpdate(document, version, expectedCurrentVersionId);
    final contentJson = _codec.encode(version.content);

    await _database.transaction(() async {
      final storedDocument = await _findDocumentRow(document.id);
      if (storedDocument == null) {
        throw ResumeNotFound(document.id);
      }
      // 在提交事务内核对基础版本，防止审阅/编辑期间的其他保存被覆盖。
      if (storedDocument.currentVersionId != expectedCurrentVersionId) {
        throw ResumeWriteConflict(
          documentId: document.id,
          expectedVersionId: expectedCurrentVersionId,
          actualVersionId: storedDocument.currentVersionId,
        );
      }
      if (!_sameInstant(storedDocument.createdAt, document.createdAt)) {
        throw ArgumentError.value(
          document.createdAt,
          'document.createdAt',
          '文档创建时间不可修改',
        );
      }
      if (document.updatedAt.isBefore(storedDocument.updatedAt)) {
        throw ArgumentError.value(
          document.updatedAt,
          'document.updatedAt',
          '文档更新时间不可倒退',
        );
      }
      if (await _findVersionRow(version.id) != null) {
        throw StateError('版本 ID 已存在：${version.id}');
      }

      // 先追加快照，再推进指针；后一步失败也必须回滚前一步，
      // 否则历史会出现一次被报告为失败的保存。
      await _database
          .into(_database.resumeVersions)
          .insert(_versionCompanion(version, contentJson));
      final updatedDocumentCount =
          await (_database.update(_database.resumeDocuments)
                ..where((table) => table.id.equals(document.id)))
              .write(_documentCompanion(document));
      if (updatedDocumentCount != 1) {
        throw StateError('文档更新数量异常：${document.id}');
      }
    });
  }

  @override
  Future<bool> deleteDocument(String documentId) async {
    return _database.transaction(() async {
      await _database.customStatement(
        'DELETE FROM remote_review_records WHERE document_id = ?',
        [documentId],
      );
      await _database.customStatement(
        'DELETE FROM remote_conversations WHERE document_id = ?',
        [documentId],
      );
      final deleted = await (_database.delete(
        _database.resumeDocuments,
      )..where((table) => table.id.equals(documentId))).go();
      return deleted == 1;
    });
  }

  Future<ResumeDocumentRow?> _findDocumentRow(String documentId) {
    return (_database.select(
      _database.resumeDocuments,
    )..where((table) => table.id.equals(documentId))).getSingleOrNull();
  }

  Future<ResumeVersionRow?> _findVersionRow(String versionId) {
    return (_database.select(
      _database.resumeVersions,
    )..where((table) => table.id.equals(versionId))).getSingleOrNull();
  }

  ResumeDocument _documentFromRow(ResumeDocumentRow row) {
    try {
      return ResumeDocument(
        id: row.id,
        title: row.title,
        currentVersionId: row.currentVersionId,
        createdAt: row.createdAt.toUtc(),
        updatedAt: row.updatedAt.toUtc(),
        metadata: _decodeObject(row.metadataJson, row.id, 'metadata_json'),
        extensions: _decodeObject(
          row.extensionsJson,
          row.id,
          'extensions_json',
        ),
      );
    } on FormatException {
      throw StoredResumeDataException(recordId: row.id, field: 'document_json');
    }
  }

  ResumeVersion _versionFromRow(ResumeVersionRow row) {
    try {
      return ResumeVersion(
        id: row.id,
        documentId: row.documentId,
        parentVersionId: row.parentVersionId,
        schemaVersion: row.schemaVersion,
        content: _codec.decode(row.contentJson),
        source: _parseSource(row.source, row.id),
        createdAt: row.createdAt.toUtc(),
        extensions: _decodeObject(
          row.extensionsJson,
          row.id,
          'extensions_json',
        ),
      );
    } on StoredResumeDataException {
      rethrow;
    } on SchemaFormatException {
      throw StoredResumeDataException(recordId: row.id, field: 'version_json');
    } on ResumeValidationException {
      throw StoredResumeDataException(recordId: row.id, field: 'version_json');
    } on UnsupportedSchemaVersionException {
      throw StoredResumeDataException(recordId: row.id, field: 'version_json');
    }
  }

  JsonMap _decodeObject(String source, String recordId, String field) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw StoredResumeDataException(recordId: recordId, field: field);
    }
    if (decoded is! Map<String, Object?>) {
      throw StoredResumeDataException(recordId: recordId, field: field);
    }
    return decoded;
  }

  ResumeVersionSource _parseSource(String source, String recordId) {
    for (final value in ResumeVersionSource.values) {
      if (value.name == source) {
        return value;
      }
    }
    throw StoredResumeDataException(recordId: recordId, field: 'source');
  }

  ResumeDocumentsCompanion _documentCompanion(ResumeDocument document) {
    return ResumeDocumentsCompanion(
      id: Value(document.id),
      title: Value(document.title),
      currentVersionId: Value(document.currentVersionId),
      createdAt: Value(document.createdAt.toUtc()),
      updatedAt: Value(document.updatedAt.toUtc()),
      metadataJson: Value(jsonEncode(document.metadata)),
      extensionsJson: Value(jsonEncode(document.extensions)),
    );
  }

  ResumeVersionsCompanion _versionCompanion(
    ResumeVersion version,
    String contentJson,
  ) {
    return ResumeVersionsCompanion(
      id: Value(version.id),
      documentId: Value(version.documentId),
      parentVersionId: Value(version.parentVersionId),
      schemaVersion: Value(version.schemaVersion),
      contentJson: Value(contentJson),
      source: Value(version.source.name),
      createdAt: Value(version.createdAt.toUtc()),
      extensionsJson: Value(jsonEncode(version.extensions)),
    );
  }

  void _validateCreate(ResumeDocument document, ResumeVersion initialVersion) {
    _validatePair(document, initialVersion);
    if (initialVersion.parentVersionId != null) {
      throw ArgumentError.value(
        initialVersion.parentVersionId,
        'initialVersion.parentVersionId',
        '首个版本不能有父版本',
      );
    }
  }

  void _validateUpdate(
    ResumeDocument document,
    ResumeVersion version,
    String expectedCurrentVersionId,
  ) {
    _validatePair(document, version);
    _requireText(expectedCurrentVersionId, 'expectedCurrentVersionId');
    if (version.parentVersionId != expectedCurrentVersionId) {
      throw ArgumentError.value(
        version.parentVersionId,
        'version.parentVersionId',
        '父版本必须是预期当前版本',
      );
    }
  }

  void _validatePair(ResumeDocument document, ResumeVersion version) {
    _requireText(document.id, 'document.id');
    _requireText(document.title, 'document.title');
    _requireText(version.id, 'version.id');
    if (version.documentId != document.id) {
      throw ArgumentError.value(
        version.documentId,
        'version.documentId',
        '版本必须属于目标文档',
      );
    }
    if (document.currentVersionId != version.id) {
      throw ArgumentError.value(
        document.currentVersionId,
        'document.currentVersionId',
        '当前版本指针必须指向待保存版本',
      );
    }
    if (document.updatedAt.isBefore(document.createdAt)) {
      throw ArgumentError.value(
        document.updatedAt,
        'document.updatedAt',
        '更新时间不能早于创建时间',
      );
    }
  }

  void _requireText(String value, String name) {
    if (value.trim().isEmpty) {
      throw ArgumentError.value(value, name, '不能为空');
    }
  }

  bool _sameInstant(DateTime left, DateTime right) {
    return left.toUtc().microsecondsSinceEpoch ==
        right.toUtc().microsecondsSinceEpoch;
  }
}
