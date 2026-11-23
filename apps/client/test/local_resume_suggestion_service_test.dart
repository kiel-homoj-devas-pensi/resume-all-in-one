import 'package:agent_protocol/agent_protocol.dart';
import 'package:agent_runtime/agent_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_storage/local_storage.dart';
import 'package:model_router/model_router.dart';
import 'support/local_suggestion_fixture.dart';
import 'package:resume_all_in_one_client/src/local_resume_suggestion_service.dart';
import 'package:resume_domain/resume_domain.dart';

final _baseTime = DateTime.utc(2026, 10, 2, 11, 0, 0, 123, 456);

void main() {
  late LocalStorageDatabase database;
  late DriftResumeRepository resumeRepository;
  late DriftAgentAuditRepository auditRepository;
  late int idCounter;

  setUp(() {
    database = LocalStorageDatabase.inMemory();
    resumeRepository = DriftResumeRepository(database);
    auditRepository = DriftAgentAuditRepository(database);
    idCounter = 0;
  });

  tearDown(() => database.close());

  String nextId(String namespace) => '$namespace-${++idCounter}';

  test('准备建议只生成 Patch、Diff 与确认票据，拒绝后不写版本', () async {
    final seeded = await _seedResume(
      resumeRepository,
      headline: 'Flutter  工程师',
    );
    final suggestionService = createOfflineLocalResumeSuggestionService(
      resumeRepository: resumeRepository,
      auditRepository: auditRepository,
      clock: () => _baseTime,
      nextId: nextId,
    );

    final preparation = await suggestionService.prepareSuggestion(
      document: seeded.$1,
      version: seeded.$2,
      networkEnabled: false,
    );

    expect(preparation.status, LocalSuggestionPreparationStatus.ready);
    final pendingSuggestion = preparation.pendingSuggestion!;
    expect(pendingSuggestion.diff.entries, hasLength(1));
    final diffEntry = pendingSuggestion.diff.entries.single;
    expect(diffEntry.path, '/profile/headline');
    expect(diffEntry.category, ResumeChangeCategory.format);
    expect(diffEntry.oldValue, 'Flutter  工程师');
    expect(diffEntry.newValue, 'Flutter 工程师');
    expect(diffEntry.reason, contains('统一多余空白'));
    expect(pendingSuggestion.hasBlockingValidationIssue, isFalse);
    expect(await resumeRepository.listVersions(seeded.$1.id), hasLength(1));
    expect(
      (await resumeRepository.findCurrentVersion(seeded.$1.id))!.id,
      seeded.$2.id,
    );

    final rejection = await suggestionService.decide(
      suggestion: pendingSuggestion,
      decision: LocalSuggestionDecision.reject,
    );
    expect(rejection.status, LocalSuggestionDecisionStatus.rejected);
    expect(await resumeRepository.listVersions(seeded.$1.id), hasLength(1));

    final auditRunCount = await database
        .customSelect('SELECT COUNT(*) AS count FROM agent_runs')
        .getSingle();
    final auditTool = await database
        .customSelect('SELECT tool_name FROM tool_calls')
        .getSingle();
    expect(auditRunCount.read<int>('count'), 1);
    expect(auditTool.read<String>('tool_name'), 'build_patch');
  });

  test('明确确认只追加一个 aiConfirmed 版本且重复确认不重复写入', () async {
    final seeded = await _seedResume(
      resumeRepository,
      headline: 'Flutter  工程师',
    );
    final suggestionService = createOfflineLocalResumeSuggestionService(
      resumeRepository: resumeRepository,
      auditRepository: auditRepository,
      clock: () => _baseTime,
      nextId: nextId,
    );
    final pendingSuggestion = (await suggestionService.prepareSuggestion(
      document: seeded.$1,
      version: seeded.$2,
      networkEnabled: false,
    )).pendingSuggestion!;

    final accepted = await suggestionService.decide(
      suggestion: pendingSuggestion,
      decision: LocalSuggestionDecision.accept,
    );
    final replayed = await suggestionService.decide(
      suggestion: pendingSuggestion,
      decision: LocalSuggestionDecision.accept,
    );

    expect(accepted.status, LocalSuggestionDecisionStatus.accepted);
    expect(replayed.status, LocalSuggestionDecisionStatus.accepted);
    expect(replayed.newVersionId, accepted.newVersionId);
    final versionHistory = await resumeRepository.listVersions(seeded.$1.id);
    expect(versionHistory, hasLength(2));
    expect(versionHistory.first.source, ResumeVersionSource.aiConfirmed);
    expect(versionHistory.first.parentVersionId, seeded.$2.id);
    expect(versionHistory.first.content.profile.headline, 'Flutter 工程师');
    expect(versionHistory.last.content.profile.headline, 'Flutter  工程师');
  });

  test('取消审阅不写版本且票据不能改为确认', () async {
    final seeded = await _seedResume(
      resumeRepository,
      headline: 'Flutter  工程师',
    );
    final suggestionService = createOfflineLocalResumeSuggestionService(
      resumeRepository: resumeRepository,
      auditRepository: auditRepository,
      clock: () => _baseTime,
      nextId: nextId,
    );
    final pendingSuggestion = (await suggestionService.prepareSuggestion(
      document: seeded.$1,
      version: seeded.$2,
      networkEnabled: false,
    )).pendingSuggestion!;

    final cancellation = await suggestionService.decide(
      suggestion: pendingSuggestion,
      decision: LocalSuggestionDecision.cancel,
    );
    final changedDecision = await suggestionService.decide(
      suggestion: pendingSuggestion,
      decision: LocalSuggestionDecision.accept,
    );

    expect(cancellation.status, LocalSuggestionDecisionStatus.cancelled);
    expect(
      changedDecision.status,
      LocalSuggestionDecisionStatus.alreadyResolved,
    );
    expect(await resumeRepository.listVersions(seeded.$1.id), hasLength(1));
  });

  test('基础版本变化后确认返回 conflict 且不在新版本上重放 Patch', () async {
    final seeded = await _seedResume(
      resumeRepository,
      headline: 'Flutter  工程师',
    );
    final suggestionService = createOfflineLocalResumeSuggestionService(
      resumeRepository: resumeRepository,
      auditRepository: auditRepository,
      clock: () => _baseTime,
      nextId: nextId,
    );
    final pendingSuggestion = (await suggestionService.prepareSuggestion(
      document: seeded.$1,
      version: seeded.$2,
      networkEnabled: false,
    )).pendingSuggestion!;
    await _appendManualVersion(resumeRepository, seeded.$1, seeded.$2);

    final confirmation = await suggestionService.decide(
      suggestion: pendingSuggestion,
      decision: LocalSuggestionDecision.accept,
    );

    expect(confirmation.status, LocalSuggestionDecisionStatus.conflict);
    final versionHistory = await resumeRepository.listVersions(seeded.$1.id);
    expect(versionHistory, hasLength(2));
    expect(versionHistory.first.source, ResumeVersionSource.edited);
    expect(
      versionHistory.where(
        (version) => version.source == ResumeVersionSource.aiConfirmed,
      ),
      isEmpty,
    );
  });

  test('没有安全候选时返回 noSuggestion 且不调用 build_patch', () async {
    final seeded = await _seedResume(resumeRepository, headline: 'Flutter 工程师');
    final suggestionService = createOfflineLocalResumeSuggestionService(
      resumeRepository: resumeRepository,
      auditRepository: auditRepository,
      clock: () => _baseTime,
      nextId: nextId,
    );

    final preparation = await suggestionService.prepareSuggestion(
      document: seeded.$1,
      version: seeded.$2,
      networkEnabled: false,
    );

    expect(preparation.status, LocalSuggestionPreparationStatus.noSuggestion);
    expect(preparation.pendingSuggestion, isNull);
    expect(await resumeRepository.listVersions(seeded.$1.id), hasLength(1));
    final toolCallCount = await database
        .customSelect('SELECT COUNT(*) AS count FROM tool_calls')
        .getSingle();
    expect(toolCallCount.read<int>('count'), 0);
  });

  test('旧值不匹配的 Provider Patch 在确认票据生成前被拒绝', () async {
    final seeded = await _seedResume(resumeRepository, headline: 'Flutter 工程师');
    final invalidPatch = ResumePatch([
      ResumePatchOperation(
        type: PatchOperationType.replace,
        path: '/profile/headline',
        oldValue: '过期旧值',
        newValue: '新标题',
        reason: '测试非法 Patch',
        source: '测试',
        category: ResumeChangeCategory.wording,
      ),
    ]);
    final suggestionService = _customSuggestionService(
      resumeRepository: resumeRepository,
      auditRepository: auditRepository,
      nextId: nextId,
      response: AgentResponse(
        summary: '非法建议',
        proposedPatch: invalidPatch.toJson(),
        nextAction: AgentNextAction.reviewPatch,
      ),
    );

    final preparation = await suggestionService.prepareSuggestion(
      document: seeded.$1,
      version: seeded.$2,
      networkEnabled: false,
    );

    expect(
      preparation.status,
      LocalSuggestionPreparationStatus.invalidResponse,
    );
    expect(preparation.errorCode, 'patch_invalid');
    expect(preparation.pendingSuggestion, isNull);
    expect(await resumeRepository.listVersions(seeded.$1.id), hasLength(1));
  });

  test('事实类建议保留显式分类供 UI 风险提示', () async {
    final seeded = await _seedResume(resumeRepository, headline: 'Flutter 工程师');
    final factPatch = ResumePatch([
      ResumePatchOperation(
        type: PatchOperationType.replace,
        path: '/profile/headline',
        oldValue: 'Flutter 工程师',
        newValue: '资深 Flutter 工程师',
        reason: '这是一项必须人工确认的事实定位变化',
        source: '测试',
        category: ResumeChangeCategory.fact,
      ),
    ]);
    final suggestionService = _customSuggestionService(
      resumeRepository: resumeRepository,
      auditRepository: auditRepository,
      nextId: nextId,
      response: AgentResponse(
        summary: '事实类建议',
        proposedPatch: factPatch.toJson(),
        nextAction: AgentNextAction.reviewPatch,
      ),
    );

    final preparation = await suggestionService.prepareSuggestion(
      document: seeded.$1,
      version: seeded.$2,
      networkEnabled: false,
    );

    expect(preparation.status, LocalSuggestionPreparationStatus.ready);
    expect(preparation.pendingSuggestion!.containsFactChanges, isTrue);
    expect(
      preparation.pendingSuggestion!.diff.entries.single.category,
      ResumeChangeCategory.fact,
    );
    expect(await resumeRepository.listVersions(seeded.$1.id), hasLength(1));
  });

  test('确认写入暂时失败后可重试同一建议且只生成一个版本', () async {
    final seeded = await _seedResume(resumeRepository, headline: 'Flutter 工程师');
    final failOnceRepository = _FailOnceResumeRepository(resumeRepository);
    final formatPatch = ResumePatch([
      ResumePatchOperation(
        type: PatchOperationType.replace,
        path: '/profile/headline',
        oldValue: 'Flutter 工程师',
        newValue: 'Flutter 客户端工程师',
        reason: '测试失败后重试',
        source: '测试',
        category: ResumeChangeCategory.wording,
      ),
    ]);
    final suggestionService = _customSuggestionService(
      resumeRepository: failOnceRepository,
      auditRepository: auditRepository,
      nextId: nextId,
      response: AgentResponse(
        summary: '可重试建议',
        proposedPatch: formatPatch.toJson(),
        nextAction: AgentNextAction.reviewPatch,
      ),
    );
    final pendingSuggestion = (await suggestionService.prepareSuggestion(
      document: seeded.$1,
      version: seeded.$2,
      networkEnabled: false,
    )).pendingSuggestion!;

    final failedConfirmation = await suggestionService.decide(
      suggestion: pendingSuggestion,
      decision: LocalSuggestionDecision.accept,
    );
    final recoveredConfirmation = await suggestionService.decide(
      suggestion: pendingSuggestion,
      decision: LocalSuggestionDecision.accept,
    );

    expect(failedConfirmation.status, LocalSuggestionDecisionStatus.failed);
    expect(failedConfirmation.errorCode, 'confirmation_failed');
    expect(
      recoveredConfirmation.status,
      LocalSuggestionDecisionStatus.accepted,
    );
    final versionHistory = await resumeRepository.listVersions(seeded.$1.id);
    expect(versionHistory, hasLength(2));
    expect(versionHistory.first.source, ResumeVersionSource.aiConfirmed);
  });
}

