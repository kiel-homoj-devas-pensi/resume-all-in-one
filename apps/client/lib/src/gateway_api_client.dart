import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:resume_domain/resume_domain.dart';

import 'cloud_sync_contracts.dart';

const gatewayAccountProtocolVersion = '0.2.0';
const gatewayRemoteProtocolVersion = '0.3.0';
const task018FakePhoneProof = 'task018-fake-phone-proof';

enum GatewaySubscriptionPlan { free, pro }

enum GatewayAccountRole { member, admin }

enum GatewayMembership { none, permanent }

final class GatewayAccountPrivileges {
  const GatewayAccountPrivileges({
    required this.accountId,
    required this.role,
    required this.membership,
  });

  final String accountId;
  final GatewayAccountRole role;
  final GatewayMembership membership;
}

abstract interface class GatewayPrivilegesApi {
  /// Null means the server does not expose this capability, not a free plan.
  Future<GatewayAccountPrivileges?> readPrivileges({
    required String sessionToken,
  });
}

final class GatewayRightsRequestReceipt {
  const GatewayRightsRequestReceipt({
    required this.receipt,
    required this.expiresAtUtc,
  });
  final String receipt;
  final DateTime expiresAtUtc;
}

abstract interface class GatewayRightsRequestApi {
  Future<GatewayRightsRequestReceipt> issueRightsRequestReceipt({
    required String sessionToken,
    required String currentPassword,
  });
}

enum RemoteAiCapability {
  basicResumeCompose,
  targetedResumeOptimization,
  resumeOptimizationConversation,
}

final class GatewayGuestSession {
  const GatewayGuestSession({required this.guestId, required this.session});
  final String guestId;
  final GatewaySession session;
}

abstract interface class GatewayGuestApi {
  Future<GatewayGuestSession> createGuestSession(String installationSecret);
}

final class GatewaySession {
  const GatewaySession({required this.token, required this.expiresAtUtc});

  final String token;
  final DateTime expiresAtUtc;
}

final class GatewayAccessSnapshot {
  const GatewayAccessSnapshot({
    required this.capability,
    required this.plan,
    required this.allowed,
    required this.reason,
    required this.remainingMonthlyBasicGenerations,
    this.monthlyLimit,
    this.remainingMonthlyGenerations,
    this.resetsAtUtc,
    this.isUnlimited = false,
  });

  final RemoteAiCapability capability;
  final GatewaySubscriptionPlan plan;
  final bool allowed;
  final String reason;
  final int? remainingMonthlyBasicGenerations;
  final int? monthlyLimit;
  final int? remainingMonthlyGenerations;
  final DateTime? resetsAtUtc;
  final bool isUnlimited;
}

final class GatewayRemoteAiResponse {
  GatewayRemoteAiResponse({
    required this.operationId,
    required this.clientRequestId,
    required this.capability,
    required Map<String, Object?> output,
    required this.promptVersion,
    this.usesNetwork = true,
    this.aigcMetadata,
  }) : output = Map.unmodifiable(output);

  final String operationId;
  final String clientRequestId;
  final RemoteAiCapability capability;
  final Map<String, Object?> output;
  final String promptVersion;
  final bool usesNetwork;
  final ResumeAigcMetadata? aigcMetadata;
}

final class GatewayApiException implements Exception {
  const GatewayApiException({
    required this.code,
    required this.message,
    required this.retryable,
    this.statusCode,
    this.operationId,
    this.usageOperationId,
  });

  final String code;
  final String message;
  final bool retryable;
  final int? statusCode;
  final String? operationId;
  final String? usageOperationId;

  @override
  String toString() => 'GatewayApiException($code)';
}

final class GatewayHttpResponse {
  const GatewayHttpResponse({
    required this.statusCode,
    required this.bodyBytes,
    this.aigcMetadataHeaders = const [],
    this.aigcVersionHeaders = const [],
  });

  final int statusCode;
  final Uint8List bodyBytes;
  final List<String> aigcMetadataHeaders;
  final List<String> aigcVersionHeaders;
}

abstract interface class GatewayHttpTransport {
  Future<GatewayHttpResponse> sendJson({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    Map<String, Object?>? jsonBody,
  });

  void close();
}

abstract interface class GatewayApi {
  Future<void> registerFakeAccount({
    required String phoneE164,
    required String password,
  });

  Future<GatewaySession> createSession({
    required String phoneE164,
    required String password,
  });

  Future<GatewayAccessSnapshot> readAccess({
    required RemoteAiCapability capability,
    required String sessionToken,
  });

