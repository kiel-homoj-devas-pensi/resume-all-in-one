import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:entitlements/entitlements.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_all_in_one_client/src/app_theme.dart';
import 'package:resume_all_in_one_client/src/cloud_policy_dialog.dart';
import 'package:resume_all_in_one_client/src/gateway_api_client.dart';
import 'package:resume_all_in_one_client/src/local_agent_composition.dart';
import 'support/local_suggestion_fixture.dart';
import 'package:resume_all_in_one_client/src/local_data_management_service.dart';
import 'package:resume_all_in_one_client/src/remote_account_service.dart';
import 'package:resume_all_in_one_client/src/remote_resume_ai_service.dart';
import 'package:resume_all_in_one_client/src/resume_file_exporter.dart';
import 'package:resume_all_in_one_client/src/resume_import_file_picker.dart';
import 'package:resume_all_in_one_client/src/resume_workspace_controller.dart';

import 'support/cloud_options_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final screenshotDirectory =
      Platform.environment['CLOUD_POLICY_SCREENSHOT_DIR'];
  setUpAll(() async {
    if (screenshotDirectory != null) {
      await (FontLoader('PolicyQaFont')..addFont(
            rootBundle.load(
              'packages/document_io/assets/fonts/NotoSansSC-Regular.ttf',
            ),
          ))
          .load();
    }
  });
  late LocalStorageDatabase database;
  late ResumeWorkspaceController controller;
  late _PolicyTransport transport;
  setUp(() async {
    database = LocalStorageDatabase.inMemory();
    transport = _PolicyTransport();
    controller = _createController(database, transport);
    await controller.initialize();
  });
  tearDown(() async {
    controller.dispose();
    await database.close();
  });

  test('访客主动查询政策不上传，不改本机稿或历史', () async {
    await controller.createDocument(title: '本机唯一稿', fullName: '合成用户');
    final versions = await DriftResumeRepository(
      database,
    ).listVersions(controller.currentDocument!.id);
    await controller.setNetworkEnabled(true);
    expect((await controller.readCloudOptions())!.enabled, isTrue);
    expect(transport.calls, 1);
    expect(controller.remoteAccountSnapshot.isSignedIn, isFalse);
    expect(
      (await DriftResumeRepository(database).listVersions(
        controller.currentDocument!.id,
      )).map((v) => v.toJson()).toList(),
      versions.map((v) => v.toJson()).toList(),
    );
    expect(controller.documents.single.title, '本机唯一稿');
  });

  test('关闭联网时不查询，旧库仍可保存和读取', () async {
    await controller.setNetworkEnabled(false);
    expect(await controller.readCloudOptions(), isNull);
    expect(transport.calls, 0);
    expect(
      await controller.createDocument(title: '离线稿', fullName: '合成用户'),
      isTrue,
    );
    expect(controller.currentVersion, isNotNull);
  });

  test('关闭再开启联网不能使先前迟到的政策响应生效', () async {
    await controller.setNetworkEnabled(true);
    transport.gate = Completer<Map<String, Object?>>();
    final pending = controller.readCloudOptions();
    await controller.setNetworkEnabled(false);
    await controller.setNetworkEnabled(true);
    transport.gate!.complete(syntheticCloudOptions());
    expect(await pending, isNull);
    expect(transport.calls, 1);
    expect(controller.networkEnabled, isTrue);
  });

  test('损坏政策不会以未开放或成功冒充，也不自动再次查询', () async {
    await controller.setNetworkEnabled(true);
    transport.response['policyFingerprint'] = 'bad';
    expect(await controller.readCloudOptions(), isNull);
    expect(controller.formError, contains('核验'));
    expect(transport.calls, 1);
  });

  for (final mode in ThemeMode.values) {
    testWidgets('${mode.name} 窄屏双倍字体政策可滚动、读取和关闭', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 740);
      addTearDown(tester.view.reset);
      await controller.setNetworkEnabled(true);
      final captureKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _visualTheme(AppTheme.light, screenshotDirectory != null),
            darkTheme: _visualTheme(AppTheme.dark, screenshotDirectory != null),
            themeMode: mode,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => CloudPolicyDialog(controller: controller),
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.text('云服务：合成测试环境'), findsOneWidget);
      expect(find.textContaining('不上传简历'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _capture(
        tester,
        captureKey,
        screenshotDirectory,
        '${mode.name}-top',
      );
      await tester.scrollUntilVisible(
        find.textContaining('以上是合成环境配置'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _capture(
        tester,
        captureKey,
        screenshotDirectory,
        '${mode.name}-bottom',
      );
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(CloudPolicyDialog), findsNothing);
      expect(transport.calls, 1);
    });
  }

  testWidgets('关闭弹窗后迟到响应不能写入已销毁界面', (tester) async {
    await controller.setNetworkEnabled(true);
    transport.gate = Completer<Map<String, Object?>>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => CloudPolicyDialog(controller: controller),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    transport.gate!.complete(syntheticCloudOptions());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(transport.calls, 1);
  });
}

