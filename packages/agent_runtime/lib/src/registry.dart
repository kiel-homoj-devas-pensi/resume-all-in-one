import 'dart:async';
import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';

final class AgentCancellationToken {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() => _isCancelled = true;
}

final class ToolArgumentException implements Exception {
  ToolArgumentException(
    this.code,
    this.message, {
    List<ProtocolValidationIssue> validationIssues = const [],
  }) : validationIssues = List<ProtocolValidationIssue>.unmodifiable(
         validationIssues,
       );

  final String code;
  final String message;
  final List<ProtocolValidationIssue> validationIssues;

  @override
  String toString() => 'ToolArgumentException($code): $message';
}

final class ToolOutcome {
  ToolOutcome({
    required this.status,
    JsonObject data = const {},
    List<ProtocolValidationIssue> validationIssues = const [],
    this.error,
  }) : data = Map<String, Object?>.unmodifiable(data),
       validationIssues = List<ProtocolValidationIssue>.unmodifiable(
         validationIssues,
       );

  final ToolResultStatus status;
  final JsonObject data;
  final List<ProtocolValidationIssue> validationIssues;
  final ToolError? error;
}

abstract interface class AgentTool {
  ToolDescriptor get descriptor;

  Future<ToolOutcome> execute(
    JsonObject arguments, {
    required AgentCancellationToken cancellationToken,
  });
}

final class ToolRegistry {
  ToolRegistry({required Iterable<AgentTool> tools, DateTime Function()? now})
    : _now = now ?? DateTime.now {
    for (final tool in tools) {
      final descriptor = tool.descriptor;
      if (descriptor.usesNetwork) {
        throw ArgumentError.value(
          descriptor.name,
          'tools',
          'Task 006 Registry 只允许离线工具',
        );
      }
      if (_tools.containsKey(descriptor.name)) {
        throw ArgumentError.value(descriptor.name, 'tools', '工具名称重复');
      }
      _tools[descriptor.name] = tool;
    }
  }

  final DateTime Function() _now;
  // 工具名是协议入口，Map 既承担白名单，也保证执行前能直接定位实现。
  final Map<String, AgentTool> _tools = {};
  // 同一个幂等键共享进行中的 Future，避免并发重试把同一工具执行两次。
  final Map<String, _TrackedToolExecution> _executions = {};

  List<ToolDescriptor> get descriptors {
    final sortedDescriptors =
        _tools.values.map((tool) => tool.descriptor).toList()
          ..sort((left, right) => left.name.compareTo(right.name));
    return List<ToolDescriptor>.unmodifiable(sortedDescriptors);
  }

  void clearExecutionHistory() {
    _executions.clear();
  }

  Future<ToolResult> execute(
    ToolCall call, {
    AgentCancellationToken? cancellationToken,
  }) async {
    final effectiveCancellationToken =
        cancellationToken ?? AgentCancellationToken();
    final registeredTool = _tools[call.toolName];
    if (registeredTool == null) {
      return _immediateResult(
        call,
        status: ToolResultStatus.invalidCall,
        version: 'unregistered',
        error: const ToolError(code: 'tool_not_allowed', message: '工具不在白名单中'),
      );
    }
    if (effectiveCancellationToken.isCancelled) {
      return _immediateResult(
        call,
        status: ToolResultStatus.cancelled,
        version: registeredTool.descriptor.version,
        error: const ToolError(code: 'cancelled', message: '调用已取消'),
      );
    }

    final callSignature = _signature(call);
    final previousExecution = _executions[call.idempotencyKey];
    if (previousExecution != null) {
      if (previousExecution.callSignature != callSignature) {
        return _immediateResult(
          call,
          status: ToolResultStatus.conflict,
          version: registeredTool.descriptor.version,
          error: const ToolError(
            code: 'idempotency_key_conflict',
            message: '幂等键已用于不同调用',
          ),
        );
      }
      final originalResult = await previousExecution.resultFuture;
      return _replayed(call, originalResult);
    }

    final resultFuture = _executeFresh(
      call,
      registeredTool,
      effectiveCancellationToken,
    );
    final trackedExecution = _TrackedToolExecution(callSignature, resultFuture);
    _executions[call.idempotencyKey] = trackedExecution;
    final executionResult = await resultFuture;
    if (!_isCacheable(executionResult.status) &&
        identical(_executions[call.idempotencyKey], trackedExecution)) {
      _executions.remove(call.idempotencyKey);
    }
    return executionResult;
  }

