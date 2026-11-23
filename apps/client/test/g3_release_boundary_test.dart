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
import 'package:resume_all_in_one_client/src/local_resume_suggestion_service.dart';
import 'package:resume_all_in_one_client/src/resume_file_exporter.dart';
import 'package:resume_all_in_one_client/src/resume_home_page.dart';
import 'package:resume_all_in_one_client/src/resume_import_file_picker.dart';

void main() {
  late LocalStorageDatabase database;
  late Directory directory;
  late LocalDataManagementService dataService;

  setUp(() async {
    // Fresh settings intentionally retain the shipping default, including the
    // network preference. Having permission must not initiate a connection.
    database = LocalStorageDatabase.inMemory();
    directory = await Directory.systemTemp.createTemp('g3-release-boundary-');
    dataService = LocalDataManagementService(
      repository: DriftLocalDataRepository(database),
      rootDirectory: () async => directory,
    );
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
        localDataManagementService: dataService,
        accessPolicy: CapabilityAccessPolicy.mvp(),
        fileExporter: ResumeFileExporter(rootDirectory: () async => directory),
        importFilePicker: const SystemResumeImportFilePicker(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> createDocument(WidgetTester tester, String title) async {
    await tester.tap(find.byKey(const Key('新建简历')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('新建标题输入框')), title);
    await tester.enterText(find.byKey(const Key('新建姓名输入框')), '合成验收用户');
    await tester.tap(find.byKey(const Key('确认新建简历')));
    await tester.pumpAndSettle();
  }

  Future<void> openPrivacy(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('隐私设置')));
    await tester.pumpAndSettle();
  }

  Future<void> tapPrivacyAction(WidgetTester tester, Key key) async {
    final action = find.byKey(key);
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
  }

  Future<String> databaseFacts() async => const LocalDataArchiveCodec().encode(
    await DriftLocalDataRepository(database).readSnapshot(),
    DateTime.utc(2026, 10, 12),
  );

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

  testApp('G3 无 Gateway 新安装创建编辑保存、账户与云政策入口不构造 HTTP 客户端', (tester) async {
    var httpClientAttempts = 0;
    await HttpOverrides.runZoned(
      () async {
        await pumpApp(tester);
        expect(
          await DriftAppSettingsRepository(database).getNetworkEnabled(),
          isTrue,
        );
        await createDocument(tester, 'G3 本机验收');
        await tester.enterText(find.byKey(const Key('意向职业岗位输入框')), '离线工程师');
        await tester.ensureVisible(find.byKey(const Key('保存新版本')));
        await tester.tap(find.byKey(const Key('保存新版本')));
        await tester.pumpAndSettle();
        final repository = DriftResumeRepository(database);
        final document = (await repository.listDocuments()).single;
        expect(await repository.listVersions(document.id), hasLength(2));
        expect(
          (await repository.findCurrentVersion(
            document.id,
          ))!.content.profile.headline,
          '离线工程师',
        );
        final before = await databaseFacts();

        await tester.tap(find.byKey(const Key('隐私设置')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('开发账号')));
        await tester.tap(find.byKey(const Key('开发账号')));
        await tester.pumpAndSettle();
        expect(find.text('联网服务尚未配置'), findsOneWidget);
        expect(find.byKey(const Key('登录开发账号')), findsNothing);
        expect(find.byKey(const Key('注册开发账号')), findsNothing);
        await tester.tap(find.text('退出'));
        await tester.pumpAndSettle();

        await openPrivacy(tester);
        await tapPrivacyAction(tester, const Key('查询云同步政策'));
        expect(find.text('云同步政策'), findsOneWidget);
        expect(find.text('未配置开发服务，无法查询云政策。'), findsOneWidget);
        expect(find.text('客户端上传尚未开放。本地编辑、历史和文件导出仍可使用。'), findsOneWidget);
        expect(find.text('云服务：合成测试环境'), findsNothing);
        expect(find.textContaining('不上传简历'), findsOneWidget);
        await tester.tap(find.text('重新查询'));
        await tester.pumpAndSettle();
        expect(find.text('未配置开发服务，无法查询云政策。'), findsOneWidget);
        expect(await databaseFacts(), before);
        expect(httpClientAttempts, 0);
        expect(tester.takeException(), isNull);
      },
      createHttpClient: (context) {
        httpClientAttempts++;
        throw StateError('G3 acceptance forbids HTTP client construction');
      },
    );
  });

  testApp('G3 危险删除与清空的真实确认链保护历史及已导出档案', (tester) async {
    await pumpApp(tester);
    await createDocument(tester, 'G3 保留历史');
    await tester.enterText(find.byKey(const Key('意向职业岗位输入框')), '第二版合成内容');
    await tester.ensureVisible(find.byKey(const Key('保存新版本')));
    await tester.tap(find.byKey(const Key('保存新版本')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('返回简历列表')));
    await tester.pumpAndSettle();
    await createDocument(tester, 'G3 删除目标');
    final repository = DriftResumeRepository(database);
    final documents = await repository.listDocuments();
    final deleted = documents.singleWhere((item) => item.title == 'G3 删除目标');
    final retained = documents.singleWhere((item) => item.title == 'G3 保留历史');
    final retainedVersions = (await repository.listVersions(
      retained.id,
    )).map((version) => version.toJson()).toList();
    final exported = (await tester.runAsync(() => dataService.exportAll()))!;
    final exportedBytes = (await tester.runAsync(exported.file.readAsBytes))!;
    final before = await databaseFacts();

    await openPrivacy(tester);
    await tapPrivacyAction(tester, Key('设置删除简历_${deleted.id}'));
    expect(find.text('删除这份简历？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await databaseFacts(), before);
    expect(await tester.runAsync(exported.file.readAsBytes), exportedBytes);

    await tapPrivacyAction(tester, const Key('清空全部本地数据'));
    final confirmation = find.byKey(const Key('确认清空全部数据'));
    for (final phrase in ['清空', ' 清空全部数据', '清空全部数据 ']) {
      await tester.enterText(find.byKey(const Key('清空确认输入框')), phrase);
      await tester.pump();
      expect(tester.widget<FilledButton>(confirmation).onPressed, isNull);
    }
    // Even an exact phrase only enables the final action; cancel still wins.
    await tester.enterText(find.byKey(const Key('清空确认输入框')), '清空全部数据');
    await tester.pump();
    expect(tester.widget<FilledButton>(confirmation).onPressed, isNotNull);
    expect(await databaseFacts(), before);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await databaseFacts(), before);
    expect(await tester.runAsync(exported.file.readAsBytes), exportedBytes);

    await tapPrivacyAction(tester, Key('设置删除简历_${deleted.id}'));
    await tester.tap(find.byKey(const Key('确认设置删除简历')));
    await tester.pumpAndSettle();
    expect(await repository.findDocument(deleted.id), isNull);
    expect(await repository.listVersions(deleted.id), isEmpty);
    expect(
      (await repository.listVersions(
        retained.id,
      )).map((version) => version.toJson()).toList(),
      retainedVersions,
    );
    expect(await tester.runAsync(exported.file.readAsBytes), exportedBytes);

    await tapPrivacyAction(tester, const Key('清空全部本地数据'));
    await tester.enterText(find.byKey(const Key('清空确认输入框')), '清空全部数据');
    await tester.pump();
    await tester.tap(find.byKey(const Key('确认清空全部数据')));
    await tester.pumpAndSettle();
    final after = await DriftLocalDataRepository(database).readSnapshot();
    expect(after.resumes, isEmpty);
    expect(after.settings, isEmpty);
    expect(after.agentAudits, isEmpty);
    expect(await tester.runAsync(exported.file.readAsBytes), exportedBytes);
    expect(tester.takeException(), isNull);
  });

  testApp('G3 清空失败保留历史建议兼容票据与编辑状态，不恢复已删除的产品入口', (tester) async {
    await pumpApp(tester);
    await createDocument(tester, 'G3 清空失败合成简历');
    await tester.enterText(find.byKey(const Key('意向职业岗位输入框')), 'Flutter  工程师');
    await tester.ensureVisible(find.byKey(const Key('保存新版本')));
    await tester.tap(find.byKey(const Key('保存新版本')));
    await tester.pumpAndSettle();
    final controller = tester
        .widget<ResumeHomePage>(find.byType(ResumeHomePage))
        .controller;
    final preparation = await controller.prepareLocalSuggestion();
    await tester.pumpAndSettle();
    expect(preparation!.status, LocalSuggestionPreparationStatus.ready);
    final pending = controller.pendingResumeSuggestion!;
    final documentBefore = controller.currentDocument!.toJson();
    final versionBefore = controller.currentVersion!.toJson();
    final before = await databaseFacts();
    // Fail inside the real DELETE transaction, after earlier table deletions.
    // The rollback must cover the audit rows and preserve its in-memory ticket.
    await database.customStatement(
      'CREATE TRIGGER g3_reject_clear BEFORE DELETE ON resume_documents '
      "BEGIN SELECT RAISE(ABORT, 'synthetic clear failure'); END",
    );
    await openPrivacy(tester);
    await tapPrivacyAction(tester, const Key('清空全部本地数据'));
    await tester.enterText(find.byKey(const Key('清空确认输入框')), '清空全部数据');
    await tester.pump();
    await tester.tap(find.byKey(const Key('确认清空全部数据')));
    await tester.pumpAndSettle();
    expect(find.textContaining('清空失败，本地数据保持不变'), findsOneWidget);
    expect(controller.isBusy, isFalse);
    expect(controller.pendingResumeSuggestion, same(pending));
    expect(controller.currentDocument!.toJson(), documentBefore);
    expect(controller.currentVersion!.toJson(), versionBefore);
    expect(await databaseFacts(), before);

    await database.customStatement('DROP TRIGGER g3_reject_clear');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('意向职业岗位输入框')))
          .controller!
          .text,
      'Flutter  工程师',
    );
    expect(find.byKey(const Key('继续审阅本地建议')), findsNothing);
    expect(find.byKey(const Key('生成本地建议')), findsNothing);
    expect(controller.pendingResumeSuggestion, same(pending));
    await controller.decidePendingSuggestion(LocalSuggestionDecision.accept);
    await tester.pumpAndSettle();
    expect(controller.pendingResumeSuggestion, isNull);
    expect(controller.currentVersion!.content.profile.headline, 'Flutter 工程师');
    expect(
      await DriftResumeRepository(
        database,
      ).listVersions(controller.currentDocument!.id),
      hasLength(3),
    );
    expect(tester.takeException(), isNull);
  });
}