LocalResumeSuggestionService _customSuggestionService({
  required ResumeRepository resumeRepository,
  required AgentAuditRepository auditRepository,
  required String Function(String namespace) nextId,
  required AgentResponse response,
}) {
  final runtime = AgentRuntime(
    repository: resumeRepository,
    now: () => _baseTime,
    nextId: nextId,
  );
  final provider = FakeModelProvider(
    descriptor: ProviderDescriptor(
      providerKey: 'test-suggestion-provider',
      location: ProviderLocation.local,
      capabilities: const {ModelCapability.structuredOutput},
    ),
    generate: (_) async => ModelResponse(
      text: response.summary,
      structuredData: response.toJson(),
      usage: ModelUsage(inputTokens: 0, outputTokens: 0),
      finishReason: ModelFinishReason.completed,
    ),
  );
  return LocalResumeSuggestionService(
    runtime: runtime,
    router: ModelRouter(
      ModelRegistry(
        registrations: [
          ProviderRegistration(
            provider: provider,
            modelId: 'test-suggestion-model',
          ),
        ],
      ),
    ),
    auditRepository: auditRepository,
    clock: () => _baseTime,
    nextId: nextId,
  );
}

Future<(ResumeDocument, ResumeVersion)> _seedResume(
  ResumeRepository repository, {
  required String headline,
}) async {
  final content = ResumeData(
    profile: ResumeProfile(
      id: 'profile-001',
      fullName: '张三',
      headline: headline,
      email: 'user@example.com',
      phone: '',
      location: '',
    ),
  );
  final version = ResumeVersion(
    id: 'version-001',
    documentId: 'document-001',
    parentVersionId: null,
    schemaVersion: currentResumeSchemaVersion,
    content: content,
    source: ResumeVersionSource.created,
    createdAt: _baseTime,
  );
  final document = ResumeDocument(
    id: 'document-001',
    title: '建议测试简历',
    currentVersionId: version.id,
    createdAt: _baseTime,
    updatedAt: _baseTime,
  );
  await repository.createDocument(document, version);
  return (document, version);
}

