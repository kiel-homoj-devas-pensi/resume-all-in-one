import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:resume_all_in_one_client/src/gateway_api_client.dart';
import 'package:resume_all_in_one_client/src/remote_account_service.dart';

void main() {
  test('权利核验经独立接口发送密码和会话，不包含简历或其他账号资料', () async {
    final transport = _ReceiptTransport();
    final api = GatewayApiClient(
      baseUri: Uri.https('synthetic.invalid'),
      transport: transport,
    );
    final result = await api.issueRightsRequestReceipt(
      sessionToken: 'session-synthetic',
      currentPassword: 'SyntheticPass1!',
    );
    expect(transport.path, '/v2/account/rights-request-receipt');
    expect(transport.headers!['authorization'], 'Bearer session-synthetic');
    expect(transport.body, {
      'protocolVersion': '0.5.0',
      'currentPassword': 'SyntheticPass1!',
    });
    expect(result.receipt, startsWith('rights-v1.'));
    expect(result.expiresAtUtc, DateTime.utc(2030));
  });

  test('退出后的迟到核验回执不归属新会话，过期回执不被使用', () async {
    final api = _RightsApi();
    final account = RemoteAccountService(
      gatewayApi: api,
      clock: () => DateTime.utc(2026, 10, 20),
    );
    await account.signIn(phoneE164: '+15550001234', password: 'SyntheticPass1!');
    final pending = account.issueRightsRequestReceipt('SyntheticPass1!');
    account.signOutLocally();
    final rejected = expectLater(pending, throwsA(isA<GatewayApiException>()));
    api.result.complete(
      GatewayRightsRequestReceipt(
        receipt: 'synthetic',
        expiresAtUtc: DateTime.utc(2030),
      ),
    );
    await rejected;
    final expiredApi = _RightsApi();
    final expiredAccount = RemoteAccountService(
      gatewayApi: expiredApi,
      clock: () => DateTime.utc(2026, 10, 20),
    );
    await expiredAccount.signIn(
      phoneE164: '+15550001234',
      password: 'SyntheticPass1!',
    );
    expiredApi.result.complete(
      GatewayRightsRequestReceipt(
        receipt: 'synthetic',
        expiresAtUtc: DateTime.utc(2026, 10, 20),
      ),
    );
    await expectLater(
      expiredAccount.issueRightsRequestReceipt('SyntheticPass1!'),
      throwsA(isA<RemoteAccountInputException>()),
    );
  });
}

final class _ReceiptTransport implements GatewayHttpTransport {
  String? path;
  Map<String, String>? headers;
  Map<String, Object?>? body;
  @override
  Future<GatewayHttpResponse> sendJson({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    Map<String, Object?>? jsonBody,
  }) async {
    path = uri.path;
    this.headers = headers;
    body = jsonBody;
    return GatewayHttpResponse(
      statusCode: 200,
      bodyBytes: Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'protocolVersion': '0.5.0',
            'receipt': 'rights-v1.c3ludGhldGlj.${'a' * 64}',
            'expiresAtUtc': '2030-01-01T00:00:00Z',
          }),
        ),
      ),
    );
  }

  @override
  void close() {}
}

final class _RightsApi implements GatewayApi, GatewayRightsRequestApi {
  final result = Completer<GatewayRightsRequestReceipt>();
  @override
  Future<GatewayRightsRequestReceipt> issueRightsRequestReceipt({
    required String sessionToken,
    required String currentPassword,
  }) => result.future;
  @override
  Future<GatewaySession> createSession({
    required String phoneE164,
    required String password,
  }) async => GatewaySession(
    token: 'session-synthetic',
    expiresAtUtc: DateTime.utc(2030),
  );
  @override
  Future<GatewayAccessSnapshot> readAccess({
    required RemoteAiCapability capability,
    required String sessionToken,
  }) async => GatewayAccessSnapshot(
    capability: capability,
    plan: GatewaySubscriptionPlan.free,
    allowed: true,
    reason: 'synthetic',
    remainingMonthlyBasicGenerations: 9,
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
  }) => throw UnimplementedError();
  @override
  void close() {}
}
