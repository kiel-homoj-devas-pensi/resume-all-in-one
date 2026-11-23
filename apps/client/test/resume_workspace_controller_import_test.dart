import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:entitlements/entitlements.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_all_in_one_client/src/local_agent_composition.dart';
import 'support/local_suggestion_fixture.dart';
import 'package:resume_all_in_one_client/src/local_data_management_service.dart';
import 'package:resume_all_in_one_client/src/remote_account_service.dart';
import 'package:resume_all_in_one_client/src/remote_resume_ai_service.dart';
import 'package:resume_all_in_one_client/src/resume_file_exporter.dart';
import 'package:resume_all_in_one_client/src/resume_import_file_picker.dart';
import 'package:resume_all_in_one_client/src/resume_workspace_controller.dart';
import 'package:resume_domain/resume_domain.dart';

void main() {
  group('内存数据库导入流程', () {
    late LocalStorageDatabase database;
    late DriftResumeRepository repository;
    late Directory temporaryDirectory;
    late _FakeResumeImportFilePicker importFilePicker;
    late ResumeWorkspaceController controller;

    setUp(() async {
      database = LocalStorageDatabase.inMemory();
      repository = DriftResumeRepository(database);
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'resume-import-controller-test-',
      );
      importFilePicker = _FakeResumeImportFilePicker();
      controller = _createController(
        database: database,
        repository: repository,
        temporaryDirectory: temporaryDirectory,
        importFilePicker: importFilePicker,
      );
      await controller.initialize();
    });

    tearDown(() async {
      controller.dispose();
      await database.close();
      await temporaryDirectory.delete(recursive: true);
    });

    test('取消文件选择或预览均不创建文档', () async {
      expect(
        await controller.prepareTextImport(),
        ImportPreparationOutcome.cancelled,
      );
      expect(await repository.listDocuments(), isEmpty);

      importFilePicker.selectedFile = _textFile(
        'candidate.txt',
        '姓名：张三\n职业标题：Flutter 工程师',
      );
      expect(
        await controller.prepareTextImport(),
        ImportPreparationOutcome.ready,
      );
      expect(controller.pendingImport, isNotNull);
      expect(await repository.listDocuments(), isEmpty);

      controller.cancelPendingImport();
      expect(controller.pendingImport, isNull);
      expect(await repository.listDocuments(), isEmpty);
    });

    test('validation error 保留预览但阻止写入', () async {
      importFilePicker.selectedFile = _textFile(
        'invalid.md',
        '姓名：张三\n邮箱：not-an-email',
      );

      expect(
        await controller.prepareTextImport(),
        ImportPreparationOutcome.ready,
      );
      expect(controller.pendingImport!.preview.canCommit, isFalse);
      expect(
        await controller.confirmPendingImport(newDocumentTitle: '无效导入'),
        ImportCommitOutcome.blocked,
      );
      expect(
        controller.validationIssues.any((issue) => issue.blocksCommit),
        isTrue,
      );
      expect(await repository.listDocuments(), isEmpty);
    });

    test('确认导入创建 imported 首版本并保留未映射行', () async {
      importFilePicker.selectedFile = _textFile(
        'candidate.md',
        '姓名：张三\n邮箱：zhangsan@example.com\n## 工作经历',
      );

      await controller.prepareTextImport();
      expect(controller.pendingImport!.preview.unmappedLineCount, 1);
      expect(
        await controller.confirmPendingImport(newDocumentTitle: '导入简历'),
        ImportCommitOutcome.completed,
      );

      final importedDocument = controller.currentDocument!;
      final importedVersion = await repository.findCurrentVersion(
        importedDocument.id,
      );
      expect(importedVersion!.source, ResumeVersionSource.imported);
      expect(importedVersion.content.profile.fullName, '张三');
      expect(importedVersion.content.unmapped, {
        'textImport': {
          'format': 'markdown',
          'lines': [
            {'lineNumber': 3, 'text': '## 工作经历'},
          ],
        },
      });
    });

    test('导入当前文档只追加 imported 版本且旧快照不变', () async {
      await controller.createDocument(title: '已有简历', fullName: '旧姓名');
      final originalVersion = controller.currentVersion!;
      importFilePicker.selectedFile = _textFile(
        'updated.txt',
        '姓名：新姓名\n职业标题：移动端工程师',
      );

      await controller.prepareTextImport();
      expect(
        controller.pendingImport!.target,
        ResumeImportTarget.currentDocument,
      );
      expect(
        await controller.confirmPendingImport(),
        ImportCommitOutcome.completed,
      );

      expect(controller.versions, hasLength(2));
      expect(controller.currentVersion!.source, ResumeVersionSource.imported);
      expect(controller.currentVersion!.parentVersionId, originalVersion.id);
      expect(controller.currentVersion!.content.profile.fullName, '新姓名');
      expect(
        (await repository.findVersion(
          originalVersion.id,
        ))!.content.profile.fullName,
        '旧姓名',
      );
    });
  });

  test('确认后的导入内容在文件数据库重启后保持不变', () async {
    final restartDirectory = await Directory.systemTemp.createTemp(
      'resume-import-restart-test-',
    );
    final databaseFile = File(
      '${restartDirectory.path}${Platform.pathSeparator}resume.db',
    );
    final fileDatabase = LocalStorageDatabase.openFile(databaseFile);
    final fileRepository = DriftResumeRepository(fileDatabase);
    final filePicker = _FakeResumeImportFilePicker()
      ..selectedFile = _textFile('persist.md', '姓名：李四\n自由文本需要保留');
    final fileController = _createController(
      database: fileDatabase,
      repository: fileRepository,
      temporaryDirectory: restartDirectory,
      importFilePicker: filePicker,
    );

    await fileController.initialize();
    await fileController.prepareTextImport();
    await fileController.confirmPendingImport(newDocumentTitle: '持久化导入');
    final documentId = fileController.currentDocument!.id;
    fileController.dispose();
    await fileDatabase.close();

    final reopenedDatabase = LocalStorageDatabase.openFile(databaseFile);
    final reopenedVersion = await DriftResumeRepository(
      reopenedDatabase,
    ).findCurrentVersion(documentId);
    expect(reopenedVersion!.source, ResumeVersionSource.imported);
    expect(reopenedVersion.content.profile.fullName, '李四');
    expect(reopenedVersion.content.unmapped, isNotEmpty);
    await reopenedDatabase.close();
    await restartDirectory.delete(recursive: true);
  });
}