Future<void> _appendManualVersion(
  ResumeRepository repository,
  ResumeDocument document,
  ResumeVersion baseVersion,
) async {
  final editedAt = _baseTime.add(const Duration(minutes: 1));
  final manualVersion = ResumeVersion(
    id: 'version-manual',
    documentId: document.id,
    parentVersionId: baseVersion.id,
    schemaVersion: currentResumeSchemaVersion,
    content: ResumeData(
      profile: ResumeProfile(
        id: 'profile-001',
        fullName: '张三',
        headline: '手工更新标题',
        email: 'user@example.com',
        phone: '',
        location: '',
      ),
    ),
    source: ResumeVersionSource.edited,
    createdAt: editedAt,
  );
  await repository.saveVersion(
    document: ResumeDocument(
      id: document.id,
      title: document.title,
      currentVersionId: manualVersion.id,
      createdAt: document.createdAt,
      updatedAt: editedAt,
    ),
    version: manualVersion,
    expectedCurrentVersionId: baseVersion.id,
  );
}

final class _FailOnceResumeRepository implements ResumeRepository {
  _FailOnceResumeRepository(this._delegate);

  final ResumeRepository _delegate;
  bool _shouldFailNextSave = true;

  @override
  Future<void> createDocument(
    ResumeDocument document,
    ResumeVersion initialVersion,
  ) => _delegate.createDocument(document, initialVersion);

  @override
  Future<bool> deleteDocument(String documentId) =>
      _delegate.deleteDocument(documentId);

  @override
  Future<ResumeDocument?> findDocument(String documentId) =>
      _delegate.findDocument(documentId);

  @override
  Future<ResumeVersion?> findCurrentVersion(String documentId) =>
      _delegate.findCurrentVersion(documentId);

  @override
  Future<ResumeVersion?> findVersion(String versionId) =>
      _delegate.findVersion(versionId);

  @override
  Future<List<ResumeDocument>> listDocuments() => _delegate.listDocuments();

  @override
  Future<List<ResumeVersion>> listVersions(String documentId) =>
      _delegate.listVersions(documentId);

  @override
  Future<void> saveVersion({
    required ResumeDocument document,
    required ResumeVersion version,
    required String expectedCurrentVersionId,
  }) {
    if (_shouldFailNextSave) {
      _shouldFailNextSave = false;
      throw StateError('测试用暂时存储故障');
    }
    return _delegate.saveVersion(
      document: document,
      version: version,
      expectedCurrentVersionId: expectedCurrentVersionId,
    );
  }
}
