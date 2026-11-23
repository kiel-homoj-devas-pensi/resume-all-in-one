import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_all_in_one_client/src/local_data_management_service.dart';
import 'package:resume_domain/resume_domain.dart';

void main() {
  final exportedAtUtc = DateTime.utc(2026, 10, 2, 12, 34, 56, 789);

  test('全量导出写入非敏感文件名并可由同版本 codec 重新解析', () async {
    final exportRoot = await Directory.systemTemp.createTemp(
      'local-data-export-test-',
    );
    try {
      final repository = _FakeLocalDataRepository(_snapshot());
      final service = LocalDataManagementService(
        repository: repository,
        rootDirectory: () async => exportRoot,
        clock: () => exportedAtUtc,
      );

      final exportResult = await service.exportAll();
      final archiveText = await exportResult.file.readAsString();
      final reparsedSummary = service.codec.decode(archiveText);

      expect(exportResult.file.path, endsWith('.json'));
      expect(exportResult.file.path, isNot(contains('张三')));
      expect(exportResult.file.path, isNot(contains('敏感简历标题')));
      expect(exportResult.file.path, isNot(contains('document-001')));
      expect(reparsedSummary.documentCount, 1);
      expect(reparsedSummary.versionCount, 1);
      expect(reparsedSummary.settingCount, 1);
      expect(reparsedSummary.agentRunCount, 1);
      expect(reparsedSummary.toolCallCount, 1);
      expect(archiveText, contains('张三'));
      expect(archiveText, isNot(contains('providerKey')));
      expect(archiveText, isNot(contains('modelId')));
      expect(
        exportRoot
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.tmp')),
        isEmpty,
      );
    } finally {
      await exportRoot.delete(recursive: true);
    }
  });

  test('codec 拒绝悬空当前版本指针和错误工具归属', () {
    final codec = const LocalDataArchiveCodec();
    final validArchive =
        jsonDecode(codec.encode(_snapshot(), exportedAtUtc))
            as Map<String, Object?>;
    final resumes = validArchive['resumes']! as List<Object?>;
    final resumeEntry = resumes.single as Map<String, Object?>;
    final document = resumeEntry['document']! as Map<String, Object?>;
    document['currentVersionId'] = 'missing-version';

    expect(
      () => codec.decode(jsonEncode(validArchive)),
      throwsA(isA<LocalDataArchiveException>()),
    );

    final auditArchive =
        jsonDecode(codec.encode(_snapshot(), exportedAtUtc))
            as Map<String, Object?>;
    final auditEntries = auditArchive['agentAudits']! as List<Object?>;
    final auditEntry = auditEntries.single as Map<String, Object?>;
    final toolCalls = auditEntry['toolCalls']! as List<Object?>;
    final toolCall = toolCalls.single as Map<String, Object?>;
    toolCall['agentRunId'] = 'wrong-run';

    expect(
      () => codec.decode(jsonEncode(auditArchive)),
      throwsA(isA<LocalDataArchiveException>()),
    );
  });

  test('清空操作只委托一次并返回数据库删除数量', () async {
    final repository = _FakeLocalDataRepository(_snapshot());
    final service = LocalDataManagementService(
      repository: repository,
      rootDirectory: () async => Directory.systemTemp,
    );

    final clearResult = await service.clearAll();

    expect(repository.clearCallCount, 1);
    expect(clearResult.documentCount, 1);
    expect(clearResult.versionCount, 1);
  });

  for (final schemaVersion in [0, 5]) {
    test('codec 拒绝不支持的数据库版本 $schemaVersion', () {
      _expectInvalidArchive((archive) {
        archive['storageSchemaVersion'] = schemaVersion;
      });
    });
  }

  test('codec 对每个历史版本执行 Canonical 业务校验', () {
    _expectInvalidArchive((archive) {
      final content = _firstVersion(archive)['content']! as JsonMap;
      final profile = content['profile']! as JsonMap;
      profile['email'] = 'invalid-email';
    });
    _expectInvalidArchive((archive) {
      final content = _firstVersion(archive)['content']! as JsonMap;
      final profile = content['profile']! as JsonMap;
      profile['links'] = [
        {'id': profile['id'], 'label': '主页', 'url': 'https://example.com'},
      ];
    });
    _expectInvalidArchive((archive) {
      final version = _firstVersion(archive);
      version['schemaVersion'] = '9.0.0';
      (version['content']! as JsonMap)['schemaVersion'] = '9.0.0';
    });
  });

  test('codec 拒绝空白文档标题和文档或版本 ID', () {
    _expectInvalidArchive((archive) {
      _firstDocument(archive)['title'] = '   ';
    });
    _expectInvalidArchive((archive) {
      _firstDocument(archive)['id'] = '   ';
      _firstVersion(archive)['documentId'] = '   ';
    });
    _expectInvalidArchive((archive) {
      _firstDocument(archive)['currentVersionId'] = '   ';
      _firstVersion(archive)['id'] = '   ';
    });
  });

  test('codec 拒绝缺失父版本、自环和两版互相引用', () {
    _expectInvalidArchive((archive) {
      _firstVersion(archive)['parentVersionId'] = 'missing-version';
    });
    _expectInvalidArchive((archive) {
      _firstVersion(archive)['parentVersionId'] = 'version-001';
    });
    _expectInvalidArchive((archive) {
      final first = _firstVersion(archive);
      first['parentVersionId'] = 'version-002';
      (_firstResume(archive)['versions']! as List<Object?>).add({
        ...first,
        'id': 'version-002',
        'parentVersionId': 'version-001',
      });
    });
  });

  test('codec 拒绝引用另一文档版本的父链', () {
    _expectInvalidArchive((archive) {
      final first = _firstVersion(archive);
      first['parentVersionId'] = 'other-version';
      (archive['resumes']! as List<Object?>).add({
        'document': {
          ..._firstDocument(archive),
          'id': 'other-document',
          'currentVersionId': 'other-version',
        },
        'versions': [
          {
            ...first,
            'id': 'other-version',
            'documentId': 'other-document',
            'parentVersionId': null,
          },
        ],
      });
    });
  });

  test('codec 拒绝倒退文档时间和被自动归一化的 UTC 时间', () {
    _expectInvalidArchive((archive) {
      _firstDocument(archive)['updatedAt'] = '2026-10-01T08:00:00Z';
    });
    _expectInvalidArchive((archive) {
      archive['exportedAtUtc'] = '2026-02-31T08:00:00Z';
    });
    _expectInvalidArchive((archive) {
      ((archive['settings']! as List<Object?>).single
              as JsonMap)['updatedAtUtc'] =
          '2026-10-02T24:00:00Z';
    });
  });

  test('codec 拒绝重复 Agent 请求身份但保留已删除文档审计', () {
    _expectInvalidArchive((archive) {
      final audits = archive['agentAudits']! as List<Object?>;
      final audit = audits.single as JsonMap;
      final run = audit['run']! as JsonMap;
      audits.add({
        'run': {...run, 'id': 'run-002', 'toolCallCount': 0},
        'toolCalls': <Object?>[],
      });
    });
    final archive = _archive();
    archive['resumes'] = <Object?>[];
    final summary = const LocalDataArchiveCodec().decode(jsonEncode(archive));
    expect(summary.documentCount, 0);
    expect(summary.agentRunCount, 1);
    expect(summary.toolCallCount, 1);
  });

  test('codec 保留未知 Canonical 字段与 unmapped 并接受无序合法父链', () {
    final snapshot = _snapshot();
    final versionJson = snapshot.resumes.single.versions.single.toJson();
    versionJson['futureVersion'] = {'enabled': true};
    final content = versionJson['content']! as JsonMap;
    content['futureContent'] = ['保留', 42];
    content['unmapped'] = {'legacySection': '待人工映射'};
    (content['profile']! as JsonMap)['futureProfile'] = {'level': 3};
    final documentJson = snapshot.resumes.single.document.toJson();
    documentJson['futureDocument'] = {'revision': 7};
    final exported = const LocalDataArchiveCodec().encode(
      LocalDataSnapshot(
        storageSchemaVersion: 4,
        resumes: [
          LocalResumeDataSnapshot(
            document: ResumeDocument.fromJson(documentJson),
            versions: [ResumeVersion.fromJson(versionJson)],
          ),
        ],
        settings: snapshot.settings,
        agentAudits: snapshot.agentAudits,
      ),
      exportedAtUtc,
    );
    final archive = jsonDecode(exported) as JsonMap;
    expect(_firstDocument(archive)['futureDocument'], {'revision': 7});
    expect(_firstVersion(archive)['futureVersion'], {'enabled': true});
    final encodedContent = _firstVersion(archive)['content']! as JsonMap;
    expect(encodedContent['futureContent'], ['保留', 42]);
    expect(encodedContent['unmapped'], {'legacySection': '待人工映射'});
    expect((encodedContent['profile']! as JsonMap)['futureProfile'], {
      'level': 3,
    });
    final versions = _firstResume(archive)['versions']! as List<Object?>;
    versions.insert(0, {
      ..._firstVersion(archive),
      'id': 'version-002',
      'parentVersionId': 'version-001',
    });
    _firstDocument(archive)['currentVersionId'] = 'version-002';
    archive['futureArchive'] = {'opaque': true};
    expect(
      const LocalDataArchiveCodec().decode(jsonEncode(archive)).versionCount,
      2,
    );
  });
}

