import 'dart:convert';
import 'guest_credential_store.dart';
import 'package:crypto/crypto.dart';

import 'gateway_api_client.dart';
import 'cloud_sync_contracts.dart';
import 'remote_operation_journal.dart';
import 'account_password_policy.dart';

enum RemoteAccountSessionStatus { gatewayUnavailable, signedOut, signedIn }

final class RemoteAccountSnapshot {
  RemoteAccountSnapshot({
    required this.status,
    required this.maskedPhone,
    required this.sessionExpiresAtUtc,
    required this.plan,
    this.privileges,
    this.isGuest = false,
    this.accessVerified = true,
    required Map<RemoteAiCapability, GatewayAccessSnapshot> accessByCapability,
  }) : accessByCapability = Map.unmodifiable(accessByCapability);

  factory RemoteAccountSnapshot.gatewayUnavailable() => RemoteAccountSnapshot(
    status: RemoteAccountSessionStatus.gatewayUnavailable,
    maskedPhone: null,
    sessionExpiresAtUtc: null,
    plan: null,
    accessByCapability: const {},
  );

  factory RemoteAccountSnapshot.signedOut() => RemoteAccountSnapshot(
    status: RemoteAccountSessionStatus.signedOut,
    maskedPhone: null,
    sessionExpiresAtUtc: null,
    plan: null,
    accessByCapability: const {},
  );

  final RemoteAccountSessionStatus status;
  final String? maskedPhone;
  final DateTime? sessionExpiresAtUtc;
  final GatewaySubscriptionPlan? plan;
  final GatewayAccountPrivileges? privileges;
  final bool accessVerified;
  final bool isGuest;
  final Map<RemoteAiCapability, GatewayAccessSnapshot> accessByCapability;

  bool get isSignedIn => status == RemoteAccountSessionStatus.signedIn;
}

final class RemoteAccountInputException implements Exception {
  const RemoteAccountInputException(this.message);

  final String message;
}

final class RemoteAccountService {
  RemoteAccountService({
    required GatewayApi? gatewayApi,
    DateTime Function()? clock,
    RemoteOperationJournal? operationJournal,
    GuestCredentialStore? guestCredentialStore,
  }) : _gatewayApi = gatewayApi,
       _clock = clock ?? _utcNow,
       guestCredentialStore = guestCredentialStore ?? GuestCredentialStore(),
       operationJournal = operationJournal ?? RemoteOperationJournal(),
       _snapshot = gatewayApi == null
           ? RemoteAccountSnapshot.gatewayUnavailable()
           : RemoteAccountSnapshot.signedOut();

  final GatewayApi? _gatewayApi;
  final DateTime Function() _clock;
  final RemoteOperationJournal operationJournal;
  final GuestCredentialStore guestCredentialStore;
  bool _isGuest = false;
  bool get supportsGuest => _gatewayApi is GatewayGuestApi;
  String? _accountId;
  bool _requestInFlight = false;
  int _sessionGeneration = 0;
  String? operationTrackingWarning;
  String? get accountId => _accountId;
  int get sessionGeneration => _sessionGeneration;

  Future<List<RemoteOperationRecord>> readOperations() async {
    final generation = _sessionGeneration;
    final owner = _accountId;
    final records = await operationJournal.read();
    _requireGeneration(generation);
    return records.where((record) => record.accountId == owner).toList();
  }

  Future<GatewayOperationStatus> queryOperation(
    RemoteOperationRecord record,
  ) async {
    if (record.accountId != _accountId) {
      throw const RemoteAccountInputException('请登录发起操作的账号');
    }
    final api = _requireGateway();
    if (api is! GatewayOperationApi) {
      throw const RemoteAccountInputException('当前服务不支持操作查询');
    }
    final session = _requireActiveSession();
    final generation = _sessionGeneration;
    final status = await _withSession(
      session,
      generation,
      () => (api as GatewayOperationApi).lookupOperation(
        sessionToken: session.token,
        capability: record.capability,
        usageOperationId: record.usageOperationId,
        idempotencyKey: record.usageOperationId == null
            ? record.idempotencyKey
            : null,
      ),
    );
    await operationJournal.save(
      record.withStatus(
        !status.quotaOccupied &&
                status.nextAction == 'explicitNewRequest' &&
                status.status == 'pendingReconciliation'
            ? 'completedWithoutCandidate'
            : status.status,
        status.usageOperationId,
      ),
    );
    _requireCurrentSession(session, generation);
    return status;
  }

