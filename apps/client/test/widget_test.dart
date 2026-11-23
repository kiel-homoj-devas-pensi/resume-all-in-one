import 'dart:convert';
import 'dart:io';

import 'package:entitlements/entitlements.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_all_in_one_client/main.dart';
import 'package:resume_all_in_one_client/src/gateway_api_client.dart';
import 'package:resume_all_in_one_client/src/local_agent_composition.dart';
import 'support/local_suggestion_fixture.dart';
import 'support/legal_consent_fixture.dart';
import 'package:resume_all_in_one_client/src/local_data_management_service.dart';
import 'package:resume_all_in_one_client/src/resume_home_page.dart';
import 'package:resume_all_in_one_client/src/resume_file_exporter.dart';
import 'package:resume_all_in_one_client/src/resume_import_file_picker.dart';
import 'package:resume_domain/resume_domain.dart';

void main() {
  late LocalStorageDatabase database;
  late Directory exportRoot;
  late _FakeResumeImportFilePicker importFilePicker;

  setUp(() async {
    database = LocalStorageDatabase.inMemory();
    // 既有离线验收明确模拟用户已关闭联网，新安装另有场景验证。
    await DriftAppSettingsRepository(database).setNetworkEnabled(false);
    exportRoot = await Directory.systemTemp.createTemp('resume-client-test-');
    importFilePicker = _FakeResumeImportFilePicker();
  });

  tearDown(() async {
    await database.close();
    await exportRoot.delete(recursive: true);
  });

  void testApp(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        // Drift 设置监听取消后会异步清理缓存，在测试约束检查前排空。
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    });
  }

  Future<void> pumpApp(WidgetTester tester, {GatewayApi? gatewayApi}) async {
    final resumeRepository = DriftResumeRepository(database);
    await tester.pumpWidget(
      ResumeAllInOneApp(
        legalConsentController: await acceptedLegalConsentFixture(),
        repository: resumeRepository,
        settingsRepository: DriftAppSettingsRepository(database),
        localAgentCheckService: createOfflineLocalAgentCheckService(
          resumeRepository: resumeRepository,
          auditRepository: DriftAgentAuditRepository(database),
        ),
        localResumeSuggestionService: createOfflineLocalResumeSuggestionService(
          resumeRepository: resumeRepository,
          auditRepository: DriftAgentAuditRepository(database),
        ),
        localDataManagementService: LocalDataManagementService(
          repository: DriftLocalDataRepository(database),
          rootDirectory: () async => exportRoot,
        ),
        accessPolicy: CapabilityAccessPolicy.mvp(),
        fileExporter: ResumeFileExporter(rootDirectory: () async => exportRoot),
        importFilePicker: importFilePicker,
        gatewayApi: gatewayApi,
      ),
    );
    await tester.pumpAndSettle();
  }

  testApp('隐私窗口真实入口可查云政策，关闭联网时保持访客数据', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('隐私设置')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('查询云同步政策')),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('查询云同步政策')));
    await tester.pumpAndSettle();
    expect(find.text('云同步政策'), findsOneWidget);
    expect(find.textContaining('联网已关闭'), findsOneWidget);
    expect(await DriftResumeRepository(database).listDocuments(), isEmpty);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsWidgets);
  });

  testApp('选填岗位与证件照确认、保存、移除及旧版本保留', (tester) async {
    const photoChannel = MethodChannel('resume_all_in_one/photo_import');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final photoBytes = File(
      '../../packages/resume_domain/test/fixtures/photo.jpg',
    ).readAsBytesSync();
    messenger.setMockMethodCallHandler(
      photoChannel,
      (_) async => {
        'bytes': photoBytes,
        'mimeType': 'image/jpeg',
        'width': 500,
        'height': 700,
      },
    );
    addTearDown(() => messenger.setMockMethodCallHandler(photoChannel, null));
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('新建简历')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('新建标题输入框')), '只用于管理的标题');
    await tester.enterText(find.byKey(const Key('新建姓名输入框')), '合成照片用户');
    await tester.tap(find.byKey(const Key('确认新建简历')));
    await tester.pumpAndSettle();
    expect(find.text('意向职业岗位（选填）'), findsOneWidget);
    expect(find.text('简历标题仅用于区分不同简历，不会显示在导出的简历中。'), findsOneWidget);
    final repository = DriftResumeRepository(database);
    final document = (await repository.listDocuments()).single;
    final first = (await repository.findCurrentVersion(document.id))!;
    expect(first.content.profile.headline, isEmpty);
    expect(first.content.profile.photo, isNull);
    Future<void> choose() async {
      await tester.ensureVisible(find.byKey(const Key('选择证件照')));
      await tester.tap(find.byKey(const Key('选择证件照')));
      await tester.pumpAndSettle();
    }

    await choose();
    expect(find.text('确认照片'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('已选证件照')), findsNothing);
    expect(await repository.listVersions(document.id), hasLength(1));
    await choose();
    await tester.tap(find.byKey(const Key('确认使用证件照')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('已选证件照')), findsOneWidget);
    expect(
      (await repository.findCurrentVersion(document.id))!.content.profile.photo,
      isNull,
    );
    await tester.tap(find.byKey(const Key('保存新版本')));
    await tester.pumpAndSettle();
    final withPhoto = (await repository.findCurrentVersion(document.id))!;
    expect(withPhoto.content.profile.photo!.bytes, photoBytes);
    expect(withPhoto.content.profile.headline, isEmpty);
    expect(await repository.listVersions(document.id), hasLength(2));
    await tester.ensureVisible(find.byKey(const Key('移除证件照')));
    await tester.tap(find.byKey(const Key('移除证件照')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('保存新版本')));
    await tester.pumpAndSettle();
    expect(
      (await repository.findCurrentVersion(document.id))!.content.profile.photo,
      isNull,
    );
    expect(
      (await repository.listVersions(
        document.id,
      )).firstWhere((v) => v.id == withPhoto.id).content.profile.photo!.bytes,
      photoBytes,
    );
  });

  testApp('照片读取失败不写入简历或改变已有版本', (tester) async {
    const channel = MethodChannel('resume_all_in_one/photo_import');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'photo_too_large'),
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('新建简历')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('新建标题输入框')), '照片失败用例');
    await tester.tap(find.byKey(const Key('确认新建简历')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('选择证件照')));
    await tester.tap(find.byKey(const Key('选择证件照')));
    await tester.pumpAndSettle();
    expect(find.textContaining('请选择不超过 10MB'), findsOneWidget);
    expect(find.byKey(const Key('已选证件照')), findsNothing);
    final repository = DriftResumeRepository(database);
    final document = (await repository.listDocuments()).single;
    expect(await repository.listVersions(document.id), hasLength(1));
  });

  testApp('设置真实入口可离线查看字体许可，返回时保留本地简历', (tester) async {
    registerBundledFontLicense();
    await pumpApp(tester);
    final repository = DriftResumeRepository(database);
    await tester.tap(find.byKey(const Key('新建简历')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('新建标题输入框')), '许可查看合成简历');
    await tester.tap(find.byKey(const Key('确认新建简历')));
    await tester.pumpAndSettle();
    final document = (await repository.listDocuments()).single;
    final before = await repository.listVersions(document.id);
    await tester.tap(find.byKey(const Key('返回简历列表')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('导航_设置')));
    await tester.pumpAndSettle();
    final entry = find.byKey(const Key('第三方许可'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
    expect(find.text('Noto Sans SC'), findsOneWidget);
    await tester.tap(find.text('Noto Sans SC'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2014-2021 Adobe'), findsWidgets);
    await tester.scrollUntilVisible(
      find.textContaining('PERMISSION & CONDITIONS'),
      180,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('PERMISSION & CONDITIONS'), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('第三方许可')), findsOneWidget);
    expect(
      await repository.listVersions(document.id),
      hasLength(before.length),
    );
    expect((await repository.findDocument(document.id))!.title, document.title);
    expect(
      await DriftAppSettingsRepository(database).getNetworkEnabled(),
      isFalse,
    );
  });

  testApp('已有用户关闭联网时保持离线功能及开启确认', (tester) async {
    await pumpApp(tester);

    expect(find.text('还没有简历'), findsOneWidget);
    expect(find.textContaining('编辑、检查和 Word 转 PDF 均可离线使用'), findsOneWidget);

    await tester.tap(find.byKey(const Key('隐私设置')));
    await tester.pumpAndSettle();
    final setting = tester.widget<SwitchListTile>(
      find.byKey(const Key('允许联网开关')),
    );
    expect(setting.value, isFalse);
    expect(find.textContaining('控制账号、联网 AI 和云政策查询'), findsOneWidget);
    expect(find.text('本地简历检查'), findsOneWidget);
    expect(find.text('本地规则建议'), findsOneWidget);
    expect(find.text('当前条件允许使用这项能力'), findsNWidgets(2));
    expect(find.text('这项能力需要联网，但联网当前已关闭'), findsNWidgets(2));

    await tester.ensureVisible(find.byKey(const Key('允许联网开关')));
    await tester.tap(find.byKey(const Key('允许联网开关')));
    await tester.pumpAndSettle();
    expect(find.text('允许联网？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byKey(const Key('允许联网开关'))).value,
      isFalse,
    );

    await tester.ensureVisible(find.byKey(const Key('允许联网开关')));
    await tester.tap(find.byKey(const Key('允许联网开关')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('确认允许联网')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byKey(const Key('允许联网开关'))).value,
      isTrue,
    );
    expect(find.text('当前没有这项能力的 entitlement'), findsNWidgets(2));
  });

  testApp('新安装无需打开总开关且未配置服务与未登录分别说明', (tester) async {
    await database.close();
    database = LocalStorageDatabase.inMemory();
    await pumpApp(tester);
    expect(
      await DriftAppSettingsRepository(database).getNetworkEnabled(),
      isTrue,
    );
    await tester.tap(find.byKey(const Key('隐私设置')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('开发账号')));
    await tester.tap(find.byKey(const Key('开发账号')));
    await tester.pumpAndSettle();
    expect(find.textContaining('未配置'), findsWidgets);
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();
    final gateway = _WidgetGatewayApi();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await pumpApp(tester, gatewayApi: gateway);
    await tester.tap(find.byKey(const Key('隐私设置')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('开发账号')));
    await tester.tap(find.byKey(const Key('开发账号')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('登录开发账号')), findsOneWidget);
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('隐私设置')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byKey(const Key('允许联网开关'))).value,
      isTrue,
    );
    expect(
      await DriftAppSettingsRepository(
        database,
      ).getRemotePersonalDataWarningAcknowledged(),
      isFalse,
    );
    expect(gateway._completedBasicGenerations, 0);
  });

  testApp('兼容账号手机号下一项自动定位密码，键盘高度变化后输入仍可核对', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await pumpApp(tester, gatewayApi: _WidgetGatewayApi());
    await tester.tap(find.byKey(const Key('隐私设置')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('开发账号')));
    await tester.tap(find.byKey(const Key('开发账号')));
    await tester.pumpAndSettle();
    tester
        .widget<EditableText>(
          find.descendant(
            of: find.byKey(const Key('开发账号手机号')),
            matching: find.byType(EditableText),
          ),
        )
        .focusNode
        .requestFocus();
    tester.view.viewInsets = const FakeViewPadding(bottom: 200);
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();
    final passwordFinder = find.byKey(const Key('开发账号密码'));
    void expectPasswordVisible(double inset) {
      final password = tester.widget<TextField>(passwordFinder);
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: passwordFinder,
                matching: find.byType(EditableText),
              ),
            )
            .focusNode
            .hasFocus,
        isTrue,
      );
      expect(password.obscureText, isTrue);
      final decorator = find.descendant(
        of: passwordFinder,
        matching: find.byType(InputDecorator),
      );
      final box = tester.renderObject<RenderBox>(decorator);
      final viewport = RenderAbstractViewport.of(box) as RenderBox;
      final visible = (viewport.localToGlobal(Offset.zero) & viewport.size)
          .intersect(Rect.fromLTWH(0, 0, 320, 640 - inset));
      final rect = box.localToGlobal(Offset.zero) & box.size;
      expect(rect.top, greaterThanOrEqualTo(visible.top - 1));
      expect(rect.bottom, lessThanOrEqualTo(visible.bottom + 1));
      expect(
        find
            .descendant(of: passwordFinder, matching: find.byType(EditableText))
            .hitTestable(),
        findsOneWidget,
      );
    }

    expectPasswordVisible(200);
    await tester.enterText(passwordFinder, 'TestPass2026!');
    for (final inset in [200.0, 240.0, 0.0, 200.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pumpAndSettle();
      expectPasswordVisible(inset);
      expect(
        tester.widget<TextField>(passwordFinder).controller!.text,
        'TestPass2026!',
      );
    }
    expect(find.text('退出').hitTestable(), findsOneWidget);
    expect(find.text('完成'), findsNothing);
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('开发账号密码')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testApp('首次AI起草先选择身份，取消不收材料，完成登录后才打开表单', (tester) async {
    final settings = DriftAppSettingsRepository(database);
    await settings.setNetworkEnabled(true);
    await settings.setRemotePersonalDataWarningAcknowledged(true);
    final gateway = _WidgetGatewayApi();
    await pumpApp(tester, gatewayApi: gateway);
    await tester.ensureVisible(find.byKey(const Key('AI创建基础简历')));
    await tester.tap(find.byKey(const Key('AI创建基础简历')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('登录开发账号')), findsOneWidget);
    expect(find.byKey(const Key('AI碎片信息')), findsNothing);
    await tester.enterText(find.byKey(const Key('开发账号密码')), 'TestPass2026!');
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('AI碎片信息')), findsNothing);
    expect(gateway._completedBasicGenerations, 0);

    await tester.tap(find.byKey(const Key('AI创建基础简历')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('开发账号密码')))
          .controller!
          .text,
      isEmpty,
    );
    await tester.enterText(find.byKey(const Key('开发账号密码')), 'TestPass2026!');
    await tester.tap(find.byKey(const Key('登录开发账号')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ResumeHomePage>(find.byType(ResumeHomePage))
          .controller
          .remoteAccountSnapshot
          .isSignedIn,
      isTrue,
    );
    expect(find.byKey(const Key('AI碎片信息')), findsOneWidget);
    expect(gateway._completedBasicGenerations, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testApp('开发账号完成基础生成后必须审阅确认才创建版本', (tester) async {
    await pumpApp(tester, gatewayApi: _WidgetGatewayApi());

    await tester.tap(find.byKey(const Key('隐私设置')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('允许联网开关')));
    await tester.tap(find.byKey(const Key('允许联网开关')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('确认允许联网')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('隐私设置')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('开发账号')));
    await tester.tap(find.byKey(const Key('开发账号')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('开发账号密码')), 'TestPass2026!');
    await tester.tap(find.byKey(const Key('登录开发账号')));
    await tester.pumpAndSettle();
    expect(find.text('套餐：免费\n令牌仅保存在本次进程内'), findsOneWidget);
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('AI创建基础简历')));
    await tester.tap(find.byKey(const Key('AI创建基础简历')));
    await tester.pumpAndSettle();
    expect(find.text('联网 AI 隐私提醒'), findsOneWidget);
    await tester.tap(find.byKey(const Key('确认联网AI隐私提醒')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('AI碎片信息')), '负责 Flutter 客户端开发');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('AI创建基础简历')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('AI碎片信息')))
          .controller!
          .text,
      '负责 Flutter 客户端开发',
    );
    expect(
      tester
          .widget<CheckboxListTile>(find.byKey(const Key('允许整体发送个人信息')))
          .value,
      isFalse,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('简历标题输入框')));
    await tester.enterText(find.byKey(const Key('简历标题输入框')), 'AI 基础简历');
    await tester.ensureVisible(find.byKey(const Key('提交基础生成')));
    await tester.tap(find.byKey(const Key('提交基础生成')));
    await tester.pumpAndSettle();

    expect(find.text('审阅联网 AI 建议'), findsOneWidget);
    expect(await DriftResumeRepository(database).listDocuments(), isEmpty);
    await tester.tap(find.byKey(const Key('确认远程建议')));
    await tester.pumpAndSettle();

    final repository = DriftResumeRepository(database);
    final document = (await repository.listDocuments()).single;
    final version = await repository.findCurrentVersion(document.id);
    expect(version!.source, ResumeVersionSource.aiConfirmed);
    expect(find.text('AI 基础简历'), findsWidgets);
  });

  for (final action in ['退出账号', '清空本地数据']) {
    testApp('$action 后不恢复上一上下文的AI输入草稿', (tester) async {
      await pumpApp(tester, gatewayApi: _WidgetGatewayApi());
      await tester.pumpAndSettle();
      final controller = tester
          .widget<ResumeHomePage>(find.byType(ResumeHomePage))
          .controller;
      await controller.setNetworkEnabled(true);
      Future<void> openCompose() async {
        await tester.ensureVisible(find.byKey(const Key('AI创建基础简历')));
        await tester.tap(find.byKey(const Key('AI创建基础简历')));
        await tester.pumpAndSettle();
        if (find.byKey(const Key('确认联网AI隐私提醒')).evaluate().isNotEmpty) {
          await tester.tap(find.byKey(const Key('确认联网AI隐私提醒')));
          await tester.pumpAndSettle();
        }
        if (find.byKey(const Key('登录开发账号')).evaluate().isNotEmpty) {
          await tester.enterText(
            find.byKey(const Key('开发账号密码')),
            'TestPass2026!',
          );
          await tester.tap(find.byKey(const Key('登录开发账号')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('退出'));
          await tester.pumpAndSettle();
        }
      }

      await openCompose();
      await tester.enterText(find.byKey(const Key('AI碎片信息')), '不应恢复给下个账号的合成材料');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      if (action == '退出账号') {
        controller.signOutRemoteAccount();
      } else {
        expect(await controller.clearAllLocalData(), isNotNull);
        // Clearing device data also removes legal choices; a prior receipt
        // must not silently authorize the next account's network operations.
        final legal = controller.legalConsent!;
        expect(legal.records, isEmpty);
        expect(await controller.setNetworkEnabled(true), isFalse);
        legal.markDocumentOpened('terms');
        legal.markDocumentOpened('privacy');
        expect(
          await legal.accept(
            adultConfirmed: true,
            termsChecked: true,
            privacyChecked: true,
          ),
          isTrue,
        );
      }
      await tester.pumpAndSettle();
      await controller.setNetworkEnabled(true);
      await openCompose();
      expect(
        find.byKey(const Key('AI碎片信息')),
        findsOneWidget,
        reason: find
            .byType(Text)
            .evaluate()
            .map((e) => (e.widget as Text).data)
            .join('|'),
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('AI碎片信息')))
            .controller!
            .text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testApp('首次启动空状态保持关键视觉层级并满足基础无障碍规则', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semanticsHandle = tester.ensureSemantics();

    await pumpApp(tester);

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/task021_empty_light.png'),
    );
    expect(find.byTooltip('导入为新简历'), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byKey(const Key('隐私设置'))).tooltip,
      '设置',
    );
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    semanticsHandle.dispose();
  });

  testApp('隐私设置保持关键视觉层级且删除入口说明具体对象', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semanticsHandle = tester.ensureSemantics();

    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('新建简历')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('新建标题输入框')), '无障碍验收简历');
    await tester.tap(find.byKey(const Key('确认新建简历')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('隐私设置')));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(AlertDialog).first,
      matchesGoldenFile('goldens/task021_privacy_light.png'),
    );
    expect(find.byTooltip('删除简历：无障碍验收简历'), findsOneWidget);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    semanticsHandle.dispose();
  });

  testApp('窄屏放大文字时隐私设置仍可滚动到清空入口', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('隐私设置')));
    await tester.pumpAndSettle();
    final clearAllButton = find.byKey(const Key('清空全部本地数据'));
    await tester.ensureVisible(clearAllButton);
    await tester.pumpAndSettle();

    expect(clearAllButton, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testApp('设置页展示全量导出并在删除单份简历前要求确认', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('新建简历')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('新建标题输入框')), '待归档简历');
    await tester.tap(find.byKey(const Key('确认新建简历')));
    await tester.pumpAndSettle();

    final resumeRepository = DriftResumeRepository(database);
    final resumeDocument = (await resumeRepository.listDocuments()).single;
    await tester.tap(find.byKey(const Key('隐私设置')));
    await tester.pumpAndSettle();
    final exportButton = find.byKey(const Key('导出全部本地数据'));
    await tester.ensureVisible(exportButton);
    final exportAction = tester.widget<OutlinedButton>(exportButton).onPressed;
    expect(exportAction, isNotNull);
    expect(find.textContaining('全部简历历史、设置和脱敏 Agent 审计'), findsOneWidget);

    final deleteButton = find.byKey(Key('设置删除简历_${resumeDocument.id}'));
    await tester.ensureVisible(deleteButton);
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();
    expect(find.text('删除这份简历？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await resumeRepository.listDocuments(), hasLength(1));

    await tester.tap(deleteButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('确认设置删除简历')), findsOneWidget);
    expect(find.textContaining('全部历史版本将不可恢复'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await resumeRepository.listDocuments(), hasLength(1));
  });

  for (final format in ['JSON', 'Markdown', '本地档案']) {
    testApp('$format 的实际界面入口打开系统另存并保留简历', (tester) async {
      const channel = MethodChannel('resume_all_in_one/file_delivery');
      MethodCall? request;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            request = call;
            return 'cancelled';
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await pumpApp(tester);
      await tester.tap(find.byKey(const Key('新建简历')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('新建标题输入框')), '系统另存合成简历');
      await tester.tap(find.byKey(const Key('确认新建简历')));
      await tester.pumpAndSettle();
      final repository = DriftResumeRepository(database);
      final before = (await repository.listDocuments()).single;
      if (format == '本地档案') {
        await tester.tap(find.byKey(const Key('隐私设置')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('导出全部本地数据')));
      } else {
        await tester.ensureVisible(find.byKey(const Key('导出菜单')));
        await tester.tap(find.byKey(const Key('导出菜单')));
        await tester.pumpAndSettle();
      }
      await tester.tap(
        format == '本地档案'
            ? find.byKey(const Key('导出全部本地数据'))
            : find.text('导出 $format'),
      );
      await tester.pump(const Duration(milliseconds: 400));
      // 文件 I/O 用真实事件循环，菜单动画和反馈用测试时钟。
      for (var attempt = 0; request == null && attempt < 100; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(request, isNotNull, reason: '实际界面应提交系统文件交付');
      await tester.runAsync(() async {
        final call = request!;
        expect(call.method, 'saveAs');
        expect(
          call.arguments['mimeType'],
          format == 'Markdown' ? 'text/markdown' : 'application/json',
        );
        expect(
          await File(call.arguments['path'] as String).length(),
          greaterThan(0),
        );
      });
      await tester.pumpAndSettle();
      expect(
        (await repository.findDocument(before.id))!.toJson(),
        before.toJson(),
      );
      expect(await repository.listVersions(before.id), hasLength(1));
      expect(find.textContaining('已取消另存'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testApp('清空全部本地数据前必须输入完整确认短语', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('新建简历')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('新建标题输入框')), '待清空简历');
    await tester.tap(find.byKey(const Key('确认新建简历')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('隐私设置')));
    await tester.pumpAndSettle();
    final clearButton = find.byKey(const Key('清空全部本地数据'));
    await tester.ensureVisible(clearButton);
    await tester.tap(clearButton);
    await tester.pumpAndSettle();
    final confirmClearButton = find.byKey(const Key('确认清空全部数据'));
    expect(tester.widget<FilledButton>(confirmClearButton).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('清空确认输入框')), '清空');
    await tester.pump();
    expect(tester.widget<FilledButton>(confirmClearButton).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('清空确认输入框')), '清空全部数据');
    await tester.pump();
    expect(
      tester.widget<FilledButton>(confirmClearButton).onPressed,
      isNotNull,
    );
    expect(find.textContaining('已主动导出的文件会保留'), findsOneWidget);
  });

  testApp('联网关闭时本地检查已保存版本并展示只读摘要', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('新建简历')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('新建标题输入框')), '本地检查简历');
    await tester.enterText(find.byKey(const Key('新建姓名输入框')), '张三');
    await tester.tap(find.byKey(const Key('确认新建简历')));
    await tester.pumpAndSettle();

    final localCheckButton = find.byKey(const Key('本地检查已保存版本'));
    await tester.ensureVisible(localCheckButton);
    await tester.tap(localCheckButton);
    await tester.pumpAndSettle();

    expect(find.text('本地检查结果'), findsOneWidget);
    expect(find.text('检查完成'), findsOneWidget);
    expect(find.text('需要留意：1 项'), findsOneWidget);
    expect(find.textContaining('建议提供一种联系方式'), findsWidgets);
    expect(find.text('精确重复内容：0 组'), findsOneWidget);
    expect(find.textContaining('不会自动修改'), findsOneWidget);
    final auditRunCount = await database
        .customSelect('SELECT COUNT(*) AS count FROM agent_runs')
        .getSingle();
    final auditToolCount = await database
        .customSelect('SELECT COUNT(*) AS count FROM tool_calls')
        .getSingle();
    expect(auditRunCount.read<int>('count'), 1);
    expect(auditToolCount.read<int>('count'), 2);
  });

  testApp('已移除本地建议入口，本地检查保持可用且不追加版本', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('新建简历')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('新建标题输入框')), '本地检查简历');
    await tester.enterText(find.byKey(const Key('新建姓名输入框')), '张三');
    await tester.tap(find.byKey(const Key('确认新建简历')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('生成本地建议')), findsNothing);
    expect(find.byKey(const Key('继续审阅本地建议')), findsNothing);
    final repository = DriftResumeRepository(database);
    final document = (await repository.listDocuments()).single;
    final before = await repository.listVersions(document.id);
    final check = find.byKey(const Key('本地检查已保存版本'));
    await tester.ensureVisible(check);
    await tester.tap(check);
    await tester.pumpAndSettle();
    expect(find.text('本地检查结果'), findsOneWidget);
    expect(
      await repository.listVersions(document.id),
      hasLength(before.length),
    );
  });

  testApp('创建、验证与编辑均追加可靠版本', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('新建简历')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('新建标题输入框')), '移动端简历');
    await tester.enterText(find.byKey(const Key('新建姓名输入框')), '张三');
    await tester.tap(find.byKey(const Key('确认新建简历')));
    await tester.pumpAndSettle();

    expect(find.text('版本历史（1）'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('邮箱输入框')), 'invalid-email');
    await tester.ensureVisible(find.byKey(const Key('保存新版本')));
    await tester.tap(find.byKey(const Key('保存新版本')));
    await tester.pumpAndSettle();

    expect(find.textContaining('邮箱格式无效'), findsWidgets);
    expect(find.text('版本历史（1）'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('邮箱输入框')),
      'zhangsan@example.com',
    );
    await tester.enterText(find.byKey(const Key('意向职业岗位输入框')), 'Flutter 工程师');
    await tester.ensureVisible(find.byKey(const Key('保存新版本')));
    await tester.tap(find.byKey(const Key('保存新版本')));
    await tester.pumpAndSettle();

    expect(find.text('版本历史（2）'), findsOneWidget);
    expect(find.text('已保存为新版本。'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('导出菜单')));
    await tester.tap(find.byKey(const Key('导出菜单')));
    await tester.pumpAndSettle();
    expect(find.text('导出 Markdown'), findsOneWidget);
    expect(find.text('导出 JSON'), findsOneWidget);
    expect(find.text('预览并导出 PDF'), findsOneWidget);
  });

  testApp('表单保存只改已知字段，根与Profile未知字段和稳定ID原样保留', (tester) async {
    final originalContent = ResumeData(
      profile: ResumeProfile(
        id: 'profile-teaching',
        fullName: '合成学生',
        headline: '原职业',
        email: '',
        phone: '',
        location: '',
        extensions: const {
          'futureProfileField': {'source': 'fixture'},
        },
      ),
      unmapped: const {
        'legacyNote': {'text': '需要保留的原文'},
      },
      extensions: const {
        'futureRootField': [1, 2],
      },
    );
    final createdAt = DateTime.utc(2026, 10, 8);
    final originalVersion = ResumeVersion(
      id: 'version-teaching',
      documentId: 'document-teaching',
      parentVersionId: null,
      schemaVersion: originalContent.schemaVersion,
      content: originalContent,
      source: ResumeVersionSource.created,
      createdAt: createdAt,
    );
    final repository = DriftResumeRepository(database);
    await repository.createDocument(
      ResumeDocument(
        id: originalVersion.documentId,
        title: '字段保留练习',
        currentVersionId: originalVersion.id,
        createdAt: createdAt,
        updatedAt: createdAt,
      ),
      originalVersion,
    );
    await pumpApp(tester);
    final documentEntry = find.byKey(const Key('打开简历_document-teaching'));
    await tester.ensureVisible(documentEntry);
    await tester.pumpAndSettle();
    expect(documentEntry.hitTestable(), findsOneWidget);
    await tester.tap(documentEntry);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('意向职业岗位输入框')), '修改后的职业');
    await tester.tap(find.byKey(const Key('保存新版本')));
    await tester.pumpAndSettle();

    final expectedJson = originalContent.toJson();
    (expectedJson['profile']! as JsonMap)['headline'] = '修改后的职业';
    final savedVersion = (await repository.findCurrentVersion(
      originalVersion.documentId,
    ))!;
    expect(savedVersion.content.toJson(), expectedJson);
    expect(savedVersion.parentVersionId, originalVersion.id);
    expect(
      (await repository.findVersion(originalVersion.id))!.toJson(),
      originalVersion.toJson(),
    );
    expect(
      await repository.listVersions(originalVersion.documentId),
      hasLength(2),
    );
  });

  testApp('完整结构化区段与文档生命周期入口可用', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('新建简历')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('新建标题输入框')), '结构化简历');
    await tester.tap(find.byKey(const Key('确认新建简历')));
    await tester.pumpAndSettle();

    for (final section in [
      '个人链接',
      '工作经历',
      '教育经历',
      '项目经历',
      '技能分组',
      '证书',
      '语言',
      '自定义区段',
    ]) {
      expect(find.byKey(Key('展开区段_$section')), findsOneWidget);
    }
    expect(find.byKey(const Key('复制简历')), findsOneWidget);
    expect(find.byKey(const Key('删除简历')), findsOneWidget);
    expect(find.byKey(const Key('按目标岗位优化')), findsNothing);
    expect(find.byKey(const Key('继续AI优化对话')), findsNothing);
    expect(find.byKey(const Key('导入文本简历')), findsNothing);
    expect(find.byKey(const Key('开发账号')), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('保存新版本')));
    await tester.tap(find.byKey(const Key('保存新版本')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('复制简历')));
    await tester.tap(find.byKey(const Key('复制简历')));
    await tester.pumpAndSettle();
    expect(find.text('结构化简历（副本）'), findsWidgets);

    await tester.ensureVisible(find.byKey(const Key('删除简历')));
    await tester.tap(find.byKey(const Key('删除简历')));
    await tester.pumpAndSettle();
    expect(find.text('删除简历？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('删除简历')), findsOneWidget);
  });

  testApp('编辑页与AI任务分离且无历史时只能开始对话', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('新建简历')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('新建标题输入框')), 'AI任务合成简历');
    await tester.tap(find.byKey(const Key('确认新建简历')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('按目标岗位优化')), findsNothing);
    expect(find.byKey(const Key('开发账号')), findsNothing);
    expect(find.byKey(const Key('导入文本简历')), findsNothing);
    await tester.enterText(find.byKey(const Key('意向职业岗位输入框')), '未保存草稿');
    await tester.tap(find.byKey(const Key('返回简历列表')));
    await tester.pumpAndSettle();
    // Navigation must still protect a draft after moving AI out of the editor.
    expect(find.text('保存这次修改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('意向职业岗位输入框')))
          .controller!
          .text,
      '未保存草稿',
    );
    await tester.tap(find.byKey(const Key('保存新版本')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('返回简历列表')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('导航_助手')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('AI选择已有简历')));
    await tester.tap(find.byKey(const Key('AI选择已有简历')));
    await tester.pumpAndSettle();
    final document = (await DriftResumeRepository(
      database,
    ).listDocuments()).single;
    await tester.tap(find.byKey(ValueKey('AI选择简历_${document.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('按目标岗位优化')), findsOneWidget);
    expect(find.byKey(const Key('开始AI优化对话')), findsNothing);
    expect(find.byKey(const Key('继续AI优化对话')), findsNothing);
    expect(find.byKey(const Key('意向职业岗位输入框')), findsNothing);
    await tester.tap(find.byKey(const Key('AI返回手工编辑')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('意向职业岗位输入框')))
          .controller!
          .text,
      '未保存草稿',
    );
    expect(find.byKey(const Key('按目标岗位优化')), findsNothing);
  });

  testApp('文件选择或导入预览取消时不写入数据', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('导入文本简历')));
    await tester.pumpAndSettle();
    expect(find.text('导入预览'), findsNothing);
    expect(await DriftResumeRepository(database).listDocuments(), isEmpty);

    importFilePicker.selectedFile = _resumeTextFile(
      'candidate.md',
      '姓名：张三\n## 工作经历',
    );
    await tester.tap(find.byKey(const Key('导入文本简历')));
    await tester.pumpAndSettle();

    expect(find.text('导入预览'), findsOneWidget);
    expect(find.text('姓名：张三'), findsOneWidget);
    expect(find.text('未映射内容（1 行）'), findsOneWidget);
    expect(find.text('第 2 行：## 工作经历'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await DriftResumeRepository(database).listDocuments(), isEmpty);
  });

  testApp('切换主题保留编辑草稿且重启恢复选择并可重新跟随系统', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('新建简历')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('新建标题输入框')), '主题草稿');
    await tester.tap(find.byKey(const Key('确认新建简历')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('意向职业岗位输入框')), '尚未保存的职业');
    await tester.tap(find.byKey(const Key('隐私设置')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('主题_dark')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    expect(
      await DriftAppSettingsRepository(database).getThemePreference(),
      AppThemePreference.dark,
    );
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('意向职业岗位输入框')))
          .controller!
          .text,
      '尚未保存的职业',
    );
    expect(find.text('有未保存的修改'), findsOneWidget);
    final repository = DriftResumeRepository(database);
    final document = (await repository.listDocuments()).single;
    expect(await repository.listVersions(document.id), hasLength(1));
    await tester.tap(find.byKey(const Key('保存新版本')));
    await tester.pumpAndSettle();
    expect(await repository.listVersions(document.id), hasLength(2));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await pumpApp(tester);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    await tester.tap(find.byKey(const Key('导航_设置')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('主题_system')));
    await tester.tap(find.byKey(const Key('主题_system')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.system,
    );
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byKey(const Key('主题_system')))).brightness,
      Brightness.dark,
    );
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byKey(const Key('主题_system')))).brightness,
      Brightness.light,
    );
  });

  testApp('顶部与系统返回都保护未保存内容且只有明确保存才追加版本', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('新建简历')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('新建标题输入框')), '返回保护');
    await tester.tap(find.byKey(const Key('确认新建简历')));
    await tester.pumpAndSettle();
    final repository = DriftResumeRepository(database);
    final document = (await repository.listDocuments()).single;
    await tester.enterText(find.byKey(const Key('姓名输入框')), '合成姓名');
    await tester.tap(find.byKey(const Key('返回简历列表')));
    await tester.pumpAndSettle();
    expect(find.text('保存这次修改？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('继续编辑')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byKey(const Key('姓名输入框'))).controller!.text,
      '合成姓名',
    );
    expect(await repository.listVersions(document.id), hasLength(1));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('保存这次修改？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('保存并继续')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('导航_简历')), findsOneWidget);
    expect(await repository.listVersions(document.id), hasLength(2));
    await tester.ensureVisible(find.byKey(ValueKey('打开简历_${document.id}')));
    await tester.tap(find.byKey(ValueKey('打开简历_${document.id}')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('姓名输入框')), '将被放弃');
    await tester.tap(find.byKey(const Key('返回简历列表')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('放弃修改')));
    await tester.pumpAndSettle();
    expect(
      (await repository.findCurrentVersion(
        document.id,
      ))!.content.profile.fullName,
      '合成姓名',
    );
    expect(await repository.listVersions(document.id), hasLength(2));
  });

  testApp('等价空白不制造未保存状态且非法输入不能通过保存并返回', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('新建简历')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('新建标题输入框')), '校验保护');
    await tester.tap(find.byKey(const Key('确认新建简历')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('简历标题输入框')));
    await tester.enterText(find.byKey(const Key('简历标题输入框')), '  校验保护  ');
    await tester.pumpAndSettle();
    expect(find.text('有未保存的修改'), findsNothing);
    await tester.enterText(find.byKey(const Key('邮箱输入框')), 'invalid');
    await tester.tap(find.byKey(const Key('返回简历列表')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('保存并继续')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('保存新版本')), findsOneWidget);
    expect(find.textContaining('邮箱格式无效'), findsWidgets);
    final repository = DriftResumeRepository(database);
    final document = (await repository.listDocuments()).single;
    expect(await repository.listVersions(document.id), hasLength(1));
  });

  for (final mode in [AppThemePreference.light, AppThemePreference.dark]) {
    testApp('${mode.name}主题下首页设置和编辑器有视觉基准', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await DriftAppSettingsRepository(database).setThemePreference(mode);
      await pumpApp(tester);
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/task021_library_${mode.name}.png'),
      );
      await tester.tap(find.byKey(const Key('导航_设置')));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/task021_settings_${mode.name}.png'),
      );
      final semanticsHandle = tester.ensureSemantics();
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      semanticsHandle.dispose();
      await tester.tap(find.byKey(const Key('导航_简历')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('新建简历')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('新建标题输入框')), '我的下一步');
      await tester.enterText(find.byKey(const Key('新建姓名输入框')), '合成示例');
      await tester.tap(find.byKey(const Key('确认新建简历')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/task021_editor_${mode.name}.png'),
      );
    });
  }

  testApp('窄屏两倍文字的三导航和编辑保存都可达且无布局异常', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpApp(tester);
    for (final label in ['助手', '设置', '简历']) {
      await tester.tap(find.byKey(Key('导航_$label')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.ensureVisible(find.byKey(const Key('新建简历')));
    await tester.tap(find.byKey(const Key('新建简历')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('新建标题输入框')), '小屏幕也可以');
    await tester.ensureVisible(find.byKey(const Key('确认新建简历')));
    await tester.tap(find.byKey(const Key('确认新建简历')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('保存新版本')).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testApp('短横屏两倍文字与键盘出现时侧边导航仍可滚动到达', (tester) async {
    tester.view.physicalSize = const Size(900, 400);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 180);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpApp(tester);
    expect(find.byType(NavigationRail), findsOneWidget);
    for (final label in ['设置', '助手', '简历']) {
      final destination = find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text(label),
      );
      await tester.ensureVisible(destination);
      await tester.pumpAndSettle();
      await tester.tap(destination);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testApp('折叠的空区段可逐项填写且折叠再展开不丢草稿', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('新建简历')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('新建标题输入框')), '区段草稿');
    await tester.tap(find.byKey(const Key('确认新建简历')));
    await tester.pumpAndSettle();
    final section = find.byKey(const Key('展开区段_工作经历'));
    await tester.ensureVisible(section);
    await tester.tap(find.descendant(of: section, matching: find.text('工作经历')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('workExperiences_add')));
    await tester.tap(find.byKey(const Key('workExperiences_add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('条目字段_organization')), '合成公司');
    await tester.enterText(find.byKey(const Key('条目字段_position')), '设计师');
    await tester.ensureVisible(find.byKey(const Key('条目日期_start_year')));
    await tester.enterText(find.byKey(const Key('条目日期_start_year')), '2024');
    await tester.ensureVisible(find.byKey(const Key('完成条目编辑')));
    await tester.tap(find.byKey(const Key('完成条目编辑')));
    await tester.pumpAndSettle();
    expect(find.text('1 条内容'), findsOneWidget);
    for (var index = 0; index < 2; index++) {
      await tester.ensureVisible(section);
      await tester.tap(
        find.descendant(of: section, matching: find.text('工作经历')),
      );
      await tester.pumpAndSettle();
    }
    expect(find.text('合成公司'), findsOneWidget);
    await tester.tap(find.byKey(const Key('保存新版本')));
    await tester.pumpAndSettle();
    final repository = DriftResumeRepository(database);
    final document = (await repository.listDocuments()).single;
    expect(
      (await repository.findCurrentVersion(
        document.id,
      ))!.content.workExperiences.single.organization,
      '合成公司',
    );
    expect(await repository.listVersions(document.id), hasLength(2));
  });

  testApp('导入预览展示 validation error 并禁用确认', (tester) async {
    importFilePicker.selectedFile = _resumeTextFile(
      'invalid.txt',
      '姓名：张三\n邮箱：invalid-email',
    );
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('导入文本简历')));
    await tester.pumpAndSettle();

    expect(find.textContaining('邮箱格式无效'), findsOneWidget);
    final confirmButton = tester.widget<FilledButton>(
      find.byKey(const Key('确认导入')),
    );
    expect(confirmButton.onPressed, isNull);
    expect(await DriftResumeRepository(database).listDocuments(), isEmpty);
  });

  testApp('工作区导入创建独立简历且保留已有简历和历史', (tester) async {
    importFilePicker.selectedFile = _resumeTextFile(
      'candidate.md',
      '姓名：张三\n职业标题：Flutter 工程师\n补充说明',
    );
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('导入文本简历')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('导入标题输入框')))
          .controller!
          .text,
      'candidate',
    );
    await tester.enterText(find.byKey(const Key('导入标题输入框')), '导入简历');
    await tester.tap(find.byKey(const Key('确认导入')));
    await tester.pumpAndSettle();

    expect(find.text('已导入并创建简历。'), findsOneWidget);
    expect(find.text('版本历史（1）'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('保留的导入内容')));
    await tester.tap(find.byKey(const Key('保留的导入内容')));
    await tester.pumpAndSettle();
    expect(find.text('第 3 行：补充说明'), findsOneWidget);
    final repository = DriftResumeRepository(database);
    final importedDocument = (await repository.listDocuments()).single;
    expect(
      (await repository.findCurrentVersion(importedDocument.id))!.source,
      ResumeVersionSource.imported,
    );

    importFilePicker.selectedFile = _resumeTextFile(
      'updated.txt',
      '姓名：李四\n职业标题：产品工程师',
    );
    expect(find.byKey(const Key('导入文本简历')), findsNothing);
    await tester.tap(find.byKey(const Key('返回简历列表')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('导入文本简历')));
    await tester.pumpAndSettle();
    expect(find.text('创建并导入'), findsOneWidget);
    await tester.tap(find.byKey(const Key('确认导入')));
    await tester.pumpAndSettle();

    expect(find.text('已导入并创建简历。'), findsOneWidget);
    expect(find.text('版本历史（1）'), findsOneWidget);
    final documents = await repository.listDocuments();
    expect(documents, hasLength(2));
    final versions = await repository.listVersions(importedDocument.id);
    expect(versions, hasLength(1));
    expect(versions.single.content.profile.fullName, '张三');
    final newDocument = documents.singleWhere(
      (d) => d.id != importedDocument.id,
    );
    expect(
      (await repository.findCurrentVersion(
        newDocument.id,
      ))!.content.profile.fullName,
      '李四',
    );
  });
}

