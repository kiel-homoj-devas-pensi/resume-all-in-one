import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:agent_runtime/agent_runtime.dart';
import 'package:local_storage/local_storage.dart';
import 'package:model_router/model_router.dart';
import 'package:resume_domain/resume_domain.dart';

import 'local_agent_check_service.dart';

enum LocalSuggestionPreparationStatus {
  ready,
  noSuggestion,
  networkDisabled,
  capabilityUnavailable,
  cancelled,
  timedOut,
  providerFailed,
  invalidResponse,
  failed,
}

enum LocalSuggestionIssueSeverity { info, warning, error }

final class LocalSuggestionValidationIssue {
  const LocalSuggestionValidationIssue({
    required this.path,
    required this.severity,
    required this.message,
    required this.blocksAction,
  });

  final String path;
  final LocalSuggestionIssueSeverity severity;
  final String message;
  final bool blocksAction;
}

final class PendingResumeSuggestion {
  PendingResumeSuggestion({
    required this.confirmationId,
    required this.documentId,
    required this.baseVersionId,
    required this.summary,
    required this.patch,
    required this.diff,
    required List<String> citations,
    required List<String> warnings,
    required List<LocalSuggestionValidationIssue> validationIssues,
  }) : citations = List.unmodifiable(citations),
       warnings = List.unmodifiable(warnings),
       validationIssues = List.unmodifiable(validationIssues);

  final String confirmationId;
  final String documentId;
  final String baseVersionId;
  final String summary;
  final ResumePatch patch;
  final ResumeDiff diff;
  final List<String> citations;
  final List<String> warnings;
  final List<LocalSuggestionValidationIssue> validationIssues;

  bool get containsFactChanges => diff.containsFactChanges;

  bool get hasBlockingValidationIssue =>
      validationIssues.any((issue) => issue.blocksAction);
}

final class LocalSuggestionPreparationResult {
  const LocalSuggestionPreparationResult({
    required this.status,
    this.pendingSuggestion,
    this.summary,
    this.errorCode,
  });

  final LocalSuggestionPreparationStatus status;
  final PendingResumeSuggestion? pendingSuggestion;
  final String? summary;
  final String? errorCode;
}

enum LocalSuggestionDecision { accept, reject, cancel }

enum LocalSuggestionDecisionStatus {
  accepted,
  rejected,
  cancelled,
  conflict,
  notFound,
  alreadyResolved,
  invalid,
  failed,
}

final class LocalSuggestionDecisionResult {
  const LocalSuggestionDecisionResult({
    required this.status,
    this.newVersionId,
    this.errorCode,
  });

  final LocalSuggestionDecisionStatus status;
  final String? newVersionId;
  final String? errorCode;
}

final class LocalResumeSuggestionService {
  LocalResumeSuggestionService({
    required AgentRuntime runtime,
    required ModelRouter router,
    required AgentAuditRepository auditRepository,
    DateTime Function()? clock,
    String Function(String namespace)? nextId,
    this.routingAndProviderTimeout = const Duration(seconds: 5),
  }) : _runtime = runtime,
       _router = router,
       _auditRepository = auditRepository,
       _clock = clock ?? _utcNow,
       _nextId = nextId ?? _SuggestionIds().next;

  final AgentRuntime _runtime;
  final ModelRouter _router;
  final AgentAuditRepository _auditRepository;
  final DateTime Function() _clock;
  final String Function(String namespace) _nextId;
  final Duration routingAndProviderTimeout;

  void clearTransientState() => _runtime.clearTransientState();