  GatewaySession? _session;
  RemoteAccountSnapshot _snapshot;

  RemoteAccountSnapshot get snapshot => _snapshot;

  bool get supportsLifecycle => _gatewayApi is GatewayAccountLifecycleApi;
  bool get supportsRightsRequests => _gatewayApi is GatewayRightsRequestApi;

  Future<GatewayRightsRequestReceipt> issueRightsRequestReceipt(
    String currentPassword,
  ) async {
    if (_isGuest) {
      throw const RemoteAccountInputException('游客或无法登录时，可直接通过邮箱提出请求并作必要人工核验。');
    }
    final api = _requireGateway();
    if (api is! GatewayRightsRequestApi) {
      throw const RemoteAccountInputException('当前服务暂不支持应用内权利请求核验，可直接通过邮箱申请。');
    }
    final session = _requireActiveSession();
    final generation = _sessionGeneration;
    final result = await _withSession(
      session,
      generation,
      () => (api as GatewayRightsRequestApi).issueRightsRequestReceipt(
        sessionToken: session.token,
        currentPassword: currentPassword,
      ),
    );
    _requireCurrentSession(session, generation);
    if (!result.expiresAtUtc.isAfter(_clock().toUtc())) {
      throw const RemoteAccountInputException('核验回执已过期，请重新核验，或直接通过邮箱提出请求。');
    }
    return result;
  }

  bool get supportsRecoveryCodes {
    final api = _gatewayApi;
    return api is GatewayRecoveryApi &&
        (api as GatewayRecoveryApi).recoveryCodesEnabled;
  }

  Future<String> createRecoveryCode(String currentPassword) async {
    if (_isGuest) throw const RemoteAccountInputException('游客没有账号密码或恢复码，请先注册');
    final session = _requireActiveSession();
    final generation = _sessionGeneration;
    final api = _requireGateway();
    if (api is! GatewayRecoveryApi || !supportsRecoveryCodes) {
      throw const RemoteAccountInputException('当前服务尚未开放恢复码，请稍后重试。');
    }
    final code = await (api as GatewayRecoveryApi).createRecoveryCode(
      sessionToken: session.token,
      currentPassword: currentPassword,
    );
    _requireCurrentSession(session, generation);
    return code;
  }

  GatewayAccountLifecycleApi _requireLifecycle() {
    final api = _requireGateway();
    if (api is! GatewayAccountLifecycleApi) {
      throw const RemoteAccountInputException('当前服务不支持验证码账户');
    }
    return api as GatewayAccountLifecycleApi;
  }

  Future<bool> readDevelopmentSmsMode() =>
      _requireLifecycle().readDevelopmentSmsMode();
  Future<GatewayVerification> requestVerification(
    String phone,
    String purpose,
  ) async {
    _validatePhone(phone);
    return _requireLifecycle().requestVerification(phone, purpose);
  }

  Future<void> registerVerified(
    String phone,
    String password,
    String challengeId,
    String code,
  ) async {
    _validatePhone(phone);
    if (!isValidNewPassword(password)) {
      throw const RemoteAccountInputException(newPasswordRule);
    }
    final generation = _beginSignIn();
    try {
      await _requireLifecycle().registerVerifiedAccount(
        phone,
        password,
        challengeId,
        code,
      );
    } on Object {
      _requireGeneration(generation);
      rethrow;
    }
    await _createSessionAndRefresh(
      gatewayApi: _requireGateway(),
      phoneE164: phone,
      password: password,
      generation: generation,
    );
  }

  Future<void> manageAccount(
    GatewayAccountAction action,
    Map<String, Object?> fields,
  ) async {
    if (_isGuest) throw const RemoteAccountInputException('游客没有手机号账号安全操作，请先注册');
    final generation = _sessionGeneration;
    final session = action == GatewayAccountAction.resetPassword
        ? null
        : _requireActiveSession();
    final token = action == GatewayAccountAction.resetPassword
        ? null
        : session!.token;
    try {
      await _requireLifecycle().manageAccount(
        action,
        fields,
        sessionToken: token,
      );
    } on Object {
      _requireGeneration(generation);
      rethrow;
    }
    _requireGeneration(generation);
    signOutLocally();
  }