  Future<GatewayRemoteAiResponse> submitRemoteAiRequest({
    required String sessionToken,
    required String clientRequestId,
    required String idempotencyKey,
    required RemoteAiCapability capability,
    required Map<String, Object?> input,
  });

  void close();
}

final class GatewayOperationStatus {
  const GatewayOperationStatus({
    required this.usageOperationId,
    required this.status,
    required this.quotaOccupied,
    required this.nextAction,
  });
  final String? usageOperationId;
  final String status;
  final bool quotaOccupied;
  final String nextAction;
}

abstract interface class GatewayOperationApi {
  Future<String> readAccountId({required String sessionToken});
  Future<GatewayOperationStatus> lookupOperation({
    required String sessionToken,
    required RemoteAiCapability capability,
    String? usageOperationId,
    String? idempotencyKey,
  });
}

final class GatewayVerification {
  const GatewayVerification(
    this.challengeId,
    this.expiresAtUtc,
    this.developmentCode,
  );
  final String challengeId;
  final DateTime expiresAtUtc;
  final String? developmentCode;
}

enum GatewayAccountAction { revoke, changePassword, resetPassword, deactivate }

abstract interface class GatewayRecoveryApi {
  bool get recoveryCodesEnabled;
  Future<String> createRecoveryCode({
    required String sessionToken,
    required String currentPassword,
  });
}

abstract interface class GatewayAccountLifecycleApi {
  Future<bool> readDevelopmentSmsMode();
  Future<GatewayVerification> requestVerification(String phone, String purpose);
  Future<void> registerVerifiedAccount(
    String phone,
    String password,
    String challengeId,
    String code,
  );
  Future<GatewaySession> createVerifiedSession(String phone, String password);
  Future<void> manageAccount(
    GatewayAccountAction action,
    Map<String, Object?> fields, {
    String? sessionToken,
  });
}

abstract interface class GatewayOriginalResultApi {
  bool get originalResultRecoveryEnabled;
  Future<GatewayRemoteAiResponse> recoverOriginalResult({
    required String sessionToken,
    required String clientRequestId,
    required RemoteAiCapability capability,
    required String idempotencyKey,
  });
}

final class DartIoGatewayHttpTransport implements GatewayHttpTransport {
  DartIoGatewayHttpTransport({
    HttpClient? httpClient,
    this.requestTimeout = const Duration(seconds: 55),
    this.remoteAiRequestTimeout = const Duration(seconds: 135),
    this.maximumResponseBytes = 262144,
  }) : _httpClient = httpClient ?? HttpClient();

  final HttpClient _httpClient;
  final Duration requestTimeout;
  final Duration remoteAiRequestTimeout;
  final int maximumResponseBytes;

  @override
  Future<GatewayHttpResponse> sendJson({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    Map<String, Object?>? jsonBody,
  }) async {
    try {
      final httpRequest = await _httpClient
          .openUrl(method, uri)
          .timeout(requestTimeout);
      httpRequest.headers.contentType = ContentType.json;
      httpRequest.headers.set(HttpHeaders.acceptHeader, 'application/json');
      for (final requestHeader in headers.entries) {
        httpRequest.headers.set(requestHeader.key, requestHeader.value);
      }
      if (jsonBody != null) {
        final requestBytes = utf8.encode(jsonEncode(jsonBody));
        if (requestBytes.length > 65536) {
          throw const GatewayApiException(
            code: 'request_too_large',
            message: '请求内容超过 Gateway 上限',
            retryable: false,
          );
        }
        httpRequest.add(requestBytes);
      }
      // Only model generation needs the longer bounded wait; account and status
      // requests retain the normal transport timeout. Never retry on timeout.
      final responseTimeout =
          method == 'POST' && uri.path == '/v1/resume-ai/requests'
          ? remoteAiRequestTimeout
          : requestTimeout;
      final httpResponse = await httpRequest.close().timeout(responseTimeout);
      final responseBuilder = BytesBuilder(copy: false);
      var receivedBytes = 0;
      await for (final responseChunk in httpResponse.timeout(requestTimeout)) {
        receivedBytes += responseChunk.length;
        if (receivedBytes > maximumResponseBytes) {
          throw const GatewayApiException(
            code: 'response_too_large',
            message: 'Gateway 响应超过客户端上限',
            retryable: false,
          );
        }
        responseBuilder.add(responseChunk);
      }
      return GatewayHttpResponse(
        statusCode: httpResponse.statusCode,
        bodyBytes: responseBuilder.takeBytes(),
        aigcMetadataHeaders: List.unmodifiable(
          httpResponse.headers['x-resume-aigc'] ?? const <String>[],
        ),
        aigcVersionHeaders: List.unmodifiable(
          httpResponse.headers['x-resume-aigc-version'] ?? const <String>[],
        ),
      );
    } on GatewayApiException {
      rethrow;
    } on TimeoutException {
      throw const GatewayApiException(
        code: 'client_timeout',
        message: '连接 Gateway 超时',
        retryable: true,
      );
    } on SocketException {
      throw const GatewayApiException(
        code: 'gateway_unreachable',
        message: '无法连接 Gateway',
        retryable: true,
      );
    } on HttpException {
      throw const GatewayApiException(
        code: 'gateway_protocol_error',
        message: 'Gateway 连接协议失败',
        retryable: false,
      );
    }
  }

