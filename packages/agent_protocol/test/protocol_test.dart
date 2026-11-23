import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('Agent Protocol v0.1', () {
    test('AgentRequest 可以 round-trip 且约束不可修改', () {
      final mutableConstraints = <String, Object?>{
        'language': 'zh-CN',
        'rules': <Object?>['offline'],
      };
      final request = AgentRequest(
        requestId: 'request-001',
        conversationId: 'conversation-001',
        resumeVersionId: 'version-001',
        intent: '检查简历',
        constraints: mutableConstraints,
        privacyMode: AgentPrivacyMode.localOnly,
      );

      mutableConstraints['language'] = 'en';
      final roundTrip = AgentRequest.fromJson(request.toJson());

      expect(roundTrip.constraints['language'], 'zh-CN');
      expect(() => roundTrip.constraints['new'] = true, throwsUnsupportedError);
      expect(roundTrip.toJson(), request.toJson());
    });

    test('AgentPlan 与 AgentResponse 可以结构化 round-trip', () {
      final call = _call('call-001');
      final plan = AgentPlan(
        actions: [call],
        requiresConfirmation: true,
        riskLevel: AgentRiskLevel.medium,
      );
      final response = AgentResponse(
        summary: '已生成待审阅修改',
        proposedPatch: const {'operations': <Object?>[]},
        warnings: const ['必须确认后保存'],
        nextAction: AgentNextAction.reviewPatch,
      );

      expect(AgentPlan.fromJson(plan.toJson()).toJson(), plan.toJson());
      expect(
        AgentResponse.fromJson(response.toJson()).toJson(),
        response.toJson(),
      );
    });

    test('Tool 描述与结果可以 round-trip', () {
      final descriptor = ToolDescriptor(
        name: 'read_resume',
        version: currentAgentProtocolVersion,
        inputSchema: const {'type': 'object'},
        outputSchema: const {'type': 'object'},
        permission: ToolPermission.resumeRead,
        access: ToolAccess.read,
        usesNetwork: false,
        retryable: true,
        timeoutMs: 5000,
        auditFields: const ['toolName'],
      );
      final now = DateTime.utc(2026, 10, 2, 8, 0, 0, 123, 456);
      final result = ToolResult(
        callId: 'call-001',
        status: ToolResultStatus.success,
        data: const {'ok': true},
        validationIssues: const [
          ProtocolValidationIssue(
            path: '/profile/fullName',
            severity: ProtocolValidationSeverity.warning,
            ruleId: 'profile.name.recommended',
            message: '建议填写姓名',
            blocksAction: false,
          ),
        ],
        auditInfo: ToolAuditInfo(
          toolName: descriptor.name,
          toolVersion: descriptor.version,
          startedAt: now,
          finishedAt: now,
          offline: true,
          idempotencyKey: 'key-001',
          replayed: false,
        ),
      );

      expect(
        ToolDescriptor.fromJson(descriptor.toJson()).toJson(),
        descriptor.toJson(),
      );
      expect(ToolResult.fromJson(result.toJson()).toJson(), result.toJson());
    });

    test('确认命令与结果可以 round-trip', () {
      final command = ConfirmationCommand(
        confirmationId: 'confirmation-001',
        decision: ConfirmationDecision.accept,
      );
      final result = ConfirmationResult(
        confirmationId: command.confirmationId,
        status: ConfirmationStatus.accepted,
        newVersionId: 'version-002',
        replayed: false,
      );

      expect(
        ConfirmationCommand.fromJson(command.toJson()).toJson(),
        command.toJson(),
      );
      expect(
        ConfirmationResult.fromJson(result.toJson()).toJson(),
        result.toJson(),
      );
    });

    test('未知字段、未知枚举和空 ID 被拒绝', () {
      final unknownField = _call('call-001').toJson()..['extra'] = true;
      final unknownEnum = AgentRequest(
        requestId: 'request-001',
        conversationId: 'conversation-001',
        resumeVersionId: 'version-001',
        intent: '检查简历',
        privacyMode: AgentPrivacyMode.localOnly,
      ).toJson()..['privacyMode'] = 'cloud';

      expect(
        () => ToolCall.fromJson(unknownField),
        throwsA(isA<AgentProtocolFormatException>()),
      );
      expect(
        () => AgentRequest.fromJson(unknownEnum),
        throwsA(isA<AgentProtocolFormatException>()),
      );
      expect(
        () => ToolCall(
          callId: '',
          toolName: 'read_resume',
          arguments: const {},
          requestedBy: 'fake-agent',
          idempotencyKey: 'key',
        ),
        throwsArgumentError,
      );
    });
  });
}

ToolCall _call(String callId) {
  return ToolCall(
    callId: callId,
    toolName: 'read_resume',
    arguments: const {'versionId': 'version-001'},
    requestedBy: 'fake-agent',
    idempotencyKey: 'key-$callId',
  );
}
