import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:entitlements/entitlements.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_all_in_one_client/src/local_agent_composition.dart';
import 'support/local_suggestion_fixture.dart';
import 'package:resume_all_in_one_client/src/local_data_management_service.dart';
import 'package:resume_all_in_one_client/src/local_resume_suggestion_service.dart';
import 'package:resume_all_in_one_client/src/remote_account_service.dart';
import 'package:resume_all_in_one_client/src/remote_resume_ai_service.dart';
import 'package:resume_all_in_one_client/src/resume_file_exporter.dart';
import 'package:resume_all_in_one_client/src/resume_import_file_picker.dart';
import 'package:resume_all_in_one_client/src/resume_workspace_controller.dart';
import 'package:resume_domain/resume_domain.dart';

void main() {
  late LocalStorageDatabase database;
  late DriftResumeRepository stored;
  late _ReadFailureRepository repository;
  late ResumeWorkspaceController controller;

  setUp(() async {
    database = LocalStorageDatabase.inMemory();
    stored = DriftResumeRepository(database);
    repository = _ReadFailureRepository(stored);
    final account = RemoteAccountService(gatewayApi: null);
    controller = ResumeWorkspaceController(
      repository: repository,
      settingsRepository: DriftAppSettingsRepository(database),
      localAgentCheckService: createOfflineLocalAgentCheckService(
        resumeRepository: repository,
        auditRepository: DriftAgentAuditRepository(database),
      ),
      localResumeSuggestionService: createOfflineLocalResumeSuggestionService(
        resumeRepository: repository,
        auditRepository: DriftAgentAuditRepository(database),
      ),
      localDataManagementService: LocalDataManagementService(
        repository: DriftLocalDataRepository(database),
        rootDirectory: () async => Directory.systemTemp,
      ),
      accessPolicy: CapabilityAccessPolicy.mvp(),
      fileExporter: ResumeFileExporter(
        rootDirectory: () async => Directory.systemTemp,
      ),
      importFilePicker: _ImportPicker(),
      remoteAccountService: account,
      remoteResumeAiService: RemoteResumeAiService(accountService: account),
    );
    await controller.initialize();
  });

  tearDown(() async {
    controller.dispose();
    await database.close();
  });

  void expectCommittedFeedback() {
    expect(controller.formError, isNull);
    expect(controller.message, contains('刷新失败'));
    expect(controller.message, isNot(contains('synthetic secret')));
    expect(controller.isBusy, isFalse);
    expect(repository.failedReads, 1, reason: '确实触发了提交后的读取故障');
  }

  for (final failedList in ['documents', 'versions']) {
    test('保存已提交但 $failedList 刷新失败，重按保存不重复追加', () async {
      await controller.createDocument(title: '原始简历', fullName: '测试姓名');
      final original = controller.currentVersion!;
      repository.failListAfterCommit = failedList;

      expect(
        await controller.saveContent(title: '新标题', content: original.content),
        SaveOutcome.saved,
      );
      expectCommittedFeedback();
      final committed = await stored.findCurrentVersion(original.documentId);
      expect(controller.currentVersion!.id, committed!.id);
      expect(controller.currentDocument!.title, '新标题');
      expect(controller.documents.single.title, '新标题');
      expect(
        controller.versions.map((version) => version.id),
        contains(committed.id),
      );
      expect(await stored.findVersion(original.id), isNotNull);
      expect(
        await controller.saveContent(title: '新标题', content: original.content),
        SaveOutcome.unchanged,
      );
      expect(await stored.listVersions(original.documentId), hasLength(2));
      expect(repository.commits, 2);
    });
  }

  for (final operation in ['创建', '复制', '导入新文档']) {
    test('$operation 已提交而文档列表读取失败，界面仍持有新文档', () async {
      if (operation == '复制') {
        await controller.createDocument(title: '原件', fullName: '测试姓名');
      }
      if (operation == '导入新文档') await controller.prepareTextImport();
      repository.failListAfterCommit = 'documents';

      switch (operation) {
        case '创建':
          expect(
            await controller.createDocument(title: '新建', fullName: '测试姓名'),
            isTrue,
          );
        case '复制':
          expect(
            await controller.duplicateCurrent(),
            DocumentLifecycleOutcome.completed,
          );
        case '导入新文档':
          expect(
            await controller.confirmPendingImport(newDocumentTitle: '导入'),
            ImportCommitOutcome.completed,
          );
      }
      expectCommittedFeedback();
      final created = controller.currentDocument!;
      expect(await stored.findDocument(created.id), isNotNull);
      expect(
        controller.documents.map((document) => document.id),
        contains(created.id),
      );
      expect(controller.versions.single.id, created.currentVersionId);
      expect(
        await stored.listDocuments(),
        hasLength(operation == '复制' ? 2 : 1),
      );
      if (operation == '导入新文档') {
        expect(controller.pendingImport, isNull);
        expect(
          await controller.confirmPendingImport(),
          ImportCommitOutcome.failed,
        );
        expect(await stored.listDocuments(), hasLength(1));
      }
      await controller.closeDocument();
      await controller.openDocument(created.id);
      expect(controller.currentVersion!.id, created.currentVersionId);
    });
  }

  for (final operation in ['导入', '恢复']) {
    test('$operation 已追加版本而历史读取失败，保留成功反馈和旧快照', () async {
      await controller.createDocument(title: '简历', fullName: '原姓名');
      final original = controller.currentVersion!;
      if (operation == '导入') await controller.prepareTextImport();
      repository.failListAfterCommit = 'versions';

      if (operation == '导入') {
        expect(
          await controller.confirmPendingImport(),
          ImportCommitOutcome.completed,
        );
        expect(controller.pendingImport, isNull);
      } else {
        expect(
          await controller.restoreVersion(original.id),
          DocumentLifecycleOutcome.completed,
        );
        expect(controller.message, contains('已恢复历史版本'));
      }
      expectCommittedFeedback();
      expect(controller.currentVersion!.id, isNot(original.id));
      expect(controller.currentVersion!.parentVersionId, original.id);
      expect(controller.versions, hasLength(2));
      expect(
        (await stored.findVersion(original.id))!.content.profile.fullName,
        '原姓名',
      );
      expect(await stored.listVersions(original.documentId), hasLength(2));
    });
  }

  for (final deleteCurrent in [false, true]) {
    test('删除${deleteCurrent ? '当前' : '其他'}文档已提交而刷新失败，列表不再显示已删项', () async {
      await controller.createDocument(title: '待删除', fullName: '测试姓名');
      final deleted = controller.currentDocument!;
      if (!deleteCurrent) {
        await controller.createDocument(title: '保留', fullName: '测试姓名');
      }
      final retainedId = controller.currentDocument!.id;
      repository.failListAfterCommit = 'documents';

      expect(
        await controller.deleteDocument(deleted.id),
        DocumentLifecycleOutcome.completed,
      );
      expectCommittedFeedback();
      expect(await stored.findDocument(deleted.id), isNull);
      expect(await stored.listVersions(deleted.id), isEmpty);
      expect(
        controller.documents.any((document) => document.id == deleted.id),
        isFalse,
      );
      expect(
        controller.currentDocument?.id,
        deleteCurrent ? isNull : retainedId,
      );
      final commits = repository.commits;
      expect(
        await controller.deleteDocument(deleted.id),
        DocumentLifecycleOutcome.failed,
      );
      expect(repository.commits, commits, reason: '已删除项不会被再次提交');
    });
  }

  test('本地建议已确认后读取失败，不恢复已解决票据或再次写入', () async {
    await controller.createDocument(title: '简历', fullName: '测试姓名');
    final content = controller.currentVersion!.content.toJson();
    (content['profile']! as Map<String, Object?>)['headline'] = 'Flutter  工程师';
    await controller.saveContent(
      title: '简历',
      content: ResumeData.fromJson(content),
    );
    final original = controller.currentVersion!;
    await controller.prepareLocalSuggestion();
    expect(controller.pendingResumeSuggestion, isNotNull);
    repository.failListAfterCommit = 'versions';

    final decision = await controller.decidePendingSuggestion(
      LocalSuggestionDecision.accept,
    );
    expect(decision!.status, LocalSuggestionDecisionStatus.accepted);
    expectCommittedFeedback();
    expect(controller.pendingResumeSuggestion, isNull);
    expect(
      (await stored.findCurrentVersion(original.documentId))!.id,
      decision.newVersionId,
    );
    expect(
      await controller.decidePendingSuggestion(LocalSuggestionDecision.accept),
      isNull,
    );
    expect(await stored.listVersions(original.documentId), hasLength(3));
    await controller.openDocument(original.documentId);
    expect(controller.currentVersion!.content.profile.headline, 'Flutter 工程师');
  });

  for (final operation in ['创建', '保存', '删除']) {
    test('$operation 写入本身失败仍报告失败，不把未提交内容加入界面', () async {
      await controller.createDocument(title: '原件', fullName: '测试姓名');
      final original = controller.currentVersion!;
      repository.failNextWrite = true;
      switch (operation) {
        case '创建':
          expect(
            await controller.createDocument(title: '未写入', fullName: '测试姓名'),
            isFalse,
          );
        case '保存':
          expect(
            await controller.saveContent(
              title: '未写入',
              content: original.content,
            ),
            SaveOutcome.failed,
          );
        case '删除':
          expect(
            await controller.deleteDocument(original.documentId),
            DocumentLifecycleOutcome.failed,
          );
      }
      expect(controller.formError, isNotNull);
      expect(controller.message, isNull);
      expect(controller.currentVersion!.id, original.id);
      expect(controller.documents.single.title, '原件');
      expect(await stored.listVersions(original.documentId), hasLength(1));
      expect(await stored.listDocuments(), hasLength(1));
    });
  }

  test('冲突后的重读也失败时不抛出，内存文档与版本不被部分替换', () async {
    await controller.createDocument(title: '原件', fullName: '测试姓名');
    final originalDocument = controller.currentDocument!;
    final original = controller.currentVersion!;
    await controller.saveContent(title: '外部更新', content: original.content);
    final committed = controller.currentVersion!;
    // 模拟另一窗口已经推进数据库，而当前页面仍停留在原版本。
    controller.currentDocument = originalDocument;
    controller.currentVersion = original;
    repository.failNextList = 'versions';
    expect(
      await controller.saveContent(title: '过期编辑', content: original.content),
      SaveOutcome.failed,
    );
    expect(controller.formError, contains('刷新失败'));
    expect(controller.currentVersion!.id, original.id);
    expect(controller.currentDocument!.currentVersionId, original.id);
    expect(
      (await stored.findCurrentVersion(original.documentId))!.id,
      committed.id,
    );
    expect(await stored.listVersions(original.documentId), hasLength(2));
    expect(controller.isBusy, isFalse);
  });
}

