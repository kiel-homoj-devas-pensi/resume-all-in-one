import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:resume_all_in_one_client/src/gateway_api_client.dart';
import 'package:resume_all_in_one_client/src/remote_account_service.dart';

void main() {
  const phone = '+15550001234';
  const password = 'TestPass2026!';
  final changed = isA<GatewayApiException>().having(
    (error) => error.code,
    'code',
    'account_session_changed',
  );
  Future<void> login(RemoteAccountService service) =>
      service.signIn(phoneE164: phone, password: password);

  test('退出后迟到的登录响应不能重新建立会话', () async {
    final api = _DelayedAccountApi()..sessionGate = Completer<GatewaySession>();
    final service = RemoteAccountService(gatewayApi: api);
    final pending = login(service);
    final rejected = expectLater(pending, throwsA(changed));
    service.signOutLocally();
    api.sessionGate!.complete(api.session('old'));
    await rejected;
    expect(service.snapshot.isSignedIn, isFalse);
    expect(api.accessCalls, 0);
  });

  test('旧登录身份查询迟到时不能覆盖新账号', () async {
    final api = _DelayedAccountApi()..identityGate = Completer<String>();
    final service = RemoteAccountService(gatewayApi: api);
    final first = login(service);
    final rejected = expectLater(first, throwsA(changed));
    await api.identityStarted.future;
    final oldGate = api.identityGate!;
    api.identityGate = null;
    await login(service);
    final owner = service.accountId;
    oldGate.complete('old-account');
    await rejected;
    expect(service.accountId, owner);
    expect(service.snapshot.isSignedIn, isTrue);
  });

  test('退出后旧访问决策不能恢复已退出的快照', () async {
    final api = _DelayedAccountApi();
    final service = RemoteAccountService(gatewayApi: api);
    await login(service);
    api.accessGate = Completer<void>();
    final pending = service.refreshAccess();
    final rejected = expectLater(pending, throwsA(changed));
    service.signOutLocally();
    api.accessGate!.complete();
    await rejected;
    expect(service.snapshot.isSignedIn, isFalse);
  });

  test('旧会话的迟到 401 不得让新账号退出', () async {
    final api = _DelayedAccountApi();
    final service = RemoteAccountService(gatewayApi: api);
    await login(service);
    api.accessGate = Completer<void>();
    final oldGate = api.accessGate!;
    final pending = service.refreshAccess();
    final rejected = expectLater(pending, throwsA(changed));
    api.accessGate = null;
    await login(service);
    final owner = service.accountId;
    oldGate.completeError(
      const GatewayApiException(
        code: 'unauthenticated',
        message: 'old session',
        statusCode: 401,
        retryable: false,
      ),
    );
    await rejected;
    expect(service.accountId, owner);
    expect(service.snapshot.isSignedIn, isTrue);
  });

  test('权限查询途中会话到期，拒绝迟到决策并清除会话', () async {
    var clock = DateTime.utc(2199, 12, 31);
    final api = _DelayedAccountApi();
    final service = RemoteAccountService(gatewayApi: api, clock: () => clock);
    await login(service);
    api.accessGate = Completer<void>();
    final pending = service.refreshAccess();
    final rejected = expectLater(
      pending,
      throwsA(
        isA<GatewayApiException>().having(
          (e) => e.code,
          'code',
          'unauthenticated',
        ),
      ),
    );
    clock = DateTime.utc(2200);
    api.accessGate!.complete();
    await rejected;
    expect(service.snapshot.isSignedIn, isFalse);
  });

  test('旧账号撤销会话的确认不能退出后来登录的账号', () async {
    final api = _DelayedAccountApi()..manageGate = Completer<void>();
    final service = RemoteAccountService(gatewayApi: api);
    await login(service);
    final pending = service.manageAccount(
      GatewayAccountAction.revoke,
      const {},
    );
    final rejected = expectLater(pending, throwsA(changed));
    await login(service);
    final owner = service.accountId;
    api.manageGate!.complete();
    await rejected;
    expect(service.accountId, owner);
    expect(service.snapshot.isSignedIn, isTrue);
  });

  test('切换账号后旧 AI 候选只记录原操作，不返回给当前账号', () async {
    final api = _DelayedAccountApi()
      ..remoteGate = Completer<GatewayRemoteAiResponse>();
    final service = RemoteAccountService(gatewayApi: api);
    await login(service);
    final owner = service.accountId;
    final pending = service.submitRemoteAiRequest(
      clientRequestId: 'original-client',
      idempotencyKey: 'original-key',
      capability: RemoteAiCapability.basicResumeCompose,
      input: const {'privateText': 'PRIVATE'},
    );
    final rejected = expectLater(pending, throwsA(changed));
    await api.remoteStarted.future;
    await login(service);
    api.remoteGate!.complete(
      GatewayRemoteAiResponse(
        operationId: 'original-operation',
        clientRequestId: 'original-client',
        capability: RemoteAiCapability.basicResumeCompose,
        output: const {'privateText': 'PRIVATE'},
        promptVersion: 'synthetic',
      ),
    );
    await rejected;
    expect(await service.readOperations(), isEmpty);
    final record = (await service.operationJournal.read()).single;
    expect(record.accountId, owner);
    expect(record.status, 'received');
    expect(record.usageOperationId, 'original-operation');
    expect(api.remoteCalls, 1);
    expect(service.snapshot.isSignedIn, isTrue);
  });
}

