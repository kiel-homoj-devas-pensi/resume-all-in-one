import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:resume_all_in_one_client/src/gateway_api_client.dart';
import 'package:resume_all_in_one_client/src/remote_account_service.dart';

void main() {
  Future<void> login(RemoteAccountService service) =>
      service.signIn(phoneE164: '+15550001234', password: 'TestPass2026!');
  final invalid = isA<GatewayApiException>().having(
    (e) => e.code,
    'code',
    'invalid_gateway_response',
  );
  final changed = isA<GatewayApiException>().having(
    (e) => e.code,
    'code',
    'account_session_changed',
  );

  test('普通登录不因相同号码文本自动获得管理员或永久权益', () async {
    final api = _PrivilegeApi();
    final service = RemoteAccountService(gatewayApi: api);
    await login(service);
    expect(service.snapshot.plan, GatewaySubscriptionPlan.free);
    expect(service.snapshot.privileges!.role, GatewayAccountRole.member);
    expect(service.snapshot.privileges!.membership, GatewayMembership.none);
  });

  test('已验证服务端永久会员显示pro且管理员角色独立保留', () async {
    final api = _PrivilegeApi()
      ..plan = GatewaySubscriptionPlan.pro
      ..role = GatewayAccountRole.admin
      ..membership = GatewayMembership.permanent;
    final service = RemoteAccountService(gatewayApi: api);
    await login(service);
    expect(service.snapshot.plan, GatewaySubscriptionPlan.pro);
    expect(service.snapshot.privileges!.role, GatewayAccountRole.admin);
    expect(
      service.snapshot.privileges!.membership,
      GatewayMembership.permanent,
    );
  });

  test('仅管理员角色不改变免费套餐访问决策', () async {
    final api = _PrivilegeApi()..role = GatewayAccountRole.admin;
    final service = RemoteAccountService(gatewayApi: api);
    await login(service);
    expect(service.snapshot.plan, GatewaySubscriptionPlan.free);
    expect(service.snapshot.privileges!.membership, GatewayMembership.none);
  });

  for (final mismatch in ['account', 'plan']) {
    test('权益与当前$mismatch不一致时拒绝建立会话', () async {
      final api = _PrivilegeApi();
      if (mismatch == 'account') {
        api.ownerOverride = 'different-account';
      } else {
        api.membership = GatewayMembership.permanent;
      }
      final service = RemoteAccountService(gatewayApi: api);
      await expectLater(login(service), throwsA(invalid));
      expect(service.snapshot.isSignedIn, isFalse);
      expect(service.snapshot.privileges, isNull);
    });
  }

  test('旧服务不提供权益时清除旧可选权益而非假定免费', () async {
    final api = _PrivilegeApi()
      ..plan = GatewaySubscriptionPlan.pro
      ..membership = GatewayMembership.permanent;
    final service = RemoteAccountService(gatewayApi: api);
    await login(service);
    api.unavailable = true;
    await service.refreshAccess();
    expect(service.snapshot.privileges, isNull);
    expect(service.snapshot.plan, GatewaySubscriptionPlan.pro);
  });

  for (final switchAccount in [false, true]) {
    test('权益响应迟到时不能恢复或覆盖会话，换账号=$switchAccount', () async {
      final api = _PrivilegeApi();
      final service = RemoteAccountService(gatewayApi: api);
      await login(service);
      final oldOwner = service.accountId;
      final gate = api.gate = Completer<GatewayAccountPrivileges?>();
      final started = api.started = Completer<void>();
      final pending = service.refreshAccess();
      final rejected = expectLater(pending, throwsA(changed));
      await started.future;
      service.signOutLocally();
      api.gate = null;
      if (switchAccount) await login(service);
      final currentOwner = service.accountId;
      gate.complete(
        GatewayAccountPrivileges(
          accountId: oldOwner!,
          role: GatewayAccountRole.admin,
          membership: GatewayMembership.permanent,
        ),
      );
      await rejected;
      expect(service.accountId, currentOwner);
      expect(service.snapshot.isSignedIn, switchAccount);
      expect(
        service.snapshot.privileges?.membership,
        switchAccount ? GatewayMembership.none : null,
      );
    });
  }

  test('真正的权益存储故障不被当成旧服务或免费状态', () async {
    final api = _PrivilegeApi()
      ..failure = const GatewayApiException(
        code: 'storage_unavailable',
        message: '暂时不可用',
        statusCode: 503,
        retryable: true,
      );
    final service = RemoteAccountService(gatewayApi: api);
    await expectLater(
      login(service),
      throwsA(
        isA<GatewayApiException>().having(
          (e) => e.code,
          'code',
          'storage_unavailable',
        ),
      ),
    );
    expect(service.snapshot.isSignedIn, isFalse);
  });

  for (final status in [404, 503]) {
    test('HTTP$status仅缺少接口或明确关闭能力才作为可选权益缺省', () async {
      final transport = _OneResponseTransport(
        status,
        status == 404
            ? {}
            : {
                'error': {
                  'code': 'account_privileges_unavailable',
                  'message': '未启用',
                  'retryable': false,
                  'operationId': 'synthetic-operation',
                },
              },
      );
      expect(
        await _client(transport).readPrivileges(sessionToken: 'session'),
        isNull,
      );
      expect(transport.method, 'GET');
      expect(transport.uri!.path, '/v1/account/privileges');
      expect(transport.headers!['authorization'], 'Bearer session');
      expect(transport.body, isNull);
    });
  }

  test('HTTP503存储失败必须向调用者传播', () async {
    final transport = _OneResponseTransport(503, {
      'error': {
        'code': 'storage_unavailable',
        'message': '暂时不可用',
        'retryable': true,
        'operationId': 'synthetic-operation',
      },
    });
    await expectLater(
      _client(transport).readPrivileges(sessionToken: 'session'),
      throwsA(
        isA<GatewayApiException>().having(
          (e) => e.code,
          'code',
          'storage_unavailable',
        ),
      ),
    );
  });

  for (final update in [
    {'protocolVersion': '0.2.0'},
    {'role': 'owner'},
    {'membership': 'infinite'},
    {'accountId': ''},
    {'unknown': true},
  ]) {
    test('权益HTTP响应严格拒绝无效协议或字段$update', () async {
      final transport = _OneResponseTransport(200, {
        'protocolVersion': '0.1.0',
        'accountId': 'account-1',
        'role': 'member',
        'membership': 'none',
        ...update,
      });
      await expectLater(
        _client(transport).readPrivileges(sessionToken: 'session'),
        throwsA(invalid),
      );
    });
  }
}