SelectedResumeTextFile _resumeTextFile(String fileName, String text) {
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

final class _WidgetGatewayApi implements GatewayApi {
  var _completedBasicGenerations = 0;

  @override
  Future<void> registerFakeAccount({
    required String phoneE164,
    required String password,
  }) async {}

  @override
  Future<GatewaySession> createSession({
    required String phoneE164,
    required String password,
  }) async {
    return GatewaySession(
      token: 'widget-session',
      expiresAtUtc: DateTime.utc(2027, 1, 1),
    );
  }

  @override
  Future<GatewayAccessSnapshot> readAccess({
    required RemoteAiCapability capability,
    required String sessionToken,
  }) async {
    return GatewayAccessSnapshot(
      capability: capability,
      plan: GatewaySubscriptionPlan.free,
      allowed: capability == RemoteAiCapability.basicResumeCompose,
      reason: capability == RemoteAiCapability.basicResumeCompose
          ? 'allowed'
          : 'subscription_required',
      remainingMonthlyBasicGenerations:
          capability == RemoteAiCapability.basicResumeCompose
          ? 10 - _completedBasicGenerations
          : null,
    );
  }

  @override
  Future<GatewayRemoteAiResponse> submitRemoteAiRequest({
    required String sessionToken,
    required String clientRequestId,
    required String idempotencyKey,
    required RemoteAiCapability capability,
    required Map<String, Object?> input,
  }) async {
    _completedBasicGenerations++;
    return GatewayRemoteAiResponse(
      operationId: 'widget-operation',
      clientRequestId: clientRequestId,
      capability: capability,
      output: {
        'outputVersion': 'basicResumeCompose.v1',
        'summary': '已整理为基础简历。',
        'candidateResume': {
          'schemaVersion': currentResumeSchemaVersion,
          'profile': {
            'id': 'widget-profile',
            'headline': 'Flutter 工程师',
            'coarseLocation': '',
          },
          'workExperiences': <Object?>[],
          'educations': <Object?>[],
          'projects': <Object?>[],
          'skillGroups': <Object?>[],
          'certifications': <Object?>[],
          'languages': <Object?>[],
          'customSections': <Object?>[],
        },
        'sourceReferences': [
          {
            'path': '/profile/headline',
            'fragmentIds': ['fragment-1'],
          },
        ],
        'missingInformation': <Object?>[],
        'warnings': <Object?>[],
      },
      promptVersion: 'basic-resume-compose.v1',
    );
  }

  @override
  void close() {}
}
