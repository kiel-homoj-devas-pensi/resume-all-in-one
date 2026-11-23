import 'package:flutter/services.dart';
import 'package:resume_all_in_one_client/src/resume_file_delivery.dart';
import 'dart:convert';
import 'dart:io';

import 'package:document_io/document_io.dart';
import 'package:entitlements/entitlements.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_all_in_one_client/src/local_agent_composition.dart';
import 'support/local_suggestion_fixture.dart';
import 'package:resume_all_in_one_client/src/local_data_management_service.dart';
import 'package:resume_all_in_one_client/src/remote_account_service.dart';
import 'package:resume_all_in_one_client/src/remote_resume_ai_service.dart';
import 'package:resume_all_in_one_client/src/local_resume_suggestion_service.dart';
import 'package:resume_all_in_one_client/src/resume_file_exporter.dart';
import 'package:resume_all_in_one_client/src/resume_import_file_picker.dart';
import 'package:resume_all_in_one_client/src/resume_workspace_controller.dart';
import 'package:resume_domain/resume_domain.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final outcome in ['saved', 'cancelled', 'failure']) {
    test('文本与本地档案系统另存 $outcome 保留原件及简历历史', () async {
      final root = await Directory.systemTemp.createTemp('local-delivery-');
      final database = LocalStorageDatabase.inMemory();
      final controller = _createController(
        database: database,
        exportDirectory: root,
        importFilePicker: const _FakeResumeImportFilePicker(null),
      );
      final repository = DriftResumeRepository(database);
      const channel = MethodChannel('resume_all_in_one/file_delivery');
      final delivered = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'saveAs');
            final path = call.arguments['path'] as String;
            expect(await File(path).exists(), isTrue);
            delivered.add(path);
            if (outcome == 'failure') {
              throw PlatformException(code: 'file_delivery_failed');
            }
            return outcome;
          });
      try {
        await controller.initialize();
        await controller.createDocument(title: '合成档案', fullName: '测试姓名');
        final content = controller.currentVersion!.content.toJson();
        content['futureField'] = {'original': '保留未知字段'};
        content['unmapped'] = {'legacyNote': '保留原文'};
        await controller.saveContent(
          title: '合成档案',
          content: ResumeData.fromJson(content),
        );
        final originalDocument = controller.currentDocument!.toJson();
        final originalVersion = controller.currentVersion!.toJson();
        final originalHistory = (await repository.listVersions(
          controller.currentDocument!.id,
        )).map((version) => version.toJson()).toList();

        for (final format in ResumeExportFormat.values) {
          final result = await controller.deliverCurrentText(format);
          expect(
            result,
            outcome == 'failure'
                ? isNull
                : outcome == 'saved'
                ? ResumeFileDeliveryOutcome.saved
                : ResumeFileDeliveryOutcome.cancelled,
          );
          expect(controller.isBusy, isFalse);
          expect(
            controller.formError,
            outcome == 'failure' ? isNotNull : isNull,
          );
        }
        final result = await controller.deliverAllLocalData();
        expect(
          result,
          outcome == 'failure'
              ? isNull
              : outcome == 'saved'
              ? ResumeFileDeliveryOutcome.saved
              : ResumeFileDeliveryOutcome.cancelled,
        );
        expect(delivered, hasLength(3));
        for (final path in delivered) {
          expect(await File(path).length(), greaterThan(0));
        }
        final jsonFile = delivered.singleWhere(
          (path) => path.endsWith('.json') && path.contains('resume_exports'),
        );
        expect(
          const CanonicalResumeCodec()
              .decode(await File(jsonFile).readAsString())
              .toJson(),
          controller.currentVersion!.content.toJson(),
        );
        final archivePath = delivered.singleWhere(
          (path) => path.contains('local_data_exports'),
        );
        final archive =
            jsonDecode(await File(archivePath).readAsString()) as Map;
        expect(archive['resumes'].single['document'], originalDocument);
        expect(
          const LocalDataArchiveCodec()
              .decode(await File(archivePath).readAsString())
              .versionCount,
          originalHistory.length,
        );
        expect(controller.currentVersion!.toJson(), originalVersion);
        expect(controller.currentDocument!.toJson(), originalDocument);
        expect(
          (await repository.listVersions(
            controller.currentDocument!.id,
          )).map((version) => version.toJson()).toList(),
          originalHistory,
        );
        if (outcome == 'cancelled') {
          expect(controller.message, contains('已取消另存'));
        }
        if (outcome == 'failure') {
          expect(controller.formError, contains('原件保留'));
        }
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        controller.dispose();
        await database.close();
        await root.delete(recursive: true);
      }
    });
  }

  test('等值编辑不新增版本，恢复等值历史仍记录恢复动作，非法输入不写入', () async {
    final exportDirectory = await Directory.systemTemp.createTemp(
      'resume-save-behavior-',
    );
    final database = LocalStorageDatabase.inMemory();
    final controller = _createController(
      database: database,
      exportDirectory: exportDirectory,
      importFilePicker: const _FakeResumeImportFilePicker(null),
    );
    final repository = DriftResumeRepository(database);
    try {
      await controller.initialize();
      expect(
        await controller.createDocument(title: '教学简历', fullName: '合成学生'),
        isTrue,
      );
      final initialDocument = controller.currentDocument!;
      final initialVersion = controller.currentVersion!;
      expect(
        await controller.saveContent(
          title: '  教学简历  ',
          content: ResumeData.fromJson(initialVersion.content.toJson()),
        ),
        SaveOutcome.unchanged,
      );
      expect(await repository.listVersions(initialDocument.id), hasLength(1));
      expect(controller.currentVersion!.id, initialVersion.id);

      final invalidResumeJson = initialVersion.content.toJson();
      (invalidResumeJson['profile']! as JsonMap)['email'] = 'invalid-email';
      expect(
        await controller.saveContent(
          title: '非法草稿',
          content: ResumeData.fromJson(invalidResumeJson),
        ),
        SaveOutcome.blocked,
      );
      expect(controller.validationIssues.single.ruleId, 'email.format');
      expect(
        (await repository.findDocument(initialDocument.id))!.toJson(),
        initialDocument.toJson(),
      );
      expect(await repository.listVersions(initialDocument.id), hasLength(1));

      expect(
        await controller.restoreVersion(initialVersion.id),
        DocumentLifecycleOutcome.completed,
      );
      final restoredVersion = controller.currentVersion!;
      expect(restoredVersion.id, isNot(initialVersion.id));
      expect(restoredVersion.source, ResumeVersionSource.restored);
      expect(restoredVersion.parentVersionId, initialVersion.id);
      expect(restoredVersion.content.toJson(), initialVersion.content.toJson());
      expect(await repository.listVersions(initialDocument.id), hasLength(2));
      expect(
        (await repository.findVersion(initialVersion.id))!.toJson(),
        initialVersion.toJson(),
      );
    } finally {
      controller.dispose();
      await database.close();
      await exportDirectory.delete(recursive: true);
    }
  });

  test('离线完成导入、编辑、建议、Word修改转PDF与重启恢复，Canonical不被副本改写', () async {
    final acceptanceDirectory = await Directory.systemTemp.createTemp(
      'phase5-offline-acceptance-',
    );
    final databaseFile = File(
      '${acceptanceDirectory.path}${Platform.pathSeparator}resume.sqlite',
    );
    final selectedTextFile = _FakeResumeImportFilePicker(
      SelectedResumeTextFile(
        fileName: 'candidate.md',
        bytes: Uint8List.fromList(
          utf8.encode('姓名：林晓舟\n职业标题：Flutter 工程师\n需人工保留的补充说明'),
        ),
      ),
    );
    var database = LocalStorageDatabase.openFile(databaseFile);
    await DriftAppSettingsRepository(database).setNetworkEnabled(false);
    var controller = _createController(
      database: database,
      exportDirectory: acceptanceDirectory,
      importFilePicker: selectedTextFile,
    );

    try {
      await controller.initialize();
      expect(controller.networkEnabled, isFalse);

      expect(
        await controller.prepareTextImport(),
        ImportPreparationOutcome.ready,
      );
      expect(
        await controller.confirmPendingImport(newDocumentTitle: '离线验收简历'),
        ImportCommitOutcome.completed,
      );
      final importedDocumentId = controller.currentDocument!.id;
      expect(controller.currentVersion!.source, ResumeVersionSource.imported);
      expect(controller.currentVersion!.content.unmapped, isNotEmpty);

      final completeResume = await _completeResumeWithFormattingIssue();
      expect(
        await controller.saveContent(title: '离线验收简历', content: completeResume),
        SaveOutcome.saved,
      );
      expect(controller.currentVersion!.source, ResumeVersionSource.edited);
      expect(controller.currentVersion!.content.workExperiences, hasLength(2));
      expect(
        controller.currentVersion!.content.unmapped['legacyNote'],
        isNotNull,
      );

      final rejectedPreparation = await controller.prepareLocalSuggestion();
      expect(
        rejectedPreparation!.status,
        LocalSuggestionPreparationStatus.ready,
      );
      expect(
        (await controller.decidePendingSuggestion(
          LocalSuggestionDecision.reject,
        ))!.status,
        LocalSuggestionDecisionStatus.rejected,
      );
      expect(controller.versions, hasLength(2));

      final acceptedPreparation = await controller.prepareLocalSuggestion();
      expect(
        acceptedPreparation!.status,
        LocalSuggestionPreparationStatus.ready,
      );
      expect(
        (await controller.decidePendingSuggestion(
          LocalSuggestionDecision.accept,
        ))!.status,
        LocalSuggestionDecisionStatus.accepted,
      );
      expect(controller.versions, hasLength(3));
      expect(
        controller.currentVersion!.source,
        ResumeVersionSource.aiConfirmed,
      );
      expect(
        controller.currentVersion!.content.profile.headline,
        'Flutter 客户端工程师 · 离线产品体验',
      );

      final markdownPath = await controller.exportCurrent(
        ResumeExportFormat.markdown,
      );
      final jsonPath = await controller.exportCurrent(ResumeExportFormat.json);
      final preparedPdf = await controller.prepareCurrentPdf();
      final pdfPath = await controller.exportPreparedPdf(preparedPdf!);
      expect(await File(markdownPath!).readAsString(), contains('# 林晓舟'));
      expect(await File(jsonPath!).readAsString(), contains('"legacyNote"'));
      expect(await File(pdfPath!).readAsBytes(), preparedPdf.bytes);
      expect(controller.networkEnabled, isFalse);

      final savedCanonicalVersion = controller.currentVersion!;
      final originalWord = (await controller.openCurrentWord())!;
      final originalDocxBytes = await File(originalWord.path).readAsBytes();
      final editedParagraphs = [
        ResumeWordParagraph(
          text: '离线文稿修改标记',
          style: originalWord.content.paragraphs.first.style,
        ),
        ...originalWord.content.paragraphs.skip(1),
      ];
      final revisedWord = (await controller.saveWord(
        savedCanonicalVersion,
        ResumeWordDocument(paragraphs: editedParagraphs),
      ))!;
      final wordPdf = (await controller.convertWordToPdf(
        revisedWord,
        controller.currentDocument!,
        savedCanonicalVersion,
      ))!;
      final wordPdfPath = (await controller.exportPreparedPdf(wordPdf))!;
      expect(await File(wordPdfPath).readAsBytes(), wordPdf.bytes);
      final handedOff = <MethodCall>[];
      final selectedBytes = <Uint8List>[];
      const channel = MethodChannel('resume_all_in_one/file_delivery');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            handedOff.add(call);
            selectedBytes.add(
              await File(call.arguments['path'] as String).readAsBytes(),
            );
            return call.method == 'share' ? 'shareOpened' : 'saved';
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      expect(
        await controller.deliverSavedWord(
          revisedWord,
          ResumeFileDeliveryAction.saveAs,
        ),
        ResumeFileDeliveryOutcome.saved,
      );
      expect(
        await controller.deliverPreparedPdf(
          wordPdf,
          ResumeFileDeliveryAction.share,
        ),
        ResumeFileDeliveryOutcome.shareOpened,
      );
      expect(selectedBytes[0], await File(revisedWord.path).readAsBytes());
      expect(selectedBytes[1], wordPdf.bytes, reason: '交付和预览必须同字节');
      expect(handedOff.map((call) => call.method), ['saveAs', 'share']);
      expect(controller.networkEnabled, isFalse);

      expect(await File(originalWord.path).readAsBytes(), originalDocxBytes);
      expect(
        (await DriftResumeRepository(
          database,
        ).findCurrentVersion(importedDocumentId))!.toJson(),
        savedCanonicalVersion.toJson(),
      );
      expect(controller.versions, hasLength(3));

      controller.dispose();
      await database.close();

      database = LocalStorageDatabase.openFile(databaseFile);
      controller = _createController(
        database: database,
        exportDirectory: acceptanceDirectory,
        importFilePicker: selectedTextFile,
      );
      await controller.initialize();
      await controller.openDocument(importedDocumentId);

      expect(controller.networkEnabled, isFalse);
      expect(
        controller.currentVersion!.source,
        ResumeVersionSource.aiConfirmed,
      );
      expect(controller.versions.map((version) => version.source), [
        ResumeVersionSource.aiConfirmed,
        ResumeVersionSource.edited,
        ResumeVersionSource.imported,
      ]);
      expect(controller.currentVersion!.content.workExperiences, hasLength(2));
      final reopenedWord = (await controller.openCurrentWord())!;
      expect(reopenedWord.path, revisedWord.path);
      expect(reopenedWord.content.paragraphs.first.text, '离线文稿修改标记');
      expect(controller.currentVersion!.content.profile.fullName, '林晓舟');
      expect(
        controller.currentVersion!.content.unmapped['legacyNote'],
        isNotNull,
      );
    } finally {
      controller.dispose();
      await database.close();
      await acceptanceDirectory.delete(recursive: true);
    }
  });
}

