import 'dart:io';

import 'package:entitlements/entitlements.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_all_in_one_client/main.dart';
import 'package:resume_all_in_one_client/src/local_agent_composition.dart';
import 'support/local_suggestion_fixture.dart';
import 'support/legal_consent_fixture.dart';
import 'package:resume_all_in_one_client/src/local_data_management_service.dart';
import 'package:resume_all_in_one_client/src/resume_file_exporter.dart';
import 'package:resume_all_in_one_client/src/resume_import_file_picker.dart';

import 'local_data_restore_test.dart'
    show SyntheticArchivePicker, syntheticRestoreBytes;

void main() {
  late LocalStorageDatabase database;
  late Directory directory;
  late SyntheticArchivePicker picker;

  setUp(() async {
    database = LocalStorageDatabase.inMemory();
    await DriftAppSettingsRepository(database).setNetworkEnabled(false);
    directory = await Directory.systemTemp.createTemp('archive-ui-test-');
    picker = SyntheticArchivePicker()..bytes = syntheticRestoreBytes();
  });

  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  Future<void> pumpApp(WidgetTester tester) async {
    final repository = DriftResumeRepository(database);
    await tester.pumpWidget(
      ResumeAllInOneApp(
        legalConsentController: await acceptedLegalConsentFixture(),
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
          rootDirectory: () async => directory,
          archiveFilePicker: picker,
        ),
        accessPolicy: CapabilityAccessPolicy.mvp(),
        fileExporter: ResumeFileExporter(rootDirectory: () async => directory),
        importFilePicker: const SystemResumeImportFilePicker(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openPrivacy(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('隐私设置')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('恢复简历与全部历史')),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
  }

  void testApp(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    });
  }

  testApp('真实隐私入口显示简历与历史数量及排除项，取消无写入、确认才添加', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpApp(tester);
    await openPrivacy(tester);
    await tester.tap(find.byKey(const Key('恢复简历与全部历史')));
    await waitForArchivePrompt(tester);
    expect(find.textContaining('将添加 2 份简历及 6 个历史版本'), findsOneWidget);
    expect(find.textContaining('文档或版本身份重复时整份拒绝'), findsOneWidget);
    expect(find.textContaining('不会恢复档案中的设置、联网同意、账号、审计'), findsOneWidget);
    expect(await DriftResumeRepository(database).listDocuments(), isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await DriftResumeRepository(database).listDocuments(), isEmpty);
    expect(find.text('恢复简历与全部历史？'), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('恢复简历与全部历史')));
    await tester.tap(find.byKey(const Key('恢复简历与全部历史')));
    await waitForArchivePrompt(tester);
    await tester.tap(find.byKey(const Key('确认恢复档案')));
    await tester.pumpAndSettle();
    expect(await DriftResumeRepository(database).listDocuments(), hasLength(2));
    expect(
      await DriftResumeRepository(database).listVersions('archive-a'),
      hasLength(3),
    );
    expect(
      await DriftResumeRepository(database).listVersions('archive-b'),
      hasLength(3),
    );
    expect(
      await DriftResumeRepository(database).findCurrentVersion('archive-b'),
      isNull,
    );
    expect(
      await DriftAppSettingsRepository(database).getNetworkEnabled(),
      isFalse,
    );
    expect(await DriftAgentAuditRepository(database).listRuns(), isEmpty);
    expect(picker.calls, 2);
    expect(tester.takeException(), isNull);
  });

  testApp('编辑草稿真实离开保护先于档案选择，继续编辑保留草稿，保存后取消恢复仅追加草稿版本', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('新建简历')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('新建标题输入框')), '合成草稿保护');
    await tester.tap(find.byKey(const Key('确认新建简历')));
    await tester.pumpAndSettle();
    final repository = DriftResumeRepository(database);
    final document = (await repository.listDocuments()).single;
    await tester.enterText(find.byKey(const Key('意向职业岗位输入框')), '尚未保存的合成职业');
    await openPrivacy(tester);
    await tester.tap(find.byKey(const Key('恢复简历与全部历史')));
    await tester.pumpAndSettle();
    expect(find.text('保存这次修改？'), findsOneWidget);
    expect(picker.calls, 0);
    await tester.tap(find.byKey(const Key('继续编辑')));
    await tester.pumpAndSettle();
    expect(picker.calls, 0);
    expect(await repository.listVersions(document.id), hasLength(1));
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('意向职业岗位输入框')))
          .controller!
          .text,
      '尚未保存的合成职业',
    );
    expect(find.text('有未保存的修改'), findsOneWidget);

    await openPrivacy(tester);
    await tester.tap(find.byKey(const Key('恢复简历与全部历史')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('保存并继续')));
    await waitForArchivePrompt(tester);
    expect(picker.calls, 1);
    expect(await repository.listVersions(document.id), hasLength(2));
    expect(
      (await repository.findCurrentVersion(
        document.id,
      ))!.content.profile.headline,
      '尚未保存的合成职业',
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await repository.listDocuments(), hasLength(1));
    expect(await repository.listVersions(document.id), hasLength(2));
    expect(await repository.findDocument('archive-a'), isNull);
    expect(
      await DriftAppSettingsRepository(database).getNetworkEnabled(),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });
}

// Isolate.run uses real event delivery; pumpAndSettle alone can finish before it.
Future<void> waitForArchivePrompt(WidgetTester tester) async {
  final prompt = find.byKey(const Key('确认恢复档案'));
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.pump();
    if (prompt.evaluate().isNotEmpty) {
      await tester.pumpAndSettle();
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(prompt, findsOneWidget, reason: '真实 worker 应完成解析并打开确认窗口');
}