  void _validatePhone(String phone) {
    if (!RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch(phone)) {
      throw const RemoteAccountInputException('请输入包含国家代码的 E.164 手机号');
    }
  }

  Future<void> registerAndSignIn({
    required String phoneE164,
    required String password,
  }) async {
    _validateDevelopmentPhone(phoneE164);
    if (!isValidNewPassword(password)) {
      throw const RemoteAccountInputException(newPasswordRule);
    }
    final gatewayApi = _requireGateway();
    final generation = _beginSignIn();
    try {
      await gatewayApi.registerFakeAccount(
        phoneE164: phoneE164,
        password: password,
      );
    } on Object {
      _requireGeneration(generation);
      rethrow;
    }
    await _createSessionAndRefresh(
      gatewayApi: gatewayApi,
      phoneE164: phoneE164,
      password: password,
      generation: generation,
    );
  }

  Future<void> startGuest() async {
    final api = _requireGateway();
    if (api is! GatewayGuestApi) {
      throw const RemoteAccountInputException('游客体验暂不可用');
    }
    final generation = _beginSignIn();
    try {
      final credential = await guestCredentialStore.getOrCreate();
      _requireGeneration(generation);
      final issued = await (api as GatewayGuestApi).createGuestSession(
        credential,
      );
      _requireGeneration(generation);
      if (!issued.session.expiresAtUtc.isAfter(_clock().toUtc())) {
        throw const RemoteAccountInputException('游客会话已失效，请重新进入');
      }
      _session = issued.session;
      _accountId = issued.guestId;
      _isGuest = true;
      await _refreshAccessWithSession(api, issued.session, generation);
    } on Object {
      _requireGeneration(generation);
      signOutLocally();
      rethrow;
    }
  }

  Future<void> signIn({
    required String phoneE164,
    required String password,
  }) async {
    if (!isValidNewPassword(password)) {
      throw const RemoteAccountInputException(newPasswordRule);
    }
    if (supportsLifecycle) {
      _validatePhone(phoneE164);
    } else {
      _validateDevelopmentPhone(phoneE164);
    }
    await _createSessionAndRefresh(
      gatewayApi: _requireGateway(),
      phoneE164: phoneE164,
      password: password,
      generation: _beginSignIn(),
    );
  }

  Future<void> refreshAccess() async {
    final session = _requireActiveSession();
    invalidateAccess();
    await _refreshAccessWithSession(
      _requireGateway(),
      session,
      _sessionGeneration,
    );
  }

  void invalidateAccess() {
    if (!_snapshot.isSignedIn) return;
    _snapshot = RemoteAccountSnapshot(
      status: _snapshot.status,
      isGuest: _isGuest,
      maskedPhone: _snapshot.maskedPhone,
      sessionExpiresAtUtc: _snapshot.sessionExpiresAtUtc,
      plan: null,
      accessVerified: false,
      accessByCapability: const {},
    );
  }

  /// Retrieves an existing task only; this path never posts a generation.
  Future<GatewayRemoteAiResponse> recoverOperationResult(
    RemoteOperationRecord record,
  ) async {
    if (record.accountId != _accountId) {
      throw const RemoteAccountInputException('请登录发起任务的账号');
    }
    final api = _requireGateway();
    if (api is! GatewayOriginalResultApi ||
        !(api as GatewayOriginalResultApi).originalResultRecoveryEnabled) {
      throw const RemoteAccountInputException('当前服务不支持原任务恢复');
    }
    if (_requestInFlight) {
      throw const RemoteAccountInputException('原任务正在处理，请稍后查看');
    }
    final session = _requireActiveSession();
    final generation = _sessionGeneration;
    _requestInFlight = true;
    try {
      final result = await (api as GatewayOriginalResultApi)
          .recoverOriginalResult(
            sessionToken: session.token,
            clientRequestId: record.clientRequestId,
            capability: record.capability,
            idempotencyKey: record.idempotencyKey,
          );
      _requireCurrentSession(session, generation);
      await operationJournal.save(
        record.withStatus('received', result.operationId),
      );
      _requireCurrentSession(session, generation);
      return result;
    } finally {
      _requestInFlight = false;
    }
  }

