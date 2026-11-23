// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $ResumeDocumentsTable extends ResumeDocuments
    with TableInfo<$ResumeDocumentsTable, ResumeDocumentRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ResumeDocumentsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(minTextLength: 1),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(minTextLength: 1),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _currentVersionIdMeta = const VerificationMeta(
    'currentVersionId',
  );
  @override
  late final GeneratedColumn<String> currentVersionId = GeneratedColumn<String>(
    'current_version_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  late final GeneratedColumnWithTypeConverter<DateTime, int> createdAt =
      GeneratedColumn<int>(
        'created_at',
        aliasedName,
        false,
        type: DriftSqlType.int,
        requiredDuringInsert: true,
      ).withConverter<DateTime>($ResumeDocumentsTable.$convertercreatedAt);
  @override
  late final GeneratedColumnWithTypeConverter<DateTime, int> updatedAt =
      GeneratedColumn<int>(
        'updated_at',
        aliasedName,
        false,
        type: DriftSqlType.int,
        requiredDuringInsert: true,
      ).withConverter<DateTime>($ResumeDocumentsTable.$converterupdatedAt);
  static const VerificationMeta _metadataJsonMeta = const VerificationMeta(
    'metadataJson',
  );
  @override
  late final GeneratedColumn<String> metadataJson = GeneratedColumn<String>(
    'metadata_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _extensionsJsonMeta = const VerificationMeta(
    'extensionsJson',
  );
  @override
  late final GeneratedColumn<String> extensionsJson = GeneratedColumn<String>(
    'extensions_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    currentVersionId,
    createdAt,
    updatedAt,
    metadataJson,
    extensionsJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'resume_documents';
  @override
  VerificationContext validateIntegrity(
    Insertable<ResumeDocumentRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('current_version_id')) {
      context.handle(
        _currentVersionIdMeta,
        currentVersionId.isAcceptableOrUnknown(
          data['current_version_id']!,
          _currentVersionIdMeta,
        ),
      );
    }
    if (data.containsKey('metadata_json')) {
      context.handle(
        _metadataJsonMeta,
        metadataJson.isAcceptableOrUnknown(
          data['metadata_json']!,
          _metadataJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_metadataJsonMeta);
    }
    if (data.containsKey('extensions_json')) {
      context.handle(
        _extensionsJsonMeta,
        extensionsJson.isAcceptableOrUnknown(
          data['extensions_json']!,
          _extensionsJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_extensionsJsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ResumeDocumentRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ResumeDocumentRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      currentVersionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}current_version_id'],
      ),
      createdAt: $ResumeDocumentsTable.$convertercreatedAt.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.int,
          data['${effectivePrefix}created_at'],
        )!,
      ),
      updatedAt: $ResumeDocumentsTable.$converterupdatedAt.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.int,
          data['${effectivePrefix}updated_at'],
        )!,
      ),
      metadataJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}metadata_json'],
      )!,
      extensionsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}extensions_json'],
      )!,
    );
  }

  @override
  $ResumeDocumentsTable createAlias(String alias) {
    return $ResumeDocumentsTable(attachedDatabase, alias);
  }

  static TypeConverter<DateTime, int> $convertercreatedAt =
      const _UtcDateTimeMicrosConverter();
  static TypeConverter<DateTime, int> $converterupdatedAt =
      const _UtcDateTimeMicrosConverter();
}

