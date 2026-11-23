import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:agent_runtime/agent_runtime.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_domain/resume_domain.dart';
import 'package:test/test.dart';

final _createdAt = DateTime.utc(2026, 10, 2, 8, 0, 0, 123, 456);
final _runtimeNow = DateTime.utc(2026, 10, 2, 9, 0, 0, 654, 321);

void main() {
  late LocalStorageDatabase database;
  late DriftResumeRepository repository;
  late AgentRuntime runtime;
  late int idCounter;

  setUp(() async {
    database = LocalStorageDatabase.inMemory();
    repository = DriftResumeRepository(database);
    idCounter = 0;
    runtime = AgentRuntime(
      repository: repository,
      now: () => _runtimeNow,
      nextId: (namespace) => '$namespace-${++idCounter}',
    );
    await _seed(repository);
  });

  tearDown(() => database.close());

  group('AgentRuntime 最小闭环', () {
    test('Registry 只暴露四个离线白名单工具', () {
      expect(runtime.toolDescriptors.map((item) => item.name), [
        'build_patch',
        'find_repeated_content',
        'read_resume',
        'validate_resume',
      ]);
      expect(
        runtime.toolDescriptors.every((descriptor) => !descriptor.usesNetwork),
        isTrue,
      );
      expect(
        runtime.toolDescriptors.map((item) => item.access),
        containsAll([ToolAccess.read, ToolAccess.proposeWrite]),
      );
    });

    test('未知工具和非法参数被拒绝且不写入', () async {
      final unknown = await runtime.executeTool(
        _call(callId: 'unknown', toolName: 'run_shell', arguments: const {}),
      );
      final invalid = await runtime.executeTool(
        _call(
          callId: 'invalid',
          toolName: 'read_resume',
          arguments: const {'versionId': 'version-001', 'path': 'C:/sensitive'},
        ),
      );

      expect(unknown.status, ToolResultStatus.invalidCall);
      expect(unknown.error!.code, 'tool_not_allowed');
      expect(invalid.status, ToolResultStatus.invalidCall);
      expect(invalid.error!.code, 'argument_unknown');
      expect(await repository.listVersions('document-001'), hasLength(1));
    });

    test('read_resume 与 validate_resume 只读且返回结构化结果', () async {
      final read = await runtime.executeTool(
        _call(
          callId: 'read',
          toolName: 'read_resume',
          arguments: const {'versionId': 'version-001'},
        ),
      );
      final validate = await runtime.executeTool(
        _call(
          callId: 'validate',
          toolName: 'validate_resume',
          arguments: const {'versionId': 'version-001'},
        ),
      );

      expect(read.status, ToolResultStatus.success);
      expect(
        (read.data['version']! as Map<String, Object?>)['id'],
        'version-001',
      );
      expect(validate.status, ToolResultStatus.success);
      expect(validate.data['isValid'], isTrue);
      expect(validate.auditInfo.offline, isTrue);
      expect(await repository.listVersions('document-001'), hasLength(1));
    });

    test('find_repeated_content 规范化空白并按首次出现顺序返回精确重复', () async {
      final repeatedContent = await runtime.executeTool(
        _call(
          callId: 'find-repeated-content',
          toolName: 'find_repeated_content',
          arguments: const {'versionId': 'version-001'},
        ),
      );

      expect(repeatedContent.status, ToolResultStatus.success);
      expect(repeatedContent.data['repeatedGroupCount'], 1);
      expect(repeatedContent.data['repeatedOccurrenceCount'], 2);
      expect(repeatedContent.data['repeatedGroups'], [
        {
          'text': '负责核心 交付',
          'paths': [
            '/workExperiences/0/summary',
            '/workExperiences/0/highlights/0',
          ],
        },
      ]);
      expect(await repository.listVersions('document-001'), hasLength(1));
    });

    test('build_patch 只生成 Diff 和确认票据，accept 后创建新版本', () async {
      final proposal = await runtime.executeTool(_buildPatchCall('proposal'));

      expect(proposal.status, ToolResultStatus.requiresConfirmation);
      expect(proposal.data['riskLevel'], AgentRiskLevel.medium.name);
      expect(await repository.listVersions('document-001'), hasLength(1));
      expect(
        (await repository.findCurrentVersion('document-001'))!.id,
        'version-001',
      );

      final confirmationId = proposal.data['confirmationId']! as String;
      final accepted = await runtime.decide(
        ConfirmationCommand(
          confirmationId: confirmationId,
          decision: ConfirmationDecision.accept,
        ),
      );

      expect(accepted.status, ConfirmationStatus.accepted);
      final current = await repository.findCurrentVersion('document-001');
      final history = await repository.listVersions('document-001');
      expect(current!.id, accepted.newVersionId);
      expect(current.parentVersionId, 'version-001');
      expect(current.source, ResumeVersionSource.aiConfirmed);
      expect(current.content.profile.headline, '资深 Flutter 工程师');
      expect(history, hasLength(2));
      expect(
        (await repository.findVersion('version-001'))!.content.profile.headline,
        'Flutter 工程师',
      );
    });

    test('事实变更标记为 high，但仍只能进入确认流程', () async {
      final proposal = await runtime.executeTool(
        _buildPatchCall(
          'fact-change',
          path: '/profile/fullName',
          oldValue: '张三',
          newValue: '张三丰',
          category: 'fact',
        ),
      );

      expect(proposal.status, ToolResultStatus.requiresConfirmation);
      expect(proposal.data['riskLevel'], AgentRiskLevel.high.name);
      expect(await repository.listVersions('document-001'), hasLength(1));
    });

    test('重复 accept 幂等且不能改为 reject', () async {
      final proposal = await runtime.executeTool(_buildPatchCall('proposal'));
      final confirmationId = proposal.data['confirmationId']! as String;
      final command = ConfirmationCommand(
        confirmationId: confirmationId,
        decision: ConfirmationDecision.accept,
      );

      final first = await runtime.decide(command);
      final replay = await runtime.decide(command);
      final changedDecision = await runtime.decide(
        ConfirmationCommand(
          confirmationId: confirmationId,
          decision: ConfirmationDecision.reject,
        ),
      );

      expect(first.status, ConfirmationStatus.accepted);
      expect(replay.status, ConfirmationStatus.accepted);
      expect(replay.replayed, isTrue);
      expect(replay.newVersionId, first.newVersionId);
      expect(changedDecision.status, ConfirmationStatus.alreadyResolved);
      expect(await repository.listVersions('document-001'), hasLength(2));
    });

    test('并发 accept 被串行化且只创建一个版本', () async {
      final proposal = await runtime.executeTool(_buildPatchCall('concurrent'));
      final command = ConfirmationCommand(
        confirmationId: proposal.data['confirmationId']! as String,
        decision: ConfirmationDecision.accept,
      );

      final results = await Future.wait([
        runtime.decide(command),
        runtime.decide(command),
      ]);

      expect(
        results.map((item) => item.status),
        everyElement(ConfirmationStatus.accepted),
      );
      expect(results.where((item) => item.replayed), hasLength(1));
      expect(results.map((item) => item.newVersionId).toSet(), hasLength(1));
      expect(await repository.listVersions('document-001'), hasLength(2));
    });

    test('reject 与 cancel 均不创建版本', () async {
      final rejectedProposal = await runtime.executeTool(
        _buildPatchCall('reject'),
      );
      final cancelledProposal = await runtime.executeTool(
        _buildPatchCall('cancel', idempotencyKey: 'cancel-key'),
      );

      final rejected = await runtime.decide(
        ConfirmationCommand(
          confirmationId: rejectedProposal.data['confirmationId']! as String,
          decision: ConfirmationDecision.reject,
        ),
      );
      final cancelled = await runtime.decide(
        ConfirmationCommand(
          confirmationId: cancelledProposal.data['confirmationId']! as String,
          decision: ConfirmationDecision.cancel,
        ),
      );

      expect(rejected.status, ConfirmationStatus.rejected);
      expect(cancelled.status, ConfirmationStatus.cancelled);
      expect(await repository.listVersions('document-001'), hasLength(1));
    });

    test('非法 Patch 被拒绝且不生成版本', () async {
      final result = await runtime.executeTool(
        _buildPatchCall('invalid-patch', oldValue: '过期旧值'),
      );

      expect(result.status, ToolResultStatus.invalidCall);
      expect(result.error!.code, 'patch_invalid');
      expect(await repository.listVersions('document-001'), hasLength(1));
    });

    test('未通过 Canonical validation 的 Patch 返回结构化问题', () async {
      final result = await runtime.executeTool(
        _buildPatchCall(
          'invalid-email',
          path: '/profile/email',
          oldValue: 'user@example.com',
          newValue: 'invalid-email',
          category: 'fact',
        ),
      );

      expect(result.status, ToolResultStatus.invalidCall);
      expect(result.error!.code, 'validation_failed');
      expect(
        result.validationIssues.map((issue) => issue.ruleId),
        contains('email.format'),
      );
      expect(await repository.listVersions('document-001'), hasLength(1));
    });

    test('基础版本变化后确认返回 conflict 且不产生部分版本', () async {
      final proposal = await runtime.executeTool(_buildPatchCall('stale'));
      await _saveManualVersion(repository);

      final result = await runtime.decide(
        ConfirmationCommand(
          confirmationId: proposal.data['confirmationId']! as String,
          decision: ConfirmationDecision.accept,
        ),
      );

      expect(result.status, ConfirmationStatus.conflict);
      expect(
        (await repository.findCurrentVersion('document-001'))!.id,
        'version-manual',
      );
      expect(await repository.listVersions('document-001'), hasLength(2));
    });

    test('相同幂等调用重放同一票据，不同调用复用键时冲突', () async {
      final first = await runtime.executeTool(
        _buildPatchCall('first', idempotencyKey: 'shared-key'),
      );
      final replay = await runtime.executeTool(
        _buildPatchCall('replay', idempotencyKey: 'shared-key'),
      );
      final conflict = await runtime.executeTool(
        _call(
          callId: 'conflict',
          toolName: 'read_resume',
          arguments: const {'versionId': 'version-001'},
          idempotencyKey: 'shared-key',
        ),
      );

      expect(replay.status, ToolResultStatus.requiresConfirmation);
      expect(replay.auditInfo.replayed, isTrue);
      expect(replay.data['confirmationId'], first.data['confirmationId']);
      expect(conflict.status, ToolResultStatus.conflict);
      expect(conflict.error!.code, 'idempotency_key_conflict');
    });

    test('清空临时状态后旧确认票据失效且幂等调用重新执行', () async {
      final proposal = await runtime.executeTool(
        _buildPatchCall('before-clear'),
      );
      final originalConfirmationId = proposal.data['confirmationId']! as String;

      runtime.clearTransientState();

      final clearedDecision = await runtime.decide(
        ConfirmationCommand(
          confirmationId: originalConfirmationId,
          decision: ConfirmationDecision.accept,
        ),
      );
      final rebuiltProposal = await runtime.executeTool(
        _buildPatchCall('after-clear'),
      );

      expect(clearedDecision.status, ConfirmationStatus.notFound);
      expect(rebuiltProposal.auditInfo.replayed, isFalse);
      expect(
        rebuiltProposal.data['confirmationId'],
        isNot(originalConfirmationId),
      );
      expect(await repository.listVersions('document-001'), hasLength(1));
    });

    test('预先取消的调用返回 cancelled 且可使用新调用恢复', () async {
      final token = AgentCancellationToken()..cancel();
      final cancelled = await runtime.executeTool(
        _call(
          callId: 'cancelled',
          toolName: 'read_resume',
          arguments: const {'versionId': 'version-001'},
          idempotencyKey: 'cancelled-key',
        ),
        cancellationToken: token,
      );
      final recovered = await runtime.executeTool(
        _call(
          callId: 'recovered',
          toolName: 'read_resume',
          arguments: const {'versionId': 'version-001'},
          idempotencyKey: 'cancelled-key',
        ),
      );

      expect(cancelled.status, ToolResultStatus.cancelled);
      expect(recovered.status, ToolResultStatus.success);
    });

    test('执行与确认过程不打印简历正文', () async {
      final output = <String>[];

      await runZoned(
        () async {
          final proposal = await runtime.executeTool(
            _buildPatchCall('private-content'),
          );
          await runtime.decide(
            ConfirmationCommand(
              confirmationId: proposal.data['confirmationId']! as String,
              decision: ConfirmationDecision.accept,
            ),
          );
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => output.add(line),
        ),
      );

      expect(output.join('\n'), isNot(contains('张三')));
      expect(output.join('\n'), isNot(contains('user@example.com')));
    });
  });

  group('ToolRegistry 故障边界', () {
    test('超时返回 timeout 且不缓存失败', () async {
      var executions = 0;
      final registry = ToolRegistry(
        tools: [_CallbackTool.slow(() => executions++)],
        now: () => _runtimeNow,
      );
      final call = _call(
        callId: 'slow-1',
        toolName: 'slow',
        arguments: const {},
        idempotencyKey: 'slow-key',
      );

      final first = await registry.execute(call);
      final second = await registry.execute(
        _call(
          callId: 'slow-2',
          toolName: 'slow',
          arguments: const {},
          idempotencyKey: 'slow-key',
        ),
      );

      expect(first.status, ToolResultStatus.timeout);
      expect(second.status, ToolResultStatus.timeout);
      expect(executions, 2);
    });

    test('工具异常被安全映射，随后可以重试成功', () async {
      var executions = 0;
      final registry = ToolRegistry(
        tools: [
          _CallbackTool(
            name: 'flaky',
            callback: () async {
              executions++;
              if (executions == 1) {
                throw StateError('不应暴露的内部错误');
              }
              return ToolOutcome(status: ToolResultStatus.success);
            },
          ),
        ],
        now: () => _runtimeNow,
      );
      final first = await registry.execute(
        _call(
          callId: 'flaky-1',
          toolName: 'flaky',
          arguments: const {},
          idempotencyKey: 'flaky-key',
        ),
      );
      final second = await registry.execute(
        _call(
          callId: 'flaky-2',
          toolName: 'flaky',
          arguments: const {},
          idempotencyKey: 'flaky-key',
        ),
      );

      expect(first.status, ToolResultStatus.failed);
      expect(first.error!.message, isNot(contains('内部错误')));
      expect(second.status, ToolResultStatus.success);
    });
  });
}

