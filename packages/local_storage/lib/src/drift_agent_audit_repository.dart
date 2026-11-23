import 'package:drift/drift.dart';

import 'database.dart';

final class AgentRunAuditRecord {
  const AgentRunAuditRecord({
    required this.id,
    required this.requestId,
    required this.documentId,
    required this.resumeVersionId,
    required this.status,
    required this.routeStatus,
    required this.startedAt,
    required this.finishedAt,
    required this.toolCallCount,
    this.errorCode,
  });

  final String id;
  final String requestId;
  final String documentId;
  final String resumeVersionId;
  final String status;
  final String routeStatus;
  final DateTime startedAt;
  final DateTime finishedAt;
  final int toolCallCount;
  final String? errorCode;
}

final class ToolCallAuditRecord {
  const ToolCallAuditRecord({
    required this.id,
    required this.agentRunId,
    required this.toolName,
    required this.toolVersion,
    required this.status,
    required this.startedAt,
    required this.finishedAt,
    required this.offline,
    required this.replayed,
    this.errorCode,
  });

  final String id;
  final String agentRunId;
  final String toolName;
  final String toolVersion;
  final String status;
  final DateTime startedAt;
  final DateTime finishedAt;
  final bool offline;
  final bool replayed;
  final String? errorCode;
}

final class AgentAuditDataException implements Exception {
  const AgentAuditDataException(this.message);

  final String message;

  @override
  String toString() => 'AgentAuditDataException: $message';
}

abstract interface class AgentAuditRepository {
  Future<void> recordRun(
    AgentRunAuditRecord agentRun,
    List<ToolCallAuditRecord> toolCalls,
  );
}

final class DriftAgentAuditRepository implements AgentAuditRepository {
  const DriftAgentAuditRepository(this._database);

  final LocalStorageDatabase _database;

  @override
  Future<void> recordRun(
    AgentRunAuditRecord agentRun,
    List<ToolCallAuditRecord> toolCalls,
  ) async {
    _validateRun(agentRun, toolCalls);
    await _database.transaction(() async {
      await _database
          .into(_database.agentRuns)
          .insert(
            AgentRunsCompanion.insert(
              id: agentRun.id,
              requestId: agentRun.requestId,
              documentId: agentRun.documentId,
              resumeVersionId: agentRun.resumeVersionId,
              status: agentRun.status,
              routeStatus: agentRun.routeStatus,
              startedAt: agentRun.startedAt.toUtc(),
              finishedAt: agentRun.finishedAt.toUtc(),
              toolCallCount: Value(agentRun.toolCallCount),
              errorCode: Value(agentRun.errorCode),
            ),
          );
      for (final toolCall in toolCalls) {
        await _database
            .into(_database.toolCalls)
            .insert(
              ToolCallsCompanion.insert(
                id: toolCall.id,
                agentRunId: toolCall.agentRunId,
                toolName: toolCall.toolName,
                toolVersion: toolCall.toolVersion,
                status: toolCall.status,
                startedAt: toolCall.startedAt.toUtc(),
                finishedAt: toolCall.finishedAt.toUtc(),
                offline: toolCall.offline,
                replayed: toolCall.replayed,
                errorCode: Value(toolCall.errorCode),
              ),
            );
      }
    });
  }

  Future<AgentRunAuditRecord?> findRun(String runId) async {
    final runRow = await (_database.select(
      _database.agentRuns,
    )..where((agentRun) => agentRun.id.equals(runId))).getSingleOrNull();
    return runRow == null ? null : _runFromRow(runRow);
  }

  Future<List<AgentRunAuditRecord>> listRuns() async {
    final runRows =
        await (_database.select(_database.agentRuns)..orderBy([
              (agentRun) => OrderingTerm.asc(agentRun.startedAt),
              (agentRun) => OrderingTerm.asc(agentRun.id),
            ]))
            .get();
    return List.unmodifiable(runRows.map(_runFromRow));
  }

  Future<List<ToolCallAuditRecord>> listToolCalls(String runId) async {
    final toolCallRows =
        await (_database.select(_database.toolCalls)
              ..where((toolCall) => toolCall.agentRunId.equals(runId))
              ..orderBy([(toolCall) => OrderingTerm.asc(toolCall.startedAt)]))
            .get();
    return List.unmodifiable(toolCallRows.map(_toolCallFromRow));
  }
}

void _validateRun(
  AgentRunAuditRecord agentRun,
  List<ToolCallAuditRecord> toolCalls,
) {
  _requireText(agentRun.id, 'run.id');
  _requireText(agentRun.requestId, 'run.requestId');
  _requireText(agentRun.documentId, 'run.documentId');
  _requireText(agentRun.resumeVersionId, 'run.resumeVersionId');
  _requireText(agentRun.status, 'run.status');
  _requireText(agentRun.routeStatus, 'run.routeStatus');
  _requireOptionalText(agentRun.errorCode, 'run.errorCode');
  _requireOrderedTime(
    agentRun.startedAt,
    agentRun.finishedAt,
    'run.finishedAt',
  );
  if (agentRun.toolCallCount != toolCalls.length) {
    throw const AgentAuditDataException('工具调用计数与记录数量不一致');
  }

  for (final toolCall in toolCalls) {
    _requireText(toolCall.id, 'toolCall.id');
    _requireText(toolCall.agentRunId, 'toolCall.agentRunId');
    _requireText(toolCall.toolName, 'toolCall.toolName');
    _requireText(toolCall.toolVersion, 'toolCall.toolVersion');
    _requireText(toolCall.status, 'toolCall.status');
    _requireOptionalText(toolCall.errorCode, 'toolCall.errorCode');
    _requireOrderedTime(
      toolCall.startedAt,
      toolCall.finishedAt,
      'toolCall.finishedAt',
    );
    if (toolCall.agentRunId != agentRun.id) {
      throw const AgentAuditDataException('工具调用不属于当前 Agent 运行');
    }
  }
}

void _requireText(String text, String fieldName) {
  if (text.trim().isEmpty) {
    throw AgentAuditDataException('$fieldName 不能为空');
  }
}

void _requireOptionalText(String? text, String fieldName) {
  if (text != null && text.trim().isEmpty) {
    throw AgentAuditDataException('$fieldName 不能是空字符串');
  }
}

void _requireOrderedTime(
  DateTime startedAt,
  DateTime finishedAt,
  String fieldName,
) {
  if (finishedAt.isBefore(startedAt)) {
    throw AgentAuditDataException('$fieldName 不能早于 startedAt');
  }
}

AgentRunAuditRecord _runFromRow(AgentRunRow runRow) {
  return AgentRunAuditRecord(
    id: runRow.id,
    requestId: runRow.requestId,
    documentId: runRow.documentId,
    resumeVersionId: runRow.resumeVersionId,
    status: runRow.status,
    routeStatus: runRow.routeStatus,
    startedAt: runRow.startedAt,
    finishedAt: runRow.finishedAt,
    toolCallCount: runRow.toolCallCount,
    errorCode: runRow.errorCode,
  );
}

ToolCallAuditRecord _toolCallFromRow(ToolCallRow toolCallRow) {
  return ToolCallAuditRecord(
    id: toolCallRow.id,
    agentRunId: toolCallRow.agentRunId,
    toolName: toolCallRow.toolName,
    toolVersion: toolCallRow.toolVersion,
    status: toolCallRow.status,
    startedAt: toolCallRow.startedAt,
    finishedAt: toolCallRow.finishedAt,
    offline: toolCallRow.offline,
    replayed: toolCallRow.replayed,
    errorCode: toolCallRow.errorCode,
  );
}