class ResumeDocumentRow extends DataClass
    implements Insertable<ResumeDocumentRow> {
  final String id;
  final String title;
  final String? currentVersionId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String metadataJson;
  final String extensionsJson;
  const ResumeDocumentRow({
    required this.id,
    required this.title,
    this.currentVersionId,
    required this.createdAt,
    required this.updatedAt,
    required this.metadataJson,
    required this.extensionsJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || currentVersionId != null) {
      map['current_version_id'] = Variable<String>(currentVersionId);
    }
    {
      map['created_at'] = Variable<int>(
        $ResumeDocumentsTable.$convertercreatedAt.toSql(createdAt),
      );
    }
    {
      map['updated_at'] = Variable<int>(
        $ResumeDocumentsTable.$converterupdatedAt.toSql(updatedAt),
      );
    }
    map['metadata_json'] = Variable<String>(metadataJson);
    map['extensions_json'] = Variable<String>(extensionsJson);
    return map;
  }

  ResumeDocumentsCompanion toCompanion(bool nullToAbsent) {
    return ResumeDocumentsCompanion(
      id: Value(id),
      title: Value(title),
      currentVersionId: currentVersionId == null && nullToAbsent
          ? const Value.absent()
          : Value(currentVersionId),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      metadataJson: Value(metadataJson),
      extensionsJson: Value(extensionsJson),
    );
  }

  factory ResumeDocumentRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ResumeDocumentRow(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      currentVersionId: serializer.fromJson<String?>(json['currentVersionId']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      metadataJson: serializer.fromJson<String>(json['metadataJson']),
      extensionsJson: serializer.fromJson<String>(json['extensionsJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'currentVersionId': serializer.toJson<String?>(currentVersionId),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'metadataJson': serializer.toJson<String>(metadataJson),
      'extensionsJson': serializer.toJson<String>(extensionsJson),
    };
  }

  ResumeDocumentRow copyWith({
    String? id,
    String? title,
    Value<String?> currentVersionId = const Value.absent(),
    DateTime? createdAt,
    DateTime? updatedAt,
    String? metadataJson,
    String? extensionsJson,
  }) => ResumeDocumentRow(
    id: id ?? this.id,
    title: title ?? this.title,
    currentVersionId: currentVersionId.present
        ? currentVersionId.value
        : this.currentVersionId,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    metadataJson: metadataJson ?? this.metadataJson,
    extensionsJson: extensionsJson ?? this.extensionsJson,
  );
  ResumeDocumentRow copyWithCompanion(ResumeDocumentsCompanion data) {
    return ResumeDocumentRow(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      currentVersionId: data.currentVersionId.present
          ? data.currentVersionId.value
          : this.currentVersionId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      metadataJson: data.metadataJson.present
          ? data.metadataJson.value
          : this.metadataJson,
      extensionsJson: data.extensionsJson.present
          ? data.extensionsJson.value
          : this.extensionsJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ResumeDocumentRow(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('currentVersionId: $currentVersionId, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('metadataJson: $metadataJson, ')
          ..write('extensionsJson: $extensionsJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    currentVersionId,
    createdAt,
    updatedAt,
    metadataJson,
    extensionsJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ResumeDocumentRow &&
          other.id == this.id &&
          other.title == this.title &&
          other.currentVersionId == this.currentVersionId &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.metadataJson == this.metadataJson &&
          other.extensionsJson == this.extensionsJson);
}

class ResumeDocumentsCompanion extends UpdateCompanion<ResumeDocumentRow> {
  final Value<String> id;
  final Value<String> title;
  final Value<String?> currentVersionId;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<String> metadataJson;
  final Value<String> extensionsJson;
  final Value<int> rowid;
  const ResumeDocumentsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.currentVersionId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.metadataJson = const Value.absent(),
    this.extensionsJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ResumeDocumentsCompanion.insert({
    required String id,
    required String title,
    this.currentVersionId = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
    required String metadataJson,
    required String extensionsJson,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt),
       metadataJson = Value(metadataJson),
       extensionsJson = Value(extensionsJson);
  static Insertable<ResumeDocumentRow> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<String>? currentVersionId,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<String>? metadataJson,
    Expression<String>? extensionsJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (currentVersionId != null) 'current_version_id': currentVersionId,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (metadataJson != null) 'metadata_json': metadataJson,
      if (extensionsJson != null) 'extensions_json': extensionsJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ResumeDocumentsCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<String?>? currentVersionId,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<String>? metadataJson,
    Value<String>? extensionsJson,
    Value<int>? rowid,
  }) {
    return ResumeDocumentsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      currentVersionId: currentVersionId ?? this.currentVersionId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      metadataJson: metadataJson ?? this.metadataJson,
      extensionsJson: extensionsJson ?? this.extensionsJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (currentVersionId.present) {
      map['current_version_id'] = Variable<String>(currentVersionId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(
        $ResumeDocumentsTable.$convertercreatedAt.toSql(createdAt.value),
      );
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(
        $ResumeDocumentsTable.$converterupdatedAt.toSql(updatedAt.value),
      );
    }
    if (metadataJson.present) {
      map['metadata_json'] = Variable<String>(metadataJson.value);
    }
    if (extensionsJson.present) {
      map['extensions_json'] = Variable<String>(extensionsJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ResumeDocumentsCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('currentVersionId: $currentVersionId, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('metadataJson: $metadataJson, ')
          ..write('extensionsJson: $extensionsJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ResumeVersionsTable extends ResumeVersions
    with TableInfo<$ResumeVersionsTable, ResumeVersionRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ResumeVersionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(minTextLength: 1),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _documentIdMeta = const VerificationMeta(
    'documentId',
  );
  @override
  late final GeneratedColumn<String> documentId = GeneratedColumn<String>(
    'document_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES resume_documents (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _parentVersionIdMeta = const VerificationMeta(
    'parentVersionId',
  );
  @override
  late final GeneratedColumn<String> parentVersionId = GeneratedColumn<String>(
    'parent_version_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _schemaVersionMeta = const VerificationMeta(
    'schemaVersion',
  );
  @override
  late final GeneratedColumn<String> schemaVersion = GeneratedColumn<String>(
    'schema_version',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(minTextLength: 1),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentJsonMeta = const VerificationMeta(
    'contentJson',
  );
  @override
  late final GeneratedColumn<String> contentJson = GeneratedColumn<String>(
    'content_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(minTextLength: 1),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  late final GeneratedColumnWithTypeConverter<DateTime, int> createdAt =
      GeneratedColumn<int>(
        'created_at',
        aliasedName,
        false,
        type: DriftSqlType.int,
        requiredDuringInsert: true,
      ).withConverter<DateTime>($ResumeVersionsTable.$convertercreatedAt);
  static const VerificationMeta _extensionsJsonMeta = const VerificationMeta(
    'extensionsJson',
  );
  @override
  late final GeneratedColumn<String> extensionsJson = GeneratedColumn<String>(
    'extensions_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    documentId,
    parentVersionId,
    schemaVersion,
    contentJson,
    source,
    createdAt,
    extensionsJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'resume_versions';
  @override
  VerificationContext validateIntegrity(
    Insertable<ResumeVersionRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('document_id')) {
      context.handle(
        _documentIdMeta,
        documentId.isAcceptableOrUnknown(data['document_id']!, _documentIdMeta),
      );
    } else if (isInserting) {
      context.missing(_documentIdMeta);
    }
    if (data.containsKey('parent_version_id')) {
      context.handle(
        _parentVersionIdMeta,
        parentVersionId.isAcceptableOrUnknown(
          data['parent_version_id']!,
          _parentVersionIdMeta,
        ),
      );
    }
    if (data.containsKey('schema_version')) {
      context.handle(
        _schemaVersionMeta,
        schemaVersion.isAcceptableOrUnknown(
          data['schema_version']!,
          _schemaVersionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_schemaVersionMeta);
    }
    if (data.containsKey('content_json')) {
      context.handle(
        _contentJsonMeta,
        contentJson.isAcceptableOrUnknown(
          data['content_json']!,
          _contentJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_contentJsonMeta);
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceMeta);
    }
    if (data.containsKey('extensions_json')) {
      context.handle(
        _extensionsJsonMeta,
        extensionsJson.isAcceptableOrUnknown(
          data['extensions_json']!,
          _extensionsJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_extensionsJsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ResumeVersionRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ResumeVersionRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      documentId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}document_id'],
      )!,
      parentVersionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}parent_version_id'],
      ),
      schemaVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}schema_version'],
      )!,
      contentJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_json'],
      )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      createdAt: $ResumeVersionsTable.$convertercreatedAt.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.int,
          data['${effectivePrefix}created_at'],
        )!,
      ),
      extensionsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}extensions_json'],
      )!,
    );
  }

  @override
  $ResumeVersionsTable createAlias(String alias) {
    return $ResumeVersionsTable(attachedDatabase, alias);
  }

  static TypeConverter<DateTime, int> $convertercreatedAt =
      const _UtcDateTimeMicrosConverter();
}

class ResumeVersionRow extends DataClass
    implements Insertable<ResumeVersionRow> {
  final String id;
  final String documentId;
  final String? parentVersionId;
  final String schemaVersion;
  final String contentJson;
  final String source;
  final DateTime createdAt;
  final String extensionsJson;
  const ResumeVersionRow({
    required this.id,
    required this.documentId,
    this.parentVersionId,
    required this.schemaVersion,
    required this.contentJson,
    required this.source,
    required this.createdAt,
    required this.extensionsJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['document_id'] = Variable<String>(documentId);
    if (!nullToAbsent || parentVersionId != null) {
      map['parent_version_id'] = Variable<String>(parentVersionId);
    }
    map['schema_version'] = Variable<String>(schemaVersion);
    map['content_json'] = Variable<String>(contentJson);
    map['source'] = Variable<String>(source);
    {
      map['created_at'] = Variable<int>(
        $ResumeVersionsTable.$convertercreatedAt.toSql(createdAt),
      );
    }
    map['extensions_json'] = Variable<String>(extensionsJson);
    return map;
  }

  ResumeVersionsCompanion toCompanion(bool nullToAbsent) {
    return ResumeVersionsCompanion(
      id: Value(id),
      documentId: Value(documentId),
      parentVersionId: parentVersionId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentVersionId),
      schemaVersion: Value(schemaVersion),
      contentJson: Value(contentJson),
      source: Value(source),
      createdAt: Value(createdAt),
      extensionsJson: Value(extensionsJson),
    );
  }

  factory ResumeVersionRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ResumeVersionRow(
      id: serializer.fromJson<String>(json['id']),
      documentId: serializer.fromJson<String>(json['documentId']),
      parentVersionId: serializer.fromJson<String?>(json['parentVersionId']),
      schemaVersion: serializer.fromJson<String>(json['schemaVersion']),
      contentJson: serializer.fromJson<String>(json['contentJson']),
      source: serializer.fromJson<String>(json['source']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      extensionsJson: serializer.fromJson<String>(json['extensionsJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'documentId': serializer.toJson<String>(documentId),
      'parentVersionId': serializer.toJson<String?>(parentVersionId),
      'schemaVersion': serializer.toJson<String>(schemaVersion),
      'contentJson': serializer.toJson<String>(contentJson),
      'source': serializer.toJson<String>(source),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'extensionsJson': serializer.toJson<String>(extensionsJson),
    };
  }

  ResumeVersionRow copyWith({
    String? id,
    String? documentId,
    Value<String?> parentVersionId = const Value.absent(),
    String? schemaVersion,
    String? contentJson,
    String? source,
    DateTime? createdAt,
    String? extensionsJson,
  }) => ResumeVersionRow(
    id: id ?? this.id,
    documentId: documentId ?? this.documentId,
    parentVersionId: parentVersionId.present
        ? parentVersionId.value
        : this.parentVersionId,
    schemaVersion: schemaVersion ?? this.schemaVersion,
    contentJson: contentJson ?? this.contentJson,
    source: source ?? this.source,
    createdAt: createdAt ?? this.createdAt,
    extensionsJson: extensionsJson ?? this.extensionsJson,
  );
  ResumeVersionRow copyWithCompanion(ResumeVersionsCompanion data) {
    return ResumeVersionRow(
      id: data.id.present ? data.id.value : this.id,
      documentId: data.documentId.present
          ? data.documentId.value
          : this.documentId,
      parentVersionId: data.parentVersionId.present
          ? data.parentVersionId.value
          : this.parentVersionId,
      schemaVersion: data.schemaVersion.present
          ? data.schemaVersion.value
          : this.schemaVersion,
      contentJson: data.contentJson.present
          ? data.contentJson.value
          : this.contentJson,
      source: data.source.present ? data.source.value : this.source,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      extensionsJson: data.extensionsJson.present
          ? data.extensionsJson.value
          : this.extensionsJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ResumeVersionRow(')
          ..write('id: $id, ')
          ..write('documentId: $documentId, ')
          ..write('parentVersionId: $parentVersionId, ')
          ..write('schemaVersion: $schemaVersion, ')
          ..write('contentJson: $contentJson, ')
          ..write('source: $source, ')
          ..write('createdAt: $createdAt, ')
          ..write('extensionsJson: $extensionsJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    documentId,
    parentVersionId,
    schemaVersion,
    contentJson,
    source,
    createdAt,
    extensionsJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ResumeVersionRow &&
          other.id == this.id &&
          other.documentId == this.documentId &&
          other.parentVersionId == this.parentVersionId &&
          other.schemaVersion == this.schemaVersion &&
          other.contentJson == this.contentJson &&
          other.source == this.source &&
          other.createdAt == this.createdAt &&
          other.extensionsJson == this.extensionsJson);
}

class ResumeVersionsCompanion extends UpdateCompanion<ResumeVersionRow> {
  final Value<String> id;
  final Value<String> documentId;
  final Value<String?> parentVersionId;
  final Value<String> schemaVersion;
  final Value<String> contentJson;
  final Value<String> source;
  final Value<DateTime> createdAt;
  final Value<String> extensionsJson;
  final Value<int> rowid;
  const ResumeVersionsCompanion({
    this.id = const Value.absent(),
    this.documentId = const Value.absent(),
    this.parentVersionId = const Value.absent(),
    this.schemaVersion = const Value.absent(),
    this.contentJson = const Value.absent(),
    this.source = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.extensionsJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ResumeVersionsCompanion.insert({
    required String id,
    required String documentId,
    this.parentVersionId = const Value.absent(),
    required String schemaVersion,
    required String contentJson,
    required String source,
    required DateTime createdAt,
    required String extensionsJson,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       documentId = Value(documentId),
       schemaVersion = Value(schemaVersion),
       contentJson = Value(contentJson),
       source = Value(source),
       createdAt = Value(createdAt),
       extensionsJson = Value(extensionsJson);
  static Insertable<ResumeVersionRow> custom({
    Expression<String>? id,
    Expression<String>? documentId,
    Expression<String>? parentVersionId,
    Expression<String>? schemaVersion,
    Expression<String>? contentJson,
    Expression<String>? source,
    Expression<int>? createdAt,
    Expression<String>? extensionsJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (documentId != null) 'document_id': documentId,
      if (parentVersionId != null) 'parent_version_id': parentVersionId,
      if (schemaVersion != null) 'schema_version': schemaVersion,
      if (contentJson != null) 'content_json': contentJson,
      if (source != null) 'source': source,
      if (createdAt != null) 'created_at': createdAt,
      if (extensionsJson != null) 'extensions_json': extensionsJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ResumeVersionsCompanion copyWith({
    Value<String>? id,
    Value<String>? documentId,
    Value<String?>? parentVersionId,
    Value<String>? schemaVersion,
    Value<String>? contentJson,
    Value<String>? source,
    Value<DateTime>? createdAt,
    Value<String>? extensionsJson,
    Value<int>? rowid,
  }) {
    return ResumeVersionsCompanion(
      id: id ?? this.id,
      documentId: documentId ?? this.documentId,
      parentVersionId: parentVersionId ?? this.parentVersionId,
      schemaVersion: schemaVersion ?? this.schemaVersion,
      contentJson: contentJson ?? this.contentJson,
      source: source ?? this.source,
      createdAt: createdAt ?? this.createdAt,
      extensionsJson: extensionsJson ?? this.extensionsJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (documentId.present) {
      map['document_id'] = Variable<String>(documentId.value);
    }
    if (parentVersionId.present) {
      map['parent_version_id'] = Variable<String>(parentVersionId.value);
    }
    if (schemaVersion.present) {
      map['schema_version'] = Variable<String>(schemaVersion.value);
    }
    if (contentJson.present) {
      map['content_json'] = Variable<String>(contentJson.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(
        $ResumeVersionsTable.$convertercreatedAt.toSql(createdAt.value),
      );
    }
    if (extensionsJson.present) {
      map['extensions_json'] = Variable<String>(extensionsJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ResumeVersionsCompanion(')
          ..write('id: $id, ')
          ..write('documentId: $documentId, ')
          ..write('parentVersionId: $parentVersionId, ')
          ..write('schemaVersion: $schemaVersion, ')
          ..write('contentJson: $contentJson, ')
          ..write('source: $source, ')
          ..write('createdAt: $createdAt, ')
          ..write('extensionsJson: $extensionsJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AppSettingsTable extends AppSettings
    with TableInfo<$AppSettingsTable, AppSettingRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AppSettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _settingKeyMeta = const VerificationMeta(
    'settingKey',
  );
  @override
  late final GeneratedColumn<String> settingKey = GeneratedColumn<String>(
    'setting_key',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(minTextLength: 1),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _boolValueMeta = const VerificationMeta(
    'boolValue',
  );
  @override
  late final GeneratedColumn<bool> boolValue = GeneratedColumn<bool>(
    'bool_value',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("bool_value" IN (0, 1))',
    ),
  );
  @override
  late final GeneratedColumnWithTypeConverter<DateTime, int> updatedAt =
      GeneratedColumn<int>(
        'updated_at',
        aliasedName,
        false,
        type: DriftSqlType.int,
        requiredDuringInsert: true,
      ).withConverter<DateTime>($AppSettingsTable.$converterupdatedAt);
  @override
  List<GeneratedColumn> get $columns => [settingKey, boolValue, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'app_settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<AppSettingRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('setting_key')) {
      context.handle(
        _settingKeyMeta,
        settingKey.isAcceptableOrUnknown(data['setting_key']!, _settingKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_settingKeyMeta);
    }
    if (data.containsKey('bool_value')) {
      context.handle(
        _boolValueMeta,
        boolValue.isAcceptableOrUnknown(data['bool_value']!, _boolValueMeta),
      );
    } else if (isInserting) {
      context.missing(_boolValueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {settingKey};
  @override
  AppSettingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AppSettingRow(
      settingKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}setting_key'],
      )!,
      boolValue: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}bool_value'],
      )!,
      updatedAt: $AppSettingsTable.$converterupdatedAt.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.int,
          data['${effectivePrefix}updated_at'],
        )!,
      ),
    );
  }

  @override
  $AppSettingsTable createAlias(String alias) {
    return $AppSettingsTable(attachedDatabase, alias);
  }

  static TypeConverter<DateTime, int> $converterupdatedAt =
      const _UtcDateTimeMicrosConverter();
}

class AppSettingRow extends DataClass implements Insertable<AppSettingRow> {
  final String settingKey;
  final bool boolValue;
  final DateTime updatedAt;
  const AppSettingRow({
    required this.settingKey,
    required this.boolValue,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['setting_key'] = Variable<String>(settingKey);
    map['bool_value'] = Variable<bool>(boolValue);
    {
      map['updated_at'] = Variable<int>(
        $AppSettingsTable.$converterupdatedAt.toSql(updatedAt),
      );
    }
    return map;
  }

  AppSettingsCompanion toCompanion(bool nullToAbsent) {
    return AppSettingsCompanion(
      settingKey: Value(settingKey),
      boolValue: Value(boolValue),
      updatedAt: Value(updatedAt),
    );
  }

  factory AppSettingRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AppSettingRow(
      settingKey: serializer.fromJson<String>(json['settingKey']),
      boolValue: serializer.fromJson<bool>(json['boolValue']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'settingKey': serializer.toJson<String>(settingKey),
      'boolValue': serializer.toJson<bool>(boolValue),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  AppSettingRow copyWith({
    String? settingKey,
    bool? boolValue,
    DateTime? updatedAt,
  }) => AppSettingRow(
    settingKey: settingKey ?? this.settingKey,
    boolValue: boolValue ?? this.boolValue,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  AppSettingRow copyWithCompanion(AppSettingsCompanion data) {
    return AppSettingRow(
      settingKey: data.settingKey.present
          ? data.settingKey.value
          : this.settingKey,
      boolValue: data.boolValue.present ? data.boolValue.value : this.boolValue,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AppSettingRow(')
          ..write('settingKey: $settingKey, ')
          ..write('boolValue: $boolValue, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(settingKey, boolValue, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AppSettingRow &&
          other.settingKey == this.settingKey &&
          other.boolValue == this.boolValue &&
          other.updatedAt == this.updatedAt);
}

class AppSettingsCompanion extends UpdateCompanion<AppSettingRow> {
  final Value<String> settingKey;
  final Value<bool> boolValue;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const AppSettingsCompanion({
    this.settingKey = const Value.absent(),
    this.boolValue = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AppSettingsCompanion.insert({
    required String settingKey,
    required bool boolValue,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : settingKey = Value(settingKey),
       boolValue = Value(boolValue),
       updatedAt = Value(updatedAt);
  static Insertable<AppSettingRow> custom({
    Expression<String>? settingKey,
    Expression<bool>? boolValue,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (settingKey != null) 'setting_key': settingKey,
      if (boolValue != null) 'bool_value': boolValue,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AppSettingsCompanion copyWith({
    Value<String>? settingKey,
    Value<bool>? boolValue,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return AppSettingsCompanion(
      settingKey: settingKey ?? this.settingKey,
      boolValue: boolValue ?? this.boolValue,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (settingKey.present) {
      map['setting_key'] = Variable<String>(settingKey.value);
    }
    if (boolValue.present) {
      map['bool_value'] = Variable<bool>(boolValue.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(
        $AppSettingsTable.$converterupdatedAt.toSql(updatedAt.value),
      );
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AppSettingsCompanion(')
          ..write('settingKey: $settingKey, ')
          ..write('boolValue: $boolValue, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AgentRunsTable extends AgentRuns
    with TableInfo<$AgentRunsTable, AgentRunRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AgentRunsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(minTextLength: 1),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _requestIdMeta = const VerificationMeta(
    'requestId',
  );
  @override
  late final GeneratedColumn<String> requestId = GeneratedColumn<String>(
    'request_id',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(minTextLength: 1),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'),
  );
  static const VerificationMeta _documentIdMeta = const VerificationMeta(
    'documentId',
  );
  @override
  late final GeneratedColumn<String> documentId = GeneratedColumn<String>(
    'document_id',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(minTextLength: 1),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _resumeVersionIdMeta = const VerificationMeta(
    'resumeVersionId',
  );
  @override
  late final GeneratedColumn<String> resumeVersionId = GeneratedColumn<String>(
    'resume_version_id',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(minTextLength: 1),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(minTextLength: 1),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _routeStatusMeta = const VerificationMeta(
    'routeStatus',
  );
  @override
  late final GeneratedColumn<String> routeStatus = GeneratedColumn<String>(
    'route_status',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(minTextLength: 1),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  late final GeneratedColumnWithTypeConverter<DateTime, int> startedAt =
      GeneratedColumn<int>(
        'started_at',
        aliasedName,
        false,
        type: DriftSqlType.int,
        requiredDuringInsert: true,
      ).withConverter<DateTime>($AgentRunsTable.$converterstartedAt);
  @override
  late final GeneratedColumnWithTypeConverter<DateTime, int> finishedAt =
      GeneratedColumn<int>(
        'finished_at',
        aliasedName,
        false,
        type: DriftSqlType.int,
        requiredDuringInsert: true,
      ).withConverter<DateTime>($AgentRunsTable.$converterfinishedAt);
  static const VerificationMeta _toolCallCountMeta = const VerificationMeta(
    'toolCallCount',
  );
  @override
  late final GeneratedColumn<int> toolCallCount = GeneratedColumn<int>(
    'tool_call_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _errorCodeMeta = const VerificationMeta(
    'errorCode',
  );
  @override
  late final GeneratedColumn<String> errorCode = GeneratedColumn<String>(
    'error_code',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    requestId,
    documentId,
    resumeVersionId,
    status,
    routeStatus,
    startedAt,
    finishedAt,
    toolCallCount,
    errorCode,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'agent_runs';
  @override
  VerificationContext validateIntegrity(
    Insertable<AgentRunRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('request_id')) {
      context.handle(
        _requestIdMeta,
        requestId.isAcceptableOrUnknown(data['request_id']!, _requestIdMeta),
      );
    } else if (isInserting) {
      context.missing(_requestIdMeta);
    }
    if (data.containsKey('document_id')) {
      context.handle(
        _documentIdMeta,
        documentId.isAcceptableOrUnknown(data['document_id']!, _documentIdMeta),
      );
    } else if (isInserting) {
      context.missing(_documentIdMeta);
    }
    if (data.containsKey('resume_version_id')) {
      context.handle(
        _resumeVersionIdMeta,
        resumeVersionId.isAcceptableOrUnknown(
          data['resume_version_id']!,
          _resumeVersionIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_resumeVersionIdMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('route_status')) {
      context.handle(
        _routeStatusMeta,
        routeStatus.isAcceptableOrUnknown(
          data['route_status']!,
          _routeStatusMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_routeStatusMeta);
    }
    if (data.containsKey('tool_call_count')) {
      context.handle(
        _toolCallCountMeta,
        toolCallCount.isAcceptableOrUnknown(
          data['tool_call_count']!,
          _toolCallCountMeta,
        ),
      );
    }
    if (data.containsKey('error_code')) {
      context.handle(
        _errorCodeMeta,
        errorCode.isAcceptableOrUnknown(data['error_code']!, _errorCodeMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AgentRunRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AgentRunRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      requestId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}request_id'],
      )!,
      documentId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}document_id'],
      )!,
      resumeVersionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}resume_version_id'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      routeStatus: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}route_status'],
      )!,
      startedAt: $AgentRunsTable.$converterstartedAt.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.int,
          data['${effectivePrefix}started_at'],
        )!,
      ),
      finishedAt: $AgentRunsTable.$converterfinishedAt.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.int,
          data['${effectivePrefix}finished_at'],
        )!,
      ),
      toolCallCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}tool_call_count'],
      )!,
      errorCode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}error_code'],
      ),
    );
  }

  @override
  $AgentRunsTable createAlias(String alias) {
    return $AgentRunsTable(attachedDatabase, alias);
  }

  static TypeConverter<DateTime, int> $converterstartedAt =
      const _UtcDateTimeMicrosConverter();
  static TypeConverter<DateTime, int> $converterfinishedAt =
      const _UtcDateTimeMicrosConverter();
}

class AgentRunRow extends DataClass implements Insertable<AgentRunRow> {
  final String id;
  final String requestId;
  final String documentId;
  final String resumeVersionId;
  final String status;
  final String routeStatus;
  final DateTime startedAt;
  final DateTime finishedAt;
  final int toolCallCount;
  final String? errorCode;
  const AgentRunRow({
    required this.id,
    required this.requestId,
    required this.documentId,
    required this.resumeVersionId,
    required this.status,
    required this.routeStatus,
    required this.startedAt,
    required this.finishedAt,
    required this.toolCallCount,
    this.errorCode,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['request_id'] = Variable<String>(requestId);
    map['document_id'] = Variable<String>(documentId);
    map['resume_version_id'] = Variable<String>(resumeVersionId);
    map['status'] = Variable<String>(status);
    map['route_status'] = Variable<String>(routeStatus);
    {
      map['started_at'] = Variable<int>(
        $AgentRunsTable.$converterstartedAt.toSql(startedAt),
      );
    }
    {
      map['finished_at'] = Variable<int>(
        $AgentRunsTable.$converterfinishedAt.toSql(finishedAt),
      );
    }
    map['tool_call_count'] = Variable<int>(toolCallCount);
    if (!nullToAbsent || errorCode != null) {
      map['error_code'] = Variable<String>(errorCode);
    }
    return map;
  }

  AgentRunsCompanion toCompanion(bool nullToAbsent) {
    return AgentRunsCompanion(
      id: Value(id),
      requestId: Value(requestId),
      documentId: Value(documentId),
      resumeVersionId: Value(resumeVersionId),
      status: Value(status),
      routeStatus: Value(routeStatus),
      startedAt: Value(startedAt),
      finishedAt: Value(finishedAt),
      toolCallCount: Value(toolCallCount),
      errorCode: errorCode == null && nullToAbsent
          ? const Value.absent()
          : Value(errorCode),
    );
  }

  factory AgentRunRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AgentRunRow(
      id: serializer.fromJson<String>(json['id']),
      requestId: serializer.fromJson<String>(json['requestId']),
      documentId: serializer.fromJson<String>(json['documentId']),
      resumeVersionId: serializer.fromJson<String>(json['resumeVersionId']),
      status: serializer.fromJson<String>(json['status']),
      routeStatus: serializer.fromJson<String>(json['routeStatus']),
      startedAt: serializer.fromJson<DateTime>(json['startedAt']),
      finishedAt: serializer.fromJson<DateTime>(json['finishedAt']),
      toolCallCount: serializer.fromJson<int>(json['toolCallCount']),
      errorCode: serializer.fromJson<String?>(json['errorCode']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'requestId': serializer.toJson<String>(requestId),
      'documentId': serializer.toJson<String>(documentId),
      'resumeVersionId': serializer.toJson<String>(resumeVersionId),
      'status': serializer.toJson<String>(status),
      'routeStatus': serializer.toJson<String>(routeStatus),
      'startedAt': serializer.toJson<DateTime>(startedAt),
      'finishedAt': serializer.toJson<DateTime>(finishedAt),
      'toolCallCount': serializer.toJson<int>(toolCallCount),
      'errorCode': serializer.toJson<String?>(errorCode),
    };
  }

  AgentRunRow copyWith({
    String? id,
    String? requestId,
    String? documentId,
    String? resumeVersionId,
    String? status,
    String? routeStatus,
    DateTime? startedAt,
    DateTime? finishedAt,
    int? toolCallCount,
    Value<String?> errorCode = const Value.absent(),
  }) => AgentRunRow(
    id: id ?? this.id,
    requestId: requestId ?? this.requestId,
    documentId: documentId ?? this.documentId,
    resumeVersionId: resumeVersionId ?? this.resumeVersionId,
    status: status ?? this.status,
    routeStatus: routeStatus ?? this.routeStatus,
    startedAt: startedAt ?? this.startedAt,
    finishedAt: finishedAt ?? this.finishedAt,
    toolCallCount: toolCallCount ?? this.toolCallCount,
    errorCode: errorCode.present ? errorCode.value : this.errorCode,
  );
  AgentRunRow copyWithCompanion(AgentRunsCompanion data) {
    return AgentRunRow(
      id: data.id.present ? data.id.value : this.id,
      requestId: data.requestId.present ? data.requestId.value : this.requestId,
      documentId: data.documentId.present
          ? data.documentId.value
          : this.documentId,
      resumeVersionId: data.resumeVersionId.present
          ? data.resumeVersionId.value
          : this.resumeVersionId,
      status: data.status.present ? data.status.value : this.status,
      routeStatus: data.routeStatus.present
          ? data.routeStatus.value
          : this.routeStatus,
      startedAt: data.startedAt.present ? data.startedAt.value : this.startedAt,
      finishedAt: data.finishedAt.present
          ? data.finishedAt.value
          : this.finishedAt,
      toolCallCount: data.toolCallCount.present
          ? data.toolCallCount.value
          : this.toolCallCount,
      errorCode: data.errorCode.present ? data.errorCode.value : this.errorCode,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AgentRunRow(')
          ..write('id: $id, ')
          ..write('requestId: $requestId, ')
          ..write('documentId: $documentId, ')
          ..write('resumeVersionId: $resumeVersionId, ')
          ..write('status: $status, ')
          ..write('routeStatus: $routeStatus, ')
          ..write('startedAt: $startedAt, ')
          ..write('finishedAt: $finishedAt, ')
          ..write('toolCallCount: $toolCallCount, ')
          ..write('errorCode: $errorCode')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    requestId,
    documentId,
    resumeVersionId,
    status,
    routeStatus,
    startedAt,
    finishedAt,
    toolCallCount,
    errorCode,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AgentRunRow &&
          other.id == this.id &&
          other.requestId == this.requestId &&
          other.documentId == this.documentId &&
          other.resumeVersionId == this.resumeVersionId &&
          other.status == this.status &&
          other.routeStatus == this.routeStatus &&
          other.startedAt == this.startedAt &&
          other.finishedAt == this.finishedAt &&
          other.toolCallCount == this.toolCallCount &&
          other.errorCode == this.errorCode);
}

class AgentRunsCompanion extends UpdateCompanion<AgentRunRow> {
  final Value<String> id;
  final Value<String> requestId;
  final Value<String> documentId;
  final Value<String> resumeVersionId;
  final Value<String> status;
  final Value<String> routeStatus;
  final Value<DateTime> startedAt;
  final Value<DateTime> finishedAt;
  final Value<int> toolCallCount;
  final Value<String?> errorCode;
  final Value<int> rowid;
  const AgentRunsCompanion({
    this.id = const Value.absent(),
    this.requestId = const Value.absent(),
    this.documentId = const Value.absent(),
    this.resumeVersionId = const Value.absent(),
    this.status = const Value.absent(),
    this.routeStatus = const Value.absent(),
    this.startedAt = const Value.absent(),
    this.finishedAt = const Value.absent(),
    this.toolCallCount = const Value.absent(),
    this.errorCode = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AgentRunsCompanion.insert({
    required String id,
    required String requestId,
    required String documentId,
    required String resumeVersionId,
    required String status,
    required String routeStatus,
    required DateTime startedAt,
    required DateTime finishedAt,
    this.toolCallCount = const Value.absent(),
    this.errorCode = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       requestId = Value(requestId),
       documentId = Value(documentId),
       resumeVersionId = Value(resumeVersionId),
       status = Value(status),
       routeStatus = Value(routeStatus),
       startedAt = Value(startedAt),
       finishedAt = Value(finishedAt);
  static Insertable<AgentRunRow> custom({
    Expression<String>? id,
    Expression<String>? requestId,
    Expression<String>? documentId,
    Expression<String>? resumeVersionId,
    Expression<String>? status,
    Expression<String>? routeStatus,
    Expression<int>? startedAt,
    Expression<int>? finishedAt,
    Expression<int>? toolCallCount,
    Expression<String>? errorCode,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (requestId != null) 'request_id': requestId,
      if (documentId != null) 'document_id': documentId,
      if (resumeVersionId != null) 'resume_version_id': resumeVersionId,
      if (status != null) 'status': status,
      if (routeStatus != null) 'route_status': routeStatus,
      if (startedAt != null) 'started_at': startedAt,
      if (finishedAt != null) 'finished_at': finishedAt,
      if (toolCallCount != null) 'tool_call_count': toolCallCount,
      if (errorCode != null) 'error_code': errorCode,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AgentRunsCompanion copyWith({
    Value<String>? id,
    Value<String>? requestId,
    Value<String>? documentId,
    Value<String>? resumeVersionId,
    Value<String>? status,
    Value<String>? routeStatus,
    Value<DateTime>? startedAt,
    Value<DateTime>? finishedAt,
    Value<int>? toolCallCount,
    Value<String?>? errorCode,
    Value<int>? rowid,
  }) {
    return AgentRunsCompanion(
      id: id ?? this.id,
      requestId: requestId ?? this.requestId,
      documentId: documentId ?? this.documentId,
      resumeVersionId: resumeVersionId ?? this.resumeVersionId,
      status: status ?? this.status,
      routeStatus: routeStatus ?? this.routeStatus,
      startedAt: startedAt ?? this.startedAt,
      finishedAt: finishedAt ?? this.finishedAt,
      toolCallCount: toolCallCount ?? this.toolCallCount,
      errorCode: errorCode ?? this.errorCode,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (requestId.present) {
      map['request_id'] = Variable<String>(requestId.value);
    }
    if (documentId.present) {
      map['document_id'] = Variable<String>(documentId.value);
    }
    if (resumeVersionId.present) {
      map['resume_version_id'] = Variable<String>(resumeVersionId.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (routeStatus.present) {
      map['route_status'] = Variable<String>(routeStatus.value);
    }
    if (startedAt.present) {
      map['started_at'] = Variable<int>(
        $AgentRunsTable.$converterstartedAt.toSql(startedAt.value),
      );
    }
    if (finishedAt.present) {
      map['finished_at'] = Variable<int>(
        $AgentRunsTable.$converterfinishedAt.toSql(finishedAt.value),
      );
    }
    if (toolCallCount.present) {
      map['tool_call_count'] = Variable<int>(toolCallCount.value);
    }
    if (errorCode.present) {
      map['error_code'] = Variable<String>(errorCode.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AgentRunsCompanion(')
          ..write('id: $id, ')
          ..write('requestId: $requestId, ')
          ..write('documentId: $documentId, ')
          ..write('resumeVersionId: $resumeVersionId, ')
          ..write('status: $status, ')
          ..write('routeStatus: $routeStatus, ')
          ..write('startedAt: $startedAt, ')
          ..write('finishedAt: $finishedAt, ')
          ..write('toolCallCount: $toolCallCount, ')
          ..write('errorCode: $errorCode, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ToolCallsTable extends ToolCalls
    with TableInfo<$ToolCallsTable, ToolCallRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ToolCallsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(minTextLength: 1),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _agentRunIdMeta = const VerificationMeta(
    'agentRunId',
  );
  @override
  late final GeneratedColumn<String> agentRunId = GeneratedColumn<String>(
    'agent_run_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES agent_runs (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _toolNameMeta = const VerificationMeta(
    'toolName',
  );
  @override
  late final GeneratedColumn<String> toolName = GeneratedColumn<String>(
    'tool_name',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(minTextLength: 1),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _toolVersionMeta = const VerificationMeta(
    'toolVersion',
  );
  @override
  late final GeneratedColumn<String> toolVersion = GeneratedColumn<String>(
    'tool_version',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(minTextLength: 1),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(minTextLength: 1),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  late final GeneratedColumnWithTypeConverter<DateTime, int> startedAt =
      GeneratedColumn<int>(
        'started_at',
        aliasedName,
        false,
        type: DriftSqlType.int,
        requiredDuringInsert: true,
      ).withConverter<DateTime>($ToolCallsTable.$converterstartedAt);
  @override
  late final GeneratedColumnWithTypeConverter<DateTime, int> finishedAt =
      GeneratedColumn<int>(
        'finished_at',
        aliasedName,
        false,
        type: DriftSqlType.int,
        requiredDuringInsert: true,
      ).withConverter<DateTime>($ToolCallsTable.$converterfinishedAt);
  static const VerificationMeta _offlineMeta = const VerificationMeta(
    'offline',
  );
  @override
  late final GeneratedColumn<bool> offline = GeneratedColumn<bool>(
    'offline',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("offline" IN (0, 1))',
    ),
  );
  static const VerificationMeta _replayedMeta = const VerificationMeta(
    'replayed',
  );
  @override
  late final GeneratedColumn<bool> replayed = GeneratedColumn<bool>(
    'replayed',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("replayed" IN (0, 1))',
    ),
  );
  static const VerificationMeta _errorCodeMeta = const VerificationMeta(
    'errorCode',
  );
  @override
  late final GeneratedColumn<String> errorCode = GeneratedColumn<String>(
    'error_code',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    agentRunId,
    toolName,
    toolVersion,
    status,
    startedAt,
    finishedAt,
    offline,
    replayed,
    errorCode,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'tool_calls';
  @override
  VerificationContext validateIntegrity(
    Insertable<ToolCallRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('agent_run_id')) {
      context.handle(
        _agentRunIdMeta,
        agentRunId.isAcceptableOrUnknown(
          data['agent_run_id']!,
          _agentRunIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_agentRunIdMeta);
    }
    if (data.containsKey('tool_name')) {
      context.handle(
        _toolNameMeta,
        toolName.isAcceptableOrUnknown(data['tool_name']!, _toolNameMeta),
      );
    } else if (isInserting) {
      context.missing(_toolNameMeta);
    }
    if (data.containsKey('tool_version')) {
      context.handle(
        _toolVersionMeta,
        toolVersion.isAcceptableOrUnknown(
          data['tool_version']!,
          _toolVersionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_toolVersionMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('offline')) {
      context.handle(
        _offlineMeta,
        offline.isAcceptableOrUnknown(data['offline']!, _offlineMeta),
      );
    } else if (isInserting) {
      context.missing(_offlineMeta);
    }
    if (data.containsKey('replayed')) {
      context.handle(
        _replayedMeta,
        replayed.isAcceptableOrUnknown(data['replayed']!, _replayedMeta),
      );
    } else if (isInserting) {
      context.missing(_replayedMeta);
    }
    if (data.containsKey('error_code')) {
      context.handle(
        _errorCodeMeta,
        errorCode.isAcceptableOrUnknown(data['error_code']!, _errorCodeMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ToolCallRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ToolCallRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      agentRunId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}agent_run_id'],
      )!,
      toolName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tool_name'],
      )!,
      toolVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tool_version'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      startedAt: $ToolCallsTable.$converterstartedAt.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.int,
          data['${effectivePrefix}started_at'],
        )!,
      ),
      finishedAt: $ToolCallsTable.$converterfinishedAt.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.int,
          data['${effectivePrefix}finished_at'],
        )!,
      ),
      offline: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}offline'],
      )!,
      replayed: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}replayed'],
      )!,
      errorCode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}error_code'],
      ),
    );
  }

  @override
  $ToolCallsTable createAlias(String alias) {
    return $ToolCallsTable(attachedDatabase, alias);
  }

  static TypeConverter<DateTime, int> $converterstartedAt =
      const _UtcDateTimeMicrosConverter();
  static TypeConverter<DateTime, int> $converterfinishedAt =
      const _UtcDateTimeMicrosConverter();
}

class ToolCallRow extends DataClass implements Insertable<ToolCallRow> {
  final String id;
  final String agentRunId;
  final String toolName;
  final String toolVersion;
  final String status;
  final DateTime startedAt;
  final DateTime finishedAt;
  final bool offline;
  final bool replayed;
  final String? errorCode;
  const ToolCallRow({
    required this.id,
    required this.agentRunId,
    required this.toolName,
    required this.toolVersion,
    required this.status,
    required this.startedAt,
    required this.finishedAt,
    required this.offline,
    required this.replayed,
    this.errorCode,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['agent_run_id'] = Variable<String>(agentRunId);
    map['tool_name'] = Variable<String>(toolName);
    map['tool_version'] = Variable<String>(toolVersion);
    map['status'] = Variable<String>(status);
    {
      map['started_at'] = Variable<int>(
        $ToolCallsTable.$converterstartedAt.toSql(startedAt),
      );
    }
    {
      map['finished_at'] = Variable<int>(
        $ToolCallsTable.$converterfinishedAt.toSql(finishedAt),
      );
    }
    map['offline'] = Variable<bool>(offline);
    map['replayed'] = Variable<bool>(replayed);
    if (!nullToAbsent || errorCode != null) {
      map['error_code'] = Variable<String>(errorCode);
    }
    return map;
  }

  ToolCallsCompanion toCompanion(bool nullToAbsent) {
    return ToolCallsCompanion(
      id: Value(id),
      agentRunId: Value(agentRunId),
      toolName: Value(toolName),
      toolVersion: Value(toolVersion),
      status: Value(status),
      startedAt: Value(startedAt),
      finishedAt: Value(finishedAt),
      offline: Value(offline),
      replayed: Value(replayed),
      errorCode: errorCode == null && nullToAbsent
          ? const Value.absent()
          : Value(errorCode),
    );
  }

  factory ToolCallRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ToolCallRow(
      id: serializer.fromJson<String>(json['id']),
      agentRunId: serializer.fromJson<String>(json['agentRunId']),
      toolName: serializer.fromJson<String>(json['toolName']),
      toolVersion: serializer.fromJson<String>(json['toolVersion']),
      status: serializer.fromJson<String>(json['status']),
      startedAt: serializer.fromJson<DateTime>(json['startedAt']),
      finishedAt: serializer.fromJson<DateTime>(json['finishedAt']),
      offline: serializer.fromJson<bool>(json['offline']),
      replayed: serializer.fromJson<bool>(json['replayed']),
      errorCode: serializer.fromJson<String?>(json['errorCode']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'agentRunId': serializer.toJson<String>(agentRunId),
      'toolName': serializer.toJson<String>(toolName),
      'toolVersion': serializer.toJson<String>(toolVersion),
      'status': serializer.toJson<String>(status),
      'startedAt': serializer.toJson<DateTime>(startedAt),
      'finishedAt': serializer.toJson<DateTime>(finishedAt),
      'offline': serializer.toJson<bool>(offline),
      'replayed': serializer.toJson<bool>(replayed),
      'errorCode': serializer.toJson<String?>(errorCode),
    };
  }

  ToolCallRow copyWith({
    String? id,
    String? agentRunId,
    String? toolName,
    String? toolVersion,
    String? status,
    DateTime? startedAt,
    DateTime? finishedAt,
    bool? offline,
    bool? replayed,
    Value<String?> errorCode = const Value.absent(),
  }) => ToolCallRow(
    id: id ?? this.id,
    agentRunId: agentRunId ?? this.agentRunId,
    toolName: toolName ?? this.toolName,
    toolVersion: toolVersion ?? this.toolVersion,
    status: status ?? this.status,
    startedAt: startedAt ?? this.startedAt,
    finishedAt: finishedAt ?? this.finishedAt,
    offline: offline ?? this.offline,
    replayed: replayed ?? this.replayed,
    errorCode: errorCode.present ? errorCode.value : this.errorCode,
  );
  ToolCallRow copyWithCompanion(ToolCallsCompanion data) {
    return ToolCallRow(
      id: data.id.present ? data.id.value : this.id,
      agentRunId: data.agentRunId.present
          ? data.agentRunId.value
          : this.agentRunId,
      toolName: data.toolName.present ? data.toolName.value : this.toolName,
      toolVersion: data.toolVersion.present
          ? data.toolVersion.value
          : this.toolVersion,
      status: data.status.present ? data.status.value : this.status,
      startedAt: data.startedAt.present ? data.startedAt.value : this.startedAt,
      finishedAt: data.finishedAt.present
          ? data.finishedAt.value
          : this.finishedAt,
      offline: data.offline.present ? data.offline.value : this.offline,
      replayed: data.replayed.present ? data.replayed.value : this.replayed,
      errorCode: data.errorCode.present ? data.errorCode.value : this.errorCode,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ToolCallRow(')
          ..write('id: $id, ')
          ..write('agentRunId: $agentRunId, ')
          ..write('toolName: $toolName, ')
          ..write('toolVersion: $toolVersion, ')
          ..write('status: $status, ')
          ..write('startedAt: $startedAt, ')
          ..write('finishedAt: $finishedAt, ')
          ..write('offline: $offline, ')
          ..write('replayed: $replayed, ')
          ..write('errorCode: $errorCode')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    agentRunId,
    toolName,
    toolVersion,
    status,
    startedAt,
    finishedAt,
    offline,
    replayed,
    errorCode,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ToolCallRow &&
          other.id == this.id &&
          other.agentRunId == this.agentRunId &&
          other.toolName == this.toolName &&
          other.toolVersion == this.toolVersion &&
          other.status == this.status &&
          other.startedAt == this.startedAt &&
          other.finishedAt == this.finishedAt &&
          other.offline == this.offline &&
          other.replayed == this.replayed &&
          other.errorCode == this.errorCode);
}

class ToolCallsCompanion extends UpdateCompanion<ToolCallRow> {
  final Value<String> id;
  final Value<String> agentRunId;
  final Value<String> toolName;
  final Value<String> toolVersion;
  final Value<String> status;
  final Value<DateTime> startedAt;
  final Value<DateTime> finishedAt;
  final Value<bool> offline;
  final Value<bool> replayed;
  final Value<String?> errorCode;
  final Value<int> rowid;
  const ToolCallsCompanion({
    this.id = const Value.absent(),
    this.agentRunId = const Value.absent(),
    this.toolName = const Value.absent(),
    this.toolVersion = const Value.absent(),
    this.status = const Value.absent(),
    this.startedAt = const Value.absent(),
    this.finishedAt = const Value.absent(),
    this.offline = const Value.absent(),
    this.replayed = const Value.absent(),
    this.errorCode = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ToolCallsCompanion.insert({
    required String id,
    required String agentRunId,
    required String toolName,
    required String toolVersion,
    required String status,
    required DateTime startedAt,
    required DateTime finishedAt,
    required bool offline,
    required bool replayed,
    this.errorCode = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       agentRunId = Value(agentRunId),
       toolName = Value(toolName),
       toolVersion = Value(toolVersion),
       status = Value(status),
       startedAt = Value(startedAt),
       finishedAt = Value(finishedAt),
       offline = Value(offline),
       replayed = Value(replayed);
  static Insertable<ToolCallRow> custom({
    Expression<String>? id,
    Expression<String>? agentRunId,
    Expression<String>? toolName,
    Expression<String>? toolVersion,
    Expression<String>? status,
    Expression<int>? startedAt,
    Expression<int>? finishedAt,
    Expression<bool>? offline,
    Expression<bool>? replayed,
    Expression<String>? errorCode,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (agentRunId != null) 'agent_run_id': agentRunId,
      if (toolName != null) 'tool_name': toolName,
      if (toolVersion != null) 'tool_version': toolVersion,
      if (status != null) 'status': status,
      if (startedAt != null) 'started_at': startedAt,
      if (finishedAt != null) 'finished_at': finishedAt,
      if (offline != null) 'offline': offline,
      if (replayed != null) 'replayed': replayed,
      if (errorCode != null) 'error_code': errorCode,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ToolCallsCompanion copyWith({
    Value<String>? id,
    Value<String>? agentRunId,
    Value<String>? toolName,
    Value<String>? toolVersion,
    Value<String>? status,
    Value<DateTime>? startedAt,
    Value<DateTime>? finishedAt,
    Value<bool>? offline,
    Value<bool>? replayed,
    Value<String?>? errorCode,
    Value<int>? rowid,
  }) {
    return ToolCallsCompanion(
      id: id ?? this.id,
      agentRunId: agentRunId ?? this.agentRunId,
      toolName: toolName ?? this.toolName,
      toolVersion: toolVersion ?? this.toolVersion,
      status: status ?? this.status,
      startedAt: startedAt ?? this.startedAt,
      finishedAt: finishedAt ?? this.finishedAt,
      offline: offline ?? this.offline,
      replayed: replayed ?? this.replayed,
      errorCode: errorCode ?? this.errorCode,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (agentRunId.present) {
      map['agent_run_id'] = Variable<String>(agentRunId.value);
    }
    if (toolName.present) {
      map['tool_name'] = Variable<String>(toolName.value);
    }
    if (toolVersion.present) {
      map['tool_version'] = Variable<String>(toolVersion.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (startedAt.present) {
      map['started_at'] = Variable<int>(
        $ToolCallsTable.$converterstartedAt.toSql(startedAt.value),
      );
    }
    if (finishedAt.present) {
      map['finished_at'] = Variable<int>(
        $ToolCallsTable.$converterfinishedAt.toSql(finishedAt.value),
      );
    }
    if (offline.present) {
      map['offline'] = Variable<bool>(offline.value);
    }
    if (replayed.present) {
      map['replayed'] = Variable<bool>(replayed.value);
    }
    if (errorCode.present) {
      map['error_code'] = Variable<String>(errorCode.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ToolCallsCompanion(')
          ..write('id: $id, ')
          ..write('agentRunId: $agentRunId, ')
          ..write('toolName: $toolName, ')
          ..write('toolVersion: $toolVersion, ')
          ..write('status: $status, ')
          ..write('startedAt: $startedAt, ')
          ..write('finishedAt: $finishedAt, ')
          ..write('offline: $offline, ')
          ..write('replayed: $replayed, ')
          ..write('errorCode: $errorCode, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$LocalStorageDatabase extends GeneratedDatabase {
  _$LocalStorageDatabase(QueryExecutor e) : super(e);
  $LocalStorageDatabaseManager get managers =>
      $LocalStorageDatabaseManager(this);
  late final $ResumeDocumentsTable resumeDocuments = $ResumeDocumentsTable(
    this,
  );
  late final $ResumeVersionsTable resumeVersions = $ResumeVersionsTable(this);
  late final $AppSettingsTable appSettings = $AppSettingsTable(this);
  late final $AgentRunsTable agentRuns = $AgentRunsTable(this);
  late final $ToolCallsTable toolCalls = $ToolCallsTable(this);
  late final Index resumeVersionsDocumentCreated = Index(
    'resume_versions_document_created',
    'CREATE INDEX resume_versions_document_created ON resume_versions (document_id, created_at)',
  );
  late final Index agentRunsDocumentStarted = Index(
    'agent_runs_document_started',
    'CREATE INDEX agent_runs_document_started ON agent_runs (document_id, started_at)',
  );
  late final Index toolCallsRunStarted = Index(
    'tool_calls_run_started',
    'CREATE INDEX tool_calls_run_started ON tool_calls (agent_run_id, started_at)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    resumeDocuments,
    resumeVersions,
    appSettings,
    agentRuns,
    toolCalls,
    resumeVersionsDocumentCreated,
    agentRunsDocumentStarted,
    toolCallsRunStarted,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'resume_documents',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('resume_versions', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'agent_runs',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('tool_calls', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$ResumeDocumentsTableCreateCompanionBuilder =
    ResumeDocumentsCompanion Function({
      required String id,
      required String title,
      Value<String?> currentVersionId,
      required DateTime createdAt,
      required DateTime updatedAt,
      required String metadataJson,
      required String extensionsJson,
      Value<int> rowid,
    });
typedef $$ResumeDocumentsTableUpdateCompanionBuilder =
    ResumeDocumentsCompanion Function({
      Value<String> id,
      Value<String> title,
      Value<String?> currentVersionId,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<String> metadataJson,
      Value<String> extensionsJson,
      Value<int> rowid,
    });

final class $$ResumeDocumentsTableReferences
    extends
        BaseReferences<
          _$LocalStorageDatabase,
          $ResumeDocumentsTable,
          ResumeDocumentRow
        > {
  $$ResumeDocumentsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static MultiTypedResultKey<$ResumeVersionsTable, List<ResumeVersionRow>>
  _resumeVersionsRefsTable(_$LocalStorageDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.resumeVersions,
        aliasName: 'resume_documents__id__resume_versions__document_id',
      );

  $$ResumeVersionsTableProcessedTableManager get resumeVersionsRefs {
    final manager = $$ResumeVersionsTableTableManager(
      $_db,
      $_db.resumeVersions,
    ).filter((f) => f.documentId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_resumeVersionsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$ResumeDocumentsTableFilterComposer
    extends Composer<_$LocalStorageDatabase, $ResumeDocumentsTable> {
  $$ResumeDocumentsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get currentVersionId => $composableBuilder(
    column: $table.currentVersionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<DateTime, DateTime, int> get createdAt =>
      $composableBuilder(
        column: $table.createdAt,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );

  ColumnWithTypeConverterFilters<DateTime, DateTime, int> get updatedAt =>
      $composableBuilder(
        column: $table.updatedAt,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );

  ColumnFilters<String> get metadataJson => $composableBuilder(
    column: $table.metadataJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get extensionsJson => $composableBuilder(
    column: $table.extensionsJson,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> resumeVersionsRefs(
    Expression<bool> Function($$ResumeVersionsTableFilterComposer f) f,
  ) {
    final $$ResumeVersionsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.resumeVersions,
      getReferencedColumn: (t) => t.documentId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ResumeVersionsTableFilterComposer(
            $db: $db,
            $table: $db.resumeVersions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ResumeDocumentsTableOrderingComposer
    extends Composer<_$LocalStorageDatabase, $ResumeDocumentsTable> {
  $$ResumeDocumentsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get currentVersionId => $composableBuilder(
    column: $table.currentVersionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get metadataJson => $composableBuilder(
    column: $table.metadataJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get extensionsJson => $composableBuilder(
    column: $table.extensionsJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ResumeDocumentsTableAnnotationComposer
    extends Composer<_$LocalStorageDatabase, $ResumeDocumentsTable> {
  $$ResumeDocumentsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get currentVersionId => $composableBuilder(
    column: $table.currentVersionId,
    builder: (column) => column,
  );

  GeneratedColumnWithTypeConverter<DateTime, int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumnWithTypeConverter<DateTime, int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get metadataJson => $composableBuilder(
    column: $table.metadataJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get extensionsJson => $composableBuilder(
    column: $table.extensionsJson,
    builder: (column) => column,
  );

  Expression<T> resumeVersionsRefs<T extends Object>(
    Expression<T> Function($$ResumeVersionsTableAnnotationComposer a) f,
  ) {
    final $$ResumeVersionsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.resumeVersions,
      getReferencedColumn: (t) => t.documentId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ResumeVersionsTableAnnotationComposer(
            $db: $db,
            $table: $db.resumeVersions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ResumeDocumentsTableTableManager
    extends
        RootTableManager<
          _$LocalStorageDatabase,
          $ResumeDocumentsTable,
          ResumeDocumentRow,
          $$ResumeDocumentsTableFilterComposer,
          $$ResumeDocumentsTableOrderingComposer,
          $$ResumeDocumentsTableAnnotationComposer,
          $$ResumeDocumentsTableCreateCompanionBuilder,
          $$ResumeDocumentsTableUpdateCompanionBuilder,
          (ResumeDocumentRow, $$ResumeDocumentsTableReferences),
          ResumeDocumentRow,
          PrefetchHooks Function({bool resumeVersionsRefs})
        > {
  $$ResumeDocumentsTableTableManager(
    _$LocalStorageDatabase db,
    $ResumeDocumentsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ResumeDocumentsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ResumeDocumentsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ResumeDocumentsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> currentVersionId = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<String> metadataJson = const Value.absent(),
                Value<String> extensionsJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ResumeDocumentsCompanion(
                id: id,
                title: title,
                currentVersionId: currentVersionId,
                createdAt: createdAt,
                updatedAt: updatedAt,
                metadataJson: metadataJson,
                extensionsJson: extensionsJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String title,
                Value<String?> currentVersionId = const Value.absent(),
                required DateTime createdAt,
                required DateTime updatedAt,
                required String metadataJson,
                required String extensionsJson,
                Value<int> rowid = const Value.absent(),
              }) => ResumeDocumentsCompanion.insert(
                id: id,
                title: title,
                currentVersionId: currentVersionId,
                createdAt: createdAt,
                updatedAt: updatedAt,
                metadataJson: metadataJson,
                extensionsJson: extensionsJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ResumeDocumentsTable, ResumeDocumentRow>(table),
                  $$ResumeDocumentsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({resumeVersionsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (resumeVersionsRefs) db.resumeVersions,
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (resumeVersionsRefs)
                    await $_getPrefetchedData<
                      ResumeDocumentRow,
                      $ResumeDocumentsTable,
                      ResumeVersionRow
                    >(
                      currentTable: table,
                      referencedTable: $$ResumeDocumentsTableReferences
                          ._resumeVersionsRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$ResumeDocumentsTableReferences(
                            db,
                            table,
                            p0,
                          ).resumeVersionsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.documentId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$ResumeDocumentsTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalStorageDatabase,
      $ResumeDocumentsTable,
      ResumeDocumentRow,
      $$ResumeDocumentsTableFilterComposer,
      $$ResumeDocumentsTableOrderingComposer,
      $$ResumeDocumentsTableAnnotationComposer,
      $$ResumeDocumentsTableCreateCompanionBuilder,
      $$ResumeDocumentsTableUpdateCompanionBuilder,
      (ResumeDocumentRow, $$ResumeDocumentsTableReferences),
      ResumeDocumentRow,
      PrefetchHooks Function({bool resumeVersionsRefs})
    >;
typedef $$ResumeVersionsTableCreateCompanionBuilder =
    ResumeVersionsCompanion Function({
      required String id,
      required String documentId,
      Value<String?> parentVersionId,
      required String schemaVersion,
      required String contentJson,
      required String source,
      required DateTime createdAt,
      required String extensionsJson,
      Value<int> rowid,
    });
typedef $$ResumeVersionsTableUpdateCompanionBuilder =
    ResumeVersionsCompanion Function({
      Value<String> id,
      Value<String> documentId,
      Value<String?> parentVersionId,
      Value<String> schemaVersion,
      Value<String> contentJson,
      Value<String> source,
      Value<DateTime> createdAt,
      Value<String> extensionsJson,
      Value<int> rowid,
    });

final class $$ResumeVersionsTableReferences
    extends
        BaseReferences<
          _$LocalStorageDatabase,
          $ResumeVersionsTable,
          ResumeVersionRow
        > {
  $$ResumeVersionsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $ResumeDocumentsTable _documentIdTable(_$LocalStorageDatabase db) => db
      .resumeDocuments
      .createAlias('resume_versions__document_id__resume_documents__id');

  $$ResumeDocumentsTableProcessedTableManager get documentId {
    final $_column = $_itemColumn<String>('document_id')!;

    final manager = $$ResumeDocumentsTableTableManager(
      $_db,
      $_db.resumeDocuments,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_documentIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ResumeVersionsTableFilterComposer
    extends Composer<_$LocalStorageDatabase, $ResumeVersionsTable> {
  $$ResumeVersionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get parentVersionId => $composableBuilder(
    column: $table.parentVersionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get schemaVersion => $composableBuilder(
    column: $table.schemaVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contentJson => $composableBuilder(
    column: $table.contentJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<DateTime, DateTime, int> get createdAt =>
      $composableBuilder(
        column: $table.createdAt,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );

  ColumnFilters<String> get extensionsJson => $composableBuilder(
    column: $table.extensionsJson,
    builder: (column) => ColumnFilters(column),
  );

  $$ResumeDocumentsTableFilterComposer get documentId {
    final $$ResumeDocumentsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.documentId,
      referencedTable: $db.resumeDocuments,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ResumeDocumentsTableFilterComposer(
            $db: $db,
            $table: $db.resumeDocuments,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ResumeVersionsTableOrderingComposer
    extends Composer<_$LocalStorageDatabase, $ResumeVersionsTable> {
  $$ResumeVersionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get parentVersionId => $composableBuilder(
    column: $table.parentVersionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get schemaVersion => $composableBuilder(
    column: $table.schemaVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contentJson => $composableBuilder(
    column: $table.contentJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get extensionsJson => $composableBuilder(
    column: $table.extensionsJson,
    builder: (column) => ColumnOrderings(column),
  );

  $$ResumeDocumentsTableOrderingComposer get documentId {
    final $$ResumeDocumentsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.documentId,
      referencedTable: $db.resumeDocuments,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ResumeDocumentsTableOrderingComposer(
            $db: $db,
            $table: $db.resumeDocuments,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ResumeVersionsTableAnnotationComposer
    extends Composer<_$LocalStorageDatabase, $ResumeVersionsTable> {
  $$ResumeVersionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get parentVersionId => $composableBuilder(
    column: $table.parentVersionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get schemaVersion => $composableBuilder(
    column: $table.schemaVersion,
    builder: (column) => column,
  );

  GeneratedColumn<String> get contentJson => $composableBuilder(
    column: $table.contentJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumnWithTypeConverter<DateTime, int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get extensionsJson => $composableBuilder(
    column: $table.extensionsJson,
    builder: (column) => column,
  );

  $$ResumeDocumentsTableAnnotationComposer get documentId {
    final $$ResumeDocumentsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.documentId,
      referencedTable: $db.resumeDocuments,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ResumeDocumentsTableAnnotationComposer(
            $db: $db,
            $table: $db.resumeDocuments,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ResumeVersionsTableTableManager
    extends
        RootTableManager<
          _$LocalStorageDatabase,
          $ResumeVersionsTable,
          ResumeVersionRow,
          $$ResumeVersionsTableFilterComposer,
          $$ResumeVersionsTableOrderingComposer,
          $$ResumeVersionsTableAnnotationComposer,
          $$ResumeVersionsTableCreateCompanionBuilder,
          $$ResumeVersionsTableUpdateCompanionBuilder,
          (ResumeVersionRow, $$ResumeVersionsTableReferences),
          ResumeVersionRow,
          PrefetchHooks Function({bool documentId})
        > {
  $$ResumeVersionsTableTableManager(
    _$LocalStorageDatabase db,
    $ResumeVersionsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ResumeVersionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ResumeVersionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ResumeVersionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> documentId = const Value.absent(),
                Value<String?> parentVersionId = const Value.absent(),
                Value<String> schemaVersion = const Value.absent(),
                Value<String> contentJson = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<String> extensionsJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ResumeVersionsCompanion(
                id: id,
                documentId: documentId,
                parentVersionId: parentVersionId,
                schemaVersion: schemaVersion,
                contentJson: contentJson,
                source: source,
                createdAt: createdAt,
                extensionsJson: extensionsJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String documentId,
                Value<String?> parentVersionId = const Value.absent(),
                required String schemaVersion,
                required String contentJson,
                required String source,
                required DateTime createdAt,
                required String extensionsJson,
                Value<int> rowid = const Value.absent(),
              }) => ResumeVersionsCompanion.insert(
                id: id,
                documentId: documentId,
                parentVersionId: parentVersionId,
                schemaVersion: schemaVersion,
                contentJson: contentJson,
                source: source,
                createdAt: createdAt,
                extensionsJson: extensionsJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ResumeVersionsTable, ResumeVersionRow>(table),
                  $$ResumeVersionsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({documentId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (documentId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.documentId,
                                referencedTable: $$ResumeVersionsTableReferences
                                    ._documentIdTable(db),
                                referencedColumn:
                                    $$ResumeVersionsTableReferences
                                        ._documentIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ResumeVersionsTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalStorageDatabase,
      $ResumeVersionsTable,
      ResumeVersionRow,
      $$ResumeVersionsTableFilterComposer,
      $$ResumeVersionsTableOrderingComposer,
      $$ResumeVersionsTableAnnotationComposer,
      $$ResumeVersionsTableCreateCompanionBuilder,
      $$ResumeVersionsTableUpdateCompanionBuilder,
      (ResumeVersionRow, $$ResumeVersionsTableReferences),
      ResumeVersionRow,
      PrefetchHooks Function({bool documentId})
    >;
typedef $$AppSettingsTableCreateCompanionBuilder =
    AppSettingsCompanion Function({
      required String settingKey,
      required bool boolValue,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$AppSettingsTableUpdateCompanionBuilder =
    AppSettingsCompanion Function({
      Value<String> settingKey,
      Value<bool> boolValue,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

class $$AppSettingsTableFilterComposer
    extends Composer<_$LocalStorageDatabase, $AppSettingsTable> {
  $$AppSettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get settingKey => $composableBuilder(
    column: $table.settingKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get boolValue => $composableBuilder(
    column: $table.boolValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<DateTime, DateTime, int> get updatedAt =>
      $composableBuilder(
        column: $table.updatedAt,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );
}

class $$AppSettingsTableOrderingComposer
    extends Composer<_$LocalStorageDatabase, $AppSettingsTable> {
  $$AppSettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get settingKey => $composableBuilder(
    column: $table.settingKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get boolValue => $composableBuilder(
    column: $table.boolValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AppSettingsTableAnnotationComposer
    extends Composer<_$LocalStorageDatabase, $AppSettingsTable> {
  $$AppSettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get settingKey => $composableBuilder(
    column: $table.settingKey,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get boolValue =>
      $composableBuilder(column: $table.boolValue, builder: (column) => column);

  GeneratedColumnWithTypeConverter<DateTime, int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$AppSettingsTableTableManager
    extends
        RootTableManager<
          _$LocalStorageDatabase,
          $AppSettingsTable,
          AppSettingRow,
          $$AppSettingsTableFilterComposer,
          $$AppSettingsTableOrderingComposer,
          $$AppSettingsTableAnnotationComposer,
          $$AppSettingsTableCreateCompanionBuilder,
          $$AppSettingsTableUpdateCompanionBuilder,
          (
            AppSettingRow,
            BaseReferences<
              _$LocalStorageDatabase,
              $AppSettingsTable,
              AppSettingRow
            >,
          ),
          AppSettingRow,
          PrefetchHooks Function()
        > {
  $$AppSettingsTableTableManager(
    _$LocalStorageDatabase db,
    $AppSettingsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AppSettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AppSettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AppSettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> settingKey = const Value.absent(),
                Value<bool> boolValue = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AppSettingsCompanion(
                settingKey: settingKey,
                boolValue: boolValue,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String settingKey,
                required bool boolValue,
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => AppSettingsCompanion.insert(
                settingKey: settingKey,
                boolValue: boolValue,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AppSettingsTable, AppSettingRow>(table),
                  BaseReferences<
                    _$LocalStorageDatabase,
                    $AppSettingsTable,
                    AppSettingRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AppSettingsTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalStorageDatabase,
      $AppSettingsTable,
      AppSettingRow,
      $$AppSettingsTableFilterComposer,
      $$AppSettingsTableOrderingComposer,
      $$AppSettingsTableAnnotationComposer,
      $$AppSettingsTableCreateCompanionBuilder,
      $$AppSettingsTableUpdateCompanionBuilder,
      (
        AppSettingRow,
        BaseReferences<
          _$LocalStorageDatabase,
          $AppSettingsTable,
          AppSettingRow
        >,
      ),
      AppSettingRow,
      PrefetchHooks Function()
    >;
typedef $$AgentRunsTableCreateCompanionBuilder =
    AgentRunsCompanion Function({
      required String id,
      required String requestId,
      required String documentId,
      required String resumeVersionId,
      required String status,
      required String routeStatus,
      required DateTime startedAt,
      required DateTime finishedAt,
      Value<int> toolCallCount,
      Value<String?> errorCode,
      Value<int> rowid,
    });
typedef $$AgentRunsTableUpdateCompanionBuilder =
    AgentRunsCompanion Function({
      Value<String> id,
      Value<String> requestId,
      Value<String> documentId,
      Value<String> resumeVersionId,
      Value<String> status,
      Value<String> routeStatus,
      Value<DateTime> startedAt,
      Value<DateTime> finishedAt,
      Value<int> toolCallCount,
      Value<String?> errorCode,
      Value<int> rowid,
    });

final class $$AgentRunsTableReferences
    extends
        BaseReferences<_$LocalStorageDatabase, $AgentRunsTable, AgentRunRow> {
  $$AgentRunsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$ToolCallsTable, List<ToolCallRow>>
  _toolCallsRefsTable(_$LocalStorageDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.toolCalls,
        aliasName: 'agent_runs__id__tool_calls__agent_run_id',
      );

  $$ToolCallsTableProcessedTableManager get toolCallsRefs {
    final manager = $$ToolCallsTableTableManager(
      $_db,
      $_db.toolCalls,
    ).filter((f) => f.agentRunId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_toolCallsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$AgentRunsTableFilterComposer
    extends Composer<_$LocalStorageDatabase, $AgentRunsTable> {
  $$AgentRunsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get requestId => $composableBuilder(
    column: $table.requestId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get documentId => $composableBuilder(
    column: $table.documentId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get resumeVersionId => $composableBuilder(
    column: $table.resumeVersionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get routeStatus => $composableBuilder(
    column: $table.routeStatus,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<DateTime, DateTime, int> get startedAt =>
      $composableBuilder(
        column: $table.startedAt,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );

  ColumnWithTypeConverterFilters<DateTime, DateTime, int> get finishedAt =>
      $composableBuilder(
        column: $table.finishedAt,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );

  ColumnFilters<int> get toolCallCount => $composableBuilder(
    column: $table.toolCallCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get errorCode => $composableBuilder(
    column: $table.errorCode,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> toolCallsRefs(
    Expression<bool> Function($$ToolCallsTableFilterComposer f) f,
  ) {
    final $$ToolCallsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.toolCalls,
      getReferencedColumn: (t) => t.agentRunId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ToolCallsTableFilterComposer(
            $db: $db,
            $table: $db.toolCalls,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$AgentRunsTableOrderingComposer
    extends Composer<_$LocalStorageDatabase, $AgentRunsTable> {
  $$AgentRunsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get requestId => $composableBuilder(
    column: $table.requestId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get documentId => $composableBuilder(
    column: $table.documentId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get resumeVersionId => $composableBuilder(
    column: $table.resumeVersionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get routeStatus => $composableBuilder(
    column: $table.routeStatus,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get toolCallCount => $composableBuilder(
    column: $table.toolCallCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get errorCode => $composableBuilder(
    column: $table.errorCode,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AgentRunsTableAnnotationComposer
    extends Composer<_$LocalStorageDatabase, $AgentRunsTable> {
  $$AgentRunsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get requestId =>
      $composableBuilder(column: $table.requestId, builder: (column) => column);

  GeneratedColumn<String> get documentId => $composableBuilder(
    column: $table.documentId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get resumeVersionId => $composableBuilder(
    column: $table.resumeVersionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get routeStatus => $composableBuilder(
    column: $table.routeStatus,
    builder: (column) => column,
  );

  GeneratedColumnWithTypeConverter<DateTime, int> get startedAt =>
      $composableBuilder(column: $table.startedAt, builder: (column) => column);

  GeneratedColumnWithTypeConverter<DateTime, int> get finishedAt =>
      $composableBuilder(
        column: $table.finishedAt,
        builder: (column) => column,
      );

  GeneratedColumn<int> get toolCallCount => $composableBuilder(
    column: $table.toolCallCount,
    builder: (column) => column,
  );

  GeneratedColumn<String> get errorCode =>
      $composableBuilder(column: $table.errorCode, builder: (column) => column);

  Expression<T> toolCallsRefs<T extends Object>(
    Expression<T> Function($$ToolCallsTableAnnotationComposer a) f,
  ) {
    final $$ToolCallsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.toolCalls,
      getReferencedColumn: (t) => t.agentRunId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ToolCallsTableAnnotationComposer(
            $db: $db,
            $table: $db.toolCalls,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$AgentRunsTableTableManager
    extends
        RootTableManager<
          _$LocalStorageDatabase,
          $AgentRunsTable,
          AgentRunRow,
          $$AgentRunsTableFilterComposer,
          $$AgentRunsTableOrderingComposer,
          $$AgentRunsTableAnnotationComposer,
          $$AgentRunsTableCreateCompanionBuilder,
          $$AgentRunsTableUpdateCompanionBuilder,
          (AgentRunRow, $$AgentRunsTableReferences),
          AgentRunRow,
          PrefetchHooks Function({bool toolCallsRefs})
        > {
  $$AgentRunsTableTableManager(_$LocalStorageDatabase db, $AgentRunsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AgentRunsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AgentRunsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AgentRunsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> requestId = const Value.absent(),
                Value<String> documentId = const Value.absent(),
                Value<String> resumeVersionId = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String> routeStatus = const Value.absent(),
                Value<DateTime> startedAt = const Value.absent(),
                Value<DateTime> finishedAt = const Value.absent(),
                Value<int> toolCallCount = const Value.absent(),
                Value<String?> errorCode = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AgentRunsCompanion(
                id: id,
                requestId: requestId,
                documentId: documentId,
                resumeVersionId: resumeVersionId,
                status: status,
                routeStatus: routeStatus,
                startedAt: startedAt,
                finishedAt: finishedAt,
                toolCallCount: toolCallCount,
                errorCode: errorCode,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String requestId,
                required String documentId,
                required String resumeVersionId,
                required String status,
                required String routeStatus,
                required DateTime startedAt,
                required DateTime finishedAt,
                Value<int> toolCallCount = const Value.absent(),
                Value<String?> errorCode = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AgentRunsCompanion.insert(
                id: id,
                requestId: requestId,
                documentId: documentId,
                resumeVersionId: resumeVersionId,
                status: status,
                routeStatus: routeStatus,
                startedAt: startedAt,
                finishedAt: finishedAt,
                toolCallCount: toolCallCount,
                errorCode: errorCode,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AgentRunsTable, AgentRunRow>(table),
                  $$AgentRunsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({toolCallsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (toolCallsRefs) db.toolCalls],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (toolCallsRefs)
                    await $_getPrefetchedData<
                      AgentRunRow,
                      $AgentRunsTable,
                      ToolCallRow
                    >(
                      currentTable: table,
                      referencedTable: $$AgentRunsTableReferences
                          ._toolCallsRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$AgentRunsTableReferences(
                            db,
                            table,
                            p0,
                          ).toolCallsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.agentRunId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$AgentRunsTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalStorageDatabase,
      $AgentRunsTable,
      AgentRunRow,
      $$AgentRunsTableFilterComposer,
      $$AgentRunsTableOrderingComposer,
      $$AgentRunsTableAnnotationComposer,
      $$AgentRunsTableCreateCompanionBuilder,
      $$AgentRunsTableUpdateCompanionBuilder,
      (AgentRunRow, $$AgentRunsTableReferences),
      AgentRunRow,
      PrefetchHooks Function({bool toolCallsRefs})
    >;
typedef $$ToolCallsTableCreateCompanionBuilder =
    ToolCallsCompanion Function({
      required String id,
      required String agentRunId,
      required String toolName,
      required String toolVersion,
      required String status,
      required DateTime startedAt,
      required DateTime finishedAt,
      required bool offline,
      required bool replayed,
      Value<String?> errorCode,
      Value<int> rowid,
    });
typedef $$ToolCallsTableUpdateCompanionBuilder =
    ToolCallsCompanion Function({
      Value<String> id,
      Value<String> agentRunId,
      Value<String> toolName,
      Value<String> toolVersion,
      Value<String> status,
      Value<DateTime> startedAt,
      Value<DateTime> finishedAt,
      Value<bool> offline,
      Value<bool> replayed,
      Value<String?> errorCode,
      Value<int> rowid,
    });

final class $$ToolCallsTableReferences
    extends
        BaseReferences<_$LocalStorageDatabase, $ToolCallsTable, ToolCallRow> {
  $$ToolCallsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $AgentRunsTable _agentRunIdTable(_$LocalStorageDatabase db) =>
      db.agentRuns.createAlias('tool_calls__agent_run_id__agent_runs__id');

  $$AgentRunsTableProcessedTableManager get agentRunId {
    final $_column = $_itemColumn<String>('agent_run_id')!;

    final manager = $$AgentRunsTableTableManager(
      $_db,
      $_db.agentRuns,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_agentRunIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ToolCallsTableFilterComposer
    extends Composer<_$LocalStorageDatabase, $ToolCallsTable> {
  $$ToolCallsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get toolName => $composableBuilder(
    column: $table.toolName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get toolVersion => $composableBuilder(
    column: $table.toolVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<DateTime, DateTime, int> get startedAt =>
      $composableBuilder(
        column: $table.startedAt,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );

  ColumnWithTypeConverterFilters<DateTime, DateTime, int> get finishedAt =>
      $composableBuilder(
        column: $table.finishedAt,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );

  ColumnFilters<bool> get offline => $composableBuilder(
    column: $table.offline,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get replayed => $composableBuilder(
    column: $table.replayed,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get errorCode => $composableBuilder(
    column: $table.errorCode,
    builder: (column) => ColumnFilters(column),
  );

  $$AgentRunsTableFilterComposer get agentRunId {
    final $$AgentRunsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.agentRunId,
      referencedTable: $db.agentRuns,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AgentRunsTableFilterComposer(
            $db: $db,
            $table: $db.agentRuns,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ToolCallsTableOrderingComposer
    extends Composer<_$LocalStorageDatabase, $ToolCallsTable> {
  $$ToolCallsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get toolName => $composableBuilder(
    column: $table.toolName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get toolVersion => $composableBuilder(
    column: $table.toolVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get offline => $composableBuilder(
    column: $table.offline,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get replayed => $composableBuilder(
    column: $table.replayed,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get errorCode => $composableBuilder(
    column: $table.errorCode,
    builder: (column) => ColumnOrderings(column),
  );

  $$AgentRunsTableOrderingComposer get agentRunId {
    final $$AgentRunsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.agentRunId,
      referencedTable: $db.agentRuns,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AgentRunsTableOrderingComposer(
            $db: $db,
            $table: $db.agentRuns,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ToolCallsTableAnnotationComposer
    extends Composer<_$LocalStorageDatabase, $ToolCallsTable> {
  $$ToolCallsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get toolName =>
      $composableBuilder(column: $table.toolName, builder: (column) => column);

  GeneratedColumn<String> get toolVersion => $composableBuilder(
    column: $table.toolVersion,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumnWithTypeConverter<DateTime, int> get startedAt =>
      $composableBuilder(column: $table.startedAt, builder: (column) => column);

  GeneratedColumnWithTypeConverter<DateTime, int> get finishedAt =>
      $composableBuilder(
        column: $table.finishedAt,
        builder: (column) => column,
      );

  GeneratedColumn<bool> get offline =>
      $composableBuilder(column: $table.offline, builder: (column) => column);

  GeneratedColumn<bool> get replayed =>
      $composableBuilder(column: $table.replayed, builder: (column) => column);

  GeneratedColumn<String> get errorCode =>
      $composableBuilder(column: $table.errorCode, builder: (column) => column);

  $$AgentRunsTableAnnotationComposer get agentRunId {
    final $$AgentRunsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.agentRunId,
      referencedTable: $db.agentRuns,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AgentRunsTableAnnotationComposer(
            $db: $db,
            $table: $db.agentRuns,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ToolCallsTableTableManager
    extends
        RootTableManager<
          _$LocalStorageDatabase,
          $ToolCallsTable,
          ToolCallRow,
          $$ToolCallsTableFilterComposer,
          $$ToolCallsTableOrderingComposer,
          $$ToolCallsTableAnnotationComposer,
          $$ToolCallsTableCreateCompanionBuilder,
          $$ToolCallsTableUpdateCompanionBuilder,
          (ToolCallRow, $$ToolCallsTableReferences),
          ToolCallRow,
          PrefetchHooks Function({bool agentRunId})
        > {
  $$ToolCallsTableTableManager(_$LocalStorageDatabase db, $ToolCallsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ToolCallsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ToolCallsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ToolCallsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> agentRunId = const Value.absent(),
                Value<String> toolName = const Value.absent(),
                Value<String> toolVersion = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<DateTime> startedAt = const Value.absent(),
                Value<DateTime> finishedAt = const Value.absent(),
                Value<bool> offline = const Value.absent(),
                Value<bool> replayed = const Value.absent(),
                Value<String?> errorCode = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ToolCallsCompanion(
                id: id,
                agentRunId: agentRunId,
                toolName: toolName,
                toolVersion: toolVersion,
                status: status,
                startedAt: startedAt,
                finishedAt: finishedAt,
                offline: offline,
                replayed: replayed,
                errorCode: errorCode,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String agentRunId,
                required String toolName,
                required String toolVersion,
                required String status,
                required DateTime startedAt,
                required DateTime finishedAt,
                required bool offline,
                required bool replayed,
                Value<String?> errorCode = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ToolCallsCompanion.insert(
                id: id,
                agentRunId: agentRunId,
                toolName: toolName,
                toolVersion: toolVersion,
                status: status,
                startedAt: startedAt,
                finishedAt: finishedAt,
                offline: offline,
                replayed: replayed,
                errorCode: errorCode,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ToolCallsTable, ToolCallRow>(table),
                  $$ToolCallsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({agentRunId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (agentRunId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.agentRunId,
                                referencedTable: $$ToolCallsTableReferences
                                    ._agentRunIdTable(db),
                                referencedColumn: $$ToolCallsTableReferences
                                    ._agentRunIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ToolCallsTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalStorageDatabase,
      $ToolCallsTable,
      ToolCallRow,
      $$ToolCallsTableFilterComposer,
      $$ToolCallsTableOrderingComposer,
      $$ToolCallsTableAnnotationComposer,
      $$ToolCallsTableCreateCompanionBuilder,
      $$ToolCallsTableUpdateCompanionBuilder,
      (ToolCallRow, $$ToolCallsTableReferences),
      ToolCallRow,
      PrefetchHooks Function({bool agentRunId})
    >;

class $LocalStorageDatabaseManager {
  final _$LocalStorageDatabase _db;
  $LocalStorageDatabaseManager(this._db);
  $$ResumeDocumentsTableTableManager get resumeDocuments =>
      $$ResumeDocumentsTableTableManager(_db, _db.resumeDocuments);
  $$ResumeVersionsTableTableManager get resumeVersions =>
      $$ResumeVersionsTableTableManager(_db, _db.resumeVersions);
  $$AppSettingsTableTableManager get appSettings =>
      $$AppSettingsTableTableManager(_db, _db.appSettings);
  $$AgentRunsTableTableManager get agentRuns =>
      $$AgentRunsTableTableManager(_db, _db.agentRuns);
  $$ToolCallsTableTableManager get toolCalls =>
      $$ToolCallsTableTableManager(_db, _db.toolCalls);
}