  Future<LocalSuggestionPreparationResult> prepareSuggestion({
    required ResumeDocument document,
    required ResumeVersion version,
    required bool networkEnabled,
    LocalAgentCancellationToken? cancellationToken,
  }) async {
    final suggestionCancellation =
        cancellationToken ?? LocalAgentCancellationToken();
    final modelCancellation = ModelCancellationToken();
    unawaited(
      suggestionCancellation.whenCancelled.then((_) {
        modelCancellation.cancel();
      }),
    );

    final startedAt = _clock().toUtc();
    final runId = _nextId('suggestion-run');
    final requestId = _nextId('suggestion-request');
    var routeStatus = 'not_started';
    String? createdConfirmationId;
    final toolAuditRecords = <ToolCallAuditRecord>[];

    Future<LocalSuggestionPreparationResult> completeWithAudit(
      LocalSuggestionPreparationStatus status, {
      PendingResumeSuggestion? pendingSuggestion,
      String? summary,
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
        // Patch、Diff 和正文只用于当前内存审阅，持久化审计仍只记录终态元数据。
        await _auditRepository.recordRun(
          AgentRunAuditRecord(
            id: runId,
            requestId: requestId,
            documentId: document.id,
            resumeVersionId: version.id,
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
        await _cancelUnexposedConfirmation(createdConfirmationId);
        return const LocalSuggestionPreparationResult(
          status: LocalSuggestionPreparationStatus.failed,
          errorCode: 'audit_write_failed',
        );
      }
      return LocalSuggestionPreparationResult(
        status: status,
        pendingSuggestion: pendingSuggestion,
        summary: summary,
        errorCode: errorCode,
      );
    }

    try {
      if (document.id != version.documentId ||
          document.currentVersionId != version.id) {
        return await completeWithAudit(
          LocalSuggestionPreparationStatus.invalidResponse,
          errorCode: 'base_version_mismatch',
        );
      }
      if (suggestionCancellation.isCancelled) {
        routeStatus = ModelRouteStatus.cancelled.name;
        return await completeWithAudit(
          LocalSuggestionPreparationStatus.cancelled,
          errorCode: 'cancelled_before_route',
        );
      }

      final modelRequest = ModelRequest(
        requestId: requestId,
        taskType: ModelTaskType.rewrite,
        input: {
          'operation': 'prepare_resume_suggestion',
          'documentId': document.id,
          'resumeVersionId': version.id,
          'resume': version.content.toJson(),
        },
        requiredCapabilities: const {ModelCapability.structuredOutput},
        contextBudgetTokens: 4096,
        privacyPolicy: ModelPrivacyPolicy.localOnly,
        cancellationToken: modelCancellation,
      );
      final routeDecision = await _waitForOperationOrCancellation(
        _router.route(
          modelRequest,
          ModelRoutingContext(
            networkEnabled: networkEnabled,
            availableQuotaUnits: 0,
          ),
        ),
        suggestionCancellation,
      ).timeout(routingAndProviderTimeout);
      routeStatus = routeDecision.status.name;
      if (!routeDecision.isSelected) {
        final routeFailure = _preparationRouteFailure(routeDecision.status);
        return await completeWithAudit(
          routeFailure.$1,
          errorCode: routeFailure.$2,
        );
      }

      final modelResponse = await _waitForOperationOrCancellation(
        routeDecision.selected!.provider.generate(modelRequest),
        suggestionCancellation,
      ).timeout(routingAndProviderTimeout);
      if (modelResponse.finishReason == ModelFinishReason.cancelled ||
          suggestionCancellation.isCancelled) {
        return await completeWithAudit(
          LocalSuggestionPreparationStatus.cancelled,
          errorCode: 'provider_cancelled',
        );
      }
      if (modelResponse.finishReason != ModelFinishReason.completed) {
        return await completeWithAudit(
          LocalSuggestionPreparationStatus.invalidResponse,
          errorCode: 'provider_response_incomplete',
        );
      }

      final agentResponse = AgentResponse.fromJson(
        modelResponse.structuredData,
      );
      final proposedPatchJson = agentResponse.proposedPatch;
      if (proposedPatchJson == null &&
          agentResponse.nextAction == AgentNextAction.none) {
        return await completeWithAudit(
          LocalSuggestionPreparationStatus.noSuggestion,
          summary: agentResponse.summary,
        );
      }
      if (proposedPatchJson == null ||
          agentResponse.nextAction != AgentNextAction.reviewPatch) {
        return await completeWithAudit(
          LocalSuggestionPreparationStatus.invalidResponse,
          errorCode: 'suggestion_response_inconsistent',
        );
      }

      final buildPatchCall = ToolCall(
        callId: '$requestId-build-patch',
        toolName: 'build_patch',
        arguments: {'versionId': version.id, 'patch': proposedPatchJson},
        requestedBy: 'local-suggestion-application',
        idempotencyKey: '$requestId-build-patch-key',
      );
      if (suggestionCancellation.isCancelled) {
        return await completeWithAudit(
          LocalSuggestionPreparationStatus.cancelled,
          errorCode: 'cancelled_before_tool',
        );
      }
      // build_patch 会创建内存确认票据，因此让它完整返回后再处理取消，
      // 才能拿到 confirmationId 并显式清理，避免留下不可达票据。
      final buildPatchResult = await _runtime.executeTool(buildPatchCall);
      toolAuditRecords.add(
        _suggestionToolAuditRecord(runId: runId, toolResult: buildPatchResult),
      );
      final rawConfirmationId = buildPatchResult.data['confirmationId'];
      if (rawConfirmationId is String && rawConfirmationId.trim().isNotEmpty) {
        createdConfirmationId = rawConfirmationId;
      }
      if (suggestionCancellation.isCancelled) {
        await _cancelUnexposedConfirmation(createdConfirmationId);
        return await completeWithAudit(
          LocalSuggestionPreparationStatus.cancelled,
          errorCode: 'cancelled_after_tool',
        );
      }
      if (buildPatchResult.status != ToolResultStatus.requiresConfirmation) {
        final toolFailure = _preparationToolFailure(buildPatchResult.status);
        return await completeWithAudit(
          toolFailure.$1,
          errorCode: buildPatchResult.error?.code ?? toolFailure.$2,
        );
      }

      final pendingSuggestion = _pendingSuggestionFromToolResult(
        document: document,
        version: version,
        agentResponse: agentResponse,
        toolResult: buildPatchResult,
      );
      return await completeWithAudit(
        LocalSuggestionPreparationStatus.ready,
        pendingSuggestion: pendingSuggestion,
        summary: agentResponse.summary,
      );
    } on _SuggestionCancelled {
      return await completeWithAudit(
        LocalSuggestionPreparationStatus.cancelled,
        errorCode: 'cancelled',
      );
    } on TimeoutException {
      modelCancellation.cancel();
      await _cancelUnexposedConfirmation(createdConfirmationId);
      return await completeWithAudit(
        LocalSuggestionPreparationStatus.timedOut,
        errorCode: 'suggestion_timeout',
      );
    } on ModelProviderException catch (providerError) {
      final providerFailure = _preparationProviderFailure(providerError.kind);
      return await completeWithAudit(
        providerFailure.$1,
        errorCode: providerFailure.$2,
      );
    } on AgentProtocolFormatException {
      await _cancelUnexposedConfirmation(createdConfirmationId);
      return await completeWithAudit(
        LocalSuggestionPreparationStatus.invalidResponse,
        errorCode: 'suggestion_response_invalid',
      );
    } on SchemaFormatException {
      await _cancelUnexposedConfirmation(createdConfirmationId);
      return await completeWithAudit(
        LocalSuggestionPreparationStatus.invalidResponse,
        errorCode: 'suggestion_patch_invalid',
      );
    } on FormatException {
      await _cancelUnexposedConfirmation(createdConfirmationId);
      return await completeWithAudit(
        LocalSuggestionPreparationStatus.invalidResponse,
        errorCode: 'suggestion_response_invalid',
      );
    } on ArgumentError {
      await _cancelUnexposedConfirmation(createdConfirmationId);
      return await completeWithAudit(
        LocalSuggestionPreparationStatus.invalidResponse,
        errorCode: 'suggestion_response_invalid',
      );
    } on Object {
      await _cancelUnexposedConfirmation(createdConfirmationId);
      return await completeWithAudit(
        LocalSuggestionPreparationStatus.failed,
        errorCode: 'suggestion_preparation_failed',
      );
    }
  }

  Future<LocalSuggestionDecisionResult> decide({
    required PendingResumeSuggestion suggestion,
    required LocalSuggestionDecision decision,
  }) async {
    final confirmationResult = await _runtime.decide(
      ConfirmationCommand(
        confirmationId: suggestion.confirmationId,
        decision: switch (decision) {
          LocalSuggestionDecision.accept => ConfirmationDecision.accept,
          LocalSuggestionDecision.reject => ConfirmationDecision.reject,
          LocalSuggestionDecision.cancel => ConfirmationDecision.cancel,
        },
      ),
    );
    return LocalSuggestionDecisionResult(
      status: LocalSuggestionDecisionStatus.values.byName(
        confirmationResult.status.name,
      ),
      newVersionId: confirmationResult.newVersionId,
      errorCode: confirmationResult.error?.code,
    );
  }

  Future<void> _cancelUnexposedConfirmation(String? confirmationId) async {
    if (confirmationId == null) {
      return;
    }
    await _runtime.decide(
      ConfirmationCommand(
        confirmationId: confirmationId,
        decision: ConfirmationDecision.cancel,
      ),
    );
  }
}

PendingResumeSuggestion _pendingSuggestionFromToolResult({
  required ResumeDocument document,
  required ResumeVersion version,
  required AgentResponse agentResponse,
  required ToolResult toolResult,
}) {
  final confirmationId = toolResult.data['confirmationId'];
  final baseVersionId = toolResult.data['baseVersionId'];
  final patchJson = toolResult.data['patch'];
  final diffJson = toolResult.data['diff'];
  if (confirmationId is! String ||
      confirmationId.trim().isEmpty ||
      baseVersionId is! String ||
      baseVersionId != version.id ||
      patchJson is! Map<String, Object?> ||
      diffJson is! Map<String, Object?>) {
    throw const FormatException('build_patch 返回结构无效');
  }

  final validatedPatch = ResumePatch.fromJson(patchJson);
  final validatedDiff = ResumeDiff.fromPatch(validatedPatch);
  if (!jsonDeepEquals(validatedDiff.toJson(), diffJson)) {
    throw const FormatException('Patch 与 Diff 不一致');
  }
  return PendingResumeSuggestion(
    confirmationId: confirmationId,
    documentId: document.id,
    baseVersionId: baseVersionId,
    summary: agentResponse.summary,
    patch: validatedPatch,
    diff: validatedDiff,
    citations: agentResponse.citations,
    warnings: agentResponse.warnings,
    validationIssues: toolResult.validationIssues
        .map(
          (issue) => LocalSuggestionValidationIssue(
            path: issue.path,
            severity: LocalSuggestionIssueSeverity.values.byName(
              issue.severity.name,
            ),
            message: issue.message,
            blocksAction: issue.blocksAction,
          ),
        )
        .toList(growable: false),
  );
}

ToolCallAuditRecord _suggestionToolAuditRecord({
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

(LocalSuggestionPreparationStatus, String) _preparationRouteFailure(
  ModelRouteStatus routeStatus,
) {
  return switch (routeStatus) {
    ModelRouteStatus.cancelled => (
      LocalSuggestionPreparationStatus.cancelled,
      'route_cancelled',
    ),
    ModelRouteStatus.networkDisabled => (
      LocalSuggestionPreparationStatus.networkDisabled,
      'route_network_disabled',
    ),
    ModelRouteStatus.capabilityUnavailable ||
    ModelRouteStatus.privacyRestricted => (
      LocalSuggestionPreparationStatus.capabilityUnavailable,
      'route_capability_unavailable',
    ),
    ModelRouteStatus.selected => (
      LocalSuggestionPreparationStatus.failed,
      'route_selection_inconsistent',
    ),
    ModelRouteStatus.quotaExceeded || ModelRouteStatus.providerUnavailable => (
      LocalSuggestionPreparationStatus.providerFailed,
      'route_provider_unavailable',
    ),
  };
}

(LocalSuggestionPreparationStatus, String) _preparationToolFailure(
  ToolResultStatus toolStatus,
) {
  return switch (toolStatus) {
    ToolResultStatus.cancelled => (
      LocalSuggestionPreparationStatus.cancelled,
      'tool_cancelled',
    ),
    ToolResultStatus.timeout => (
      LocalSuggestionPreparationStatus.timedOut,
      'tool_timeout',
    ),
    ToolResultStatus.invalidCall => (
      LocalSuggestionPreparationStatus.invalidResponse,
      'suggestion_patch_invalid',
    ),
    ToolResultStatus.notFound ||
    ToolResultStatus.conflict ||
    ToolResultStatus.failed => (
      LocalSuggestionPreparationStatus.failed,
      'build_patch_failed',
    ),
    ToolResultStatus.success || ToolResultStatus.requiresConfirmation => (
      LocalSuggestionPreparationStatus.invalidResponse,
      'build_patch_status_invalid',
    ),
  };
}

(LocalSuggestionPreparationStatus, String) _preparationProviderFailure(
  ModelProviderFailureKind failureKind,
) {
  return switch (failureKind) {
    ModelProviderFailureKind.cancelled => (
      LocalSuggestionPreparationStatus.cancelled,
      'provider_cancelled',
    ),
    ModelProviderFailureKind.timeout => (
      LocalSuggestionPreparationStatus.timedOut,
      'provider_timeout',
    ),
    _ => (LocalSuggestionPreparationStatus.providerFailed, 'provider_failed'),
  };
}

Future<T> _waitForOperationOrCancellation<T>(
  Future<T> operation,
  LocalAgentCancellationToken cancellationToken,
) {
  return Future.any([
    operation,
    cancellationToken.whenCancelled.then<T>(
      (_) => throw const _SuggestionCancelled(),
    ),
  ]);
}

final class _SuggestionCancelled implements Exception {
  const _SuggestionCancelled();
}

final class _SuggestionIds {
  int _counter = 0;

  String next(String namespace) {
    _counter++;
    return '${namespace}_${DateTime.now().toUtc().microsecondsSinceEpoch}_$_counter';
  }
}

DateTime _utcNow() => DateTime.now().toUtc();
