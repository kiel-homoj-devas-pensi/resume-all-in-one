import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:resume_all_in_one_client/src/gateway_api_client.dart';

void main() {
  const sessionToken = 'only-in-memory-session-token';

  test('操作查询区分成果为0与模型仍待对账，显式声明新计数契约', () async {
    final transport = _RecordingGatewayTransport(
      responses: [
        _jsonResponse(200, {
          'protocolVersion': '0.4.0',
          'traceId': 'trace',
          'usageOperationId': 'op',
          'capability': 'basicResumeCompose',
          'status': 'pendingReconciliation',
          'quotaOccupied': false,
          'nextAction': 'explicitNewRequest',
          'resultAvailable': false,
        }),
      ],
    );
    final status = await _client(transport).lookupOperation(
      sessionToken: sessionToken,
      capability: RemoteAiCapability.basicResumeCompose,
      usageOperationId: 'op',
    );
    expect(status.status, 'pendingReconciliation');
    expect(status.quotaOccupied, isFalse);
    expect(
      transport.requests.single.headers['X-Quota-Contract'],
      'usableCandidate.v1',
    );
  });

  test(
    'guest API only sends anonymous credential and never requests account entitlements',
    () async {
      final transport = _RecordingGatewayTransport(
        responses: [
          _jsonResponse(200, {
            'protocolVersion': '0.1.0',
            'guestId': 'guest-synthetic',
            'sessionToken': 'guest-memory-token',
            'expiresAtUtc': '2030-01-01T00:00:00Z',
          }),
          _jsonResponse(200, {
            'protocolVersion': '0.1.0',
            'guestId': 'guest-synthetic',
          }),
        ],
      );
      final client = _client(transport);
      final issued = await client.createGuestSession('a' * 64);
      expect(issued.guestId, 'guest-synthetic');
      expect(
        await client.readPrivileges(sessionToken: issued.session.token),
        isNull,
      );
      expect(
        await client.readAccountId(sessionToken: issued.session.token),
        'guest-synthetic',
      );
      expect(transport.requests, hasLength(2));
      expect(transport.requests.first.uri.path, '/v1/guest/sessions');
      expect(transport.requests.last.uri.path, '/v1/guest/identity');
    },
  );

  for (final wrongTask in [false, true]) {
    test('生成连接丢失后只取回原任务，不重复生成且拒绝串结果 $wrongTask', () async {
      final transport = _LostResponseTransport(wrongTask: wrongTask);
      final api = GatewayApiClient(
        baseUri: Uri.parse('https://gateway.example'),
        transport: transport,
        originalResultRecoveryEnabled: true,
      );
      final result = api.submitRemoteAiRequest(
        sessionToken: sessionToken,
        clientRequestId: 'original-action',
        idempotencyKey: 'original-key',
        capability: RemoteAiCapability.basicResumeCompose,
        input: const {'sourceText': 'SYNTHETIC_PRIVATE_MATERIAL'},
      );
      if (wrongTask) {
        await expectLater(result, throwsA(isA<GatewayApiException>()));
      } else {
        expect((await result).operationId, 'original-operation');
      }
      expect(transport.requests.map((r) => r.uri.path), [
        '/v1/resume-ai/requests',
        '/v1/resume-ai/results/lookup',
      ]);
      expect(transport.requests.first.headers['X-Result-Recovery'], '0.1.0');
      expect(transport.requests.last.body, {
        'protocolVersion': '0.4.0',
        'capability': 'basicResumeCompose',
        'idempotencyKey': 'original-key',
      });
      expect(
        jsonEncode(transport.requests.last.body),
        isNot(contains('PRIVATE_MATERIAL')),
      );
    });
  }

  test('模型生成可有界等待慢响应，账号查询保持短超时且不重试', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final transport = DartIoGatewayHttpTransport(
      requestTimeout: const Duration(milliseconds: 100),
      remoteAiRequestTimeout: const Duration(seconds: 2),
    );
    addTearDown(() async {
      transport.close();
      await server.close(force: true);
    });
    var received = 0;
    server.listen((request) async {
      received++;
      await request.drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      try {
        request.response.write('{}');
        await request.response.close();
      } on Object {
        // The normal request has already timed out and closed its transport.
      }
    });
    Uri endpoint(String path) =>
        Uri.parse('http://127.0.0.1:${server.port}$path');
    final result = await transport.sendJson(
      method: 'POST',
      uri: endpoint('/v1/resume-ai/requests'),
      headers: const {},
    );
    expect(result.statusCode, 200);
    await expectLater(
      transport.sendJson(
        method: 'POST',
        uri: endpoint('/v1/resume-ai/operations/lookup'),
        headers: const {},
      ),
      throwsA(
        isA<GatewayApiException>().having(
          (e) => e.code,
          'code',
          'client_timeout',
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(received, 2, reason: '超时不能隐式重发模型或状态请求');
  });

  test('开发注册只发送合成身份协议要求的固定字段', () async {
    final transport = _RecordingGatewayTransport(
      responses: [_jsonResponse(201, _registeredResponse())],
    );
    final gatewayClient = _client(transport);

    await gatewayClient.registerFakeAccount(
      phoneE164: '+15550001234',
      password: 'TestPass2026!',
    );

    final request = transport.requests.single;
    expect(request.method, 'POST');
    expect(request.uri.path, '/v1/accounts');
    expect(request.headers, isEmpty);
    expect(request.body, {
      'protocolVersion': '0.2.0',
      'phoneE164': '+15550001234',
      'password': 'TestPass2026!',
      'verificationProof': 'task018-fake-phone-proof',
    });
  });

  test('登录解析 UTC 到期时间且客户端不持久化令牌', () async {
    final transport = _RecordingGatewayTransport(
      responses: [
        _jsonResponse(200, {
          'protocolVersion': '0.2.0',
          'sessionToken': sessionToken,
          'expiresAtUtc': '2026-11-02T08:00:00Z',
        }),
      ],
    );

    final session = await _client(
      transport,
    ).createSession(phoneE164: '+15550001234', password: 'TestPass2026!');

    expect(session.token, sessionToken);
    expect(session.expiresAtUtc, DateTime.utc(2026, 11, 2, 8));
  });

  test('访问决策使用会话 Bearer 且要求 capability 原样返回', () async {
    final transport = _RecordingGatewayTransport(
      responses: [
        _jsonResponse(200, {
          'protocolVersion': '0.2.0',
          'capability': 'basicResumeCompose',
          'plan': 'free',
          'allowed': true,
          'reason': 'allowed',
          'remainingMonthlyBasicGenerations': 7,
          'monthlyLimit': 9,
          'remainingMonthlyGenerations': 7,
          'resetsAtUtc': '2026-10-31T16:00:00Z',
          'countingUnit': 'usableCandidate',
        }),
      ],
    );

    final accessSnapshot = await _client(transport).readAccess(
      capability: RemoteAiCapability.basicResumeCompose,
      sessionToken: sessionToken,
    );

    expect(accessSnapshot.plan, GatewaySubscriptionPlan.free);
    expect(accessSnapshot.isUnlimited, isFalse);
    expect(accessSnapshot.remainingMonthlyBasicGenerations, 7);
    expect(accessSnapshot.monthlyLimit, 9);
    expect(accessSnapshot.remainingMonthlyGenerations, 7);
    expect(
      transport.requests.single.headers['authorization'],
      'Bearer $sessionToken',
    );
  });

  for (final token in [sessionToken, 'guest-in-memory-session']) {
    test('服务端允许不限次数时，零剩余额度也可用 $token', () async {
      final transport = _RecordingGatewayTransport(
        responses: [
          _jsonResponse(200, {
            'protocolVersion': '0.2.0',
            'capability': 'basicResumeCompose',
            'plan': 'free',
            'allowed': true,
            'reason': 'allowed',
            'remainingMonthlyBasicGenerations': 0,
            'monthlyLimit': 1,
            'remainingMonthlyGenerations': 0,
            'resetsAtUtc': '2026-10-31T16:00:00Z',
            'countingUnit': 'usableCandidate',
            'isUnlimited': true,
          }),
        ],
      );
      final access = await _client(transport).readAccess(
        capability: RemoteAiCapability.basicResumeCompose,
        sessionToken: token,
      );
      expect(access.allowed, isTrue);
      expect(access.isUnlimited, isTrue);
      expect(access.monthlyLimit, 1);
      expect(access.remainingMonthlyGenerations, 0);
      expect(
        transport.requests.single.headers['authorization'],
        'Bearer $token',
      );
    });
  }

  for (final invalid in [
    {'isUnlimited': true, 'allowed': false, 'reason': 'allowed'},
    {'isUnlimited': false, 'allowed': true, 'reason': 'allowed'},
    {'isUnlimited': true, 'allowed': true, 'reason': 'quota_exhausted'},
    {'isUnlimited': null, 'allowed': true, 'reason': 'allowed'},
    {'isUnlimited': 'true', 'allowed': true, 'reason': 'allowed'},
  ]) {
    test('不限次数仍拒绝冲突或无效服务器响应 $invalid', () async {
      final transport = _RecordingGatewayTransport(
        responses: [
          _jsonResponse(200, {
            'protocolVersion': '0.2.0',
            'capability': 'basicResumeCompose',
            'plan': 'free',
            'remainingMonthlyBasicGenerations': 0,
            'monthlyLimit': 9,
            'remainingMonthlyGenerations': 0,
            'resetsAtUtc': '2026-10-31T16:00:00Z',
            'countingUnit': 'usableCandidate',
            ...invalid,
          }),
        ],
      );
      await expectLater(
        _client(transport).readAccess(
          capability: RemoteAiCapability.basicResumeCompose,
          sessionToken: sessionToken,
        ),
        throwsA(
          isA<GatewayApiException>().having(
            (error) => error.code,
            'code',
            'invalid_gateway_response',
          ),
        ),
      );
    });
  }

  test('远程结果必须匹配请求 ID capability 与联网元数据', () async {
    final transport = _RecordingGatewayTransport(
      responses: [
        _jsonResponse(200, {
          'protocolVersion': '0.3.0',
          'operationId': 'operation-001',
          'clientRequestId': 'client-request-001',
          'capability': 'basicResumeCompose',
          'status': 'succeeded',
          'output': {
            'outputVersion': 'basicResumeCompose.v1',
            'summary': '已整理',
          },
          'execution': {
            'usesNetwork': true,
            'promptVersion': 'basic-resume-compose.v1',
          },
        }),
      ],
    );

    final remoteResponse = await _client(transport).submitRemoteAiRequest(
      sessionToken: sessionToken,
      clientRequestId: 'client-request-001',
      idempotencyKey: 'idempotency-001',
      capability: RemoteAiCapability.basicResumeCompose,
      input: {
        'inputType': 'basicResumeCompose',
        'sourceFragments': [
          {'fragmentId': 'fragment-001', 'text': '负责项目交付'},
        ],
      },
    );

    expect(remoteResponse.operationId, 'operation-001');
    expect(remoteResponse.promptVersion, 'basic-resume-compose.v1');
    expect(
      transport.requests.single.body?['idempotencyKey'],
      'idempotency-001',
    );
  });

  for (final usesNetwork in [true, false, 'false']) {
    test('执行元数据保留真假模型标识且拒绝非布尔值 $usesNetwork', () async {
      final transport = _RecordingGatewayTransport(
        responses: [
          _jsonResponse(200, {
            'protocolVersion': '0.3.0',
            'operationId': 'usage-synthetic',
            'clientRequestId': 'action-synthetic',
            'capability': 'basicResumeCompose',
            'status': 'succeeded',
            'output': {'outputVersion': 'basicResumeCompose.v1'},
            'execution': {
              'usesNetwork': usesNetwork,
              'promptVersion': 'synthetic.v1',
            },
          }),
        ],
      );
      final response = _client(transport).submitRemoteAiRequest(
        sessionToken: sessionToken,
        clientRequestId: 'action-synthetic',
        idempotencyKey: 'key-synthetic',
        capability: RemoteAiCapability.basicResumeCompose,
        input: const {},
      );
      if (usesNetwork is bool) {
        expect((await response).usesNetwork, usesNetwork);
      } else {
        await expectLater(response, throwsA(isA<GatewayApiException>()));
      }
    });
  }

  test('错误包络转换成不包含正文的稳定异常', () async {
    final transport = _RecordingGatewayTransport(
      responses: [
        _jsonResponse(429, {
          'error': {
            'code': 'quota_exhausted',
            'message': '免费账号本月基础生成额度已用完',
            'operationId': 'operation-002',
            'retryable': false,
          },
        }),
      ],
    );

    await expectLater(
      _client(transport).readAccess(
        capability: RemoteAiCapability.basicResumeCompose,
        sessionToken: sessionToken,
      ),
      throwsA(
        isA<GatewayApiException>()
            .having((error) => error.code, 'code', 'quota_exhausted')
            .having((error) => error.statusCode, 'statusCode', 429)
            .having(
              (error) => error.toString().contains('免费账号'),
              'toString 不含服务端消息',
              isFalse,
            ),
      ),
    );
  });

  for (final errorCase in const [
    (statusCode: 401, code: 'unauthenticated'),
    (statusCode: 403, code: 'subscription_required'),
    (statusCode: 409, code: 'idempotency_conflict'),
    (statusCode: 429, code: 'quota_exhausted'),
    (statusCode: 502, code: 'invalid_provider_response'),
    (statusCode: 503, code: 'provider_unavailable'),
    (statusCode: 504, code: 'provider_timeout'),
  ]) {
    test('${errorCase.statusCode} 错误保持稳定分类且不回显服务端正文', () async {
      final transport = _RecordingGatewayTransport(
        responses: [
          _jsonResponse(errorCase.statusCode, {
            'error': {
              'code': errorCase.code,
              'message': '不应显示的服务端正文与用户数据',
              'operationId': 'operation-error',
              'retryable': errorCase.statusCode >= 500,
            },
          }),
        ],
      );

      await expectLater(
        _client(transport).readAccess(
          capability: RemoteAiCapability.basicResumeCompose,
          sessionToken: sessionToken,
        ),
        throwsA(
          isA<GatewayApiException>()
              .having((error) => error.code, 'code', errorCase.code)
              .having(
                (error) => error.statusCode,
                'statusCode',
                errorCase.statusCode,
              )
              .having(
                (error) => error.toString().contains('用户数据'),
                'toString 不含服务端正文',
                isFalse,
              ),
        ),
      );
    });
  }

  test('非法 JSON 响应被固定归类且不暴露响应正文', () async {
    final transport = _RecordingGatewayTransport(
      responses: [
        GatewayHttpResponse(
          statusCode: 200,
          bodyBytes: Uint8List.fromList(utf8.encode('{用户简历正文')),
        ),
      ],
    );

    await expectLater(
      _client(transport).readAccess(
        capability: RemoteAiCapability.basicResumeCompose,
        sessionToken: sessionToken,
      ),
      throwsA(
        isA<GatewayApiException>()
            .having((error) => error.code, 'code', 'invalid_gateway_response')
            .having(
              (error) => error.toString().contains('用户简历正文'),
              'toString 不含响应正文',
              isFalse,
            ),
      ),
    );
  });

  test('响应额外字段和非 HTTPS 生产地址均被拒绝', () async {
    final transport = _RecordingGatewayTransport(
      responses: [
        _jsonResponse(200, {..._registeredResponse(), 'unexpected': true}),
      ],
    );

    await expectLater(
      _client(transport).registerFakeAccount(
        phoneE164: '+15550001234',
        password: 'TestPass2026!',
      ),
      throwsA(
        isA<GatewayApiException>().having(
          (error) => error.code,
          'code',
          'invalid_gateway_response',
        ),
      ),
    );
    expect(
      () => GatewayApiClient(
        baseUri: Uri.parse('http://gateway.example'),
        transport: transport,
      ),
      throwsArgumentError,
    );
  });
}

GatewayApiClient _client(_RecordingGatewayTransport transport) {
  return GatewayApiClient(
    baseUri: Uri.parse('https://gateway.example'),
    transport: transport,
  );
}

Map<String, Object?> _registeredResponse() => {
  'protocolVersion': '0.2.0',
  'accountId': 'account-001',
  'status': 'registered',
};

GatewayHttpResponse _jsonResponse(int statusCode, Map<String, Object?> body) {
  return GatewayHttpResponse(
    statusCode: statusCode,
    bodyBytes: Uint8List.fromList(utf8.encode(jsonEncode(body))),
  );
}

final class _RecordedRequest {
  const _RecordedRequest({
    required this.method,
    required this.uri,
    required this.headers,
    required this.body,
  });

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Map<String, Object?>? body;
}

final class _RecordingGatewayTransport implements GatewayHttpTransport {
  _RecordingGatewayTransport({required List<GatewayHttpResponse> responses})
    : _responses = List.of(responses);

  final List<GatewayHttpResponse> _responses;
  final List<_RecordedRequest> requests = [];

  @override
  Future<GatewayHttpResponse> sendJson({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    Map<String, Object?>? jsonBody,
  }) async {
    requests.add(
      _RecordedRequest(
        method: method,
        uri: uri,
        headers: Map.of(headers),
        body: jsonBody == null ? null : Map.of(jsonBody),
      ),
    );
    return _responses.removeAt(0);
  }

  @override
  void close() {}
}

final class _LostResponseTransport implements GatewayHttpTransport {
  _LostResponseTransport({required this.wrongTask});
  final bool wrongTask;
  final requests = <_RecordedRequest>[];
  @override
  Future<GatewayHttpResponse> sendJson({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    Map<String, Object?>? jsonBody,
  }) async {
    requests.add(
      _RecordedRequest(
        method: method,
        uri: uri,
        headers: headers,
        body: jsonBody,
      ),
    );
    if (uri.path == '/v1/resume-ai/requests') {
      throw const GatewayApiException(
        code: 'client_timeout',
        message: 'lost response',
        retryable: false,
      );
    }
    return _jsonResponse(200, {
      'protocolVersion': '0.3.0',
      'operationId': 'original-operation',
      'clientRequestId': wrongTask ? 'another-action' : 'original-action',
      'capability': 'basicResumeCompose',
      'status': 'succeeded',
      'output': {'outputVersion': 'basicResumeCompose.v1'},
      'execution': {
        'usesNetwork': true,
        'promptVersion': 'basic-resume-compose.v8',
      },
    });
  }

  @override
  void close() {}
}