Future<void> _seed(ResumeRepository repository) async {
  final content = ResumeData(
    profile: ResumeProfile(
      id: 'profile-001',
      fullName: '张三',
      headline: 'Flutter 工程师',
      email: 'user@example.com',
      phone: '13800000000',
      location: '上海',
    ),
    workExperiences: [
      WorkExperience(
        id: 'work-001',
        organization: '示例科技',
        position: 'Flutter 工程师',
        dateRange: DateRange(
          start: ResumeDate(year: 2024, month: 1),
          end: null,
          isCurrent: true,
        ),
        summary: '  负责核心\n交付  ',
        highlights: const ['负责核心 交付', ''],
      ),
    ],
  );
  final version = ResumeVersion(
    id: 'version-001',
    documentId: 'document-001',
    parentVersionId: null,
    schemaVersion: currentResumeSchemaVersion,
    content: content,
    source: ResumeVersionSource.created,
    createdAt: _createdAt,
  );
  final document = ResumeDocument(
    id: 'document-001',
    title: '主简历',
    currentVersionId: version.id,
    createdAt: _createdAt,
    updatedAt: _createdAt,
  );
  await repository.createDocument(document, version);
}

Future<void> _saveManualVersion(ResumeRepository repository) async {
  final document = (await repository.findDocument('document-001'))!;
  final current = (await repository.findCurrentVersion('document-001'))!;
  final version = ResumeVersion(
    id: 'version-manual',
    documentId: document.id,
    parentVersionId: current.id,
    schemaVersion: current.schemaVersion,
    content: ResumeData(
      profile: ResumeProfile(
        id: 'profile-001',
        fullName: '张三',
        headline: '手工更新',
        email: 'user@example.com',
        phone: '13800000000',
        location: '上海',
      ),
    ),
    source: ResumeVersionSource.edited,
    createdAt: _runtimeNow,
  );
  await repository.saveVersion(
    document: ResumeDocument(
      id: document.id,
      title: document.title,
      currentVersionId: version.id,
      createdAt: document.createdAt,
      updatedAt: _runtimeNow,
      metadata: document.metadata,
      extensions: document.extensions,
    ),
    version: version,
    expectedCurrentVersionId: current.id,
  );
}

