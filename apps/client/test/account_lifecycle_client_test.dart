import 'dart:async';
import 'dart:convert';

import 'package:entitlements/entitlements.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_all_in_one_client/src/app_theme.dart';
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
  testWidgets('短横屏双倍文字及真实比例键盘下密码标签和光标可见', (tester) async {
    _setAccountViewport(tester, const Size(640, 320));
    tester.view.padding = const FakeViewPadding(top: 24);
    addTearDown(tester.view.resetPadding);
    await _openModernAccount(tester, _LifecycleTransport(), textScale: 2);
    await _focusAccountField(tester, '账户密码');
    await tester.enterText(find.byKey(const Key('账户密码')), 'TestPass2026!');
    tester.view.viewInsets = const FakeViewPadding(bottom: 210);
    await tester.pumpAndSettle();
    _expectAccountFieldVisible(tester, '账户密码');
    expect(_accountField(tester, '账户密码').controller!.text, 'TestPass2026!');
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏双倍深色注册由下一项自动定位整字段，键盘变高后首错仍可读', (tester) async {
    _setAccountViewport(tester, const Size(320, 640));
    final transport = _LifecycleTransport();
    await _openModernAccount(
      tester,
      transport,
      textScale: 2,
      brightness: Brightness.dark,
    );
    await _tapAccountAction(tester, '创建账号');
    await _focusAccountField(tester, '账户区号');
    tester.view.viewInsets = const FakeViewPadding(bottom: 180);
    await tester.pumpAndSettle();
    _expectAccountFieldVisible(tester, '账户区号');
    await _nextAccountField(tester, '账户区号', '账户手机号');
    await tester.enterText(find.byKey(const Key('账户手机号')), '13800000000');
    await _nextAccountField(tester, '账户手机号', '账户密码');
    await tester.enterText(find.byKey(const Key('账户密码')), 'TestPass2026!');
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    await tester.pumpAndSettle();
    _expectAccountFieldVisible(tester, '账户密码');
    await tester.tap(find.byTooltip('显示密码').hitTestable());
    await tester.pumpAndSettle();
    expect(_accountField(tester, '账户密码').obscureText, isFalse);
    expect(_accountField(tester, '账户密码').controller!.text, 'TestPass2026!');
    _expectAccountFieldVisible(tester, '账户密码');
    await _nextAccountField(tester, '账户密码', '账户确认密码');
    await tester.enterText(find.byKey(const Key('账户确认密码')), 'TestPass2026!');
    await _nextAccountField(tester, '账户确认密码', '账户验证码');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('请获取并输入仍有效的6位验证码'), findsOneWidget);
    _expectAccountFieldVisible(tester, '账户验证码');
    // 提交时仍处于表单末尾；第一个错误必须由产品自动带回屏幕。
    _accountField(tester, '账户手机号').controller!.clear();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('请核对区号和手机号'), findsOneWidget);
    _expectAccountFieldVisible(tester, '账户手机号');
    _accountField(tester, '账户手机号').controller!.text = '13800000000';
    _accountField(tester, '账户密码').controller!.clear();
    await _focusAccountField(tester, '账户验证码');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    _expectAccountFieldVisible(tester, '账户密码');
    expect(transport.requests.where((r) => r.$1 == '/v2/accounts'), isEmpty);
    expect(
      transport.requests.where((r) => r.$1 == '/v2/account-verifications'),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('常见手机找回下一项、粘贴、旋转和收放键盘保留输入，错误修正可提交', (tester) async {
    _setAccountViewport(tester, const Size(390, 844));
    final transport = _LifecycleTransport()..recoveryCodes = true;
    await _openModernAccount(tester, transport);
    await _tapAccountAction(tester, '找回密码');
    await _focusAccountField(tester, '账户手机号');
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    _expectAccountFieldVisible(tester, '账户手机号');
    await tester.enterText(find.byKey(const Key('账户手机号')), '13800000000');
    await _nextAccountField(tester, '账户手机号', '账户新密码');
    await tester.enterText(find.byKey(const Key('账户新密码')), 'NewPass026!');
    await _nextAccountField(tester, '账户新密码', '账户确认密码');
    await tester.enterText(find.byKey(const Key('账户确认密码')), 'WrongPass1');
    await _nextAccountField(tester, '账户确认密码', '账户恢复码');
    // 一次编辑值更新模拟粘贴完整恢复码，而非逐字符输入。
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: _syntheticRecoveryCode,
        selection: TextSelection.collapsed(
          offset: _syntheticRecoveryCode.length,
        ),
      ),
    );
    await tester.pumpAndSettle();
    _expectAccountFieldVisible(tester, '账户恢复码');
    tester.view.physicalSize = const Size(844, 390);
    tester.view.viewInsets = const FakeViewPadding(bottom: 100);
    await tester.pumpAndSettle();
    _expectAccountFieldVisible(tester, '账户恢复码');
    for (final inset in [0.0, 120.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pumpAndSettle();
      _expectAccountFieldVisible(tester, '账户恢复码');
      expect(
        _accountField(tester, '账户恢复码').controller!.text,
        _syntheticRecoveryCode,
      );
      expect(_accountField(tester, '账户新密码').controller!.text, 'NewPass026!');
      expect(_accountField(tester, '账户确认密码').controller!.text, 'WrongPass1');
    }
    tester.view.physicalSize = const Size(390, 844);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('两次密码不一致，请重新核对'), findsOneWidget);
    _expectAccountFieldVisible(tester, '账户确认密码');
    expect(
      transport.requests.where((r) => r.$1 == '/v2/account/password-reset'),
      isEmpty,
    );
    await tester.enterText(find.byKey(const Key('账户确认密码')), 'NewPass026!');
    await _nextAccountField(tester, '账户确认密码', '账户恢复码');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      transport.requests.where((r) => r.$1 == '/v2/account/password-reset'),
      hasLength(1),
    );
    expect(find.text('欢迎回来'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('根退出回原页并清理秘密，登录和安全子页返回不撤销已有会话', (tester) async {
    _setAccountViewport(tester, const Size(390, 844));
    final transport = _LifecycleTransport();
    final controller = await _openModernAccount(tester, transport);
    expect(find.text('完成'), findsNothing);
    await _focusAccountField(tester, '账户密码');
    await tester.enterText(find.byKey(const Key('账户密码')), 'TestPass2026!');
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();
    expect(find.text('欢迎回来'), findsNothing);
    expect(find.text('打开').hitTestable(), findsOneWidget);
    expect(controller.remoteAccountSnapshot.isSignedIn, isFalse);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(_accountField(tester, '账户密码').controller!.text, isEmpty);
    expect(_accountField(tester, '账户密码').obscureText, isTrue);
    await tester.enterText(find.byKey(const Key('账户手机号')), '13800000000');
    await tester.enterText(find.byKey(const Key('账户密码')), 'TestPass2026!');
    await _tapAccountAction(tester, '登录');
    expect(controller.remoteAccountSnapshot.isSignedIn, isTrue);
    await _tapAccountAction(tester, '账号安全');
    await _focusAccountField(tester, '账户密码');
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    _expectAccountFieldVisible(tester, '账户密码');
    await tester.enterText(find.byKey(const Key('账户密码')), 'TestPass2026!');
    await _nextAccountField(tester, '账户密码', '账户新密码');
    await tester.enterText(find.byKey(const Key('账户新密码')), 'NewPass026!');
    await _nextAccountField(tester, '账户新密码', '账户确认密码');
    await tester.enterText(find.byKey(const Key('账户确认密码')), 'NewPass026!');
    await tester.tap(find.text('返回账号'));
    await tester.pumpAndSettle();
    expect(find.text('我的账号'), findsOneWidget);
    tester.view.viewInsets = const FakeViewPadding();
    await tester.pumpAndSettle();
    await _tapAccountAction(tester, '账号安全');
    for (final key in ['账户密码', '账户新密码', '账户确认密码']) {
      expect(_accountField(tester, key).controller!.text, isEmpty);
      expect(_accountField(tester, key).obscureText, isTrue);
    }
    await tester.tap(find.text('返回账号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();
    expect(controller.remoteAccountSnapshot.isSignedIn, isTrue);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('我的账号'), findsOneWidget);
    expect(
      transport.requests.where((r) => r.$1 == '/v2/account-sessions'),
      hasLength(1),
    );
    expect(
      transport.requests.where((r) => r.$1 == '/v2/account-sessions/revoke'),
      isEmpty,
    );
    expect(
      transport.requests.where((r) => r.$1 == '/v2/account/password'),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('游客通过正常入口体验，不发短信、不创建账号、不展示账号安全和第三能力', (tester) async {
    final transport = _LifecycleTransport();
    final controller = await _openModernAccount(tester, transport);
    await tester.ensureVisible(find.byKey(const Key('游客体验AI')));
    await tester.tap(find.byKey(const Key('游客体验AI')));
    await tester.pumpAndSettle();
    expect(controller.remoteAccountSnapshot.isGuest, isTrue);
    expect(find.text('游客体验'), findsOneWidget);
    expect(find.text('账号安全'), findsNothing);
    expect(find.textContaining('对话优化'), findsNothing);
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();
    expect(controller.remoteAccountSnapshot.isGuest, isTrue);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(controller.remoteAccountSnapshot.isGuest, isTrue);
    expect(find.text('游客体验'), findsOneWidget);
    expect(
      transport.requests.where((entry) => entry.$1 == '/v1/guest/sessions'),
      hasLength(1),
    );
    expect(
      transport.requests.where(
        (entry) => {
          '/v2/accounts',
          '/v2/account-sessions',
          '/v2/account-verifications',
        }.contains(entry.$1),
      ),
      isEmpty,
    );
    await tester.ensureVisible(find.text('登录或创建账号'));
    await tester.tap(find.text('登录或创建账号'));
    await tester.pumpAndSettle();
    expect(controller.remoteAccountSnapshot.isSignedIn, isFalse);
    expect(find.byKey(const Key('游客体验AI')), findsOneWidget);
  });

  for (final failure in [
    'verification_delivery_unknown',
    'client_timeout',
    'gateway_unreachable',
    'storage_unavailable',
    'operation_outcome_unknown',
  ]) {
    test('验证码 $failure 不返回挑战、不自动重发并提示等待', () async {
      final database = LocalStorageDatabase.inMemory();
      final transport = _LifecycleTransport()..failVerification = failure;
      final controller = _controller(database, _client(transport));
      await controller.initialize();
      addTearDown(() async {
        controller.dispose();
        await database.close();
      });
      final challenge = await controller.requestAccountVerification(
        '+8613800000000',
        'register',
      );
      expect(challenge, isNull);
      expect(controller.formError, contains('请勿连续重复发送'));
      expect(controller.formError, isNot(contains('重复生成')));
      expect(
        transport.requests.where(
          (entry) => entry.$1 == '/v2/account-verifications',
        ),
        hasLength(1),
      );
    });
  }

  test('正常格式号码通过验证码契约注册，撤销成功才清除登录且重启不保留 token', () async {
    final transport = _LifecycleTransport();
    final api = _client(transport);
    final account = RemoteAccountService(gatewayApi: api);
    final challenge = await account.requestVerification(
      '+8613800000000',
      'register',
    );
    await account.registerVerified(
      '+8613800000000',
      'TestPass2026!',
      challenge.challengeId,
      challenge.developmentCode!,
    );
    expect(account.snapshot.isSignedIn, isTrue);
    final register = transport.requests.firstWhere(
      (entry) => entry.$1 == '/v2/accounts',
    );
    expect(
      register.$2.keys,
      unorderedEquals([
        'protocolVersion',
        'phoneE164',
        'password',
        'challengeId',
        'code',
      ]),
    );
    expect(
      transport.requests.any((entry) => entry.$1 == '/v1/accounts'),
      isFalse,
    );
    transport.failRevoke = true;
    await expectLater(
      account.manageAccount(GatewayAccountAction.revoke, {'allDevices': true}),
      throwsA(isA<GatewayApiException>()),
    );
    expect(account.snapshot.isSignedIn, isTrue);
    transport.failRevoke = false;
    await account.manageAccount(GatewayAccountAction.revoke, {
      'allDevices': true,
    });
    expect(account.snapshot.isSignedIn, isFalse);
    expect(RemoteAccountService(gatewayApi: api).snapshot.isSignedIn, isFalse);
    expect(transport.lastToken, 'synthetic-memory-token');
  });

  for (final brightness in Brightness.values) {
    testWidgets('${brightness.name} 验证码账户在窄屏双倍文字下可操作，停用取消不发送', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final database = LocalStorageDatabase.inMemory();
      final transport = _LifecycleTransport();
      final controller = _controller(database, _client(transport));
      await controller.initialize();
      addTearDown(() async {
        controller.dispose();
        await database.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: brightness == Brightness.dark ? AppTheme.dark : AppTheme.light,
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
                  builder: (_) => RemoteAccountDialog(
                    controller: controller,
                    onFeedback: () {},
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Fake'), findsNothing);
      await tester.ensureVisible(find.text('创建账号'));
      await tester.tap(find.text('创建账号'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('账户手机号')), '+15550001234');
      await tester.ensureVisible(find.byKey(const Key('账户密码')));
      await tester.enterText(find.byKey(const Key('账户密码')), 'TestPass2026!');
      await tester.ensureVisible(find.byKey(const Key('账户确认密码')));
      await tester.enterText(find.byKey(const Key('账户确认密码')), 'TestPass2026!');
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('获取验证码'));
      await tester.tap(find.text('获取验证码'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('账户验证码')))
            .controller!
            .text,
        '123456',
      );
      await tester.ensureVisible(find.text('验证并注册'));
      await tester.tap(find.text('验证并注册'));
      await tester.pumpAndSettle();
      expect(controller.remoteAccountSnapshot.isSignedIn, isTrue);
      await tester.ensureVisible(find.text('账号安全'));
      await tester.tap(find.text('账号安全'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('账户密码')), 'TestPass2026!');
      await tester.ensureVisible(find.text('停用账户'));
      await tester.tap(find.text('停用账户'));
      await tester.pumpAndSettle();
      expect(find.textContaining('本地简历不会清空'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        transport.requests.any((entry) => entry.$1 == '/v2/account/deactivate'),
        isFalse,
      );
      await _tapAccountAction(tester, '返回账号');
      expect(find.text('我的账号'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('登录独立展示，国码默认86，显隐和返回不保留密码', (tester) async {
    final transport = _LifecycleTransport();
    await _openModernAccount(tester, transport);
    expect(find.text('验证码用途'), findsNothing);
    expect(find.textContaining('E.164'), findsNothing);
    expect(find.byKey(const Key('账户验证码')), findsNothing);
    expect(
      tester.widget<TextField>(find.byKey(const Key('账户区号'))).controller!.text,
      '+86',
    );
    await tester.enterText(find.byKey(const Key('账户手机号')), '13800000000');
    await tester.enterText(find.byKey(const Key('账户密码')), 'TestPass2026!');
    await tester.tap(find.byTooltip('显示密码'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byKey(const Key('账户密码'))).obscureText,
      isFalse,
    );
    await tester.ensureVisible(find.text('创建账号'));
    await tester.tap(find.text('创建账号'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('账户验证码')), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(const Key('账户密码'))).controller!.text,
      isEmpty,
    );
    await tester.ensureVisible(find.text('返回登录'));
    await tester.tap(find.text('返回登录'));
    await tester.pumpAndSettle();
    expect(find.text('欢迎回来'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(const Key('账户手机号'))).controller!.text,
      '13800000000',
    );
    expect(
      tester.widget<TextField>(find.byKey(const Key('账户密码'))).obscureText,
      isTrue,
    );
    expect(
      transport.requests.where((r) => r.$1 == '/v2/account-verifications'),
      isEmpty,
    );
  });

  testWidgets('加载不显示配置错误，加载完成后恢复登录', (tester) async {
    final transport = _LifecycleTransport()..optionsGate = Completer<void>();
    await _openModernAccount(tester, transport);
    expect(find.text('正在连接账号服务…'), findsOneWidget);
    expect(find.textContaining('配置读取失败'), findsNothing);
    final login = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '登录'),
    );
    expect(login.onPressed, isNull);
    transport.optionsGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('正在连接账号服务…'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '登录'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('无效输入不发请求，正常登录归一国码并只展示账号概览', (tester) async {
    final transport = _LifecycleTransport();
    final controller = await _openModernAccount(tester, transport);
    await tester.ensureVisible(find.text('登录'));
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();
    expect(find.text('请核对区号和手机号'), findsOneWidget);
    expect(
      transport.requests.where((r) => r.$1 == '/v2/account-sessions'),
      isEmpty,
    );
    await tester.enterText(find.byKey(const Key('账户手机号')), '13800000000');
    await tester.enterText(find.byKey(const Key('账户密码')), 'TestPass2026!');
    await tester.ensureVisible(find.text('登录'));
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();
    expect(controller.remoteAccountSnapshot.isSignedIn, isTrue);
    expect(
      transport.requests
          .firstWhere((r) => r.$1 == '/v2/account-sessions')
          .$2['phoneE164'],
      '+8613800000000',
    );
    expect(find.text('我的账号'), findsOneWidget);
    expect(find.byKey(const Key('账户密码')), findsNothing);
    await tester.ensureVisible(find.text('退出当前会话'));
    await tester.tap(find.text('退出当前会话'));
    await tester.pumpAndSettle();
    expect(controller.remoteAccountSnapshot.isSignedIn, isFalse);
    expect(find.text('欢迎回来'), findsOneWidget);
  });

  testWidgets('首次注册绑定用途，未知发送不自动重试，取消重试保持一次', (tester) async {
    final transport = _LifecycleTransport()
      ..failVerification = 'verification_delivery_unknown';
    await _openModernAccount(tester, transport);
    await tester.ensureVisible(find.text('创建账号'));
    await tester.tap(find.text('创建账号'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('账户手机号')), '13800000000');
    await tester.ensureVisible(find.text('获取验证码'));
    await tester.tap(find.text('获取验证码'));
    await tester.pumpAndSettle();
    final requests = transport.requests.where(
      (r) => r.$1 == '/v2/account-verifications',
    );
    expect(requests, hasLength(1));
    expect(requests.single.$2['purpose'], 'register');
    expect(find.byKey(const Key('账户验证码')), findsOneWidget);
    await tester.ensureVisible(find.text('重新尝试发送'));
    await tester.tap(find.text('重新尝试发送'));
    await tester.pumpAndSettle();
    expect(find.text('重新请求验证码？'), findsOneWidget);
    await tester.tap(find.text('继续等待'));
    await tester.pumpAndSettle();
    expect(
      transport.requests.where((r) => r.$1 == '/v2/account-verifications'),
      hasLength(1),
    );
  });

  testWidgets('找回只使用恢复码，不出现或发送短信验证码', (tester) async {
    final transport = _LifecycleTransport()..recoveryCodes = true;
    await _openModernAccount(tester, transport);
    await tester.ensureVisible(find.text('找回密码'));
    await tester.tap(find.text('找回密码'));
    await tester.pumpAndSettle();
    expect(find.text('获取验证码'), findsNothing);
    expect(find.byKey(const Key('账户验证码')), findsNothing);
    await tester.enterText(find.byKey(const Key('账户手机号')), '13800000000');
    await tester.enterText(find.byKey(const Key('账户新密码')), 'NewPass026!');
    await tester.enterText(find.byKey(const Key('账户确认密码')), 'NewPass026!');
    await tester.enterText(
      find.byKey(const Key('账户恢复码')),
      _syntheticRecoveryCode,
    );
    await tester.ensureVisible(find.text('重设密码'));
    await tester.tap(find.text('重设密码'));
    await tester.pumpAndSettle();
    expect(
      transport.requests.where((r) => r.$1 == '/v2/account-verifications'),
      isEmpty,
    );
    final request = transport.requests.singleWhere(
      (r) => r.$1 == '/v2/account/password-reset',
    );
    expect(request.$2['recoveryCode'], _syntheticRecoveryCode);
    expect(request.$2.containsKey('challengeId'), isFalse);
    expect(find.text('欢迎回来'), findsOneWidget);
  });

  testWidgets('恢复密码不一致时不提交，修正后只提交恢复码找回', (tester) async {
    final transport = _LifecycleTransport()..recoveryCodes = true;
    await _openModernAccount(tester, transport);
    await tester.ensureVisible(find.text('找回密码'));
    await tester.tap(find.text('找回密码'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('账户手机号')), '13800000000');
    await tester.enterText(find.byKey(const Key('账户新密码')), 'NewPass026!');
    await tester.enterText(find.byKey(const Key('账户确认密码')), 'WrongPass1');
    await tester.enterText(
      find.byKey(const Key('账户恢复码')),
      _syntheticRecoveryCode,
    );
    await tester.ensureVisible(find.text('重设密码'));
    await tester.tap(find.text('重设密码'));
    await tester.pumpAndSettle();
    expect(find.text('两次密码不一致，请重新核对'), findsOneWidget);
    expect(
      transport.requests.where((r) => r.$1 == '/v2/account/password-reset'),
      isEmpty,
    );
    await tester.ensureVisible(find.byKey(const Key('账户确认密码')));
    await tester.enterText(find.byKey(const Key('账户确认密码')), 'NewPass026!');
    await tester.ensureVisible(find.text('重设密码'));
    await tester.tap(find.text('重设密码'));
    await tester.pumpAndSettle();
    expect(
      transport.requests.where((r) => r.$1 == '/v2/account/password-reset'),
      hasLength(1),
    );
    expect(
      transport.requests.where((r) => r.$1 == '/v2/account-verifications'),
      isEmpty,
    );
  });
}

const _syntheticRecoveryCode = '00000000-11111111-22222222-33333333';

Future<ResumeWorkspaceController> _openModernAccount(
  WidgetTester tester,
  _LifecycleTransport transport, {
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  final database = LocalStorageDatabase.inMemory();
  final controller = _controller(database, _client(transport));
  await controller.initialize();
  await controller.setNetworkEnabled(true);
  addTearDown(() async {
    controller.dispose();
    await database.close();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.dark ? AppTheme.dark : AppTheme.light,
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
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  if (transport.optionsGate == null) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 300));
  }
  return controller;
}

void _setAccountViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
}

TextField _accountField(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(Key(key)));

FocusNode _accountInputFocus(WidgetTester tester, String key) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(EditableText),
      ),
    )
    .focusNode;

Future<void> _focusAccountField(WidgetTester tester, String key) async {
  _accountInputFocus(tester, key).requestFocus();
  await tester.pumpAndSettle();
  _expectAccountFieldVisible(tester, key);
}

Future<void> _nextAccountField(
  WidgetTester tester,
  String from,
  String to,
) async {
  expect(_accountField(tester, from).textInputAction, TextInputAction.next);
  await tester.testTextInput.receiveAction(TextInputAction.next);
  await tester.pumpAndSettle();
  _expectAccountFieldVisible(tester, to);
}

void _expectAccountFieldVisible(WidgetTester tester, String key) {
  final field = find.byKey(Key(key));
  expect(_accountInputFocus(tester, key).hasFocus, isTrue, reason: '$key应保持焦点');
  final decorator = find.descendant(
    of: field,
    matching: find.byType(InputDecorator),
  );
  final box = tester.renderObject<RenderBox>(decorator);
  final viewport = RenderAbstractViewport.of(box) as RenderBox;
  final viewportRect = viewport.localToGlobal(Offset.zero) & viewport.size;
  final usableScreen = Rect.fromLTWH(
    0,
    0,
    tester.view.physicalSize.width / tester.view.devicePixelRatio,
    (tester.view.physicalSize.height - tester.view.viewInsets.bottom) /
        tester.view.devicePixelRatio,
  );
  final visible = viewportRect.intersect(usableScreen);
  final decorationRect = box.localToGlobal(Offset.zero) & box.size;
  final label = _accountField(tester, key).decoration?.labelText;
  if (label != null) {
    final labelBox = tester.renderObject<RenderBox>(
      find
          .descendant(
            of: decorator,
            matching: find.text(label, findRichText: true),
          )
          .last,
    );
    final labelRect = MatrixUtils.transformRect(
      labelBox.getTransformTo(null),
      labelBox.paintBounds,
    );
    expect(
      labelRect.top,
      greaterThanOrEqualTo(visible.top - 1),
      reason: '$key浮动标签完整可读',
    );
  }
  final error = _accountField(tester, key).decoration?.errorText;
  if (error != null) {
    final paragraph = tester.renderObject<RenderParagraph>(
      find
          .descendant(
            of: decorator,
            matching: find.text(error, findRichText: true),
          )
          .last,
    );
    expect(paragraph.didExceedMaxLines, isFalse, reason: '$key的校验提示必须完整可读');
  }
  expect(
    decorationRect.top,
    greaterThanOrEqualTo(visible.top - 1),
    reason: '$key标签不能滚出实际视口',
  );
  expect(
    decorationRect.bottom,
    lessThanOrEqualTo(visible.bottom + 1),
    reason: '$key输入、说明和错误不能落在键盘下',
  );
  expect(decorationRect.left, greaterThanOrEqualTo(visible.left - 1));
  expect(decorationRect.right, lessThanOrEqualTo(visible.right + 1));
  final editable = find.descendant(
    of: field,
    matching: find.byType(EditableText),
  );
  expect(editable.hitTestable(), findsOneWidget, reason: '$key可视输入区必须可点击');
  final state = tester.state<EditableTextState>(editable);
  final selection = state.widget.controller.selection;
  expect(selection.isValid, isTrue);
  final caret = state.renderEditable.getLocalRectForCaret(selection.extent);
  final caretCenter = state.renderEditable.localToGlobal(caret.center);
  expect(
    visible.inflate(1).contains(caretCenter),
    isTrue,
    reason: '$key当前光标应位于键盘上方',
  );
}

Future<void> _tapAccountAction(WidgetTester tester, String label) async {
  // 导航和提交按钮允许用户主动滚动；字段定位断言不借此滚动。
  final target = find.text(label).last;
  if (target.hitTestable().evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target.hitTestable(),
      140,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }
  expect(target.hitTestable(), findsOneWidget);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

GatewayApiClient _client(_LifecycleTransport transport) => GatewayApiClient(
  baseUri: Uri.parse('https://synthetic.invalid'),
  transport: transport,
);

final class _LifecycleTransport implements GatewayHttpTransport {
  final requests = <(String, Map<String, Object?>)>[];
  Completer<void>? optionsGate;
  bool failRevoke = false;
  bool recoveryCodes = false;
  String? failVerification;
  String? lastToken;
  @override
  Future<GatewayHttpResponse> sendJson({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    Map<String, Object?>? jsonBody,
  }) async {
    requests.add((uri.path, jsonBody ?? {}));
    lastToken =
        headers['authorization']?.replaceFirst('Bearer ', '') ?? lastToken;
    var status = 200;
    final Map<String, Object?> body;
    if (uri.path == '/v1/guest/sessions') {
      body = {
        'protocolVersion': '0.1.0',
        'guestId': 'guest-synthetic',
        'sessionToken': 'guest-synthetic-token',
        'expiresAtUtc': DateTime.now()
            .toUtc()
            .add(const Duration(days: 1))
            .toIso8601String(),
      };
    } else if (uri.path == '/v1/guest/identity') {
      body = {'protocolVersion': '0.1.0', 'guestId': 'guest-synthetic'};
    } else if (uri.path == '/v2/account/options') {
      await optionsGate?.future;
      body = {
        'protocolVersion': '0.5.0',
        'developmentSms': true,
        'persistentLogin': false,
        'recoveryCodes': recoveryCodes,
      };
    } else if (uri.path == '/v2/account/recovery-code') {
      body = {
        'protocolVersion': '0.5.0',
        'recoveryCode': _syntheticRecoveryCode,
      };
    } else if (uri.path == '/v2/account-verifications' &&
        failVerification != null) {
      status = 503;
      body = {
        'error': {
          'code': failVerification!,
          'message': 'synthetic',
          'operationId': 'trace-synthetic',
          'retryable': false,
        },
      };
    } else if (uri.path == '/v2/account-verifications') {
      body = {
        'protocolVersion': '0.5.0',
        'challengeId': 'challenge-synthetic',
        'expiresAtUtc': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 5))
            .toIso8601String(),
        'developmentCode': '123456',
      };
    } else if (uri.path == '/v2/accounts') {
      body = {'protocolVersion': '0.5.0', 'accountId': 'account-synthetic'};
    } else if (uri.path == '/v2/account-sessions') {
      body = {
        'protocolVersion': '0.5.0',
        'sessionToken': 'synthetic-memory-token',
        'expiresAtUtc': DateTime.now()
            .toUtc()
            .add(const Duration(days: 30))
            .toIso8601String(),
      };
    } else if (uri.path == '/v1/account/identity') {
      body = {'protocolVersion': '0.4.0', 'accountId': 'account-synthetic'};
    } else if (uri.path == '/v1/account/privileges') {
      body = {
        'protocolVersion': '0.1.0',
        'accountId': 'account-synthetic',
        'role': 'member',
        'membership': 'none',
      };
    } else if (uri.path.startsWith('/v1/account/quota/')) {
      body = {
        'protocolVersion': '0.2.0',
        'capability': uri.path.split('/').last,
        'plan': 'free',
        'allowed': true,
        'reason': 'allowed',
        'remainingMonthlyBasicGenerations':
            uri.path.endsWith('basicResumeCompose')
            ? (lastToken?.startsWith('guest-') == true ? 1 : 9)
            : null,
        'monthlyLimit': lastToken?.startsWith('guest-') == true
            ? 1
            : (uri.path.endsWith('basicResumeCompose') ? 9 : 5),
        'remainingMonthlyGenerations': lastToken?.startsWith('guest-') == true
            ? 1
            : (uri.path.endsWith('basicResumeCompose') ? 9 : 5),
        'resetsAtUtc': '2026-10-31T16:00:00Z',
        'countingUnit': 'usableCandidate',
      };
    } else if (uri.path == '/v2/account-sessions/revoke' && failRevoke) {
      status = 503;
      body = {
        'error': {
          'code': 'account_service_unavailable',
          'message': 'synthetic',
          'operationId': 'trace-synthetic',
          'retryable': false,
        },
      };
    } else {
      body = {'protocolVersion': '0.5.0', 'status': 'completed'};
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
  GatewayApi api,
) {
  final repository = DriftResumeRepository(database);
  final audit = DriftAgentAuditRepository(database);
  final account = RemoteAccountService(gatewayApi: api);
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