  @override
  void close() => _httpClient.close(force: true);
}

final class GatewayApiClient
    implements
        GatewayApi,
        GatewayGuestApi,
        GatewayOperationApi,
        GatewayOriginalResultApi,
        GatewayAccountLifecycleApi,
        GatewayPrivilegesApi,
        GatewayRecoveryApi,
        GatewayRightsRequestApi,
        GatewayCloudApi {
  GatewayApiClient({
    required Uri baseUri,
    required GatewayHttpTransport transport,
    bool allowInsecureHttp = false,
    this.originalResultRecoveryEnabled = false,
  }) : _baseUri = _validatedBaseUri(baseUri, allowInsecureHttp),
       _transport = transport;

  @override
  final bool originalResultRecoveryEnabled;
  final Uri _baseUri;
  final GatewayHttpTransport _transport;
  @override
  bool recoveryCodesEnabled = false;

  @override
  Future<GatewayRightsRequestReceipt> issueRightsRequestReceipt({
    required String sessionToken,
    required String currentPassword,
  }) async {
    final response = await _send(
      method: 'POST',
      path: '/v2/account/rights-request-receipt',
      sessionToken: sessionToken,
      body: {'protocolVersion': '0.5.0', 'currentPassword': currentPassword},
    );
    _expectExactKeys(response, const {
      'protocolVersion',
      'receipt',
      'expiresAtUtc',
    });
    final receipt = _expectNonEmptyString(response, 'receipt');
    final expiry = DateTime.tryParse(
      _expectNonEmptyString(response, 'expiresAtUtc'),
    );
    if (response['protocolVersion'] != '0.5.0' ||
        receipt.length > 2048 ||
        !RegExp(
          r'^rights-v1\.[A-Za-z0-9_-]+\.[0-9a-f]{64}$',
        ).hasMatch(receipt) ||
        expiry == null ||
        !expiry.isUtc) {
      throw _invalidResponse();
    }
    return GatewayRightsRequestReceipt(receipt: receipt, expiresAtUtc: expiry);
  }

  @override
  Future<String> createRecoveryCode({
    required String sessionToken,
    required String currentPassword,
  }) async {
    final response = await _send(
      method: 'POST',
      path: '/v2/account/recovery-code',
      sessionToken: sessionToken,
      body: {'protocolVersion': '0.5.0', 'currentPassword': currentPassword},
    );
    _expectExactKeys(response, const {'protocolVersion', 'recoveryCode'});
    final code = _expectNonEmptyString(response, 'recoveryCode');
    if (response['protocolVersion'] != '0.5.0' ||
        !RegExp(r'^[0-9A-F]{8}(?:-[0-9A-F]{8}){3}$').hasMatch(code)) {
      throw _invalidResponse();
    }
    return code;
  }

  @override
  Future<CloudSyncOptions> readCloudOptions() async {
    final response = await _send(
      method: 'GET',
      path: '/v1/cloud-resumes/options',
    );
    try {
      return CloudSyncOptions.fromJson(response);
    } on FormatException {
      throw _invalidResponse();
    }
  }

  @override
  Future<bool> readDevelopmentSmsMode() async {
    final response = await _send(
      method: 'GET',
      path: '/v2/account/options?features=recoveryCodes',
    );
    final knownFields = Map<String, Object?>.of(response)
      ..remove('recoveryCodes');
    _expectExactKeys(knownFields, const {
      'protocolVersion',
      'developmentSms',
      'persistentLogin',
    });
    if (response['protocolVersion'] != '0.5.0' ||
        response['developmentSms'] is! bool ||
        response['persistentLogin'] != false ||
        (response.containsKey('recoveryCodes') &&
            response['recoveryCodes'] is! bool)) {
      throw _invalidResponse();
    }
    recoveryCodesEnabled = response['recoveryCodes'] == true;
    return response['developmentSms']! as bool;
  }

  @override
  Future<GatewayVerification> requestVerification(
    String phone,
    String purpose,
  ) async {
    final response = await _send(
      method: 'POST',
      path: '/v2/account-verifications',
      body: {
        'protocolVersion': '0.5.0',
        'phoneE164': phone,
        'purpose': purpose,
      },
    );
    _expectExactKeys(response, const {
      'protocolVersion',
      'challengeId',
      'expiresAtUtc',
      'developmentCode',
    });
    final expiry = DateTime.tryParse(_expectString(response, 'expiresAtUtc'));
    final code = response['developmentCode'];
    if (response['protocolVersion'] != '0.5.0' ||
        expiry == null ||
        !expiry.isUtc ||
        (code != null &&
            (code is! String || !RegExp(r'^\d{6}$').hasMatch(code)))) {
      throw _invalidResponse();
    }
    return GatewayVerification(
      _expectNonEmptyString(response, 'challengeId'),
      expiry,
      code as String?,
    );
  }

  @override
  Future<void> registerVerifiedAccount(
    String phone,
    String password,
    String challengeId,
    String code,
  ) async {
    final response = await _send(
      method: 'POST',
      path: '/v2/accounts',
      body: {
        'protocolVersion': '0.5.0',
        'phoneE164': phone,
        'password': password,
        'challengeId': challengeId,
        'code': code,
      },
    );
    _expectExactKeys(response, const {'protocolVersion', 'accountId'});
    if (response['protocolVersion'] != '0.5.0') throw _invalidResponse();
    _expectNonEmptyString(response, 'accountId');
  }

  @override
  Future<GatewaySession> createVerifiedSession(
    String phone,
    String password,
  ) async {
    final response = await _send(
      method: 'POST',
      path: '/v2/account-sessions',
      body: {
        'protocolVersion': '0.5.0',
        'phoneE164': phone,
        'password': password,
      },
    );
    _expectExactKeys(response, const {
      'protocolVersion',
      'sessionToken',
      'expiresAtUtc',
    });
    final expiry = DateTime.tryParse(_expectString(response, 'expiresAtUtc'));
    if (response['protocolVersion'] != '0.5.0' ||
        expiry == null ||
        !expiry.isUtc) {
      throw _invalidResponse();
    }
    return GatewaySession(
      token: _expectNonEmptyString(response, 'sessionToken'),
      expiresAtUtc: expiry,
    );
  }

  @override
  Future<void> manageAccount(
    GatewayAccountAction action,
    Map<String, Object?> fields, {
    String? sessionToken,
  }) async {
    final path = switch (action) {
      GatewayAccountAction.revoke => '/v2/account-sessions/revoke',
      GatewayAccountAction.changePassword => '/v2/account/password',
      GatewayAccountAction.resetPassword => '/v2/account/password-reset',
      GatewayAccountAction.deactivate => '/v2/account/deactivate',
    };
    final response = await _send(
      method: 'POST',
      path: path,
      sessionToken: sessionToken,
      body: {...fields, 'protocolVersion': '0.5.0'},
    );
    _expectExactKeys(response, const {'protocolVersion', 'status'});
    if (response['protocolVersion'] != '0.5.0' ||
        response['status'] != 'completed') {
      throw _invalidResponse();
    }
  }

  @override
  Future<GatewayGuestSession> createGuestSession(
    String installationSecret,
  ) async {
    final response = await _send(
      method: 'POST',
      path: '/v1/guest/sessions',
      body: {'installationSecret': installationSecret},
    );
    _expectExactKeys(response, const {
      'protocolVersion',
      'guestId',
      'sessionToken',
      'expiresAtUtc',
    });
    final owner = _expectNonEmptyString(response, 'guestId');
    final token = _expectNonEmptyString(response, 'sessionToken');
    final expiry = DateTime.tryParse(_expectString(response, 'expiresAtUtc'));
    if (response['protocolVersion'] != '0.1.0' ||
        !owner.startsWith('guest-') ||
        !token.startsWith('guest-') ||
        expiry == null ||
        !expiry.isUtc) {
      throw _invalidResponse();
    }
    return GatewayGuestSession(
      guestId: owner,
      session: GatewaySession(token: token, expiresAtUtc: expiry),
    );
  }

  @override
  Future<String> readAccountId({required String sessionToken}) async {
    final response = await _send(
      method: 'GET',
      path: sessionToken.startsWith('guest-')
          ? '/v1/guest/identity'
          : '/v1/account/identity',
      sessionToken: sessionToken,
    );
    if (sessionToken.startsWith('guest-')) {
      _expectExactKeys(response, const {'protocolVersion', 'guestId'});
      if (response['protocolVersion'] != '0.1.0') throw _invalidResponse();
      return _expectNonEmptyString(response, 'guestId');
    }
    _expectExactKeys(response, const {'protocolVersion', 'accountId'});
    if (response['protocolVersion'] != '0.4.0') throw _invalidResponse();
    return _expectNonEmptyString(response, 'accountId');
  }

  @override
  Future<GatewayOperationStatus> lookupOperation({
    required String sessionToken,
    required RemoteAiCapability capability,
    String? usageOperationId,
    String? idempotencyKey,
  }) async {
    final response = await _send(
      method: 'POST',
      path: '/v1/resume-ai/operations/lookup',
      additionalHeaders: const {'X-Quota-Contract': 'usableCandidate.v1'},
      sessionToken: sessionToken,
      body: {
        'protocolVersion': '0.4.0',
        'capability': capability.name,
        'usageOperationId': ?usageOperationId,
        'idempotencyKey': ?idempotencyKey,
      },
    );
    _expectExactKeys(response, const {
      'protocolVersion',
      'traceId',
      'usageOperationId',
      'capability',
      'status',
      'quotaOccupied',
      'nextAction',
      'resultAvailable',
    });
    if (response['protocolVersion'] != '0.4.0' ||
        response['capability'] != capability.name ||
        response['resultAvailable'] != false ||
        response['quotaOccupied'] is! bool ||
        (response['usageOperationId'] != null &&
            response['usageOperationId'] is! String)) {
      throw _invalidResponse();
    }
    final status = _expectNonEmptyString(response, 'status');
    final nextAction = _expectNonEmptyString(response, 'nextAction');
    const actions = {
      'reserved': 'queryLater',
      'notFound': 'queryLater',
      'pendingReconciliation': 'reconcile',
      'committed': 'resultUnavailable',
      'released': 'explicitNewRequest',
    };
    final noCandidate =
        response['quotaOccupied'] == false &&
        ((status == 'committed' && nextAction == 'resultUnavailable') ||
            (status == 'pendingReconciliation' &&
                nextAction == 'explicitNewRequest'));
    if ((!noCandidate && actions[status] != nextAction) ||
        (status == 'notFound') != (response['usageOperationId'] == null) ||
        (!noCandidate &&
            response['quotaOccupied'] !=
                (status != 'released' && status != 'notFound'))) {
      throw _invalidResponse();
    }
    return GatewayOperationStatus(
      usageOperationId: response['usageOperationId'] as String?,
      status: status,
      quotaOccupied: response['quotaOccupied']! as bool,
      nextAction: nextAction,
    );
  }

  @override
  Future<void> registerFakeAccount({
    required String phoneE164,
    required String password,
  }) async {
    final responseJson = await _send(
      method: 'POST',
      path: '/v1/accounts',
      body: {
        'protocolVersion': gatewayAccountProtocolVersion,
        'phoneE164': phoneE164,
        'password': password,
        'verificationProof': task018FakePhoneProof,
      },
    );
    _expectExactKeys(responseJson, const {
      'protocolVersion',
      'accountId',
      'status',
    });
    if (_expectString(responseJson, 'protocolVersion') !=
            gatewayAccountProtocolVersion ||
        _expectString(responseJson, 'status') != 'registered') {
      throw _invalidResponse();
    }
    _expectNonEmptyString(responseJson, 'accountId');
  }

  @override
  Future<GatewaySession> createSession({
    required String phoneE164,
    required String password,
  }) async {
    final responseJson = await _send(
      method: 'POST',
      path: '/v1/account-sessions',
      body: {
        'protocolVersion': gatewayAccountProtocolVersion,
        'phoneE164': phoneE164,
        'password': password,
      },
    );
    _expectExactKeys(responseJson, const {
      'protocolVersion',
      'sessionToken',
      'expiresAtUtc',
    });
    if (_expectString(responseJson, 'protocolVersion') !=
        gatewayAccountProtocolVersion) {
      throw _invalidResponse();
    }
    final expiresAtUtc = DateTime.tryParse(
      _expectString(responseJson, 'expiresAtUtc'),
    );
    if (expiresAtUtc == null || !expiresAtUtc.isUtc) {
      throw _invalidResponse();
    }
    return GatewaySession(
      token: _expectNonEmptyString(responseJson, 'sessionToken'),
      expiresAtUtc: expiresAtUtc,
    );
  }

  @override
  Future<GatewayAccountPrivileges?> readPrivileges({
    required String sessionToken,
  }) async {
    if (sessionToken.startsWith('guest-')) return null;
    final response = await _transport.sendJson(
      method: 'GET',
      uri: _baseUri.resolve('/v1/account/privileges'),
      headers: {HttpHeaders.authorizationHeader: 'Bearer $sessionToken'},
    );
    // Older deployments do not have this optional endpoint.
    if (response.statusCode == 404) return null;
    final json = _decodeResponse(response.bodyBytes);
    if (response.statusCode != 200) {
      final error = _parseGatewayError(response.statusCode, json);
      if (response.statusCode == 503 &&
          error.code == 'account_privileges_unavailable') {
        return null;
      }
      throw error;
    }
    _expectExactKeys(json, const {
      'protocolVersion',
      'accountId',
      'role',
      'membership',
    });
    if (json['protocolVersion'] != '0.1.0') throw _invalidResponse();
    return GatewayAccountPrivileges(
      accountId: _expectNonEmptyString(json, 'accountId'),
      role: _enumByName(GatewayAccountRole.values, _expectString(json, 'role')),
      membership: _enumByName(
        GatewayMembership.values,
        _expectString(json, 'membership'),
      ),
    );
  }

  @override
  Future<GatewayAccessSnapshot> readAccess({
    required RemoteAiCapability capability,
    required String sessionToken,
  }) async {
    final responseJson = await _send(
      method: 'GET',
      path: '/v1/account/quota/${capability.name}',
      sessionToken: sessionToken,
    );
    _expectExactKeys(responseJson, {
      'protocolVersion',
      'capability',
      'plan',
      if (responseJson.containsKey('isUnlimited')) 'isUnlimited',
      'allowed',
      'reason',
      'remainingMonthlyBasicGenerations',
      'monthlyLimit',
      'remainingMonthlyGenerations',
      'resetsAtUtc',
      'countingUnit',
    });
    if (_expectString(responseJson, 'protocolVersion') !=
            gatewayAccountProtocolVersion ||
        _expectString(responseJson, 'capability') != capability.name) {
      throw _invalidResponse();
    }
    final planName = _expectString(responseJson, 'plan');
    final plan = _enumByName(GatewaySubscriptionPlan.values, planName);
    final allowed = responseJson['allowed'];
    final isUnlimited = responseJson.containsKey('isUnlimited')
        ? responseJson['isUnlimited']
        : false;
    final remaining = responseJson['remainingMonthlyBasicGenerations'];
    final limit = responseJson['monthlyLimit'];
    final resultRemaining = responseJson['remainingMonthlyGenerations'];
    final reset = DateTime.tryParse(_expectString(responseJson, 'resetsAtUtc'));
    if (allowed is! bool ||
        isUnlimited is! bool ||
        (remaining != null && (remaining is! int || remaining < 0)) ||
        limit is! int ||
        limit < 1 ||
        resultRemaining is! int ||
        resultRemaining < 0 ||
        resultRemaining > limit ||
        reset == null ||
        !reset.isUtc ||
        responseJson['countingUnit'] != 'usableCandidate' ||
        allowed != (isUnlimited || resultRemaining > 0) ||
        (isUnlimited && responseJson['reason'] != 'allowed')) {
      throw _invalidResponse();
    }
    return GatewayAccessSnapshot(
      capability: capability,
      plan: plan,
      allowed: allowed,
      reason: _expectNonEmptyString(responseJson, 'reason'),
      remainingMonthlyBasicGenerations: remaining as int?,
      monthlyLimit: limit,
      remainingMonthlyGenerations: resultRemaining,
      resetsAtUtc: reset,
      isUnlimited: isUnlimited,
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
    Map<String, Object?> responseJson;
    ResumeAigcMetadata? aigcMetadata;
    try {
      responseJson = await _send(
        method: 'POST',
        path: '/v1/resume-ai/requests',
        additionalHeaders: originalResultRecoveryEnabled
            ? const {'X-Result-Recovery': '0.1.0'}
            : null,
        sessionToken: sessionToken,
        body: {
          'protocolVersion': gatewayRemoteProtocolVersion,
          'clientRequestId': clientRequestId,
          'idempotencyKey': idempotencyKey,
          'capability': capability.name,
          'input': input,
        },
        onSuccessResponse: (response) {
          aigcMetadata = _readAigcHeaders(response);
        },
      );
    } on GatewayApiException catch (error) {
      if (!originalResultRecoveryEnabled ||
          !{
            'client_timeout',
            'gateway_unreachable',
            'gateway_protocol_error',
            'invalid_gateway_response',
          }.contains(error.code)) {
        rethrow;
      }
      // Recovery only reads the original task. Never resend the generation POST.
      try {
        return await recoverOriginalResult(
          sessionToken: sessionToken,
          clientRequestId: clientRequestId,
          capability: capability,
          idempotencyKey: idempotencyKey,
        );
      } on GatewayApiException {
        throw error;
      }
    }
    return _parseRemoteAiSuccess(
      responseJson,
      clientRequestId,
      capability,
      aigcMetadata: aigcMetadata,
    );
  }

  @override
  Future<GatewayRemoteAiResponse> recoverOriginalResult({
    required String sessionToken,
    required String clientRequestId,
    required RemoteAiCapability capability,
    required String idempotencyKey,
  }) async {
    if (!originalResultRecoveryEnabled) {
      throw const GatewayApiException(
        code: 'result_recovery_unavailable',
        message: '原任务恢复暂不可用',
        retryable: false,
      );
    }
    for (var attempt = 0; attempt < 12; attempt++) {
      ResumeAigcMetadata? aigcMetadata;
      final response = await _send(
        method: 'POST',
        path: '/v1/resume-ai/results/lookup',
        sessionToken: sessionToken,
        body: {
          'protocolVersion': '0.4.0',
          'capability': capability.name,
          'idempotencyKey': idempotencyKey,
        },
        onSuccessResponse: (response) {
          aigcMetadata = _readAigcHeaders(response);
          if (response.statusCode != 200 && aigcMetadata != null) {
            throw _invalidResponse();
          }
        },
      );
      if (response.length == 1 && response['status'] == 'pending') {
        await Future<void>.delayed(const Duration(seconds: 3));
        continue;
      }
      return _parseRemoteAiSuccess(
        response,
        clientRequestId,
        capability,
        aigcMetadata: aigcMetadata,
      );
    }
    throw const GatewayApiException(
      code: 'original_result_pending',
      message: 'AI仍在处理原任务，请稍后查看；本地简历未改变。',
      retryable: false,
    );
  }

  GatewayRemoteAiResponse _parseRemoteAiSuccess(
    Map<String, Object?> responseJson,
    String clientRequestId,
    RemoteAiCapability capability, {
    ResumeAigcMetadata? aigcMetadata,
  }) {
    _expectExactKeys(responseJson, const {
      'protocolVersion',
      'operationId',
      'clientRequestId',
      'capability',
      'status',
      'output',
      'execution',
    });
    if (_expectString(responseJson, 'protocolVersion') !=
            gatewayRemoteProtocolVersion ||
        _expectString(responseJson, 'clientRequestId') != clientRequestId ||
        _expectString(responseJson, 'capability') != capability.name ||
        _expectString(responseJson, 'status') != 'succeeded') {
      throw _invalidResponse();
    }
    final output = _expectMap(responseJson, 'output');
    final execution = _expectMap(responseJson, 'execution');
    _expectExactKeys(execution, const {'usesNetwork', 'promptVersion'});
    if (execution['usesNetwork'] is! bool) {
      throw _invalidResponse();
    }
    final operationId = _expectNonEmptyString(responseJson, 'operationId');
    if (aigcMetadata != null &&
        (execution['usesNetwork'] != true ||
            aigcMetadata.propagateId != operationId)) {
      throw _invalidResponse();
    }
    return GatewayRemoteAiResponse(
      operationId: operationId,
      clientRequestId: clientRequestId,
      capability: capability,
      output: output,
      promptVersion: _expectNonEmptyString(execution, 'promptVersion'),
      usesNetwork: execution['usesNetwork']! as bool,
      aigcMetadata: aigcMetadata,
    );
  }

  Future<Map<String, Object?>> _send({
    required String method,
    required String path,
    Map<String, Object?>? body,
    String? sessionToken,
    Map<String, String>? additionalHeaders,
    void Function(GatewayHttpResponse)? onSuccessResponse,
  }) async {
    final headers = <String, String>{
      if (path.startsWith('/v1/resume-ai/')) 'X-Operation-Protocol': '0.4.0',
      ...?additionalHeaders,
    };
    if (sessionToken != null) {
      headers[HttpHeaders.authorizationHeader] = 'Bearer $sessionToken';
    }
    final httpResponse = await _transport.sendJson(
      method: method,
      uri: _baseUri.resolve(path),
      headers: headers,
      jsonBody: body,
    );
    if (path.startsWith('/v1/cloud-resumes/') &&
        httpResponse.bodyBytes.length > 65536) {
      throw _invalidResponse();
    }
    final responseJson = _decodeResponse(httpResponse.bodyBytes);
    if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
      throw _parseGatewayError(httpResponse.statusCode, responseJson);
    }
    onSuccessResponse?.call(httpResponse);
    return responseJson;
  }

  @override
  void close() => _transport.close();
}

