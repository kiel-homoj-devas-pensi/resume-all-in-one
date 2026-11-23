import 'package:agent_protocol/agent_protocol.dart';
import 'package:agent_runtime/agent_runtime.dart';
import 'package:local_storage/local_storage.dart';
import 'package:model_router/model_router.dart';
import 'package:resume_domain/resume_domain.dart';

import 'local_agent_check_service.dart';

LocalAgentCheckService createOfflineLocalAgentCheckService({
  required ResumeRepository resumeRepository,
  required AgentAuditRepository auditRepository,
  DateTime Function()? clock,
  String Function(String namespace)? nextId,
}) {
  final runtime = AgentRuntime(
    repository: resumeRepository,
    now: clock,
    nextId: nextId,
  );
  final localProvider = FakeModelProvider(
    descriptor: ProviderDescriptor(
      providerKey: 'local-structured-check',
      location: ProviderLocation.local,
      capabilities: const {
        ModelCapability.structuredOutput,
        ModelCapability.toolCalling,
      },
    ),
    generate: _buildLocalCheckPlan,
  );
  final router = ModelRouter(
    ModelRegistry(
      registrations: [
        ProviderRegistration(
          provider: localProvider,
          modelId: 'local-structured-check-v0.1',
        ),
      ],
    ),
  );
  return LocalAgentCheckService(
    runtime: runtime,
    router: router,
    auditRepository: auditRepository,
    clock: clock,
    nextId: nextId,
  );
}

Future<ModelResponse> _buildLocalCheckPlan(ModelRequest request) async {
  final versionId = request.input['resumeVersionId'];
  if (versionId is! String || versionId.trim().isEmpty) {
    throw const ModelProviderException(
      kind: ModelProviderFailureKind.invalidResponse,
      message: '缺少目标版本',
    );
  }
  final requestId = request.requestId;
  final plan = AgentPlan(
    actions: [
      ToolCall(
        callId: '$requestId-validate',
        toolName: 'validate_resume',
        arguments: {'versionId': versionId},
        requestedBy: 'local-structured-check',
        idempotencyKey: '$requestId-validate-key',
      ),
      ToolCall(
        callId: '$requestId-repeated',
        toolName: 'find_repeated_content',
        arguments: {'versionId': versionId},
        requestedBy: 'local-structured-check',
        idempotencyKey: '$requestId-repeated-key',
      ),
    ],
    requiresConfirmation: false,
    riskLevel: AgentRiskLevel.low,
  );
  return ModelResponse(
    text: '本地检查计划已生成',
    structuredData: plan.toJson(),
    usage: ModelUsage(inputTokens: 0, outputTokens: 0),
    finishReason: ModelFinishReason.completed,
  );
}