final class _DelayedAccountApi
    implements GatewayApi, GatewayOperationApi, GatewayAccountLifecycleApi {
  Completer<GatewaySession>? sessionGate;
  Completer<String>? identityGate;
  Completer<void>? accessGate;
  Completer<void>? manageGate;
  Completer<GatewayRemoteAiResponse>? remoteGate;
  final remoteStarted = Completer<void>();
  int remoteCalls = 0;
  final identityStarted = Completer<void>();
  int sessionCalls = 0;
  int accessCalls = 0;
  GatewaySession session(String token) =>
      GatewaySession(token: token, expiresAtUtc: DateTime.utc(2200));
  @override
  Future<GatewaySession> createSession({
    required String phoneE164,
    required String password,
  }) async => sessionGate?.future ?? session('session-${++sessionCalls}');
  @override
  Future<String> readAccountId({required String sessionToken}) async {
    if (!identityStarted.isCompleted) identityStarted.complete();
    return identityGate?.future ?? 'account-$sessionToken';
  }

  @override
  Future<GatewayAccessSnapshot> readAccess({
    required RemoteAiCapability capability,
    required String sessionToken,
  }) async {
    accessCalls++;
    await accessGate?.future;
    return GatewayAccessSnapshot(
      capability: capability,
      plan: GatewaySubscriptionPlan.free,
      allowed: true,
      reason: 'allowed',
      remainingMonthlyBasicGenerations: 10,
    );
  }

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
  }) async {
    remoteCalls++;
    if (!remoteStarted.isCompleted) remoteStarted.complete();
    return remoteGate!.future;
  }

  @override
  Future<GatewayOperationStatus> lookupOperation({
    required String sessionToken,
    required RemoteAiCapability capability,
    String? usageOperationId,
    String? idempotencyKey,
  }) async => throw UnimplementedError();
  @override
  void close() {}

  @override
  Future<bool> readDevelopmentSmsMode() async => true;
  @override
  Future<GatewaySession> createVerifiedSession(String phone, String password) =>
      createSession(phoneE164: phone, password: password);
  @override
  Future<void> manageAccount(
    GatewayAccountAction action,
    Map<String, Object?> fields, {
    String? sessionToken,
  }) async {
    await manageGate?.future;
  }

  @override
  Future<void> registerVerifiedAccount(
    String phone,
    String password,
    String challengeId,
    String code,
  ) async {}
  @override
  Future<GatewayVerification> requestVerification(
    String phone,
    String purpose,
  ) async => throw UnimplementedError();
}