JsonMap _archive() =>
    jsonDecode(
          const LocalDataArchiveCodec().encode(_snapshot(), DateTime.utc(2026)),
        )
        as JsonMap;

JsonMap _firstResume(JsonMap archive) =>
    (archive['resumes']! as List<Object?>).first as JsonMap;

JsonMap _firstDocument(JsonMap archive) =>
    _firstResume(archive)['document']! as JsonMap;

JsonMap _firstVersion(JsonMap archive) =>
    (_firstResume(archive)['versions']! as List<Object?>).first as JsonMap;

void _expectInvalidArchive(void Function(JsonMap archive) mutate) {
  final archive = _archive();
  mutate(archive);
  expect(
    () => const LocalDataArchiveCodec().decode(jsonEncode(archive)),
    throwsA(isA<LocalDataArchiveException>()),
  );
}

LocalDataSnapshot _snapshot() {
  final createdAtUtc = DateTime.utc(2026, 10, 2, 8);
  final resumeVersion = ResumeVersion(
    id: 'version-001',
    documentId: 'document-001',
    parentVersionId: null,
    schemaVersion: currentResumeSchemaVersion,
    content: ResumeData(
      profile: ResumeProfile(
        id: 'profile-001',
        fullName: '张三',
        headline: '工程师',
        email: '',
        phone: '',
        location: '',
      ),
    ),
    source: ResumeVersionSource.created,
    createdAt: createdAtUtc,
  );
  final resumeDocument = ResumeDocument(
    id: 'document-001',
    title: '敏感简历标题',
    currentVersionId: resumeVersion.id,
    createdAt: createdAtUtc,
    updatedAt: createdAtUtc,
  );
  final agentRun = AgentRunAuditRecord(
    id: 'run-001',
    requestId: 'request-001',
    documentId: resumeDocument.id,
    resumeVersionId: resumeVersion.id,
    status: 'completed',
    routeStatus: 'selected',
    startedAt: createdAtUtc,
    finishedAt: createdAtUtc.add(const Duration(milliseconds: 10)),
    toolCallCount: 1,
  );
  return LocalDataSnapshot(
    storageSchemaVersion: 3,
    resumes: [
      LocalResumeDataSnapshot(
        document: resumeDocument,
        versions: [resumeVersion],
      ),
    ],
    settings: [
      LocalBooleanSettingSnapshot(
        key: 'network_enabled',
        value: false,
        updatedAtUtc: createdAtUtc,
      ),
    ],
    agentAudits: [
      LocalAgentAuditSnapshot(
        run: agentRun,
        toolCalls: [
          ToolCallAuditRecord(
            id: 'call-001',
            agentRunId: agentRun.id,
            toolName: 'validate_resume',
            toolVersion: '0.1.0',
            status: 'success',
            startedAt: createdAtUtc,
            finishedAt: createdAtUtc.add(const Duration(milliseconds: 5)),
            offline: true,
            replayed: false,
          ),
        ],
      ),
    ],
  );
}

final class _FakeLocalDataRepository implements LocalDataRepository {
  @override
  Future<void> restoreResumes(List<LocalResumeDataSnapshot> resumes) =>
      throw UnimplementedError('该导出/清空夹具不执行恢复');
  _FakeLocalDataRepository(this.snapshot);

  final LocalDataSnapshot snapshot;
  int clearCallCount = 0;

  @override
  Future<LocalDataSnapshot> readSnapshot() async => snapshot;

  @override
  Future<LocalDataSnapshot> readExportSnapshot() async => snapshot;

  @override
  Future<LocalDataClearResult> clearAll() async {
    clearCallCount++;
    return const LocalDataClearResult(
      documentCount: 1,
      versionCount: 1,
      settingCount: 1,
      agentRunCount: 1,
      toolCallCount: 1,
    );
  }
}
