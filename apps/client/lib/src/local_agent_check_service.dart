import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:agent_runtime/agent_runtime.dart';
import 'package:local_storage/local_storage.dart';
import 'package:model_router/model_router.dart';

enum LocalAgentCheckStatus {
  completed,
  networkDisabled,
  capabilityUnavailable,
  cancelled,
  timedOut,
  providerFailed,
  invalidPlan,
  failed,
}

final class LocalAgentCheckResult {
  const LocalAgentCheckResult({
    required this.status,
    required this.validationIssueCount,
    required this.repeatedContentGroupCount,
    required this.executedToolCount,
    this.errorCode,
    this.findings = const [],
  });

  final LocalAgentCheckStatus status;
  final int validationIssueCount;
  final int repeatedContentGroupCount;
  final int executedToolCount;
  final String? errorCode;
  final List<ProtocolValidationIssue> findings;
}

final class LocalAgentCancellationToken {
  final Completer<void> _cancelled = Completer<void>();
  final Set<void Function()> _listeners = {};

  bool get isCancelled => _cancelled.isCompleted;

  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (isCancelled) {
      return;
    }
    for (final listener in _listeners.toList(growable: false)) {
      listener();
    }
    _cancelled.complete();
  }

  void _addListener(void Function() listener) {
    if (isCancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  void _removeListener(void Function() listener) {
    _listeners.remove(listener);
  }
}

final class LocalAgentCheckService {
  LocalAgentCheckService({
    required AgentRuntime runtime,
    required ModelRouter router,
    required AgentAuditRepository auditRepository,
    DateTime Function()? clock,
    String Function(String namespace)? nextId,
    this.providerTimeout = const Duration(seconds: 5),
  }) : _runtime = runtime,
       _router = router,
       _auditRepository = auditRepository,
       _clock = clock ?? _utcNow,
       _nextId = nextId ?? _LocalAgentIds().next;

  final AgentRuntime _runtime;
  final ModelRouter _router;
  final AgentAuditRepository _auditRepository;
  final DateTime Function() _clock;
  final String Function(String namespace) _nextId;
  final Duration providerTimeout;

  void clearTransientState() => _runtime.clearTransientState();

  Future<LocalAgentCheckResult> checkSavedVersion({
    required String documentId,
    required String resumeVersionId,
    required bool networkEnabled,
    LocalAgentCancellationToken? cancellationToken,
  }) async {
    final checkCancellation =
        cancellationToken ?? LocalAgentCancellationToken();
    final modelCancellation = ModelCancellationToken();
    final toolCancellation = AgentCancellationToken();

    // 一个用户取消动作必须同时到达 Router/Provider 与 Runtime，避免某一层继续推进。
    void forwardCancellation() {
      modelCancellation.cancel();
      toolCancellation.cancel();
    }

    checkCancellation._addListener(forwardCancellation);
    final startedAt = _clock().toUtc();
    final runId = _nextId('agent-run');
    final requestId = _nextId('agent-request');
    var routeStatus = 'not_started';
    final toolAuditRecords = <ToolCallAuditRecord>[];
    var findings = <ProtocolValidationIssue>[];

    Future<LocalAgentCheckResult> completeWithAudit(
      LocalAgentCheckStatus status, {
      int validationIssueCount = 0,
      int repeatedContentGroupCount = 0,
      String? errorCode,
    }) async {
      var finishedAt = _clock().toUtc();
      if (finishedAt.isBefore(startedAt)) {
        finishedAt = startedAt;
      }
      for (final toolAudit in toolAuditRecords) {
        if (finishedAt.isBefore(toolAudit.finishedAt)) {
          finishedAt = toolAudit.finishedAt;
        }
      }
      try {
        // 审计只接收终态和工具元数据；计划、参数与结果都停留在内存中。
        await _auditRepository.recordRun(
          AgentRunAuditRecord(
            id: runId,
            requestId: requestId,
            documentId: documentId,
            resumeVersionId: resumeVersionId,
            status: status.name,
            routeStatus: routeStatus,
            startedAt: startedAt,
            finishedAt: finishedAt,
            toolCallCount: toolAuditRecords.length,
            errorCode: errorCode,
          ),
          toolAuditRecords,
        );
      } on Object {
        return LocalAgentCheckResult(
          status: LocalAgentCheckStatus.failed,
          validationIssueCount: validationIssueCount,
          repeatedContentGroupCount: repeatedContentGroupCount,
          executedToolCount: toolAuditRecords.length,
          errorCode: 'audit_write_failed',
        );
      }
      return LocalAgentCheckResult(
        status: status,
        validationIssueCount: validationIssueCount,
        repeatedContentGroupCount: repeatedContentGroupCount,
        executedToolCount: toolAuditRecords.length,
        errorCode: errorCode,
        findings: List.unmodifiable(findings),
      );
    }

    try {
      if (checkCancellation.isCancelled) {
        routeStatus = ModelRouteStatus.cancelled.name;
        return await completeWithAudit(
          LocalAgentCheckStatus.cancelled,
          errorCode: 'cancelled_before_route',
        );
      }

      // 即使 Runtime 还有其他工具，本流程也只向 Provider 暴露两项固定只读能力。
      final readOnlyTools = _runtime.toolDescriptors
          .where(
            (descriptor) =>
                descriptor.access == ToolAccess.read &&
                _localCheckToolNames.contains(descriptor.name),
          )
          .toList(growable: false);
      final modelRequest = ModelRequest(
        requestId: requestId,
        taskType: ModelTaskType.toolPlanning,
        input: {
          'documentId': documentId,
          'resumeVersionId': resumeVersionId,
          'intent': '检查已保存版本的结构有效性与精确重复内容',
        },
        requiredCapabilities: const {
          ModelCapability.structuredOutput,
          ModelCapability.toolCalling,
        },
        outputSchema: const {'type': 'object'},
        tools: readOnlyTools,
        contextBudgetTokens: 1024,
        privacyPolicy: ModelPrivacyPolicy.localOnly,
        cancellationToken: modelCancellation,
      );
      final routeDecision = await _withCancellation(
        _router.route(
          modelRequest,
          ModelRoutingContext(
            networkEnabled: networkEnabled,
            availableQuotaUnits: 0,
          ),
        ),
        checkCancellation,
      ).timeout(providerTimeout);
      routeStatus = routeDecision.status.name;
      if (!routeDecision.isSelected) {
        final routeFailure = _routeFailure(routeDecision.status);
        return await completeWithAudit(
          routeFailure.$1,
          errorCode: routeFailure.$2,
        );
      }

      final modelResponse = await _withCancellation(
        routeDecision.selected!.provider.generate(modelRequest),
        checkCancellation,
      ).timeout(providerTimeout);
      if (modelResponse.finishReason == ModelFinishReason.cancelled ||
          checkCancellation.isCancelled) {
        return await completeWithAudit(
          LocalAgentCheckStatus.cancelled,
          errorCode: 'provider_cancelled',
        );
      }
      if (modelResponse.finishReason != ModelFinishReason.completed) {
        return await completeWithAudit(
          LocalAgentCheckStatus.invalidPlan,
          errorCode: 'provider_response_incomplete',
        );
      }

      final agentPlan = AgentPlan.fromJson(modelResponse.structuredData);
      // Provider 给出的计划仍需由 Application 复核完整性，不能把“在白名单内”
      // 误当成“完成了本次检查所需的全部步骤”。
      if (!_isCompleteReadOnlyPlan(agentPlan, resumeVersionId, readOnlyTools)) {
        return await completeWithAudit(
          LocalAgentCheckStatus.invalidPlan,
          errorCode: 'plan_not_allowed',
        );
      }

      var validationIssueCount = 0;
      var repeatedContentGroupCount = 0;
      for (final toolCall in agentPlan.actions) {
        if (checkCancellation.isCancelled) {
          return await completeWithAudit(
            LocalAgentCheckStatus.cancelled,
            validationIssueCount: validationIssueCount,
            repeatedContentGroupCount: repeatedContentGroupCount,
            errorCode: 'cancelled_before_tool',
          );
        }
        final toolResult = await _runtime.executeTool(
          toolCall,
          cancellationToken: toolCancellation,
        );
        toolAuditRecords.add(
          _toolAuditRecord(runId: runId, toolResult: toolResult),
        );
        final toolFailure = _toolFailure(toolResult.status);
        if (toolFailure != null) {
          return await completeWithAudit(
            toolFailure.$1,
            validationIssueCount: validationIssueCount,
            repeatedContentGroupCount: repeatedContentGroupCount,
            errorCode: toolResult.error?.code ?? toolFailure.$2,
          );
        }

        if (toolCall.toolName == 'validate_resume') {
          final validationIssueList = toolResult.data['validationIssues'];
          if (validationIssueList is! List<Object?>) {
            return await completeWithAudit(
              LocalAgentCheckStatus.failed,
              errorCode: 'tool_result_invalid',
            );
          }
          validationIssueCount = validationIssueList.length;
          findings = validationIssueList
              .map((entry) {
                if (entry is! Map<String, Object?>) {
                  throw const AgentProtocolFormatException(
                    r'$.validationIssues',
                    '无效的检查结果',
                  );
                }
                return ProtocolValidationIssue.fromJson(entry);
              })
              .toList(growable: false);
        }
        if (toolCall.toolName == 'find_repeated_content') {
          final repeatedGroupCount = toolResult.data['repeatedGroupCount'];
          if (repeatedGroupCount is! int || repeatedGroupCount < 0) {
            return await completeWithAudit(
              LocalAgentCheckStatus.failed,
              validationIssueCount: validationIssueCount,
              errorCode: 'tool_result_invalid',
            );
          }
          repeatedContentGroupCount = repeatedGroupCount;
        }
      }

      return await completeWithAudit(
        LocalAgentCheckStatus.completed,
        validationIssueCount: validationIssueCount,
        repeatedContentGroupCount: repeatedContentGroupCount,
      );
    } on _LocalAgentCancelled {
      return await completeWithAudit(
        LocalAgentCheckStatus.cancelled,
        errorCode: 'cancelled',
      );
    } on TimeoutException {
      forwardCancellation();
      return await completeWithAudit(
        LocalAgentCheckStatus.timedOut,
        errorCode: 'provider_timeout',
      );
    } on ModelProviderException catch (providerError) {
      final providerFailure = _providerFailure(providerError.kind);
      return await completeWithAudit(
        providerFailure.$1,
        errorCode: providerFailure.$2,
      );
    } on AgentProtocolFormatException {
      return await completeWithAudit(
        LocalAgentCheckStatus.invalidPlan,
        errorCode: 'plan_format_invalid',
      );
    } on ArgumentError {
      return await completeWithAudit(
        LocalAgentCheckStatus.invalidPlan,
        errorCode: 'plan_format_invalid',
      );
    } on Object {
      return await completeWithAudit(
        LocalAgentCheckStatus.failed,
        errorCode: 'local_agent_failed',
      );
    } finally {
      checkCancellation._removeListener(forwardCancellation);
    }
  }
}

const _localCheckToolNames = {'validate_resume', 'find_repeated_content'};

bool _isCompleteReadOnlyPlan(
  AgentPlan agentPlan,
  String resumeVersionId,
  List<ToolDescriptor> exposedTools,
) {
  if (agentPlan.requiresConfirmation ||
      agentPlan.riskLevel != AgentRiskLevel.low) {
    return false;
  }
  final exposedToolNames = exposedTools
      .map((descriptor) => descriptor.name)
      .toSet();
  final callIds = <String>{};
  final idempotencyKeys = <String>{};
  final plannedToolNames = <String>{};
  for (final toolCall in agentPlan.actions) {
    if (!exposedToolNames.contains(toolCall.toolName) ||
        !plannedToolNames.add(toolCall.toolName) ||
        !callIds.add(toolCall.callId) ||
        !idempotencyKeys.add(toolCall.idempotencyKey) ||
        toolCall.arguments.length != 1 ||
        toolCall.arguments['versionId'] != resumeVersionId) {
      return false;
    }
  }
  return plannedToolNames.length == _localCheckToolNames.length &&
      plannedToolNames.containsAll(_localCheckToolNames);
}

ToolCallAuditRecord _toolAuditRecord({
  required String runId,
  required ToolResult toolResult,
}) {
  final auditInfo = toolResult.auditInfo;
  return ToolCallAuditRecord(
    id: toolResult.callId,
    agentRunId: runId,
    toolName: auditInfo.toolName,
    toolVersion: auditInfo.toolVersion,
    status: toolResult.status.name,
    startedAt: auditInfo.startedAt,
    finishedAt: auditInfo.finishedAt,
    offline: auditInfo.offline,
    replayed: auditInfo.replayed,
    errorCode: toolResult.error?.code,
  );
}

(LocalAgentCheckStatus, String) _routeFailure(ModelRouteStatus routeStatus) {
  return switch (routeStatus) {
    ModelRouteStatus.cancelled => (
      LocalAgentCheckStatus.cancelled,
      'route_cancelled',
    ),
    ModelRouteStatus.networkDisabled => (
      LocalAgentCheckStatus.networkDisabled,
      'route_network_disabled',
    ),
    ModelRouteStatus.capabilityUnavailable ||
    ModelRouteStatus.privacyRestricted => (
      LocalAgentCheckStatus.capabilityUnavailable,
      'route_capability_unavailable',
    ),
    ModelRouteStatus.selected => (
      LocalAgentCheckStatus.failed,
      'route_selection_inconsistent',
    ),
    ModelRouteStatus.quotaExceeded || ModelRouteStatus.providerUnavailable => (
      LocalAgentCheckStatus.providerFailed,
      'route_provider_unavailable',
    ),
  };
}

(LocalAgentCheckStatus, String)? _toolFailure(ToolResultStatus toolStatus) {
  return switch (toolStatus) {
    ToolResultStatus.success => null,
    ToolResultStatus.cancelled => (
      LocalAgentCheckStatus.cancelled,
      'tool_cancelled',
    ),
    ToolResultStatus.timeout => (
      LocalAgentCheckStatus.timedOut,
      'tool_timeout',
    ),
    ToolResultStatus.invalidCall || ToolResultStatus.requiresConfirmation => (
      LocalAgentCheckStatus.invalidPlan,
      'tool_call_invalid',
    ),
    ToolResultStatus.notFound ||
    ToolResultStatus.conflict ||
    ToolResultStatus.failed => (LocalAgentCheckStatus.failed, 'tool_failed'),
  };
}

(LocalAgentCheckStatus, String) _providerFailure(
  ModelProviderFailureKind failureKind,
) {
  return switch (failureKind) {
    ModelProviderFailureKind.cancelled => (
      LocalAgentCheckStatus.cancelled,
      'provider_cancelled',
    ),
    ModelProviderFailureKind.timeout => (
      LocalAgentCheckStatus.timedOut,
      'provider_timeout',
    ),
    _ => (LocalAgentCheckStatus.providerFailed, 'provider_failed'),
  };
}

Future<T> _withCancellation<T>(
  Future<T> operation,
  LocalAgentCancellationToken cancellationToken,
) {
  // Provider 不一定主动轮询 token；Future 竞速让 UI 取消能立即结束等待。
  return Future.any([
    operation,
    cancellationToken.whenCancelled.then<T>(
      (_) => throw const _LocalAgentCancelled(),
    ),
  ]);
}

final class _LocalAgentCancelled implements Exception {
  const _LocalAgentCancelled();
}

final class _LocalAgentIds {
  int _counter = 0;

  String next(String namespace) {
    _counter++;
    return '${namespace}_${DateTime.now().toUtc().microsecondsSinceEpoch}_$_counter';
  }
}

DateTime _utcNow() => DateTime.now().toUtc();