ResumeAigcMetadata? _readAigcHeaders(GatewayHttpResponse response) {
  final labels = response.aigcMetadataHeaders;
  final versions = response.aigcVersionHeaders;
  if (labels.isEmpty && versions.isEmpty) return null; // Legacy gateway.
  try {
    if (labels.length != 1 || versions.length != 1 || versions.single != '1') {
      throw const FormatException();
    }
    final encoded = labels.single;
    if (encoded.isEmpty ||
        encoded.length > 5462 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(encoded)) {
      throw const FormatException();
    }
    final bytes = base64Url.decode(base64Url.normalize(encoded));
    if (bytes.length > 4096 ||
        base64Url.encode(bytes).replaceAll('=', '') != encoded) {
      throw const FormatException();
    }
    final text = utf8.decode(bytes);
    final metadata = ResumeAigcMetadata.fromJson(jsonDecode(text));
    // This internal header has one canonical representation. Besides bounding
    // parsing, this rejects duplicate JSON keys without silently taking the last.
    if (metadata.toJsonString() != text) throw const FormatException();
    return metadata;
  } on FormatException {
    throw _invalidResponse();
  }
}

Uri _validatedBaseUri(Uri baseUri, bool allowInsecureHttp) {
  final validScheme =
      baseUri.scheme == 'https' ||
      (allowInsecureHttp && baseUri.scheme == 'http');
  if (!validScheme ||
      baseUri.host.isEmpty ||
      baseUri.hasQuery ||
      baseUri.hasFragment ||
      baseUri.userInfo.isNotEmpty) {
    throw ArgumentError.value(baseUri, 'baseUri', 'Gateway URL 无效');
  }
  return baseUri;
}