  Future<String?> originalRequestForMaterial({
    required RemoteAiCapability capability,
    required Map<String, Object?> input,
    String? documentId,
    String? baseVersionId,
  }) async {
    final fingerprint = _remoteInputFingerprint(
      capability,
      input,
      documentId,
      baseVersionId,
    );
    final records = await readOperations();
    return records
        .where(
          (record) =>
              record.capability == capability &&
              record.blocksNewRequest &&
              record.requestFingerprint == fingerprint,
        )
        .firstOrNull
        ?.clientRequestId;
  }

  Future<GatewayRemoteAiResponse> submitRemoteAiRequest({
    required String clientRequestId,
    required String idempotencyKey,
    required RemoteAiCapability capability,
    required Map<String, Object?> input,
    String? documentId,
    String? baseVersionId,
  }) async {
    final session = _requireActiveSession();
    final generation = _sessionGeneration;
    if (_requestInFlight) {
      throw const RemoteAccountInputException('当前联网请求尚未结束，请先等待或查询状态');
    }
    _requestInFlight = true;
    operationTrackingWarning = null;
    try {
      final accountId = _accountId;
      RemoteOperationRecord? record;
      if (accountId != null) {
        final fingerprint = _remoteInputFingerprint(
          capability,
          input,
          documentId,
          baseVersionId,
        );
        final previousOperations = await readOperations();
        if (previousOperations.any(
          (entry) =>
              (entry.clientRequestId == clientRequestId ||
                  entry.idempotencyKey == idempotencyKey) &&
              entry.requestFingerprint != null &&
              entry.requestFingerprint != fingerprint,
        )) {
          throw const RemoteAccountInputException('原任务编号不能用于不同材料；本地简历未改变。');
        }
        final unresolved = previousOperations.where(
          (entry) =>
              entry.blocksNewRequest &&
              (entry.clientRequestId == clientRequestId ||
                  entry.idempotencyKey == idempotencyKey ||
                  (entry.capability == capability &&
                      entry.requestFingerprint == fingerprint)),
        );
        if (unresolved.isNotEmpty) {
          final original = unresolved.first;
          final api = _requireGateway();
          if (api is GatewayOriginalResultApi &&
              (api as GatewayOriginalResultApi).originalResultRecoveryEnabled &&
              original.requestFingerprint == fingerprint) {
            try {
              final response = await (api as GatewayOriginalResultApi)
                  .recoverOriginalResult(
                    sessionToken: session.token,
                    clientRequestId: original.clientRequestId,
                    capability: original.capability,
                    idempotencyKey: original.idempotencyKey,
                  );
              _requireCurrentSession(session, generation);
              await operationJournal.save(
                original.withStatus('received', response.operationId),
              );
              _requireCurrentSession(session, generation);
              return response;
            } on GatewayApiException catch (error) {
              if (error.code == 'original_result_expired') {
                _requireCurrentSession(session, generation);
                await operationJournal.save(
                  original.withStatus('expired', original.usageOperationId),
                );
                throw const RemoteAccountInputException(
                  '原结果已超过24小时恢复保留期；输入草稿仍在，可以重新开始任务。',
                );
              }
              rethrow;
            }
          }
          throw const RemoteAccountInputException('原任务仍在恢复中，请稍后查看；不会重复生成。');
        }
        record = RemoteOperationRecord(
          accountId: accountId,
          clientRequestId: clientRequestId,
          idempotencyKey: idempotencyKey,
          capability: capability,
          documentId: documentId,
          baseVersionId: baseVersionId,
          status: 'sent',
          requestFingerprint: fingerprint,
        );
        await operationJournal.save(record);
      }
      _requireCurrentSession(session, generation);
      late GatewayRemoteAiResponse response;
      try {
        response = await _requireGateway().submitRemoteAiRequest(
          sessionToken: session.token,
          clientRequestId: clientRequestId,
          idempotencyKey: idempotencyKey,
          capability: capability,
          input: input,
        );
        if (record != null) {
          try {
            await operationJournal.save(
              record.withStatus('received', response.operationId),
            );
          } on Object {
            operationTrackingWarning = '已收到候选，但操作状态未能保存；重启后请查询原操作。';
          }
        }
      } on GatewayApiException catch (error) {
        if (record != null) {
          try {
            await operationJournal.save(
              record.withStatus(
                error.code == 'invalid_provider_response'
                    ? 'completedWithoutCandidate'
                    : {
                        'invalid_request',
                        'quota_exhausted',
                        'guest_temporarily_unavailable',
                        'trial_admission_closed',
                        'subscription_required',
                        'account_service_unavailable',
                        'result_recovery_unavailable',
                        'queue_full',
                        'unauthenticated',
                        'operation_released',
                      }.contains(error.code)
                    ? 'released'
                    : 'unknown',
                error.usageOperationId,
              ),
            );
          } on Object {
            operationTrackingWarning = '操作记录更新失败，已保留发送前的动作身份。';
          }
        }
        _requireCurrentSession(session, generation);
        rethrow;
      }
      _requireCurrentSession(session, generation);
      return response;
    } finally {
      _requestInFlight = false;
    }
  }

