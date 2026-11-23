import 'dart:io';

import 'package:entitlements/entitlements.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_all_in_one_client/src/account_lifecycle_dialog.dart';
import 'package:resume_all_in_one_client/src/app.dart';
import 'package:resume_all_in_one_client/src/gateway_api_client.dart';
import 'package:resume_all_in_one_client/src/legal_consent_controller.dart';
import 'package:resume_all_in_one_client/src/legal_consent_pages.dart';
import 'package:resume_all_in_one_client/src/legal_consent_repository.dart';
import 'package:resume_all_in_one_client/src/legal_documents.dart';
import 'package:resume_all_in_one_client/src/legal_gateway_transport.dart';
import 'package:resume_all_in_one_client/src/local_agent_composition.dart';
import 'package:resume_all_in_one_client/src/local_data_management_service.dart';
import 'package:resume_all_in_one_client/src/resume_file_exporter.dart';
import 'package:resume_all_in_one_client/src/resume_home_page.dart';
import 'package:resume_all_in_one_client/src/resume_import_file_picker.dart';

import 'support/local_suggestion_fixture.dart';
import 'support/legal_consent_fixture.dart';

void main() {
  late LocalStorageDatabase database;
  late Directory directory;
  late FileLegalConsentRepository consentRepository;

  setUp(() async {
    database = LocalStorageDatabase.inMemory();
    directory = await Directory.systemTemp.createTemp('legal-app-integration-');
    consentRepository = FileLegalConsentRepository(
      rootDirectory: () async => directory,
    );
  });

  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  LegalConsentController newLegalController({LegalBundle? bundle}) =>
      LegalConsentController(
        repository: consentRepository,
        loadBundle: bundle == null ? null : () async => bundle,
        clock: () => DateTime.utc(2026, 10, 21, 8),
      );

  Future<void> pumpApp(
    WidgetTester tester,
    LegalConsentController legal, {
    GatewayApi? gateway,
  }) async {
    final repository = DriftResumeRepository(database);
    await _settleFileOperations(
      tester,
      legal,
      () => tester.pumpWidget(
        ResumeAllInOneApp(
          legalConsentController: legal,
          repository: repository,
          settingsRepository: DriftAppSettingsRepository(database),
          localAgentCheckService: createOfflineLocalAgentCheckService(
            resumeRepository: repository,
            auditRepository: DriftAgentAuditRepository(database),
          ),
          localResumeSuggestionService:
              createOfflineLocalResumeSuggestionService(
                resumeRepository: repository,
                auditRepository: DriftAgentAuditRepository(database),
              ),
          localDataManagementService: LocalDataManagementService(
            repository: DriftLocalDataRepository(database),
            rootDirectory: () async => directory,
          ),
          accessPolicy: CapabilityAccessPolicy.mvp(),
          fileExporter: ResumeFileExporter(
            rootDirectory: () async => directory,
          ),
          importFilePicker: const SystemResumeImportFilePicker(),
          gatewayApi: gateway,
          // App disposal must not close the shared database between launches.
        ),
      ),
    );
  }

  Future<void> localChoice(
    WidgetTester tester,
    LegalConsentController legal, {
    required bool suppressReminder,
  }) async {
    if (suppressReminder) {
      await _reveal(tester, find.byKey(const Key('不再提醒当前版本')));
      await tester.tap(find.byKey(const Key('不再提醒当前版本')));
      await tester.pump();
    }
    await _reveal(tester, find.byKey(const Key('仅使用本地功能')));
    await _settleFileOperations(
      tester,
      legal,
      () => tester.tap(find.byKey(const Key('仅使用本地功能'))),
    );
    expect(find.byType(ResumeHomePage), findsOneWidget);
  }

  Future<void> createAndSaveLocalResume(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('新建简历')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('新建标题输入框')), '协议升级保留的简历');
    await tester.enterText(find.byKey(const Key('新建姓名输入框')), '合成测试用户');
    await tester.tap(find.byKey(const Key('确认新建简历')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('意向职业岗位输入框')), '本地工程师');
    final save = find.byKey(const Key('保存新版本'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final repository = DriftResumeRepository(database);
    final document = (await repository.listDocuments()).single;
    expect(document.title, '协议升级保留的简历');
    expect(await repository.listVersions(document.id), hasLength(2));
    expect(
      (await repository.findCurrentVersion(
        document.id,
      ))!.content.profile.headline,
      '本地工程师',
    );
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  testWidgets('首次主动同意后默认联网，重启保留同意且不再弹窗', (tester) async {
    try {
      final bundle = publishedLegalBundleFixture();
      final legal = newLegalController(bundle: bundle);
      await pumpApp(tester, legal);
      for (final id in ['terms', 'privacy']) {
        await _reveal(
          tester,
          find
              .descendant(
                of: find.byKey(Key('阅读$id')),
                matching: find.byType(ListTile),
              )
              .first,
        );
        await tester.tap(
          find
              .descendant(
                of: find.byKey(Key('阅读$id')),
                matching: find.byType(ListTile),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await _reveal(
          tester,
          find
              .descendant(
                of: find.byKey(Key('阅读$id')),
                matching: find.byType(ListTile),
              )
              .first,
        );
        await tester.tap(
          find
              .descendant(
                of: find.byKey(Key('阅读$id')),
                matching: find.byType(ListTile),
              )
              .first,
        );
        await tester.pumpAndSettle();
      }
      for (final key in ['同意用户协议', '同意隐私政策', '确认已满18周岁']) {
        await _reveal(tester, find.byKey(Key(key)));
        await tester.tap(find.byKey(Key(key)));
        await tester.pump();
      }
      await _reveal(tester, find.byKey(const Key('同意并继续')));
      await _settleFileOperations(
        tester,
        legal,
        () => tester.tap(find.byKey(const Key('同意并继续'))),
      );
      expect(legal.canUseRemoteServices, isTrue);
      expect(
        await tester.runAsync(
          () => DriftAppSettingsRepository(database).getNetworkEnabled(),
        ),
        isTrue,
      );
      expect(find.byKey(const Key('首次使用协议弹窗')), findsNothing);
      await unmount(tester);
      await pumpApp(tester, newLegalController(bundle: bundle));
      expect(find.byKey(const Key('首次使用协议弹窗')), findsNothing);
      expect(find.byType(ResumeHomePage), findsOneWidget);
    } finally {
      await unmount(tester);
    }
  });

  testWidgets('不再提醒后主动开启联网仍弹协议，取消后保持本地且零HTTP', (tester) async {
    try {
      final legal = newLegalController();
      final transport = _CountingTransport();
      final gateway = GatewayApiClient(
        baseUri: Uri.parse('https://synthetic.invalid/'),
        transport: LegalGatewayHttpTransport(
          transport: transport,
          legalConsent: legal,
        ),
      );
      await pumpApp(tester, legal, gateway: gateway);
      await localChoice(tester, legal, suppressReminder: true);
      await tester.tap(find.byKey(const Key('隐私设置')));
      await tester.pumpAndSettle();
      await _reveal(tester, find.byKey(const Key('允许联网开关')));
      await tester.tap(find.byKey(const Key('允许联网开关')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('首次使用协议弹窗')), findsOneWidget);
      expect(legal.canUseRemoteServices, isFalse);
      expect(transport.requests, 0);
      await _reveal(tester, find.byKey(const Key('仅使用本地功能')));
      await _settleFileOperations(
        tester,
        legal,
        () => tester.tap(find.byKey(const Key('仅使用本地功能'))),
      );
      expect(find.byKey(const Key('首次使用协议弹窗')), findsNothing);
      expect(
        tester.widget<SwitchListTile>(find.byKey(const Key('允许联网开关'))).value,
        isFalse,
      );
      // The saved preference can remain true; effective permission is closed.
      expect(legal.canSendNetworkRequest, isFalse);
      expect(transport.requests, 0);
    } finally {
      await unmount(tester);
    }
  });

  testWidgets('先拒绝后主动开启联网，补充有效同意后启用且不自动发HTTP', (tester) async {
    try {
      final legal = newLegalController(bundle: publishedLegalBundleFixture());
      final transport = _CountingTransport();
      final gateway = GatewayApiClient(
        baseUri: Uri.parse('https://synthetic.invalid/'),
        transport: LegalGatewayHttpTransport(
          transport: transport,
          legalConsent: legal,
        ),
      );
      await pumpApp(tester, legal, gateway: gateway);
      await localChoice(tester, legal, suppressReminder: true);
      await tester.tap(find.byKey(const Key('隐私设置')));
      await tester.pumpAndSettle();
      await _reveal(tester, find.byKey(const Key('允许联网开关')));
      await tester.tap(find.byKey(const Key('允许联网开关')));
      await tester.pumpAndSettle();
      for (final id in ['terms', 'privacy']) {
        final header = find
            .descendant(
              of: find.byKey(Key('阅读$id')),
              matching: find.byType(ListTile),
            )
            .first;
        await _reveal(tester, header);
        await tester.tap(header);
        await tester.pumpAndSettle();
        await _reveal(tester, header);
        await tester.tap(header);
        await tester.pumpAndSettle();
      }
      for (final key in ['同意用户协议', '同意隐私政策', '确认已满18周岁']) {
        await _reveal(tester, find.byKey(Key(key)));
        await tester.tap(find.byKey(Key(key)));
        await tester.pump();
      }
      await _reveal(tester, find.byKey(const Key('同意并继续')));
      await _settleFileOperations(
        tester,
        legal,
        () => tester.tap(find.byKey(const Key('同意并继续'))),
      );
      expect(find.byKey(const Key('首次使用协议弹窗')), findsNothing);
      expect(legal.canUseRemoteServices, isTrue);
      expect(legal.records, hasLength(2));
      expect(legal.records.last.action, LegalConsentAction.accepted);
      expect(
        await tester.runAsync(
          () => DriftAppSettingsRepository(database).getNetworkEnabled(),
        ),
        isTrue,
      );
      expect(transport.requests, 0);
    } finally {
      await unmount(tester);
    }
  });

  testWidgets('未登录且未同意联网时仍能准备投诉邮件，不发HTTP也不夹带凭据', (tester) async {
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    try {
      final legal = newLegalController();
      final transport = _CountingTransport();
      final gateway = GatewayApiClient(
        baseUri: Uri.parse('https://synthetic.invalid/'),
        transport: LegalGatewayHttpTransport(
          transport: transport,
          legalConsent: legal,
        ),
      );
      await pumpApp(tester, legal, gateway: gateway);
      await localChoice(tester, legal, suppressReminder: true);
      await tester.tap(find.byKey(const Key('隐私设置')));
      await tester.pumpAndSettle();
      await _reveal(tester, find.byKey(const Key('设置个人信息请求')));
      await tester.tap(find.byKey(const Key('设置个人信息请求')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('权利请求当前密码')), findsNothing);
      await _reveal(tester, find.byKey(const Key('个人信息请求说明')));
      await tester.enterText(find.byKey(const Key('个人信息请求说明')), '合成投诉内容');
      await _reveal(tester, find.byKey(const Key('复制个人信息请求邮件')));
      await tester.tap(find.byKey(const Key('复制个人信息请求邮件')));
      await tester.pumpAndSettle();
      expect(clipboard, contains('support@example.com'));
      expect(clipboard, contains('合成投诉内容'));
      expect(clipboard, contains('必要人工核验'));
      expect(clipboard, isNot(contains('rights-v1.')));
      expect(transport.requests, 0);
      expect(legal.canSendNetworkRequest, isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      await unmount(tester);
    }
  });

  testWidgets('真实定稿文件记录跨启动不再提醒，同标签正文更新重新提示且保留简历', (tester) async {
    try {
      final first = newLegalController();
      await pumpApp(tester, first);
      expect(find.byType(LegalConsentIntroduction), findsOneWidget);
      expect(first.bundle!.status, 'final');
      expect(first.bundle!.pendingFields, isEmpty);
      final originalHash = first.bundle!.contentHash;
      final originalBundle = first.bundle!.toJson();
      await localChoice(tester, first, suppressReminder: true);
      await createAndSaveLocalResume(tester);
      final originalDocuments = await DriftResumeRepository(
        database,
      ).listDocuments();
      final originalDocumentId = originalDocuments.single.id;
      await unmount(tester);

      final second = newLegalController();
      await pumpApp(tester, second);
      expect(find.byType(LegalConsentIntroduction), findsNothing);
      expect(find.byType(ResumeHomePage), findsOneWidget);
      expect(second.bundle!.contentHash, originalHash);
      expect(second.records.single.suppressReminder, isTrue);
      expect(second.canUseRemoteServices, isFalse);
      expect(find.text('协议升级保留的简历'), findsWidgets);
      expect(
        (await DriftResumeRepository(database).listDocuments()).single.id,
        originalDocumentId,
      );
      await unmount(tester);

      // Keep both visible 1.10 version labels. The actual text, not the label,
      // must invalidate the earlier reminder suppression.
      final documents = originalBundle['documents'] as List;
      for (final document in documents.cast<Map<String, dynamic>>()) {
        expect(document['version'], '1.10');
      }
      final firstSection =
          (documents.first as Map<String, dynamic>)['sections'] as List;
      final paragraphs =
          (firstSection.first as Map<String, dynamic>)['paragraphs'] as List;
      paragraphs[0] = '${paragraphs[0]} 合成测试：正文发生变更，需重新提示。';
      final updatedBundle = LegalBundle.fromJson(originalBundle);
      final third = newLegalController(bundle: updatedBundle);
      await pumpApp(tester, third);
      expect(third.bundle!.contentHash, isNot(originalHash));
      expect(find.byType(LegalConsentIntroduction), findsOneWidget);
      expect(third.canUseRemoteServices, isFalse);
      await localChoice(tester, third, suppressReminder: false);
      expect(find.text('协议升级保留的简历'), findsWidgets);
      final repository = DriftResumeRepository(database);
      expect((await repository.listDocuments()).single.id, originalDocumentId);
      expect(await repository.listVersions(originalDocumentId), hasLength(2));
      expect(
        (await repository.findCurrentVersion(
          originalDocumentId,
        ))!.content.profile.headline,
        '本地工程师',
      );
      final persisted = await tester.runAsync(consentRepository.load);
      expect(persisted, hasLength(2));
      expect(persisted!.first.record.bundleHash, originalHash);
      expect(persisted.last.record.bundleHash, updatedBundle.contentHash);
      expect(tester.takeException(), isNull);
    } finally {
      await unmount(tester);
    }
  });

  testWidgets('旧联网偏好不等于同意，定稿阅读与本地入口均不发送HTTP', (tester) async {
    try {
      final settings = DriftAppSettingsRepository(database);
      await settings.setNetworkEnabled(true);
      final legal = newLegalController();
      final transport = _CountingTransport();
      final gateway = GatewayApiClient(
        baseUri: Uri.parse('https://synthetic.invalid/'),
        transport: LegalGatewayHttpTransport(
          transport: transport,
          legalConsent: legal,
        ),
      );
      await pumpApp(tester, legal, gateway: gateway);
      expect(await settings.getNetworkEnabled(), isTrue);
      expect(legal.records, isEmpty);
      expect(legal.canUseRemoteServices, isFalse);
      expect(transport.requests, 0);

      for (final id in ['terms', 'privacy']) {
        await _reveal(
          tester,
          find
              .descendant(
                of: find.byKey(Key('阅读$id')),
                matching: find.byType(ListTile),
              )
              .first,
        );
        await tester.tap(
          find
              .descendant(
                of: find.byKey(Key('阅读$id')),
                matching: find.byType(ListTile),
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(legal.bundle!.isComplete, isTrue);
        expect(legal.canAcceptCurrentBundle, isTrue);
        expect(find.textContaining('待补充草案'), findsNothing);
        await _reveal(
          tester,
          find
              .descendant(
                of: find.byKey(Key('阅读$id')),
                matching: find.byType(ListTile),
              )
              .first,
        );
        await tester.tap(
          find
              .descendant(
                of: find.byKey(Key('阅读$id')),
                matching: find.byType(ListTile),
              )
              .first,
        );
        await tester.pumpAndSettle();
      }
      expect(legal.records, isEmpty);
      expect(transport.requests, 0);
      await localChoice(tester, legal, suppressReminder: true);
      await createAndSaveLocalResume(tester);
      expect(transport.requests, 0);

      await tester.tap(find.byKey(const Key('隐私设置')));
      await tester.pumpAndSettle();
      final account = find.byKey(const Key('开发账号'));
      await tester.ensureVisible(account);
      await tester.tap(account);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('首次使用协议弹窗')), findsOneWidget);
      expect(find.byType(AccountLifecycleDialog), findsNothing);
      expect(find.byKey(const Key('登录开发账号')), findsNothing);
      expect(find.byKey(const Key('注册开发账号')), findsNothing);
      expect(legal.canUseRemoteServices, isFalse);
      expect(transport.requests, 0);

      await _reveal(tester, find.byKey(const Key('同意并继续')));
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('同意并继续'))).onPressed,
        isNull,
      );
      expect(transport.requests, 0);
      expect(await settings.getNetworkEnabled(), isTrue);
      expect(
        (await DriftResumeRepository(database).listDocuments()),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    } finally {
      await unmount(tester);
    }
  });
}

/// Start the widget action in the real async zone, so its unawaited file I/O
/// does not capture fake microtasks that real-time polling cannot advance.
Future<void> _settleFileOperations(
  WidgetTester tester,
  LegalConsentController controller,
  Future<void> Function() start,
) async {
  await tester.runAsync(() async {
    await start();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (controller.isLoading || controller.isSaving) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('合成本机协议存储在限定时间内未完成');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  final prompt = find.byType(LegalConsentIntroduction);
  final scrollable = prompt.evaluate().isNotEmpty
      ? find.descendant(of: prompt, matching: find.byType(Scrollable)).first
      : find.byType(Scrollable).first;
  if (finder.evaluate().isEmpty) {
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(
      finder,
      180,
      scrollable: scrollable,
      maxScrolls: 100,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

final class _CountingTransport implements GatewayHttpTransport {
  int requests = 0;

  @override
  Future<GatewayHttpResponse> sendJson({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    Map<String, Object?>? jsonBody,
  }) async {
    requests++;
    throw StateError('未同意协议的集成测试禁止发出HTTP');
  }

  @override
  void close() {}
}