ResumeWorkspaceController _createController({
  required LocalStorageDatabase database,
  required Directory exportDirectory,
  required ResumeImportFilePicker importFilePicker,
}) {
  final resumeRepository = DriftResumeRepository(database);
  final auditRepository = DriftAgentAuditRepository(database);
  final remoteAccountService = RemoteAccountService(gatewayApi: null);
  return ResumeWorkspaceController(
    repository: resumeRepository,
    settingsRepository: DriftAppSettingsRepository(database),
    localAgentCheckService: createOfflineLocalAgentCheckService(
      resumeRepository: resumeRepository,
      auditRepository: auditRepository,
    ),
    localResumeSuggestionService: createOfflineLocalResumeSuggestionService(
      resumeRepository: resumeRepository,
      auditRepository: auditRepository,
    ),
    localDataManagementService: LocalDataManagementService(
      repository: DriftLocalDataRepository(database),
      rootDirectory: () async => exportDirectory,
    ),
    accessPolicy: CapabilityAccessPolicy.mvp(),
    fileExporter: ResumeFileExporter(
      rootDirectory: () async => exportDirectory,
    ),
    importFilePicker: importFilePicker,
    remoteAccountService: remoteAccountService,
    remoteResumeAiService: RemoteResumeAiService(
      accountService: remoteAccountService,
    ),
  );
}

Future<ResumeData> _completeResumeWithFormattingIssue() async {
  final fixtureText = await File(
    '../../packages/document_io/test/fixtures/pdf_resume_input.json',
  ).readAsString();
  final completeResumeJson = const CanonicalResumeCodec()
      .decode(fixtureText)
      .toJson();
  final profileJson = Map<String, Object?>.from(
    completeResumeJson['profile']! as Map,
  );
  profileJson['headline'] = 'Flutter  客户端工程师 · 离线产品体验';
  completeResumeJson['profile'] = profileJson;
  return ResumeData.fromJson(completeResumeJson);
}

final class _FakeResumeImportFilePicker implements ResumeImportFilePicker {
  const _FakeResumeImportFilePicker(this.selectedFile);

  final SelectedResumeTextFile? selectedFile;

  @override
  Future<SelectedResumeTextFile?> pickResumeTextFile() async => selectedFile;
}
