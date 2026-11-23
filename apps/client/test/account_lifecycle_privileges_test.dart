import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:entitlements/entitlements.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_all_in_one_client/src/gateway_api_client.dart';
import 'package:resume_all_in_one_client/src/local_agent_composition.dart';
import 'support/local_suggestion_fixture.dart';
import 'package:resume_all_in_one_client/src/local_data_management_service.dart';
import 'package:resume_all_in_one_client/src/remote_account_service.dart';
import 'package:resume_all_in_one_client/src/remote_ai_dialogs.dart';
import 'package:resume_all_in_one_client/src/remote_resume_ai_service.dart';
import 'package:resume_all_in_one_client/src/resume_file_exporter.dart';
import 'package:resume_all_in_one_client/src/resume_import_file_picker.dart';
import 'package:resume_all_in_one_client/src/resume_workspace_controller.dart';

void main() {
  testWidgets('真实验证码账户路径显示服务端管理员、永久会员与会员套餐', (tester) async {
    final transport = _PrivilegeTransport()
      ..role = 'admin'
      ..membership = 'permanent'
      ..plan = 'pro';
    await _openSignedInDialog(tester, transport, textScale: 2);
    expect(find.text('管理员'), findsOneWidget);
    expect(find.text('永久会员 · 无需缴费续期'), findsOneWidget);
    expect(find.text('套餐：会员'), findsOneWidget);
    expect(find.textContaining('Fake'), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('刷新账户权益')));
    expect(find.byKey(const Key('刷新账户权益')).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('不限次由服务器确认，刷新恢复真实有限额度而不显示伪造大数', (tester) async {
    final transport = _PrivilegeTransport()
      ..quotaIsUnlimited = true
      ..quotaEmpty = true;
    await _openSignedInDialog(tester, transport);
    expect(find.text('基础生成：当前不限次数'), findsOneWidget);
    expect(find.text('岗位优化：当前不限次数'), findsOneWidget);
    expect(find.textContaining('本月剩余'), findsNothing);
    transport.quotaIsUnlimited = false;
    await _refresh(tester);
    expect(find.textContaining('当前不限次数'), findsNothing);
    expect(find.text('基础生成：本月剩余 0 / 9份'), findsOneWidget);
    expect(find.text('岗位优化：本月剩余 0 / 5份'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('普通账号与仅管理员均不推断永久会员', (tester) async {
    final transport = _PrivilegeTransport();
    await _openSignedInDialog(tester, transport);
    expect(find.text('普通用户'), findsOneWidget);
    expect(find.text('未授予永久会员'), findsOneWidget);
    expect(find.text('套餐：免费'), findsOneWidget);
    expect(find.text('永久会员 · 无需缴费续期'), findsNothing);
    transport.role = 'admin';
    await _refresh(tester);
    expect(find.text('管理员'), findsOneWidget);
    expect(find.text('未授予永久会员'), findsOneWidget);
    expect(find.text('套餐：免费'), findsOneWidget);
  });

  testWidgets('刷新服务端撤销结果会替换旧管理员与永久会员显示', (tester) async {
    final transport = _PrivilegeTransport()
      ..role = 'admin'
      ..membership = 'permanent'
      ..plan = 'pro';
    await _openSignedInDialog(tester, transport);
    transport
      ..role = 'member'
      ..membership = 'none'
      ..plan = 'free';
    await _refresh(tester);
    expect(find.text('管理员'), findsNothing);
    expect(find.text('永久会员 · 无需缴费续期'), findsNothing);
    expect(find.text('普通用户'), findsOneWidget);
    expect(find.text('套餐：免费'), findsOneWidget);
    expect(transport.privilegeRequests, 2);
  });

  testWidgets('刷新失败清除缓存权益，关闭重开保持未核验，重试成功才恢复显示', (tester) async {
    final transport = _PrivilegeTransport()
      ..role = 'admin'
      ..membership = 'permanent'
      ..plan = 'pro';
    final controller = await _openSignedInDialog(tester, transport);
    final gate = transport.privilegeGate = Completer<void>();
    transport.failPrivileges = true;
    await tester.ensureVisible(find.byKey(const Key('刷新账户权益')));
    await tester.tap(find.byKey(const Key('刷新账户权益')));
    await tester.pumpAndSettle();
    expect(find.text('正在更新身份、会员与 AI 额度…'), findsOneWidget);
    expect(find.text('管理员'), findsNothing);
    expect(find.text('永久会员 · 无需缴费续期'), findsNothing);
    expect(find.byKey(const Key('账户套餐')), findsNothing);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('账户权益刷新失败')), findsOneWidget);
    expect(find.text('管理员'), findsNothing);
    expect(find.textContaining('基础生成：可用'), findsNothing);
    expect(controller.remoteAccountSnapshot.isSignedIn, isTrue);
    expect(controller.remoteAccountSnapshot.accessVerified, isFalse);
    expect(controller.remoteAccountSnapshot.plan, isNull);
    expect(controller.remoteAccountSnapshot.privileges, isNull);
    expect(controller.remoteAccountSnapshot.accessByCapability, isEmpty);
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();
    expect(controller.remoteAccountSnapshot.isSignedIn, isTrue);
    await tester.tap(find.text('打开账号'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('账户权益刷新失败')), findsOneWidget);
    expect(find.text('管理员'), findsNothing);
    expect(find.text('永久会员 · 无需缴费续期'), findsNothing);
    expect(find.byKey(const Key('账户套餐')), findsNothing);
    transport
      ..failPrivileges = false
      ..privilegeGate = null
      ..role = 'member'
      ..membership = 'none'
      ..plan = 'free';
    await _refresh(tester);
    expect(find.byKey(const Key('账户权益刷新失败')), findsNothing);
    expect(find.text('普通用户'), findsOneWidget);
    expect(find.text('套餐：免费'), findsOneWidget);
    expect(controller.remoteAccountSnapshot.accessVerified, isTrue);
    expect(transport.privilegeRequests, 3);
  });

  testWidgets('缺少权益接口不把会员套餐冒称为永久会员', (tester) async {
    final transport = _PrivilegeTransport()
      ..plan = 'pro'
      ..privilegesUnavailable = true;
    await _openSignedInDialog(tester, transport);
    expect(find.text('服务尚未提供管理员与永久会员身份信息。'), findsOneWidget);
    expect(find.text('套餐：会员'), findsOneWidget);
    expect(find.text('管理员'), findsNothing);
    expect(find.text('永久会员 · 无需缴费续期'), findsNothing);
  });

  testWidgets('不一致的其他账号权益响应刷新失败，不显示旧特权', (tester) async {
    final transport = _PrivilegeTransport()
      ..role = 'admin'
      ..membership = 'permanent'
      ..plan = 'pro';
    await _openSignedInDialog(tester, transport);
    transport.privilegeAccountId = 'account-other';
    await _refresh(tester);
    expect(find.byKey(const Key('账户权益刷新失败')), findsOneWidget);
    expect(find.text('管理员'), findsNothing);
    expect(find.text('永久会员 · 无需缴费续期'), findsNothing);
  });
}

Future<void> _refresh(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('刷新账户权益')));
  await tester.tap(find.byKey(const Key('刷新账户权益')));
  await tester.pumpAndSettle();
}

Future<ResumeWorkspaceController> _openSignedInDialog(
  WidgetTester tester,
  _PrivilegeTransport transport, {
  double textScale = 1,
}) async {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final database = LocalStorageDatabase.inMemory();
  final controller = _controller(database, transport);
  addTearDown(() async {
    controller.dispose();
    await database.close();
  });
  await controller.initialize();
  await controller.setNetworkEnabled(true);
  expect(
    await controller.signInRemoteAccount(
      phoneE164: '+8613800000000',
      password: 'TestPass2026!',
    ),
    isTrue,
  );
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => RemoteAccountDialog(
                controller: controller,
                onFeedback: () {},
              ),
            ),
            child: const Text('打开账号'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开账号'));
  await tester.pumpAndSettle();
  expect(find.text('我的账号'), findsOneWidget);
  expect(find.byKey(const Key('账户密码')), findsNothing);
  return controller;
}

final class _PrivilegeTransport implements GatewayHttpTransport {
  bool quotaIsUnlimited = false;
  bool quotaEmpty = false;
  String role = 'member';
  String membership = 'none';
  String plan = 'free';
  String privilegeAccountId = 'account-synthetic';
  bool failPrivileges = false;
  bool privilegesUnavailable = false;
  int privilegeRequests = 0;
  Completer<void>? privilegeGate;

  @override
  Future<GatewayHttpResponse> sendJson({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    Map<String, Object?>? jsonBody,
  }) async {
    var status = 200;
    final Map<String, Object?> body;
    if (uri.path == '/v2/account/options') {
      body = {
        'protocolVersion': '0.5.0',
        'developmentSms': false,
        'persistentLogin': false,
      };
    } else if (uri.path == '/v2/account-sessions') {
      body = {
        'protocolVersion': '0.5.0',
        'sessionToken': 'synthetic-memory-token',
        'expiresAtUtc': DateTime.now()
            .toUtc()
            .add(const Duration(days: 1))
            .toIso8601String(),
      };
    } else if (uri.path == '/v1/account/identity') {
      body = {'protocolVersion': '0.4.0', 'accountId': 'account-synthetic'};
    } else if (uri.path.startsWith('/v1/account/quota/')) {
      final basic = uri.path.endsWith('basicResumeCompose');
      body = {
        'protocolVersion': '0.2.0',
        'capability': uri.path.split('/').last,
        'plan': plan,
        'allowed': quotaIsUnlimited || !quotaEmpty,
        'reason': quotaIsUnlimited || !quotaEmpty
            ? 'allowed'
            : 'quota_exhausted',
        'isUnlimited': quotaIsUnlimited,
        'remainingMonthlyBasicGenerations': basic
            ? (quotaEmpty ? 0 : (plan == 'pro' ? 99 : 9))
            : null,
        'monthlyLimit': basic
            ? (plan == 'pro' ? 99 : 9)
            : (plan == 'pro' ? 60 : 5),
        'remainingMonthlyGenerations': quotaEmpty
            ? 0
            : basic
            ? (plan == 'pro' ? 99 : 9)
            : (plan == 'pro' ? 60 : 5),
        'resetsAtUtc': '2026-10-31T16:00:00Z',
        'countingUnit': 'usableCandidate',
      };
    } else if (uri.path == '/v1/account/privileges') {
      privilegeRequests++;
      await privilegeGate?.future;
      if (failPrivileges || privilegesUnavailable) {
        status = 503;
        body = {
          'error': {
            'code': privilegesUnavailable
                ? 'account_privileges_unavailable'
                : 'storage_unavailable',
            'message': 'synthetic unavailable',
            'operationId': 'trace-synthetic',
            'retryable': true,
          },
        };
      } else {
        body = {
          'protocolVersion': '0.1.0',
          'accountId': privilegeAccountId,
          'role': role,
          'membership': membership,
        };
      }
    } else {
      throw StateError('Unexpected synthetic route: ${uri.path}');
    }
    return GatewayHttpResponse(
      statusCode: status,
      bodyBytes: Uint8List.fromList(utf8.encode(jsonEncode(body))),
    );
  }

  @override
  void close() {}
}

ResumeWorkspaceController _controller(
  LocalStorageDatabase database,
  _PrivilegeTransport transport,
) {
  final repository = DriftResumeRepository(database);
  final audit = DriftAgentAuditRepository(database);
  final account = RemoteAccountService(
    gatewayApi: GatewayApiClient(
      baseUri: Uri.parse('https://synthetic.invalid'),
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
      rootDirectory: () async => throw StateError('不访问导出目录'),
    ),
    accessPolicy: CapabilityAccessPolicy.mvp(),
    fileExporter: ResumeFileExporter(
      rootDirectory: () async => throw StateError('不访问导出目录'),
    ),
    importFilePicker: const SystemResumeImportFilePicker(),
    remoteAccountService: account,
    remoteResumeAiService: RemoteResumeAiService(accountService: account),
  );
}