  void signOutLocally() {
    _sessionGeneration++;
    _session = null;
    _accountId = null;
    _isGuest = false;
    if (_gatewayApi != null) {
      _snapshot = RemoteAccountSnapshot.signedOut();
    }
  }

  void close() {
    signOutLocally();
    _gatewayApi?.close();
  }

  Future<void> _createSessionAndRefresh({
    required GatewayApi gatewayApi,
    required String phoneE164,
    required String password,
    required int generation,
  }) async {
    _requireGeneration(generation);
    try {
      final newSession = gatewayApi is GatewayAccountLifecycleApi
          ? await (gatewayApi as GatewayAccountLifecycleApi)
                .createVerifiedSession(phoneE164, password)
          : await gatewayApi.createSession(
              phoneE164: phoneE164,
              password: password,
            );
      _requireGeneration(generation);
      if (!newSession.expiresAtUtc.isAfter(_clock().toUtc())) {
        throw const GatewayApiException(
          code: 'invalid_gateway_response',
          message: 'Gateway 返回了已经过期的会话',
          retryable: false,
        );
      }
      _session = newSession;
      if (gatewayApi is GatewayOperationApi) {
        final owner = await (gatewayApi as GatewayOperationApi).readAccountId(
          sessionToken: newSession.token,
        );
        _requireCurrentSession(newSession, generation);
        _accountId = owner;
      }
      await _refreshAccessWithSession(gatewayApi, newSession, generation);
      _snapshot = RemoteAccountSnapshot(
        status: RemoteAccountSessionStatus.signedIn,
        isGuest: _isGuest,
        maskedPhone: _maskPhone(phoneE164),
        sessionExpiresAtUtc: newSession.expiresAtUtc,
        plan: _snapshot.plan,
        privileges: _snapshot.privileges,
        accessByCapability: _snapshot.accessByCapability,
      );
    } on Object {
      _requireGeneration(generation);
      signOutLocally();
      rethrow;
    }
  }

  Future<void> _refreshAccessWithSession(
    GatewayApi gatewayApi,
    GatewaySession session,
    int generation,
  ) async {
    final accessSnapshots = await _withSession(
      session,
      generation,
      () => Future.wait(
        RemoteAiCapability.values.map(
          (capability) => gatewayApi.readAccess(
            capability: capability,
            sessionToken: session.token,
          ),
        ),
      ),
    );
    final plans = accessSnapshots.map((snapshot) => snapshot.plan).toSet();
    if (plans.length != 1 ||
        (_isGuest && plans.single != GatewaySubscriptionPlan.free)) {
      throw const GatewayApiException(
        code: 'invalid_gateway_response',
        message: 'Gateway 套餐快照不一致',
        retryable: false,
      );
    }
    GatewayAccountPrivileges? privileges;
    if (!_isGuest && gatewayApi is GatewayPrivilegesApi) {
      privileges = await _withSession(
        session,
        generation,
        () => (gatewayApi as GatewayPrivilegesApi).readPrivileges(
          sessionToken: session.token,
        ),
      );
      if (privileges != null &&
          (privileges.accountId != _accountId ||
              (privileges.membership == GatewayMembership.permanent &&
                  plans.single != GatewaySubscriptionPlan.pro))) {
        throw const GatewayApiException(
          code: 'invalid_gateway_response',
          message: '账号权益与当前身份或访问状态不一致',
          retryable: false,
        );
      }
    }
    _snapshot = RemoteAccountSnapshot(
      status: RemoteAccountSessionStatus.signedIn,
      isGuest: _isGuest,
      maskedPhone: _snapshot.maskedPhone,
      sessionExpiresAtUtc: session.expiresAtUtc,
      plan: plans.single,
      privileges: privileges,
      accessByCapability: {
        for (final accessSnapshot in accessSnapshots)
          accessSnapshot.capability: accessSnapshot,
      },
    );
  }

