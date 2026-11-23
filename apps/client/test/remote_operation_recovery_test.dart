import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resume_all_in_one_client/src/gateway_api_client.dart';
import 'package:resume_all_in_one_client/src/remote_account_service.dart';
import 'package:resume_all_in_one_client/src/remote_operation_journal.dart';

void main() {
  test('试用关闭是未执行，不留未知任务或自动查询重发', () async {
    final gateway = _TrialClosedGateway();
    final account = RemoteAccountService(gatewayApi: gateway);
    await account.signIn(phoneE164: '+15550001234', password: 'TestPass2026!');
    await expectLater(
      account.submitRemoteAiRequest(
        clientRequestId: 'trial-closed',
        idempotencyKey: 'trial-closed-key',
        capability: RemoteAiCapability.basicResumeCompose,
        input: const {'sourceText': '合成经历'},
      ),
      throwsA(
        isA<GatewayApiException>().having(
          (error) => error.code,
          'code',
          'trial_admission_closed',
        ),
      ),
    );
    final record = (await account.readOperations()).single;
    expect(record.status, 'released');
    expect(record.blocksNewRequest, isFalse);
    expect(gateway.calls, 1);
    expect(gateway.lookupKey, isNull);
  });
  test(
    'explicit task recovery only retrieves original response and rejects another owner',
    () async {
      final gateway = _RecoverableTrackingGateway();
      final account = RemoteAccountService(gatewayApi: gateway);
      await account.signIn(
        phoneE164: '+15550001234',
        password: 'TestPass2026!',
      );
      await expectLater(
        account.submitRemoteAiRequest(
          clientRequestId: 'original',
          idempotencyKey: 'key-original',
          capability: RemoteAiCapability.basicResumeCompose,
          input: const {'sourceText': '合成经历'},
        ),
        throwsA(isA<GatewayApiException>()),
      );
      final original = (await account.readOperations()).single;
      final response = await account.recoverOperationResult(original);
      expect(response.operationId, 'usage-original');
      expect(gateway.calls, 1);
      expect(gateway.recoveryCalls, 1);
      expect((await account.readOperations()).single.status, 'received');
      account.signOutLocally();
      gateway.owner = 'another-owner';
      await account.signIn(
        phoneE164: '+15550004321',
        password: 'TestPass2026!',
      );
      await expectLater(
        account.recoverOperationResult(original),
        throwsA(isA<RemoteAccountInputException>()),
      );
      expect(gateway.recoveryCalls, 1);
      expect(gateway.calls, 1);
    },
  );

  test('一个未知任务不锁住不同材料，原记录和未知状态保留', () async {
    final gateway = _TrackingGateway();
    final account = RemoteAccountService(gatewayApi: gateway);
    await account.signIn(phoneE164: '+15550001234', password: 'TestPass2026!');
    Future<GatewayRemoteAiResponse> submit(String id, String text) =>
        account.submitRemoteAiRequest(
          clientRequestId: id,
          idempotencyKey: 'key-$id',
          capability: RemoteAiCapability.basicResumeCompose,
          input: {'sourceText': text},
        );
    await expectLater(
      submit('first', '第一项合成材料'),
      throwsA(isA<GatewayApiException>()),
    );
    await expectLater(
      submit('second', '另一项合成材料'),
      throwsA(isA<GatewayApiException>()),
    );
    expect(gateway.calls, 2);
    final records = await account.readOperations();
    expect(records, hasLength(2));
    expect(records.map((r) => r.status), everyElement('unknown'));
    expect(records.map((r) => r.idempotencyKey), ['key-first', 'key-second']);
    await expectLater(
      submit('first', '已改变的材料'),
      throwsA(isA<RemoteAccountInputException>()),
    );
    expect(gateway.calls, 2, reason: '不能将旧编号用于不同材料');
  });

  test('相同材料换动作编号仍取回原结果，不新增模型调用或覆盖原记录', () async {
    final gateway = _RecoverableTrackingGateway();
    final account = RemoteAccountService(gatewayApi: gateway);
    await account.signIn(phoneE164: '+15550001234', password: 'TestPass2026!');
    Future<GatewayRemoteAiResponse> submit(String id) =>
        account.submitRemoteAiRequest(
          clientRequestId: id,
          idempotencyKey: 'key-$id',
          capability: RemoteAiCapability.basicResumeCompose,
          input: const {'sourceText': '同一项合成材料'},
        );
    await expectLater(submit('original'), throwsA(isA<GatewayApiException>()));
    final result = await submit('another-local-click');
    expect(result.operationId, 'usage-original');
    expect(gateway.calls, 1);
    expect(gateway.recoveryCalls, 1);
    final record = (await account.readOperations()).single;
    expect(record.clientRequestId, 'original');
    expect(record.idempotencyKey, 'key-original');
    expect(record.status, 'received');
  });

  test('已完成的原结果过期只终结恢复，不在查询中另开生成', () async {
    final gateway = _RecoverableTrackingGateway(expired: true);
    final account = RemoteAccountService(gatewayApi: gateway);
    await account.signIn(phoneE164: '+15550001234', password: 'TestPass2026!');
    Future<GatewayRemoteAiResponse> submit(String id) =>
        account.submitRemoteAiRequest(
          clientRequestId: id,
          idempotencyKey: 'key-$id',
          capability: RemoteAiCapability.basicResumeCompose,
          input: const {'sourceText': '同一项已过期材料'},
        );
    await expectLater(submit('original'), throwsA(isA<GatewayApiException>()));
    await expectLater(
      submit('recover'),
      throwsA(isA<RemoteAccountInputException>()),
    );
    expect(gateway.calls, 1);
    expect(gateway.recoveryCalls, 1);
    final record = (await account.readOperations()).single;
    expect(record.status, 'expired');
    expect(record.idempotencyKey, 'key-original');
    expect(record.blocksNewRequest, isFalse);
  });

  test('重启后的会话标记和JSON字段顺序不使同一轮材料重复计费', () async {
    final gateway = _RecoverableTrackingGateway();
    final account = RemoteAccountService(gatewayApi: gateway);
    await account.signIn(phoneE164: '+15550001234', password: 'TestPass2026!');
    Future<GatewayRemoteAiResponse> submit(
      String id,
      Map<String, Object?> input,
    ) => account.submitRemoteAiRequest(
      clientRequestId: id,
      idempotencyKey: 'key-$id',
      capability: RemoteAiCapability.resumeOptimizationConversation,
      documentId: 'document',
      baseVersionId: 'version',
      input: input,
    );
    await expectLater(
      submit('original', const {
        'conversationToken': 'before-restart',
        'userMessage': '简化表达',
        'recentMessages': [
          {'role': 'user', 'content': '原材料'},
        ],
      }),
      throwsA(isA<GatewayApiException>()),
    );
    await submit('reopened', const {
      'recentMessages': [
        {'content': '原材料', 'role': 'user'},
      ],
      'userMessage': '简化表达',
      'conversationToken': 'after-restart',
    });
    expect(gateway.calls, 1);
    expect(gateway.recoveryCalls, 1);
    await expectLater(
      submit('changed', const {
        'recentMessages': [
          {'content': '原材料', 'role': 'user'},
        ],
        'userMessage': '强调项目分工',
        'conversationToken': 'after-restart',
      }),
      throwsA(isA<GatewayApiException>()),
    );
    expect(gateway.calls, 2, reason: '真正改变材料的独立任务仍能执行');
  });

  test('丢失响应重启后凭原动作查询，换账号不见原记录且不自动重发', () async {
    final directory = await Directory.systemTemp.createTemp(
      'operation-recovery-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final gateway = _TrackingGateway();
    RemoteAccountService open() => RemoteAccountService(
      gatewayApi: gateway,
      operationJournal: RemoteOperationJournal(
        rootDirectory: () async => directory,
      ),
    );
    final first = open();
    await first.signIn(phoneE164: '+15550001234', password: 'TestPass2026!');
    Future<GatewayRemoteAiResponse> submit(RemoteAccountService service) =>
        service.submitRemoteAiRequest(
          clientRequestId: 'action-1',
          idempotencyKey: 'stable-key-1',
          capability: RemoteAiCapability.basicResumeCompose,
          input: const {'privateText': 'PRIVATE_RESUME_MUST_NOT_PERSIST'},
        );
    await expectLater(submit(first), throwsA(isA<GatewayApiException>()));
    expect(gateway.calls, 1);
    first.signOutLocally();
    final reopened = open();
    await reopened.signIn(phoneE164: '+15550001234', password: 'TestPass2026!');
    final record = (await reopened.readOperations()).single;
    expect(record.idempotencyKey, 'stable-key-1');
    expect(record.usageOperationId, isNull);
    await expectLater(
      submit(reopened),
      throwsA(isA<RemoteAccountInputException>()),
    );
    expect((await reopened.queryOperation(record)).status, 'committed');
    expect(gateway.lookupKey, 'stable-key-1');
    expect(gateway.calls, 1);
    await expectLater(
      submit(reopened),
      throwsA(isA<RemoteAccountInputException>()),
    );
    gateway.owner = 'another-account';
    reopened.signOutLocally();
    await reopened.signIn(phoneE164: '+15550004321', password: 'TestPass2026!');
    expect(await reopened.readOperations(), isEmpty);
    await expectLater(
      reopened.queryOperation(record),
      throwsA(isA<RemoteAccountInputException>()),
    );
    final saved = await File(
      '${directory.path}/remote_operations_v1.json',
    ).readAsString();
    for (final secret in [
      'PRIVATE_RESUME',
      'TestPass2026!',
      'session-secret',
      '+1555000',
    ]) {
      expect(saved, isNot(contains(secret)));
    }
  });

  test('发送前恢复记录无法落盘时不调用模型', () async {
    final gateway = _TrackingGateway();
    final account = RemoteAccountService(
      gatewayApi: gateway,
      operationJournal: RemoteOperationJournal(
        rootDirectory: () async =>
            throw const FileSystemException('disk unavailable'),
      ),
    );
    await account.signIn(phoneE164: '+15550001234', password: 'TestPass2026!');
    await expectLater(
      account.submitRemoteAiRequest(
        clientRequestId: 'action-2',
        idempotencyKey: 'stable-key-2',
        capability: RemoteAiCapability.basicResumeCompose,
        input: const {},
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(gateway.calls, 0);
  });

  test('并发写入记录重启后都保留，损坏文件不会被默认为空', () async {
    final directory = await Directory.systemTemp.createTemp(
      'operation-journal-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final journal = RemoteOperationJournal(
      rootDirectory: () async => directory,
    );
    await Future.wait([
      for (var i = 0; i < 2; i++)
        journal.save(
          RemoteOperationRecord(
            accountId: 'owner',
            clientRequestId: 'action-$i',
            idempotencyKey: 'key-$i',
            capability: RemoteAiCapability.basicResumeCompose,
            documentId: null,
            baseVersionId: null,
            status: 'unknown',
          ),
        ),
    ]);
    expect(
      await RemoteOperationJournal(rootDirectory: () async => directory).read(),
      hasLength(2),
    );
    await File(
      '${directory.path}/remote_operations_v1.json',
    ).writeAsString('{broken');
    await expectLater(
      RemoteOperationJournal(rootDirectory: () async => directory).read(),
      throwsA(isA<FormatException>()),
    );
  });
}

final class _TrialClosedGateway extends _TrackingGateway {
  @override
  Future<GatewayRemoteAiResponse> submitRemoteAiRequest({
    required String sessionToken,
    required String clientRequestId,
    required String idempotencyKey,
    required RemoteAiCapability capability,
    required Map<String, Object?> input,
  }) async {
    calls++;
    throw const GatewayApiException(
      code: 'trial_admission_closed',
      message: 'closed',
      retryable: false,
    );
  }
}

class _TrackingGateway implements GatewayApi, GatewayOperationApi {
  int calls = 0;
  String owner = 'account-owner';
  String? lookupKey;
  @override
  Future<String> readAccountId({required String sessionToken}) async => owner;
  @override
  Future<GatewayOperationStatus> lookupOperation({
    required String sessionToken,
    required RemoteAiCapability capability,
    String? usageOperationId,
    String? idempotencyKey,
  }) async {
    lookupKey = idempotencyKey;
    return const GatewayOperationStatus(
      usageOperationId: 'usage-original',
      status: 'committed',
      quotaOccupied: true,
      nextAction: 'resultUnavailable',
    );
  }

  @override
  Future<void> registerFakeAccount({
    required String phoneE164,
    required String password,
  }) async {}
  @override
  Future<GatewaySession> createSession({
    required String phoneE164,
    required String password,
  }) async =>
      GatewaySession(token: 'session-secret', expiresAtUtc: DateTime.utc(2030));
  @override
  Future<GatewayAccessSnapshot> readAccess({
    required RemoteAiCapability capability,
    required String sessionToken,
  }) async => GatewayAccessSnapshot(
    capability: capability,
    plan: GatewaySubscriptionPlan.free,
    allowed: true,
    reason: 'allowed',
    remainingMonthlyBasicGenerations: 10,
  );
  @override
  Future<GatewayRemoteAiResponse> submitRemoteAiRequest({
    required String sessionToken,
    required String clientRequestId,
    required String idempotencyKey,
    required RemoteAiCapability capability,
    required Map<String, Object?> input,
  }) async {
    calls++;
    throw const GatewayApiException(
      code: 'client_timeout',
      message: 'lost response',
      retryable: true,
    );
  }

  @override
  void close() {}
}

final class _RecoverableTrackingGateway extends _TrackingGateway
    implements GatewayOriginalResultApi {
  _RecoverableTrackingGateway({this.expired = false});
  final bool expired;
  int recoveryCalls = 0;
  @override
  bool get originalResultRecoveryEnabled => true;
  @override
  Future<GatewayRemoteAiResponse> recoverOriginalResult({
    required String sessionToken,
    required String clientRequestId,
    required RemoteAiCapability capability,
    required String idempotencyKey,
  }) async {
    recoveryCalls++;
    if (expired) {
      throw const GatewayApiException(
        code: 'original_result_expired',
        message: 'original completed result expired',
        retryable: false,
      );
    }
    return GatewayRemoteAiResponse(
      operationId: 'usage-original',
      clientRequestId: clientRequestId,
      capability: capability,
      output: const {},
      promptVersion: 'synthetic.v1',
      usesNetwork: true,
    );
  }
}
