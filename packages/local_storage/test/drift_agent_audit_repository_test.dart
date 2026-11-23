import 'package:local_storage/local_storage.dart';
import 'package:test/test.dart';

final _startedAt = DateTime.utc(2026, 10, 2, 9, 0, 0, 123, 456);
final _finishedAt = _startedAt.add(const Duration(milliseconds: 20));

void main() {
  late LocalStorageDatabase database;
  late DriftAgentAuditRepository auditRepository;

  setUp(() {
    database = LocalStorageDatabase.inMemory();
    auditRepository = DriftAgentAuditRepository(database);
  });

  tearDown(() => database.close());

  test('一次事务写入运行与工具审计且只保留脱敏字段', () async {
    final agentRun = _run(toolCallCount: 2);
    final toolCalls = [
      _toolCall(id: 'call-validate', toolName: 'validate_resume'),
      _toolCall(
        id: 'call-repeated',
        toolName: 'find_repeated_content',
        replayed: true,
      ),
    ];

    await auditRepository.recordRun(agentRun, toolCalls);

    final storedRun = await auditRepository.findRun(agentRun.id);
    final storedToolCalls = await auditRepository.listToolCalls(agentRun.id);
    expect(storedRun!.requestId, 'request-001');
    expect(storedRun.toolCallCount, 2);
    expect(storedToolCalls.map((toolCall) => toolCall.toolName), [
      'validate_resume',
      'find_repeated_content',
    ]);
    expect(storedToolCalls.last.replayed, isTrue);

    final auditColumnRows = await database
        .customSelect(
          "SELECT name FROM pragma_table_info('agent_runs') "
          "UNION ALL SELECT name FROM pragma_table_info('tool_calls')",
        )
        .get();
    final auditColumnNames = auditColumnRows
        .map((columnRow) => columnRow.read<String>('name'))
        .toSet();
    const forbiddenAuditColumns = {
      'content_json',
      'arguments',
      'result_data',
      'idempotency_key',
      'api_key',
      'model_id',
      'provider_key',
    };
    expect(auditColumnNames.intersection(forbiddenAuditColumns), isEmpty);
  });

  test('计数或归属不一致时整次审计不写入', () async {
    final mismatchedToolCall = _toolCall(
      id: 'call-wrong-run',
      toolName: 'validate_resume',
      agentRunId: 'run-other',
    );

    await expectLater(
      auditRepository.recordRun(_run(toolCallCount: 1), [mismatchedToolCall]),
      throwsA(isA<AgentAuditDataException>()),
    );

    expect(await auditRepository.findRun('run-001'), isNull);
    final runCount = await database
        .customSelect('SELECT COUNT(*) AS count FROM agent_runs')
        .getSingle();
    final toolCallCount = await database
        .customSelect('SELECT COUNT(*) AS count FROM tool_calls')
        .getSingle();
    expect(runCount.read<int>('count'), 0);
    expect(toolCallCount.read<int>('count'), 0);
  });

  test('数据库约束失败时运行记录与工具记录共同回滚', () async {
    await auditRepository.recordRun(_run(toolCallCount: 0), const []);

    await expectLater(
      auditRepository.recordRun(
        _run(id: 'run-002', requestId: 'request-002', toolCallCount: 1),
        [
          _toolCall(
            id: 'call-duplicate',
            toolName: 'validate_resume',
            agentRunId: 'run-002',
          ),
        ],
      ),
      completes,
    );
    await expectLater(
      auditRepository.recordRun(
        _run(id: 'run-003', requestId: 'request-003', toolCallCount: 1),
        [
          _toolCall(
            id: 'call-duplicate',
            toolName: 'find_repeated_content',
            agentRunId: 'run-003',
          ),
        ],
      ),
      throwsA(isA<Exception>()),
    );

    expect(await auditRepository.findRun('run-003'), isNull);
  });
}

AgentRunAuditRecord _run({
  String id = 'run-001',
  String requestId = 'request-001',
  required int toolCallCount,
}) {
  return AgentRunAuditRecord(
    id: id,
    requestId: requestId,
    documentId: 'document-001',
    resumeVersionId: 'version-001',
    status: 'completed',
    routeStatus: 'selected',
    startedAt: _startedAt,
    finishedAt: _finishedAt,
    toolCallCount: toolCallCount,
  );
}

ToolCallAuditRecord _toolCall({
  required String id,
  required String toolName,
  String agentRunId = 'run-001',
  bool replayed = false,
}) {
  return ToolCallAuditRecord(
    id: id,
    agentRunId: agentRunId,
    toolName: toolName,
    toolVersion: '0.1.0',
    status: 'success',
    startedAt: _startedAt,
    finishedAt: _finishedAt,
    offline: true,
    replayed: replayed,
  );
}