final class _ImportPicker implements ResumeImportFilePicker {
  @override
  Future<SelectedResumeTextFile?> pickResumeTextFile() async =>
      SelectedResumeTextFile(
        fileName: 'synthetic.txt',
        bytes: Uint8List.fromList(utf8.encode('姓名：导入姓名\n职业标题：Flutter 工程师')),
      );
}

// 写入委托给真实 SQLite；只在提交成功后注入一次读取异常。
final class _ReadFailureRepository implements ResumeRepository {
  _ReadFailureRepository(this.delegate);
  final ResumeRepository delegate;
  String? failListAfterCommit;
  String? failNextList;
  bool failNextWrite = false;
  int commits = 0;
  int failedReads = 0;

  void _beforeWrite() {
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('synthetic secret write failure');
    }
  }

  void _committed() {
    commits++;
    failNextList = failListAfterCommit;
    failListAfterCommit = null;
  }

  void _beforeRead(String list) {
    if (failNextList == list) {
      failNextList = null;
      failedReads++;
      throw StateError('synthetic secret read failure');
    }
  }

  @override
  Future<void> createDocument(
    ResumeDocument document,
    ResumeVersion initialVersion,
  ) async {
    _beforeWrite();
    await delegate.createDocument(document, initialVersion);
    _committed();
  }

  @override
  Future<void> saveVersion({
    required ResumeDocument document,
    required ResumeVersion version,
    required String expectedCurrentVersionId,
  }) async {
    _beforeWrite();
    await delegate.saveVersion(
      document: document,
      version: version,
      expectedCurrentVersionId: expectedCurrentVersionId,
    );
    _committed();
  }

  @override
  Future<bool> deleteDocument(String documentId) async {
    _beforeWrite();
    final deleted = await delegate.deleteDocument(documentId);
    if (deleted) _committed();
    return deleted;
  }

  @override
  Future<List<ResumeDocument>> listDocuments() async {
    _beforeRead('documents');
    return delegate.listDocuments();
  }

  @override
  Future<List<ResumeVersion>> listVersions(String documentId) async {
    _beforeRead('versions');
    return delegate.listVersions(documentId);
  }

  @override
  Future<ResumeDocument?> findDocument(String documentId) =>
      delegate.findDocument(documentId);
  @override
  Future<ResumeVersion?> findCurrentVersion(String documentId) =>
      delegate.findCurrentVersion(documentId);
  @override
  Future<ResumeVersion?> findVersion(String versionId) =>
      delegate.findVersion(versionId);
}