GatewayApiClient _client(GatewayHttpTransport transport) => GatewayApiClient(
  baseUri: Uri.parse('https://gateway.example'),
  transport: transport,
);

final class _OneResponseTransport implements GatewayHttpTransport {
  _OneResponseTransport(this.status, this.response);
  final int status;
  final Map<String, Object?> response;
  String? method;
  Uri? uri;
  Map<String, String>? headers;
  Map<String, Object?>? body;
  @override
  Future<GatewayHttpResponse> sendJson({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    Map<String, Object?>? jsonBody,
  }) async {
    this.method = method;
    this.uri = uri;
    this.headers = headers;
    body = jsonBody;
    return GatewayHttpResponse(
      statusCode: status,
      bodyBytes: Uint8List.fromList(utf8.encode(jsonEncode(response))),
    );
  }

  @override
  void close() {}
}

final class _PrivilegeApi
    implements GatewayApi, GatewayOperationApi, GatewayPrivilegesApi {
  GatewaySubscriptionPlan plan = GatewaySubscriptionPlan.free;
  GatewayAccountRole role = GatewayAccountRole.member;
  GatewayMembership membership = GatewayMembership.none;
  String? ownerOverride;
  bool unavailable = false;
  GatewayApiException? failure;
  Completer<GatewayAccountPrivileges?>? gate;
  Completer<void>? started;
  int sessions = 0;
  @override
  Future<GatewaySession> createSession({
    required String phoneE164,
    required String password,
  }) async => GatewaySession(
    token: 'session-${++sessions}',
    expiresAtUtc: DateTime.utc(2200),
  );
  @override
  Future<String> readAccountId({required String sessionToken}) async =>
      'account-$sessionToken';
  @override
  Future<GatewayAccountPrivileges?> readPrivileges({
    required String sessionToken,
  }) async {
    if (started != null && !started!.isCompleted) started!.complete();
    if (gate != null) return gate!.future;
    if (failure != null) throw failure!;
    return unavailable
        ? null
        : GatewayAccountPrivileges(
            accountId: ownerOverride ?? 'account-$sessionToken',
            role: role,
            membership: membership,
          );
  }

  @override
  Future<GatewayAccessSnapshot> readAccess({
    required RemoteAiCapability capability,
    required String sessionToken,
  }) async => GatewayAccessSnapshot(
    capability: capability,
    plan: plan,
    allowed: true,
    reason: 'allowed',
    remainingMonthlyBasicGenerations: 10,
  );
  @override
  Future<void> registerFakeAccount({
    required String phoneE164,
    required String password,
  }) async {}
  @override
  Future<GatewayRemoteAiResponse> submitRemoteAiRequest({
    required String sessionToken,
    required String clientRequestId,
    required String idempotencyKey,
    required RemoteAiCapability capability,
    required Map<String, Object?> input,
  }) async => throw UnimplementedError();
  @override
  Future<GatewayOperationStatus> lookupOperation({
    required String sessionToken,
    required RemoteAiCapability capability,
    String? usageOperationId,
    String? idempotencyKey,
  }) async => throw UnimplementedError();
  @override
  void close() {}
}