ResumeWorkspaceController _createController({
  required LocalStorageDatabase database,
  required DriftResumeRepository repository,
  required Directory temporaryDirectory,
  required ResumeImportFilePicker importFilePicker,
}) {
  final remoteAccountService = RemoteAccountService(gatewayApi: null);
  return ResumeWorkspaceController(
    repository: repository,
    settingsRepository: DriftAppSettingsRepository(database),
    localAgentCheckService: createOfflineLocalAgentCheckService(
      resumeRepository: repository,
      auditRepository: DriftAgentAuditRepository(database),
      clock: () => DateTime.utc(2026, 10, 2, 8),
    ),
    localResumeSuggestionService: createOfflineLocalResumeSuggestionService(
      resumeRepository: repository,
      auditRepository: DriftAgentAuditRepository(database),
      clock: () => DateTime.utc(2026, 10, 2, 8),
    ),
    localDataManagementService: LocalDataManagementService(
      repository: DriftLocalDataRepository(database),
      rootDirectory: () async => temporaryDirectory,
      clock: () => DateTime.utc(2026, 10, 2, 8),
    ),
    accessPolicy: CapabilityAccessPolicy.mvp(),
    fileExporter: ResumeFileExporter(
      rootDirectory: () async => temporaryDirectory,
    ),
    importFilePicker: importFilePicker,
    remoteAccountService: remoteAccountService,
    remoteResumeAiService: RemoteResumeAiService(
      accountService: remoteAccountService,
    ),
    clock: () => DateTime.utc(2026, 10, 2, 8),
  );
}

SelectedResumeTextFile _textFile(String fileName, String text) {
  return SelectedResumeTextFile(
    fileName: fileName,
    bytes: Uint8List.fromList(utf8.encode(text)),
  );
}

final class _FakeResumeImportFilePicker implements ResumeImportFilePicker {
  SelectedResumeTextFile? selectedFile;

  @override
  Future<SelectedResumeTextFile?> pickResumeTextFile() async => selectedFile;
}