  Future<ToolResult> _executeFresh(
    ToolCall call,
    AgentTool tool,
    AgentCancellationToken token,
  ) async {
    final descriptor = tool.descriptor;
    final startedAt = _now().toUtc();
    ToolOutcome outcome;
    try {
      outcome = await tool
          .execute(call.arguments, cancellationToken: token)
          .timeout(Duration(milliseconds: descriptor.timeoutMs));
      if (token.isCancelled) {
        outcome = ToolOutcome(
          status: ToolResultStatus.cancelled,
          error: const ToolError(code: 'cancelled', message: '调用已取消'),
        );
      }
    } on ToolArgumentException catch (error) {
      outcome = ToolOutcome(
        status: ToolResultStatus.invalidCall,
        validationIssues: error.validationIssues,
        error: ToolError(code: error.code, message: error.message),
      );
    } on TimeoutException {
      outcome = ToolOutcome(
        status: ToolResultStatus.timeout,
        error: const ToolError(code: 'tool_timeout', message: '工具执行超时'),
      );
    } on Object {
      outcome = ToolOutcome(
        status: ToolResultStatus.failed,
        error: const ToolError(code: 'tool_failed', message: '工具执行失败，未写入任何内容'),
      );
    }

    return ToolResult(
      callId: call.callId,
      status: outcome.status,
      data: outcome.data,
      validationIssues: outcome.validationIssues,
      error: outcome.error,
      auditInfo: ToolAuditInfo(
        toolName: descriptor.name,
        toolVersion: descriptor.version,
        startedAt: startedAt,
        finishedAt: _now().toUtc(),
        offline: true,
        idempotencyKey: call.idempotencyKey,
        replayed: false,
      ),
    );
  }

  ToolResult _immediateResult(
    ToolCall call, {
    required ToolResultStatus status,
    required String version,
    required ToolError error,
  }) {
    final timestamp = _now().toUtc();
    return ToolResult(
      callId: call.callId,
      status: status,
      error: error,
      auditInfo: ToolAuditInfo(
        toolName: call.toolName,
        toolVersion: version,
        startedAt: timestamp,
        finishedAt: timestamp,
        offline: true,
        idempotencyKey: call.idempotencyKey,
        replayed: false,
      ),
    );
  }

  ToolResult _replayed(ToolCall call, ToolResult originalResult) {
    final timestamp = _now().toUtc();
    return ToolResult(
      callId: call.callId,
      status: originalResult.status,
      data: originalResult.data,
      validationIssues: originalResult.validationIssues,
      error: originalResult.error,
      auditInfo: ToolAuditInfo(
        toolName: originalResult.auditInfo.toolName,
        toolVersion: originalResult.auditInfo.toolVersion,
        startedAt: timestamp,
        finishedAt: timestamp,
        offline: true,
        idempotencyKey: call.idempotencyKey,
        replayed: true,
      ),
    );
  }

  bool _isCacheable(ToolResultStatus status) {
    return switch (status) {
      ToolResultStatus.success ||
      ToolResultStatus.requiresConfirmation ||
      ToolResultStatus.invalidCall ||
      ToolResultStatus.notFound => true,
      ToolResultStatus.conflict ||
      ToolResultStatus.cancelled ||
      ToolResultStatus.timeout ||
      ToolResultStatus.failed => false,
    };
  }

  String _signature(ToolCall call) {
    return jsonEncode(
      _canonicalize({
        'toolName': call.toolName,
        'requestedBy': call.requestedBy,
        'arguments': call.arguments,
      }),
    );
  }
}

final class _TrackedToolExecution {
  const _TrackedToolExecution(this.callSignature, this.resultFuture);

  final String callSignature;
  final Future<ToolResult> resultFuture;
}

Object? _canonicalize(Object? jsonValue) {
  if (jsonValue is List<Object?>) {
    return jsonValue.map(_canonicalize).toList();
  }
  if (jsonValue is Map<String, Object?>) {
    final sortedKeys = jsonValue.keys.toList()..sort();
    return {for (final key in sortedKeys) key: _canonicalize(jsonValue[key])};
  }
  return jsonValue;
}