ThemeData _visualTheme(ThemeData base, bool enabled) {
  if (!enabled) return base;
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PolicyQaFont'),
    dialogTheme: base.dialogTheme.copyWith(
      titleTextStyle: base.dialogTheme.titleTextStyle?.copyWith(
        fontFamily: 'PolicyQaFont',
      ),
      contentTextStyle: base.dialogTheme.contentTextStyle?.copyWith(
        fontFamily: 'PolicyQaFont',
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: base.textButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll(
          base.textTheme.labelLarge?.copyWith(fontFamily: 'PolicyQaFont'),
        ),
      ),
    ),
  );
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey key,
  String? output,
  String name,
) async {
  if (output == null) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

ResumeWorkspaceController _createController(
  LocalStorageDatabase database,
  GatewayHttpTransport transport,
) {
  final repository = DriftResumeRepository(database);
  final audit = DriftAgentAuditRepository(database);
  final account = RemoteAccountService(
    gatewayApi: GatewayApiClient(
      baseUri: Uri.parse('https://gateway.invalid'),
      transport: transport,
    ),
  );
  return ResumeWorkspaceController(
    repository: repository,
    settingsRepository: DriftAppSettingsRepository(database),
    localAgentCheckService: createOfflineLocalAgentCheckService(
      resumeRepository: repository,
      auditRepository: audit,
    ),
    localResumeSuggestionService: createOfflineLocalResumeSuggestionService(
      resumeRepository: repository,
      auditRepository: audit,
    ),
    localDataManagementService: LocalDataManagementService(
      repository: DriftLocalDataRepository(database),
      rootDirectory: () async => Directory.systemTemp,
    ),
    accessPolicy: CapabilityAccessPolicy.mvp(),
    fileExporter: ResumeFileExporter(
      rootDirectory: () async => Directory.systemTemp,
    ),
    importFilePicker: const SystemResumeImportFilePicker(),
    remoteAccountService: account,
    remoteResumeAiService: RemoteResumeAiService(accountService: account),
  );
}

final class _PolicyTransport implements GatewayHttpTransport {
  final response = syntheticCloudOptions();
  Completer<Map<String, Object?>>? gate;
  int calls = 0;
  @override
  Future<GatewayHttpResponse> sendJson({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    Map<String, Object?>? jsonBody,
  }) async {
    expect(method, 'GET');
    expect(headers, isEmpty);
    expect(jsonBody, isNull);
    expect(uri.path, '/v1/cloud-resumes/options');
    calls++;
    final value = await (gate?.future ?? Future.value(response));
    return GatewayHttpResponse(
      statusCode: 200,
      bodyBytes: Uint8List.fromList(utf8.encode(jsonEncode(value))),
    );
  }

  @override
  void close() {}
}