  int _beginSignIn() {
    signOutLocally();
    return _sessionGeneration;
  }

  void _requireGeneration(int generation) {
    if (generation != _sessionGeneration) {
      throw const GatewayApiException(
        code: 'account_session_changed',
        message: '账号会话已改变，请在当前账号重新查看状态',
        retryable: false,
      );
    }
  }

  void _requireCurrentSession(GatewaySession session, int generation) {
    _requireGeneration(generation);
    if (!identical(_requireActiveSession(), session)) {
      throw StateError('Account session invariant violated');
    }
  }

  Future<T> _withSession<T>(
    GatewaySession session,
    int generation,
    Future<T> Function() operation,
  ) async {
    _requireCurrentSession(session, generation);
    final T result;
    try {
      result = await operation();
    } on Object {
      // 旧会话的 401 或超时不能让后来登录的账号退出。
      _requireCurrentSession(session, generation);
      rethrow;
    }
    _requireCurrentSession(session, generation);
    return result;
  }

  GatewaySession _requireActiveSession() {
    final session = _session;
    if (session == null) {
      throw const GatewayApiException(
        code: 'unauthenticated',
        message: '请先登录',
        retryable: false,
      );
    }
    if (!session.expiresAtUtc.isAfter(_clock().toUtc())) {
      signOutLocally();
      throw const GatewayApiException(
        code: 'unauthenticated',
        message: '会话已过期',
        retryable: false,
      );
    }
    return session;
  }

  GatewayApi _requireGateway() {
    final gatewayApi = _gatewayApi;
    if (gatewayApi == null) {
      throw const GatewayApiException(
        code: 'gateway_not_configured',
        message: '开发 Gateway 未配置',
        retryable: false,
      );
    }
    return gatewayApi;
  }

  Future<CloudSyncOptions> readCloudOptions() {
    final api = _requireGateway();
    if (api is! GatewayCloudApi) {
      throw const GatewayApiException(
        code: 'cloud_api_not_supported',
        message: '当前服务不支持云政策查询',
        retryable: false,
      );
    }
    return (api as GatewayCloudApi).readCloudOptions();
  }
}

void _validateDevelopmentPhone(String phoneE164) {
  if (!RegExp(r'^\+1555000[0-9]{4}$').hasMatch(phoneE164)) {
    throw const RemoteAccountInputException('开发期只接受 +1555000 开头的 12 位合成号码');
  }
}

String _maskPhone(String phoneE164) {
  final visibleSuffix = phoneE164.substring(phoneE164.length - 4);
  return '${phoneE164.substring(0, 4)}****$visibleSuffix';
}

DateTime _utcNow() => DateTime.now().toUtc();

String _remoteInputFingerprint(
  RemoteAiCapability capability,
  Map<String, Object?> input,
  String? documentId,
  String? baseVersionId,
) {
  Object? canonical(Object? value) {
    if (value is Map<String, Object?>) {
      final keys = value.keys.toList()..sort();
      return {for (final key in keys) key: canonical(value[key])};
    }
    if (value is List<Object?>) return value.map(canonical).toList();
    return value;
  }

  return sha256
      .convert(
        utf8.encode(
          jsonEncode(
            canonical({
              'capability': capability.name,
              // This client correlation token can change after restart. The
              // actual messages, saved version and material still define the task.
              'input':
                  capability ==
                      RemoteAiCapability.resumeOptimizationConversation
                  ? ({...input}..remove('conversationToken'))
                  : input,
              'documentId': documentId,
              'baseVersionId': baseVersionId,
            }),
          ),
        ),
      )
      .toString();
}