ToolCall _buildPatchCall(
  String callId, {
  String idempotencyKey = 'proposal-key',
  String path = '/profile/headline',
  Object? oldValue = 'Flutter 工程师',
  Object? newValue = '资深 Flutter 工程师',
  String category = 'wording',
}) {
  return _call(
    callId: callId,
    toolName: 'build_patch',
    idempotencyKey: idempotencyKey,
    arguments: {
      'versionId': 'version-001',
      'patch': {
        'operations': [
          {
            'type': 'replace',
            'path': path,
            'oldValue': oldValue,
            'newValue': newValue,
            'reason': '让职位定位更清晰',
            'source': 'fake-agent',
            'category': category,
          },
        ],
      },
    },
  );
}

ToolCall _call({
  required String callId,
  required String toolName,
  required JsonObject arguments,
  String? idempotencyKey,
}) {
  return ToolCall(
    callId: callId,
    toolName: toolName,
    arguments: arguments,
    requestedBy: 'fake-agent',
    idempotencyKey: idempotencyKey ?? 'key-$callId',
  );
}

final class _CallbackTool implements AgentTool {
  _CallbackTool({required String name, required this.callback})
    : descriptor = _testDescriptor(name, timeoutMs: 100);

  _CallbackTool.slow(void Function() onExecute)
    : descriptor = _testDescriptor('slow', timeoutMs: 1),
      callback = (() async {
        onExecute();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return ToolOutcome(status: ToolResultStatus.success);
      });

  @override
  final ToolDescriptor descriptor;

  final Future<ToolOutcome> Function() callback;

  @override
  Future<ToolOutcome> execute(
    JsonObject arguments, {
    required AgentCancellationToken cancellationToken,
  }) {
    return callback();
  }
}

ToolDescriptor _testDescriptor(String name, {required int timeoutMs}) {
  return ToolDescriptor(
    name: name,
    version: currentAgentProtocolVersion,
    inputSchema: const {'type': 'object'},
    outputSchema: const {'type': 'object'},
    permission: ToolPermission.resumeRead,
    access: ToolAccess.read,
    usesNetwork: false,
    retryable: true,
    timeoutMs: timeoutMs,
    auditFields: const ['toolName'],
  );
}