Map<String, Object?> _decodeResponse(Uint8List responseBytes) {
  try {
    final decoded = jsonDecode(utf8.decode(responseBytes));
    if (decoded is! Map<String, Object?>) {
      throw const FormatException();
    }
    return decoded;
  } on FormatException {
    throw _invalidResponse();
  }
}

GatewayApiException _parseGatewayError(
  int statusCode,
  Map<String, Object?> responseJson,
) {
  try {
    _expectExactKeys(responseJson, const {'error'});
    final error = _expectMap(responseJson, 'error');
    final allowedKeys = {
      'code',
      'message',
      'operationId',
      'retryable',
      if (error.containsKey('issues')) 'issues',
      if (error.containsKey('operationProtocolVersion')) ...{
        'operationProtocolVersion',
        'traceId',
        'usageOperationId',
      },
    };
    _expectExactKeys(error, allowedKeys);
    final retryable = error['retryable'];
    if (retryable is! bool) {
      throw const FormatException();
    }
    if (error.containsKey('operationProtocolVersion') &&
        (error['operationProtocolVersion'] != '0.4.0' ||
            error['traceId'] != error['operationId'] ||
            (error['usageOperationId'] != null &&
                error['usageOperationId'] is! String))) {
      throw const FormatException();
    }
    return GatewayApiException(
      statusCode: statusCode,
      code: _expectNonEmptyString(error, 'code'),
      message: _expectNonEmptyString(error, 'message'),
      operationId: _expectNonEmptyString(error, 'operationId'),
      usageOperationId: error['usageOperationId'] as String?,
      retryable: retryable,
    );
  } on GatewayApiException {
    rethrow;
  } on Object {
    return GatewayApiException(
      statusCode: statusCode,
      code: 'invalid_gateway_error',
      message: 'Gateway 返回了无法识别的错误',
      retryable: false,
    );
  }
}

Map<String, Object?> _expectMap(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value is! Map<String, Object?>) {
    throw _invalidResponse();
  }
  return value;
}

String _expectString(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value is! String) {
    throw _invalidResponse();
  }
  return value;
}

String _expectNonEmptyString(Map<String, Object?> source, String key) {
  final value = _expectString(source, key);
  if (value.trim().isEmpty) {
    throw _invalidResponse();
  }
  return value;
}

void _expectExactKeys(Map<String, Object?> source, Set<String> expectedKeys) {
  if (source.keys.toSet().difference(expectedKeys).isNotEmpty ||
      expectedKeys.difference(source.keys.toSet()).isNotEmpty) {
    throw _invalidResponse();
  }
}

T _enumByName<T extends Enum>(Iterable<T> candidates, String name) {
  for (final candidate in candidates) {
    if (candidate.name == name) {
      return candidate;
    }
  }
  throw _invalidResponse();
}

GatewayApiException _invalidResponse() => const GatewayApiException(
  code: 'invalid_gateway_response',
  message: 'Gateway 返回了无法验证的数据',
  retryable: false,
);
