import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_domain/resume_domain.dart';

import 'gateway_api_client.dart';
import 'remote_account_service.dart';
import 'remote_task_draft_store.dart';
import 'resume_review_format.dart';

enum RemotePersonalDataField { fullName, phone, email, preciseAddress }

const remoteSemanticReviewWarning =
    '改写含义待核实：程序无法确认全部语义，请核对完整建议，明确确认事实与修改范围后再保存。';

final class RemoteWritingContext {
  RemoteWritingContext({
    Map<String, String> confirmedFacts = const {},
    List<String> constraints = const [],
  }) : confirmedFacts = Map.unmodifiable(
         confirmedFacts.map((path, text) => MapEntry(path, text.trim())),
       ),
       constraints = List.unmodifiable(constraints.map((text) => text.trim()));

  final Map<String, String> confirmedFacts;
  final List<String> constraints;
  bool get isEmpty => confirmedFacts.isEmpty && constraints.isEmpty;
  Map<String, Object?> toJson(String fingerprint) => {
    'baseResumeFingerprint': fingerprint,
    'confirmedFacts': [
      for (final fact in confirmedFacts.entries)
        {'path': fact.key, 'text': fact.value},
    ],
    'constraints': constraints,
  };
}

final class RemoteWritingFactField {
  const RemoteWritingFactField(this.path, this.label, this.text);
  final String path;
  final String label;
  final String text;
}

List<RemoteWritingFactField> remoteWritingFactFields(ResumeData content) => [
  RemoteWritingFactField('/profile/headline', '职业概述', content.profile.headline),
  for (var i = 0; i < content.workExperiences.length; i++) ...[
    RemoteWritingFactField(
      '/workExperiences/$i/summary',
      '工作${i + 1}：${content.workExperiences[i].organization} · 描述',
      content.workExperiences[i].summary,
    ),
    for (var j = 0; j < content.workExperiences[i].highlights.length; j++)
      RemoteWritingFactField(
        '/workExperiences/$i/highlights/$j',
        '工作${i + 1} · 要点${j + 1}',
        content.workExperiences[i].highlights[j],
      ),
  ],
  for (var i = 0; i < content.educations.length; i++)
    for (var j = 0; j < content.educations[i].highlights.length; j++)
      RemoteWritingFactField(
        '/educations/$i/highlights/$j',
        '教育${i + 1} · 要点${j + 1}',
        content.educations[i].highlights[j],
      ),
  for (var i = 0; i < content.projects.length; i++) ...[
    RemoteWritingFactField(
      '/projects/$i/summary',
      '项目${i + 1}：${content.projects[i].name} · 描述',
      content.projects[i].summary,
    ),
    for (var j = 0; j < content.projects[i].highlights.length; j++)
      RemoteWritingFactField(
        '/projects/$i/highlights/$j',
        '项目${i + 1} · 要点${j + 1}',
        content.projects[i].highlights[j],
      ),
  ],
  for (var i = 0; i < content.customSections.length; i++)
    for (var j = 0; j < content.customSections[i].items.length; j++) ...[
      RemoteWritingFactField(
        '/customSections/$i/items/$j/title',
        '自定义${i + 1} · 项目${j + 1}标题',
        content.customSections[i].items[j].title,
      ),
      RemoteWritingFactField(
        '/customSections/$i/items/$j/description',
        '自定义${i + 1} · 项目${j + 1}描述',
        content.customSections[i].items[j].description,
      ),
    ],
];

final class BasicResumeComposeDraft {
  BasicResumeComposeDraft({
    required this.documentTitle,
    required this.sourceText,
    required this.fullName,
    required this.phone,
    required this.email,
    required this.preciseAddress,
    this.naturalLanguageInput = false,
    this.confirmedInputSharing = false,
    this.headline = '',
    List<ResumeLink> links = const [],
    this.photo,
    this.sharePersonalData,
    Set<RemotePersonalDataField> selectedPersonalFields = const {},
  }) : links = List.unmodifiable(links),
       selectedPersonalFields = Set.unmodifiable(selectedPersonalFields);

  final String documentTitle;
  final String sourceText;
  final String fullName;
  final String phone;
  final String email;
  final String preciseAddress;
  final String headline;
  final List<ResumeLink> links;
  final ResumePhoto? photo;
  // Null keeps the older field-level API contract; new dialogs always choose once.
  final bool? sharePersonalData;
  final bool naturalLanguageInput;
  final bool confirmedInputSharing;
  final Set<RemotePersonalDataField> selectedPersonalFields;

  ResumeProfile localProfile(String id) => ResumeProfile(
    id: id,
    fullName: fullName.trim(),
    headline: headline.trim(),
    email: email.trim(),
    phone: phone.trim(),
    location: preciseAddress.trim(),
    links: links,
    photo: photo,
  );

  String get sourceMaterial => [
    sourceText,
    if (headline.trim().isNotEmpty) '意向职业岗位：${headline.trim()}',
  ].join('\n');

  String get remoteMaterialPreview => sharePersonalData == false
      ? _RemotePersonalTextRedactor(
          localProfile('local-profile'),
        ).redact(sourceMaterial)
      : sourceMaterial;

  List<ValidationIssue> get profileValidationIssues => const ResumeValidator()
      .validate(ResumeData(profile: localProfile('draft-profile')))
      .issues;
}

enum RemoteResumeChangeTarget { newDocument, currentDocument }

final class PendingRemoteResumeChange {
  PendingRemoteResumeChange({
    required this.target,
    required this.documentTitle,
    required this.documentId,
    required this.baseVersionId,
    required this.operationId,
    required this.summary,
    required this.baseContent,
    required this.proposedContent,
    required this.patch,
    required this.diff,
    required List<String> missingInformation,
    required List<String> warnings,
    this.expiresAtUtc,
    this.aigcMetadata,
    this.networkGenerated = true,
  }) : missingInformation = List.unmodifiable(missingInformation),
       warnings = List.unmodifiable(warnings) {
    if (aigcMetadata != null &&
        (!networkGenerated || aigcMetadata!.propagateId != operationId)) {
      throw const FormatException('候选的AI来源与原任务不一致。');
    }
  }

  final RemoteResumeChangeTarget target;
  final String documentTitle;
  final String? documentId;
  final String? baseVersionId;
  final String operationId;
  final String summary;
  final ResumeData baseContent;
  final ResumeData proposedContent;
  final ResumePatch patch;
  final ResumeDiff diff;
  final List<String> missingInformation;
  final List<String> warnings;
  final DateTime? expiresAtUtc;
  final ResumeAigcMetadata? aigcMetadata;
  final bool networkGenerated;

  bool get requiresSemanticReview =>
      warnings.contains(remoteSemanticReviewWarning);

  PendingRemoteResumeChange withWarnings(List<String> value) =>
      PendingRemoteResumeChange(
        target: target,
        documentTitle: documentTitle,
        documentId: documentId,
        baseVersionId: baseVersionId,
        operationId: operationId,
        summary: summary,
        baseContent: baseContent,
        proposedContent: proposedContent,
        patch: patch,
        diff: diff,
        missingInformation: missingInformation,
        warnings: value,
        expiresAtUtc: expiresAtUtc,
        aigcMetadata: aigcMetadata,
        networkGenerated: networkGenerated,
      );
}

final class RemoteOptimizationPreparation {
  RemoteOptimizationPreparation({
    required this.summary,
    required this.pendingChange,
    required List<String> missingInformation,
    required List<String> warnings,
  }) : missingInformation = List.unmodifiable(missingInformation),
       warnings = List.unmodifiable(warnings);

  final String summary;
  final PendingRemoteResumeChange? pendingChange;
  final List<String> missingInformation;
  final List<String> warnings;
}

final class RemoteConversationRound {
  const RemoteConversationRound({
    required this.userMessage,
    required this.assistantSummary,
  });

  final String userMessage;
  final String assistantSummary;
}

final class RemoteResumeAiInputException implements Exception {
  const RemoteResumeAiInputException(this.message);

  final String message;
}

final class RemoteResumeAiResponseException implements Exception {
  const RemoteResumeAiResponseException();
}

final class RemoteResumeAiQuestions implements Exception {
  RemoteResumeAiQuestions(
    this.summary,
    List<String> questions,
    List<String> warnings,
  ) : questions = List.unmodifiable(questions),
      warnings = List.unmodifiable(warnings);
  final String summary;
  final List<String> questions;
  final List<String> warnings;
}

final class RemoteResumeAiService {
  RemoteResumeAiService({
    required RemoteAccountService accountService,
    String Function(String namespace)? nextId,
    DriftRemoteReviewRepository? reviewRepository,
    RemoteTaskDraftStore? taskDraftStore,
    DateTime Function()? clock,
  }) : _accountService = accountService,
       _reviewRepository = reviewRepository,
       taskDraftStore = taskDraftStore ?? RemoteTaskDraftStore(clock: clock),
       _clock = clock ?? DateTime.now,
       _nextId = nextId ?? _RemoteAiIds().next;

  final RemoteTaskDraftStore taskDraftStore;
  final RemoteAccountService _accountService;
  final String Function(String namespace) _nextId;
  final DriftRemoteReviewRepository? _reviewRepository;
  final DateTime Function() _clock;
  String? _conversationOwner;
  int _transientGeneration = 0;
  int get transientGeneration => _transientGeneration;
  final Map<String, String> _conversationBaseByDocument = {};
  final Map<String, RemoteWritingContext> _writingContextByDocument = {};

  String createTaskId() => _nextId('ai-task');

  Future<List<RemoteTaskDraft>> unfinishedTasks() async {
    final owner = _accountService.accountId;
    if (owner == null) return const [];
    final tasks = await taskDraftStore.read(owner);
    if (_accountService.accountId != owner) return const [];
    return tasks;
  }

  Future<void> _rememberTask({
    required String kind,
    required String clientRequestId,
    required Map<String, Object?> material,
    required Map<String, Object?> requestInput,
    required bool submittedPersonalDataShared,
    String? taskId,
    String? documentId,
    String? baseVersionId,
  }) async {
    final owner = _accountService.accountId;
    if (owner == null) return;
    final previous = (await taskDraftStore.read(
      owner,
    )).where((e) => e.id == taskId).firstOrNull;
    if (previous != null &&
        (previous.kind != kind ||
            previous.documentId != documentId ||
            previous.baseVersionId != baseVersionId)) {
      throw const RemoteResumeAiInputException('原任务与当前简历版本不一致');
    }
    if (previous?.clientRequestId != null) {
      final operations = await _accountService.readOperations();
      if (operations.any(
        (e) =>
            e.clientRequestId == previous!.clientRequestId &&
            e.blocksNewRequest,
      )) {
        throw const RemoteResumeAiInputException('原任务仍在处理，请先恢复原任务；不会重复生成');
      }
    }
    final originalRequest = await _accountService.originalRequestForMaterial(
      capability: kind == 'compose'
          ? RemoteAiCapability.basicResumeCompose
          : RemoteAiCapability.targetedResumeOptimization,
      input: requestInput,
      documentId: documentId,
      baseVersionId: baseVersionId,
    );
    final now = _clock().toUtc();
    await taskDraftStore.save(
      RemoteTaskDraft(
        owner: owner,
        id:
            taskId ??
            sha256.convert(utf8.encode('$owner:$clientRequestId')).toString(),
        kind: kind,
        documentId: documentId,
        baseVersionId: baseVersionId,
        clientRequestId: originalRequest ?? clientRequestId,
        submittedPersonalDataShared: submittedPersonalDataShared,
        createdAtUtc: previous?.createdAtUtc ?? now,
        expiresAtUtc:
            previous?.expiresAtUtc ?? now.add(const Duration(days: 7)),
        material: material,
      ),
    );
    if (_accountService.accountId != owner) {
      throw const RemoteResumeAiInputException('账号已变化，原任务没有重新发送');
    }
  }

  Future<void> completeTaskForOperation(String operationId) async {
    final owner = _accountService.accountId;
    if (owner == null) return;
    final operations = await _accountService.readOperations();
    final requestIds = operations
        .where((e) => e.usageOperationId == operationId)
        .map((e) => e.clientRequestId)
        .toSet();
    for (final task in await taskDraftStore.read(owner)) {
      if (requestIds.contains(task.clientRequestId)) {
        await taskDraftStore.remove(owner, task.id);
      }
    }
  }

  BasicResumeComposeDraft restoreComposeMaterial(
    RemoteTaskDraft task, {
    bool forResultRecovery = false,
  }) {
    if (task.kind != 'compose') {
      throw const RemoteResumeAiInputException('任务类型不一致');
    }
    final material = task.material;
    final profile = const CanonicalResumeCodec()
        .decode(jsonEncode(material['profileDocument']))
        .profile;
    final source = material['sourceText'] as String;
    if (source.runes.length > 20000) throw const FormatException('任务材料过长');
    return BasicResumeComposeDraft(
      documentTitle: material['documentTitle'] as String,
      sourceText: source,
      fullName: profile.fullName,
      phone: profile.phone,
      email: profile.email,
      preciseAddress: profile.location,
      headline: profile.headline,
      links: profile.links,
      photo: profile.photo,
      naturalLanguageInput: material['naturalLanguageInput'] == true,
      sharePersonalData: forResultRecovery
          ? task.submittedPersonalDataShared
          : false,
      confirmedInputSharing: false,
    );
  }

  void _bindConversation(String documentId, String versionId) {
    final owner = _accountService.accountId;
    if (_conversationOwner != owner) {
      clearTransientState();
      _conversationOwner = owner;
    }
    if (_conversationBaseByDocument[documentId] != versionId) {
      clearDocumentConversation(documentId);
      _conversationBaseByDocument[documentId] = versionId;
    }
  }

  void _requireConversationOwner(String? owner) {
    if (owner == null || owner != _accountService.accountId) {
      throw const RemoteResumeAiInputException('账号已改变，请重新打开AI任务');
    }
  }

  RemoteWritingContext writingContextFor(String documentId, String versionId) {
    _bindConversation(documentId, versionId);
    return _writingContextByDocument[documentId] ?? RemoteWritingContext();
  }

  void _validateWritingContext(
    RemoteWritingContext context,
    ResumeData content,
  ) {
    final paths = remoteWritingFactFields(
      content,
    ).map((field) => field.path).toSet();
    if (context.confirmedFacts.length > 12 ||
        context.constraints.length > 12 ||
        context.confirmedFacts.entries.any(
          (entry) =>
              !paths.contains(entry.key) ||
              entry.key.length > 256 ||
              entry.value.isEmpty ||
              entry.value.runes.length > 1000,
        ) ||
        context.confirmedFacts.values.fold<int>(
              0,
              (n, text) => n + text.runes.length,
            ) >
            6000 ||
        context.constraints.any(
          (text) => text.isEmpty || text.runes.length > 500,
        ) ||
        context.constraints.fold<int>(0, (n, text) => n + text.runes.length) >
            3000) {
      throw const RemoteResumeAiInputException(
        '事实或长期要求超出范围，请缩短文本；结构信息请先在编辑页保存',
      );
    }
    _rejectProfileDataInsideRemoteText(
      content.profile,
      [...context.confirmedFacts.values, ...context.constraints].join('\n'),
    );
  }

  Future<bool> confirmWritingContext({
    required ResumeDocument document,
    required ResumeVersion version,
    required RemoteWritingContext context,
  }) async {
    _requireMatchingSavedVersion(document, version);
    _bindConversation(document.id, version.id);
    final owner = _accountService.accountId;
    _requireConversationOwner(owner);
    _validateWritingContext(context, version.content);
    final token = _conversationTokenByDocument.putIfAbsent(
      document.id,
      () => _nextId('conversation'),
    );
    final persisted = _reviewRepository != null;
    if (persisted) {
      await _reviewRepository.saveConversation(
        owner!,
        document.id,
        jsonEncode(
          _conversationPayload(document.id, version.id, token, context),
        ),
        _clock().toUtc().add(const Duration(days: 7)),
      );
      _requireConversationOwner(owner);
    }
    _writingContextByDocument[document.id] = context;
    return persisted;
  }

  Map<String, Object?> _conversationPayload(
    String documentId,
    String versionId,
    String token,
    RemoteWritingContext? context,
  ) => {
    'schemaVersion': 2,
    'baseVersionId': versionId,
    'conversationToken': token,
    'rounds': [
      for (final round
          in _conversationByDocument[documentId] ?? <RemoteConversationRound>[])
        {
          'userMessage': round.userMessage,
          'assistantSummary': round.assistantSummary,
        },
    ],
    'writingContext': context == null
        ? null
        : {
            'confirmedFacts': [
              for (final fact in context.confirmedFacts.entries)
                {'path': fact.key, 'text': fact.value},
            ],
            'constraints': context.constraints,
          },
  };

  Future<void> restoreConversation(
    String documentId,
    String baseVersionId, {
    ResumeData? content,
  }) async {
    final owner = _accountService.accountId;
    _bindConversation(documentId, baseVersionId);
    if (owner == null || _reviewRepository == null) return;
    final payload = await _reviewRepository.readConversation(
      owner,
      documentId,
      _clock(),
    );
    _requireConversationOwner(owner);
    if (payload == null) {
      clearDocumentConversation(documentId);
      _conversationBaseByDocument[documentId] = baseVersionId;
      return;
    }
    final value = jsonDecode(payload) as Map<String, dynamic>;
    if (!const [1, 2].contains(value['schemaVersion']) ||
        value['baseVersionId'] != baseVersionId) {
      clearDocumentConversation(documentId);
      return;
    }
    final rounds = (value['rounds'] as List)
        .map(
          (entry) => RemoteConversationRound(
            userMessage: entry['userMessage'] as String,
            assistantSummary: entry['assistantSummary'] as String,
          ),
        )
        .toList();
    if (rounds.length > 3 ||
        rounds.any(
          (round) =>
              round.userMessage.runes.length > 4000 ||
              round.assistantSummary.runes.length > 2000,
        )) {
      throw const FormatException('对话记录损坏');
    }
    _conversationByDocument[documentId] = rounds;
    _conversationTokenByDocument[documentId] =
        value['conversationToken'] as String;
    if (value['writingContext'] case final Map<String, dynamic> raw) {
      final facts = raw['confirmedFacts'] as List;
      final context = RemoteWritingContext(
        confirmedFacts: {
          for (final fact in facts)
            fact['path'] as String: fact['text'] as String,
        },
        constraints: (raw['constraints'] as List).cast<String>(),
      );
      if (facts.length != context.confirmedFacts.length ||
          context.confirmedFacts.length > 12 ||
          context.constraints.length > 12) {
        throw const FormatException('AI事实记录损坏');
      }
      _writingContextByDocument[documentId] = context;
      if (content != null) _validateWritingContext(context, content);
    }
  }

  final Map<String, List<RemoteConversationRound>> _conversationByDocument = {};
  final Map<String, String> _conversationTokenByDocument = {};

  Future<PendingRemoteResumeChange> prepareBasicResumeCompose(
    BasicResumeComposeDraft draft, {
    String? taskId,
    GatewayRemoteAiResponse? recoveredResponse,
  }) async {
    final trimmedTitle = draft.documentTitle.trim();
    if (trimmedTitle.isEmpty) {
      throw const RemoteResumeAiInputException('简历标题不能为空');
    }
    if (recoveredResponse == null &&
        draft.naturalLanguageInput &&
        !draft.confirmedInputSharing) {
      throw const RemoteResumeAiInputException('请先确认发送本次输入的完整材料给在线AI。');
    }
    if (draft.sharePersonalData != null &&
        draft.profileValidationIssues.any((issue) => issue.blocksCommit)) {
      throw const RemoteResumeAiInputException('请检查个人基础信息格式。');
    }
    final privacy = draft.sharePersonalData == false
        ? _RemotePersonalTextRedactor(draft.localProfile('local-profile'))
        : null;
    final sourceText = draft.sourceMaterial;
    final sourceFragments = _buildSourceFragments(
      privacy?.redact(sourceText) ?? sourceText,
      naturalLanguageInput: draft.naturalLanguageInput,
    );
    if (!draft.naturalLanguageInput) {
      _rejectPersonalDataInsideFragments(draft, sourceFragments);
    }
    final personalData = draft.sharePersonalData == null
        ? _buildPersonalData(draft)
        : _buildProfilePersonalData(
            draft.localProfile('local-profile'),
            draft.sharePersonalData == true
                ? RemotePersonalDataField.values.toSet()
                : {},
            skipEmpty: true,
          );
    final requestInput = <String, Object?>{
      'inputType': RemoteAiCapability.basicResumeCompose.name,
      'sourceFragments': sourceFragments,
      'personalData': ?personalData,
      if (draft.naturalLanguageInput) 'naturalLanguageInput': true,
    };
    final clientRequestId = _nextId('remote-request');
    if (recoveredResponse == null) {
      await _rememberTask(
        kind: 'compose',
        requestInput: requestInput,
        clientRequestId: clientRequestId,
        taskId: taskId,
        submittedPersonalDataShared: draft.sharePersonalData == true,
        material: {
          'documentTitle': draft.documentTitle,
          'sourceText': draft.sourceText,
          'profileDocument': ResumeData(
            profile: draft.localProfile('task-profile'),
          ).toJson(),
          'naturalLanguageInput': draft.naturalLanguageInput,
        },
      );
    }
    final remoteResponse =
        recoveredResponse ??
        await _accountService.submitRemoteAiRequest(
          clientRequestId: clientRequestId,
          idempotencyKey: _nextId('remote-idempotency'),
          capability: RemoteAiCapability.basicResumeCompose,
          input: requestInput,
        );
    final output =
        privacy?.restorePayload(remoteResponse.output) ?? remoteResponse.output;
    if (output['missingInformation'] case final List<Object?> items
        when items.isNotEmpty) {
      _expectExactKeys(output, const {
        'outputVersion',
        'summary',
        'candidateResume',
        'sourceReferences',
        'missingInformation',
        'warnings',
      });
      if (output['outputVersion'] != 'basicResumeCompose.v1') {
        throw const RemoteResumeAiResponseException();
      }
      throw RemoteResumeAiQuestions(
        _expectBoundedText(output, 'summary', 200),
        _parseMissingInformation(items, maximumItems: 30),
        [
          if (!remoteResponse.usesNetwork) '本轮由写作流程检查材料，未调用模型。',
          ..._parseBoundedStringList(
            _expectList(output, 'warnings'),
            maximumItems: 20,
            maximumCharacters: 200,
          ),
        ],
      );
    }
    final parsedOutput = _parseBasicComposeOutput(
      output,
      knownFragmentIds: sourceFragments
          .map((fragment) => fragment['fragmentId']! as String)
          .toSet(),
      draft: draft,
    );
    final candidateContent = parsedOutput.candidateContent;
    final baseContent = ResumeData(
      profile: draft.localProfile(candidateContent.profile.id),
    );
    final candidatePatch = _buildBasicCandidatePatch(
      baseContent,
      candidateContent,
    );
    final reappliedCandidate = candidatePatch.apply(baseContent);
    if (!jsonDeepEquals(
      reappliedCandidate.toJson(),
      candidateContent.toJson(),
    )) {
      throw const RemoteResumeAiResponseException();
    }
    return PendingRemoteResumeChange(
      target: RemoteResumeChangeTarget.newDocument,
      documentTitle: trimmedTitle,
      documentId: null,
      baseVersionId: null,
      operationId: remoteResponse.operationId,
      summary: parsedOutput.summary,
      aigcMetadata: remoteResponse.aigcMetadata,
      networkGenerated: remoteResponse.usesNetwork,
      baseContent: baseContent,
      proposedContent: candidateContent,
      patch: candidatePatch,
      diff: ResumeDiff.fromPatch(candidatePatch),
      missingInformation: parsedOutput.missingInformation,
      warnings: [
        if (!remoteResponse.usesNetwork) '本轮未调用模型，请核对流程提示与候选来源。',
        ...parsedOutput.warnings,
      ],
    );
  }

  Future<RemoteOptimizationPreparation> prepareTargetedOptimization({
    required ResumeDocument document,
    required ResumeVersion version,
    required String targetJobTitle,
    required String jobDescription,
    required String userInstruction,
    Set<RemotePersonalDataField> selectedPersonalFields = const {},
    bool confirmedInputSharing = false,
    bool? sharePersonalData,
    String? taskId,
    GatewayRemoteAiResponse? recoveredResponse,
  }) async {
    _requireMatchingSavedVersion(document, version);
    await restoreConversation(
      document.id,
      version.id,
      content: version.content,
    );
    final writingContext = writingContextFor(document.id, version.id);
    _validateWritingContext(writingContext, version.content);
    final normalizedJobTitle = _validateOptionalText(
      targetJobTitle,
      label: '目标岗位',
      maximumCharacters: 100,
    );
    final normalizedJobDescription = _validateOptionalText(
      jobDescription,
      label: '岗位描述',
      maximumCharacters: 2000,
    );
    final normalizedInstruction = _validateOptionalText(
      userInstruction,
      label: '优化要求',
      maximumCharacters: 4000,
    );
    if ('$normalizedJobTitle$normalizedJobDescription$normalizedInstruction'
        .isEmpty) {
      throw const RemoteResumeAiInputException('请写下希望如何改进，或提供目标岗位。');
    }
    if (sharePersonalData == null && !confirmedInputSharing) {
      _rejectProfileDataInsideRemoteText(
        version.content.profile,
        '$normalizedJobTitle\n$normalizedJobDescription\n$normalizedInstruction',
      );
    }
    final privacy = sharePersonalData == false
        ? _RemotePersonalTextRedactor(version.content.profile)
        : null;
    return _prepareOptimization(
      capability: RemoteAiCapability.targetedResumeOptimization,
      document: document,
      version: version,
      input: {
        'inputType': RemoteAiCapability.targetedResumeOptimization.name,
        if (confirmedInputSharing) 'allowSemanticReview': true,
        'baseResumeFingerprint': contentFingerprint(version.content),
        'resume': _buildResumeProjection(version.content),
        if (!writingContext.isEmpty)
          'writingContext': writingContext.toJson(
            contentFingerprint(version.content),
          ),
        'targetJobTitle': normalizedJobTitle,
        'jobDescription': normalizedJobDescription,
        'userInstruction': normalizedInstruction,
        'personalData': ?_buildProfilePersonalData(
          version.content.profile,
          sharePersonalData == null
              ? selectedPersonalFields
              : sharePersonalData
              ? RemotePersonalDataField.values.toSet()
              : {},
          skipEmpty: sharePersonalData != null,
        ),
      },
      privacy: privacy,
      expectedOutputVersion: 'targetedResumeOptimization.v1',
      recoveredResponse: recoveredResponse,
      taskId: taskId,
      taskMaterial: {
        'targetJobTitle': targetJobTitle,
        'jobDescription': jobDescription,
        'userInstruction': userInstruction,
      },
      submittedPersonalDataShared: sharePersonalData == true,
    );
  }

  Future<RemoteOptimizationPreparation> prepareConversationTurn({
    required ResumeDocument document,
    required ResumeVersion version,
    required String targetJobTitle,
    required String jobDescription,
    required String userMessage,
    Set<RemotePersonalDataField> selectedPersonalFields = const {},
    bool confirmedInputSharing = false,
    bool? sharePersonalData,
  }) async {
    _requireMatchingSavedVersion(document, version);
    final owner = _accountService.accountId;
    await restoreConversation(
      document.id,
      version.id,
      content: version.content,
    );
    _requireConversationOwner(owner);
    final writingContext = writingContextFor(document.id, version.id);
    _validateWritingContext(writingContext, version.content);
    final normalizedJobTitle = _validateOptionalText(
      targetJobTitle,
      label: '目标岗位',
      maximumCharacters: 100,
    );
    final normalizedJobDescription = _validateOptionalText(
      jobDescription,
      label: '岗位描述',
      maximumCharacters: 2000,
    );
    final normalizedUserMessage = _validateRequiredText(
      userMessage,
      label: '本轮问题',
      maximumCharacters: 4000,
    );
    if (sharePersonalData == null && !confirmedInputSharing) {
      _rejectProfileDataInsideRemoteText(
        version.content.profile,
        '$normalizedJobTitle\n$normalizedJobDescription\n$normalizedUserMessage',
      );
    }
    final recentRounds = _conversationByDocument[document.id] ?? const [];
    final recentMessages = <Map<String, Object?>>[
      for (final recentRound in recentRounds) ...[
        {'role': 'user', 'content': recentRound.userMessage},
        {'role': 'assistant', 'content': recentRound.assistantSummary},
      ],
    ];
    while (recentMessages.fold<int>(
          0,
          (count, entry) => count + (entry['content']! as String).runes.length,
        ) >
        8000) {
      recentMessages.removeRange(0, 2);
    }
    final privacy = sharePersonalData == false
        ? _RemotePersonalTextRedactor(version.content.profile)
        : null;
    final preparation = await _prepareOptimization(
      capability: RemoteAiCapability.resumeOptimizationConversation,
      document: document,
      version: version,
      input: {
        'inputType': RemoteAiCapability.resumeOptimizationConversation.name,
        'conversationToken': _conversationTokenByDocument.putIfAbsent(
          document.id,
          () => _nextId('conversation'),
        ),
        'baseResumeFingerprint': contentFingerprint(version.content),
        'resume': _buildResumeProjection(version.content),
        'targetJobTitle': normalizedJobTitle,
        'jobDescription': normalizedJobDescription,
        'recentMessages': recentMessages,
        if (!writingContext.isEmpty)
          'writingContext': writingContext.toJson(
            contentFingerprint(version.content),
          ),
        'userMessage': normalizedUserMessage,
        if (confirmedInputSharing) 'allowSemanticReview': true,
        'personalData': ?_buildProfilePersonalData(
          version.content.profile,
          sharePersonalData == null
              ? selectedPersonalFields
              : sharePersonalData
              ? RemotePersonalDataField.values.toSet()
              : {},
          skipEmpty: sharePersonalData != null,
        ),
      },
      privacy: privacy,
      expectedOutputVersion: 'resumeOptimizationConversation.v1',
    );
    _requireConversationOwner(owner);
    final updatedRounds = [
      ...recentRounds,
      RemoteConversationRound(
        userMessage: normalizedUserMessage,
        assistantSummary: preparation.summary,
      ),
    ];
    _conversationByDocument[document.id] = updatedRounds.length <= 3
        ? updatedRounds
        : updatedRounds.sublist(updatedRounds.length - 3);
    if (owner != null && _reviewRepository != null) {
      try {
        await _reviewRepository.saveConversation(
          owner,
          document.id,
          jsonEncode(
            _conversationPayload(
              document.id,
              version.id,
              _conversationTokenByDocument[document.id]!,
              writingContext,
            ),
          ),
          _clock().toUtc().add(const Duration(days: 7)),
        );
        _requireConversationOwner(owner);
      } on Object {
        _requireConversationOwner(owner);
        final warnings = [...preparation.warnings, '本轮对话未能保存到本机，关闭应用后可能丢失。'];
        return RemoteOptimizationPreparation(
          summary: preparation.summary,
          pendingChange: preparation.pendingChange?.withWarnings(warnings),
          missingInformation: preparation.missingInformation,
          warnings: warnings,
        );
      }
    }
    return preparation;
  }

  List<RemoteConversationRound> conversationFor(String documentId) {
    if (_conversationOwner != null &&
        _conversationOwner != _accountService.accountId) {
      return const [];
    }
    return List.unmodifiable(_conversationByDocument[documentId] ?? const []);
  }

  void clearDocumentConversation(String documentId) {
    _conversationByDocument.remove(documentId);
    _conversationTokenByDocument.remove(documentId);
    _conversationBaseByDocument.remove(documentId);
    _writingContextByDocument.remove(documentId);
  }

  void clearTransientState() {
    _transientGeneration++;
    _conversationByDocument.clear();
    _conversationTokenByDocument.clear();
    _conversationBaseByDocument.clear();
    _writingContextByDocument.clear();
  }

  String contentFingerprint(ResumeData resumeContent) {
    final canonicalBytes = utf8.encode(jsonEncode(resumeContent.toJson()));
    return sha256.convert(canonicalBytes).toString();
  }

  Future<RemoteOptimizationPreparation> _prepareOptimization({
    required RemoteAiCapability capability,
    required ResumeDocument document,
    required ResumeVersion version,
    required Map<String, Object?> input,
    required String expectedOutputVersion,
    _RemotePersonalTextRedactor? privacy,
    String? taskId,
    Map<String, Object?>? taskMaterial,
    bool submittedPersonalDataShared = false,
    GatewayRemoteAiResponse? recoveredResponse,
  }) async {
    final confirmedFacts =
        _writingContextByDocument[document.id]?.confirmedFacts ??
        const <String, String>{};
    final requestInput = privacy?.redactPayload(input) ?? input;
    final clientRequestId = _nextId('remote-request');
    if (recoveredResponse == null && taskMaterial != null) {
      await _rememberTask(
        kind: 'optimize',
        requestInput: requestInput,
        clientRequestId: clientRequestId,
        taskId: taskId,
        documentId: document.id,
        baseVersionId: version.id,
        material: taskMaterial,
        submittedPersonalDataShared: submittedPersonalDataShared,
      );
    }
    final remoteResponse =
        recoveredResponse ??
        await _accountService.submitRemoteAiRequest(
          clientRequestId: clientRequestId,
          idempotencyKey: _nextId('remote-idempotency'),
          capability: capability,
          input: requestInput,
          documentId: document.id,
          baseVersionId: version.id,
        );
    final parsedOutput = _parseOptimizationOutput(
      privacy?.restorePayload(remoteResponse.output) ?? remoteResponse.output,
      expectedOutputVersion: expectedOutputVersion,
      baseContent: version.content,
    );
    final originalPatch = parsedOutput.patch;
    final proposedPatch = originalPatch == null
        ? null
        : ResumePatch([
            for (final operation in originalPatch.operations)
              if (confirmedFacts.containsKey(operation.path) &&
                  confirmedFacts[operation.path] != operation.oldValue)
                ResumePatchOperation(
                  type: operation.type,
                  path: operation.path,
                  oldValue: operation.oldValue,
                  newValue: operation.newValue,
                  reason: operation.reason,
                  source: operation.source,
                  category: ResumeChangeCategory.fact,
                )
              else
                operation,
          ]);
    final warnings = [
      if (!remoteResponse.usesNetwork) '本轮由写作流程检查材料，未调用模型。',
      ...parsedOutput.warnings,
    ];
    if (proposedPatch == null) {
      return RemoteOptimizationPreparation(
        summary: parsedOutput.summary,
        pendingChange: null,
        missingInformation: parsedOutput.missingInformation,
        warnings: warnings,
      );
    }
    final proposedContent = proposedPatch.apply(version.content);
    final validation = const ResumeValidator().validate(proposedContent);
    if (!validation.isValid) {
      throw const RemoteResumeAiResponseException();
    }
    return RemoteOptimizationPreparation(
      summary: parsedOutput.summary,
      pendingChange: PendingRemoteResumeChange(
        target: RemoteResumeChangeTarget.currentDocument,
        documentTitle: document.title,
        documentId: document.id,
        baseVersionId: version.id,
        operationId: remoteResponse.operationId,
        summary: parsedOutput.summary,
        aigcMetadata: remoteResponse.aigcMetadata,
        networkGenerated: remoteResponse.usesNetwork,
        baseContent: version.content,
        proposedContent: proposedContent,
        patch: proposedPatch,
        diff: ResumeDiff.fromPatch(proposedPatch),
        missingInformation: parsedOutput.missingInformation,
        warnings: warnings,
      ),
      missingInformation: parsedOutput.missingInformation,
      warnings: warnings,
    );
  }
}

final class _ParsedBasicComposeOutput {
  const _ParsedBasicComposeOutput({
    required this.summary,
    required this.candidateContent,
    required this.missingInformation,
    required this.warnings,
  });

  final String summary;
  final ResumeData candidateContent;
  final List<String> missingInformation;
  final List<String> warnings;
}

final class _ParsedOptimizationOutput {
  const _ParsedOptimizationOutput({
    required this.summary,
    required this.patch,
    required this.missingInformation,
    required this.warnings,
  });

  final String summary;
  final ResumePatch? patch;
  final List<String> missingInformation;
  final List<String> warnings;
}

void _requireMatchingSavedVersion(
  ResumeDocument document,
  ResumeVersion version,
) {
  if (version.documentId != document.id ||
      document.currentVersionId != version.id) {
    throw const RemoteResumeAiInputException('当前简历版本已经变化，请重新打开后再优化');
  }
  if (!const ResumeValidator().validate(version.content).isValid) {
    throw const RemoteResumeAiInputException('当前简历未通过本地校验，不能发送');
  }
}

final class _RemotePersonalTextRedactor {
  _RemotePersonalTextRedactor(ResumeProfile profile) {
    final values =
        [
            profile.fullName.trim(),
            profile.phone.trim(),
            profile.email.trim(),
            profile.location.trim(),
            ...profile.links.map((link) => link.url.trim()),
          ].where((text) => text.isNotEmpty).toSet().toList()
          ..sort((a, b) => b.length.compareTo(a.length));
    for (final value in values) {
      _token(value);
    }
  }
  final Map<String, String> _tokens = {};
  String _token(String value) => _tokens.putIfAbsent(
    value,
    () => '〔本地私密${String.fromCharCode(0x4e00 + _tokens.length)}〕',
  );
  String redact(String text) {
    if (_tokens.isNotEmpty) {
      final known = RegExp(_tokens.keys.map(RegExp.escape).join('|'));
      text = text.replaceAllMapped(known, (match) => _tokens[match[0]]!);
    }
    text = text.replaceAllMapped(
      RegExp(r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}', caseSensitive: false),
      (match) => _token(match[0]!),
    );
    text = text.replaceAllMapped(
      RegExp(r'(?<![0-9])\+?[0-9][0-9 -]{6,18}[0-9](?![0-9])'),
      (match) => RegExp(r'[0-9]').allMatches(match[0]!).length >= 10
          ? _token(match[0]!)
          : match[0]!,
    );
    return text;
  }

  String restore(String text) {
    for (final entry in _tokens.entries) {
      text = text.replaceAll(entry.value, entry.key);
    }
    return text;
  }

  Object? _walk(Object? value, String Function(String) convert) {
    if (value is String) return convert(value);
    if (value is List) {
      return value.map((item) => _walk(item, convert)).toList();
    }
    if (value is Map<String, Object?>) {
      return {
        for (final entry in value.entries)
          entry.key:
              const {
                'id',
                'path',
                'fragmentId',
                'baseResumeFingerprint',
                'conversationToken',
                'outputVersion',
              }.contains(entry.key)
              ? entry.value
              : _walk(entry.value, convert),
      };
    }
    return value;
  }

  Map<String, Object?> redactPayload(Map<String, Object?> value) =>
      _walk(value, redact)! as Map<String, Object?>;
  Map<String, Object?> restorePayload(Map<String, Object?> value) =>
      _walk(value, restore)! as Map<String, Object?>;
}

String _validateRequiredText(
  String source, {
  required String label,
  required int maximumCharacters,
}) {
  final normalizedText = source.trim();
  if (normalizedText.isEmpty) {
    throw RemoteResumeAiInputException('$label不能为空');
  }
  if (normalizedText.runes.length > maximumCharacters) {
    throw RemoteResumeAiInputException('$label不能超过 $maximumCharacters 个字符');
  }
  return normalizedText;
}

String _validateOptionalText(
  String source, {
  required String label,
  required int maximumCharacters,
}) {
  final normalizedText = source.trim();
  if (normalizedText.runes.length > maximumCharacters) {
    throw RemoteResumeAiInputException('$label不能超过 $maximumCharacters 个字符');
  }
  return normalizedText;
}

void _rejectProfileDataInsideRemoteText(
  ResumeProfile profile,
  String remoteText,
) {
  final profileValues = {
    '姓名': profile.fullName.trim(),
    '手机号': profile.phone.trim(),
    '邮箱': profile.email.trim(),
    '精确地址': profile.location.trim(),
  };
  for (final profileValue in profileValues.entries) {
    if (profileValue.value.isNotEmpty &&
        remoteText.contains(profileValue.value)) {
      throw RemoteResumeAiInputException(
        '${profileValue.key}请通过独立勾选决定是否发送，不要写入岗位描述或对话',
      );
    }
  }
  if (_containsEmail(remoteText)) {
    throw const RemoteResumeAiInputException('输入中疑似包含邮箱，请移除后再提交');
  }
  if (_containsPhoneNumber(remoteText)) {
    throw const RemoteResumeAiInputException('输入中疑似包含手机号，请移除后再提交');
  }
}

Map<String, Object?>? _buildProfilePersonalData(
  ResumeProfile profile,
  Set<RemotePersonalDataField> selectedPersonalFields, {
  bool skipEmpty = false,
}) {
  if (selectedPersonalFields.isEmpty) {
    return null;
  }
  final fieldValues = <RemotePersonalDataField, String>{
    RemotePersonalDataField.fullName: profile.fullName.trim(),
    RemotePersonalDataField.phone: profile.phone.trim(),
    RemotePersonalDataField.email: profile.email.trim(),
    RemotePersonalDataField.preciseAddress: profile.location.trim(),
  };
  final orderedFields = RemotePersonalDataField.values
      .where(
        (field) =>
            selectedPersonalFields.contains(field) &&
            (!skipEmpty || fieldValues[field]!.isNotEmpty),
      )
      .toList(growable: false);
  if (orderedFields.isEmpty) return null;
  for (final selectedField in orderedFields) {
    if (fieldValues[selectedField]!.isEmpty) {
      throw RemoteResumeAiInputException(
        '${_personalFieldLabel(selectedField)}为空，不能选择发送',
      );
    }
  }
  return {
    'consentedFields': orderedFields.map((field) => field.name).toList(),
    for (final selectedField in orderedFields)
      selectedField.name: fieldValues[selectedField],
  };
}

Map<String, Object?> _buildResumeProjection(ResumeData resumeContent) {
  // 联系方式、链接、未知字段和扩展字段都在本地截断，防止未来 schema 扩展时意外扩大上传面。
  return {
    'schemaVersion': resumeContent.schemaVersion,
    'profile': {
      'id': resumeContent.profile.id,
      'headline': resumeContent.profile.headline,
      'coarseLocation': '',
    },
    'workExperiences': [
      for (final workExperience in resumeContent.workExperiences)
        {
          'id': workExperience.id,
          'organization': workExperience.organization,
          'position': workExperience.position,
          'dateRange': _dateRangeProjection(workExperience.dateRange),
          'summary': workExperience.summary,
          'highlights': workExperience.highlights,
        },
    ],
    'educations': [
      for (final education in resumeContent.educations)
        {
          'id': education.id,
          'institution': education.institution,
          'degree': education.degree,
          'fieldOfStudy': education.fieldOfStudy,
          'dateRange': _dateRangeProjection(education.dateRange),
          'highlights': education.highlights,
        },
    ],
    'projects': [
      for (final project in resumeContent.projects)
        {
          'id': project.id,
          'name': project.name,
          'role': project.role,
          'dateRange': project.dateRange == null
              ? null
              : _dateRangeProjection(project.dateRange!),
          'summary': project.summary,
          'highlights': project.highlights,
        },
    ],
    'skillGroups': [
      for (final skillGroup in resumeContent.skillGroups)
        {
          'id': skillGroup.id,
          'name': skillGroup.name,
          'skills': skillGroup.skills,
        },
    ],
    'certifications': [
      for (final certification in resumeContent.certifications)
        {
          'id': certification.id,
          'name': certification.name,
          'issuer': certification.issuer,
          'issuedOn': _resumeDateProjection(certification.issuedOn),
          'expiresOn': _resumeDateProjection(certification.expiresOn),
        },
    ],
    'languages': [
      for (final language in resumeContent.languages)
        {
          'id': language.id,
          'name': language.name,
          'proficiency': language.proficiency.name,
        },
    ],
    'customSections': [
      for (final customSection in resumeContent.customSections)
        {
          'id': customSection.id,
          'title': customSection.title,
          'items': [
            for (final sectionItem in customSection.items)
              {
                'id': sectionItem.id,
                'title': sectionItem.title,
                'description': sectionItem.description,
              },
          ],
        },
    ],
  };
}

Map<String, Object?> _dateRangeProjection(DateRange dateRange) => {
  'start': _resumeDateProjection(dateRange.start),
  'end': _resumeDateProjection(dateRange.end),
  'isCurrent': dateRange.isCurrent,
};

Map<String, Object?>? _resumeDateProjection(ResumeDate? resumeDate) {
  if (resumeDate == null) {
    return null;
  }
  return {'year': resumeDate.year, 'month': resumeDate.month};
}

_ParsedOptimizationOutput _parseOptimizationOutput(
  Map<String, Object?> output, {
  required String expectedOutputVersion,
  required ResumeData baseContent,
}) {
  _expectExactKeys(output, const {
    'outputVersion',
    'summary',
    'proposedPatch',
    'missingInformation',
    'warnings',
    'nextAction',
  });
  if (_expectString(output, 'outputVersion') != expectedOutputVersion) {
    throw const RemoteResumeAiResponseException();
  }
  final summary = _expectBoundedText(output, 'summary', 200);
  final missingInformation = _parseMissingInformation(
    _expectList(output, 'missingInformation'),
    maximumItems: 20,
  );
  final warnings = _parseBoundedStringList(
    _expectList(output, 'warnings'),
    maximumItems: 20,
    maximumCharacters: 200,
  );
  final nextAction = _expectString(output, 'nextAction');
  if (!const {
    'reviewPatch',
    'provideMoreInformation',
    'none',
  }.contains(nextAction)) {
    throw const RemoteResumeAiResponseException();
  }
  final proposedPatchValue = output['proposedPatch'];
  if (proposedPatchValue == null) {
    if (nextAction == 'reviewPatch') {
      throw const RemoteResumeAiResponseException();
    }
    return _ParsedOptimizationOutput(
      summary: summary,
      patch: null,
      missingInformation: missingInformation,
      warnings: warnings,
    );
  }
  if (nextAction != 'reviewPatch' ||
      missingInformation.isNotEmpty ||
      proposedPatchValue is! Map<String, Object?>) {
    throw const RemoteResumeAiResponseException();
  }
  _expectExactKeys(proposedPatchValue, const {'operations'});
  final operations = _expectList(proposedPatchValue, 'operations');
  if (operations.isEmpty || operations.length > 12) {
    throw const RemoteResumeAiResponseException();
  }
  final seenPaths = <String>{};
  for (final operationValue in operations) {
    if (operationValue is! Map<String, Object?>) {
      throw const RemoteResumeAiResponseException();
    }
    _expectExactKeys(operationValue, const {
      'type',
      'path',
      'oldValue',
      'newValue',
      'reason',
      'source',
      'category',
    });
    if (_expectString(operationValue, 'type') != 'replace' ||
        _expectString(operationValue, 'source') != 'remoteAi') {
      throw const RemoteResumeAiResponseException();
    }
    final category = _expectString(operationValue, 'category');
    if (category != 'wording' && category != 'format') {
      throw const RemoteResumeAiResponseException();
    }
    final patchPath = _expectString(operationValue, 'path');
    if (!_allowedRemotePatchPath.hasMatch(patchPath) ||
        !seenPaths.add(patchPath)) {
      throw const RemoteResumeAiResponseException();
    }
    final oldValue = operationValue['oldValue'];
    if (oldValue != null && oldValue is! String) {
      throw const RemoteResumeAiResponseException();
    }
    if (oldValue is String && oldValue.runes.length > 1000) {
      throw const RemoteResumeAiResponseException();
    }
    _expectBoundedText(operationValue, 'newValue', 1000);
    _expectBoundedText(operationValue, 'reason', 200);
  }
  try {
    final patch = ResumePatch.fromJson(proposedPatchValue);
    // 在返回 UI 前先应用一次，oldValue、路径索引和最终领域校验都必须同时通过。
    patch.apply(baseContent);
    return _ParsedOptimizationOutput(
      summary: summary,
      patch: patch,
      missingInformation: missingInformation,
      warnings: warnings,
    );
  } on Object {
    throw const RemoteResumeAiResponseException();
  }
}

final _allowedRemotePatchPath = RegExp(
  r'^(?:/profile/headline|/workExperiences/[0-9]+/(?:summary|highlights/[0-9]+)|/educations/[0-9]+/highlights/[0-9]+|/projects/[0-9]+/(?:summary|highlights/[0-9]+)|/customSections/[0-9]+/items/[0-9]+/(?:title|description))$',
);

List<Map<String, Object?>> _buildSourceFragments(
  String sourceText, {
  bool naturalLanguageInput = false,
}) {
  if (naturalLanguageInput) {
    final text = sourceText.trim();
    final characters = text.runes.toList(growable: false);
    if (characters.isEmpty || characters.length > 20000) {
      throw const RemoteResumeAiInputException('请写下你的经历与需求，整段材料最多20000字。');
    }
    final fragments = <Map<String, Object?>>[];
    for (var offset = 0; offset < characters.length; offset += 1000) {
      final end = (offset + 1000).clamp(0, characters.length);
      final part = String.fromCharCodes(characters.sublist(offset, end)).trim();
      if (part.isEmpty) continue;
      fragments.add({
        'fragmentId': 'fragment-${fragments.length + 1}',
        'category': 'unspecified',
        'text': part,
      });
    }
    return fragments;
  }
  final sourceFragments = sourceText
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
  if (sourceFragments.isEmpty) {
    throw const RemoteResumeAiInputException('请至少填写一行经历或能力信息');
  }
  if (sourceFragments.length > 40) {
    throw const RemoteResumeAiInputException('碎片信息不能超过 40 行');
  }
  var totalCharacters = 0;
  final projectedFragments = <Map<String, Object?>>[];
  for (final indexedFragment in sourceFragments.indexed) {
    final fragmentText = indexedFragment.$2;
    final fragmentLength = fragmentText.runes.length;
    if (fragmentLength > 1000) {
      throw RemoteResumeAiInputException(
        '第 ${indexedFragment.$1 + 1} 行不能超过 1000 个字符',
      );
    }
    totalCharacters += fragmentLength;
    projectedFragments.add({
      'fragmentId': 'fragment-${indexedFragment.$1 + 1}',
      'category': 'unspecified',
      'text': fragmentText,
    });
  }
  if (totalCharacters > 20000) {
    throw const RemoteResumeAiInputException('碎片信息总长度不能超过 20000 个字符');
  }
  return projectedFragments;
}

void _rejectPersonalDataInsideFragments(
  BasicResumeComposeDraft draft,
  List<Map<String, Object?>> sourceFragments,
) {
  final fragmentText = sourceFragments
      .map((fragment) => fragment['text']! as String)
      .join('\n');
  final personalValues = {
    '姓名': draft.fullName.trim(),
    '手机号': draft.phone.trim(),
    '邮箱': draft.email.trim(),
    '地址': draft.preciseAddress.trim(),
  };
  for (final personalValue in personalValues.entries) {
    if (personalValue.value.isNotEmpty &&
        fragmentText.contains(personalValue.value)) {
      throw RemoteResumeAiInputException(
        '碎片信息中包含${personalValue.key}，请只在单独字段填写并决定本次是否发送',
      );
    }
  }
  if (_containsEmail(fragmentText)) {
    throw const RemoteResumeAiInputException('碎片信息中疑似包含邮箱，请移到单独字段后再提交');
  }
  if (_containsPhoneNumber(fragmentText)) {
    throw const RemoteResumeAiInputException('碎片信息中疑似包含手机号，请移到单独字段后再提交');
  }
}

bool _containsEmail(String source) => RegExp(
  r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}',
  caseSensitive: false,
).hasMatch(source);

bool _containsPhoneNumber(String source) {
  final possiblePhonePattern = RegExp(
    r'(?<![0-9])\+?[0-9][0-9 -]{6,18}[0-9](?![0-9])',
  );
  return possiblePhonePattern.allMatches(source).any((possiblePhone) {
    final matchedText = possiblePhone.group(0)!;
    return RegExp(r'[0-9]').allMatches(matchedText).length >= 10;
  });
}

Map<String, Object?>? _buildPersonalData(BasicResumeComposeDraft draft) {
  if (draft.selectedPersonalFields.isEmpty) {
    return null;
  }
  final fieldValues = <RemotePersonalDataField, String>{
    RemotePersonalDataField.fullName: draft.fullName.trim(),
    RemotePersonalDataField.phone: draft.phone.trim(),
    RemotePersonalDataField.email: draft.email.trim(),
    RemotePersonalDataField.preciseAddress: draft.preciseAddress.trim(),
  };
  final orderedSelectedFields = RemotePersonalDataField.values
      .where(draft.selectedPersonalFields.contains)
      .toList(growable: false);
  for (final selectedField in orderedSelectedFields) {
    if (fieldValues[selectedField]!.isEmpty) {
      throw RemoteResumeAiInputException(
        '${_personalFieldLabel(selectedField)}为空，不能选择发送',
      );
    }
  }
  return {
    'consentedFields': orderedSelectedFields
        .map((field) => field.name)
        .toList(),
    for (final selectedField in orderedSelectedFields)
      selectedField.name: fieldValues[selectedField],
  };
}

_ParsedBasicComposeOutput _parseBasicComposeOutput(
  Map<String, Object?> output, {
  required Set<String> knownFragmentIds,
  required BasicResumeComposeDraft draft,
}) {
  _expectExactKeys(output, const {
    'outputVersion',
    'summary',
    'candidateResume',
    'sourceReferences',
    'missingInformation',
    'warnings',
  });
  if (_expectString(output, 'outputVersion') != 'basicResumeCompose.v1') {
    throw const RemoteResumeAiResponseException();
  }
  final candidateProjection = _expectMap(output, 'candidateResume');
  _validateSourceReferences(
    _expectList(output, 'sourceReferences'),
    candidateProjection,
    knownFragmentIds,
  );
  final candidateContent = _candidateProjectionToResumeData(
    candidateProjection,
    draft,
  );
  final validation = const ResumeValidator().validate(candidateContent);
  if (!validation.isValid) {
    throw const RemoteResumeAiResponseException();
  }
  return _ParsedBasicComposeOutput(
    summary: _expectNonEmptyString(output, 'summary'),
    candidateContent: candidateContent,
    missingInformation: _parseMissingInformation(
      _expectList(output, 'missingInformation'),
    ),
    warnings: _parseStringList(_expectList(output, 'warnings')),
  );
}

ResumeData _candidateProjectionToResumeData(
  Map<String, Object?> candidateProjection,
  BasicResumeComposeDraft draft,
) {
  _expectExactKeys(candidateProjection, const {
    'schemaVersion',
    'profile',
    'workExperiences',
    'educations',
    'projects',
    'skillGroups',
    'certifications',
    'languages',
    'customSections',
  });
  if (_expectString(candidateProjection, 'schemaVersion') !=
      currentResumeSchemaVersion) {
    throw const RemoteResumeAiResponseException();
  }
  final profileProjection = _expectMap(candidateProjection, 'profile');
  final coreProfile = Map<String, Object?>.of(profileProjection);
  for (final field in ['fullName', 'phone', 'email', 'preciseAddress']) {
    if (coreProfile.containsKey(field) && coreProfile[field] is! String) {
      throw const RemoteResumeAiResponseException();
    }
    coreProfile.remove(field);
  }
  _expectExactKeys(coreProfile, const {'id', 'headline', 'coarseLocation'});
  String personalValue(String field, String local) =>
      draft.sharePersonalData != null || local.trim().isNotEmpty
      ? local.trim()
      : draft.naturalLanguageInput
      ? (profileProjection[field] as String? ?? '').trim()
      : '';
  final localAddress = personalValue('preciseAddress', draft.preciseAddress);
  final canonicalJson = <String, Object?>{
    'schemaVersion': currentResumeSchemaVersion,
    'profile': {
      'id': _expectEntityId(profileProjection, 'id'),
      'fullName': personalValue('fullName', draft.fullName),
      'headline': draft.headline.trim().isNotEmpty
          ? draft.headline.trim()
          : _expectString(profileProjection, 'headline'),
      'email': personalValue('email', draft.email),
      'phone': personalValue('phone', draft.phone),
      'location': draft.sharePersonalData != null || localAddress.isNotEmpty
          ? localAddress
          : _expectString(profileProjection, 'coarseLocation'),
      'links': draft.links.map((link) => link.toJson()).toList(),
      if (draft.photo != null) 'photo': draft.photo!.toJson(),
    },
    'workExperiences': _parseObjectList(
      _expectList(candidateProjection, 'workExperiences'),
      _workProjectionToCanonical,
    ),
    'educations': _parseObjectList(
      _expectList(candidateProjection, 'educations'),
      _educationProjectionToCanonical,
    ),
    'projects': _parseObjectList(
      _expectList(candidateProjection, 'projects'),
      _projectProjectionToCanonical,
    ),
    'skillGroups': _parseObjectList(
      _expectList(candidateProjection, 'skillGroups'),
      _skillProjectionToCanonical,
    ),
    'certifications': _parseObjectList(
      _expectList(candidateProjection, 'certifications'),
      _certificationProjectionToCanonical,
    ),
    'languages': _parseObjectList(
      _expectList(candidateProjection, 'languages'),
      _languageProjectionToCanonical,
    ),
    'customSections': _parseObjectList(
      _expectList(candidateProjection, 'customSections'),
      _customSectionProjectionToCanonical,
    ),
    'unmapped': <String, Object?>{},
  };
  _preserveUndatedExperiences(canonicalJson);
  try {
    return ResumeData.fromJson(canonicalJson);
  } on Object {
    throw const RemoteResumeAiResponseException();
  }
}

void _preserveUndatedExperiences(Map<String, Object?> canonicalJson) {
  // Domain work/education ranges require a start. Preserve undated source facts
  // as normal custom items instead of inventing dates or discarding the entry.
  final usedIds = <String>{};
  void collectIds(Object? value) {
    if (value is Map<String, Object?>) {
      if (value['id'] case final String id) usedIds.add(id);
      value.values.forEach(collectIds);
    } else if (value is List) {
      value.forEach(collectIds);
    }
  }

  collectIds(canonicalJson);
  final customSections = List<Map<String, Object?>>.of(
    canonicalJson['customSections']! as List<Map<String, Object?>>,
  );
  for (final field in ['workExperiences', 'educations']) {
    final isEducation = field == 'educations';
    final dated = <Map<String, Object?>>[];
    final undated = <Map<String, Object?>>[];
    for (final entry in canonicalJson[field]! as List<Map<String, Object?>>) {
      if (entry['dateRange'] != null) {
        dated.add(entry);
        continue;
      }
      final title = isEducation
          ? entry['institution']! as String
          : [entry['organization'], entry['position']]
                .cast<String>()
                .where((value) => value.trim().isNotEmpty)
                .join(' · ');
      undated.add({
        'id': entry['id'],
        'title': title.trim().isEmpty ? (isEducation ? '教育经历' : '工作经历') : title,
        'description': [
          if (isEducation) ...[
            if ((entry['degree']! as String).isNotEmpty)
              '学历：${entry['degree']}',
            if ((entry['fieldOfStudy']! as String).isNotEmpty)
              '专业：${entry['fieldOfStudy']}',
          ] else
            entry['summary']! as String,
          ...(entry['highlights']! as List<String>),
        ].where((value) => value.trim().isNotEmpty).join('\n'),
      });
    }
    canonicalJson[field] = dated;
    if (undated.isNotEmpty) {
      final prefix = isEducation
          ? 'candidate-undated-education'
          : 'candidate-undated-work';
      var sectionId = prefix;
      for (var suffix = 1; !usedIds.add(sectionId); suffix++) {
        sectionId = '$prefix-$suffix';
      }
      customSections.add({
        'id': sectionId,
        'title': isEducation ? '教育经历' : '工作经历',
        'items': undated,
      });
    }
  }
  canonicalJson['customSections'] = customSections;
}

Map<String, Object?> _workProjectionToCanonical(Map<String, Object?> source) {
  _expectExactKeys(source, const {
    'id',
    'organization',
    'position',
    'dateRange',
    'summary',
    'highlights',
  });
  return {
    'id': _expectEntityId(source, 'id'),
    'organization': _expectString(source, 'organization'),
    'position': _expectString(source, 'position'),
    'dateRange': _parseDateRange(source['dateRange']),
    'summary': _expectString(source, 'summary'),
    'highlights': _parseStringList(_expectList(source, 'highlights')),
  };
}

Map<String, Object?> _educationProjectionToCanonical(
  Map<String, Object?> source,
) {
  _expectExactKeys(source, const {
    'id',
    'institution',
    'degree',
    'fieldOfStudy',
    'dateRange',
    'highlights',
  });
  return {
    'id': _expectEntityId(source, 'id'),
    'institution': _expectString(source, 'institution'),
    'degree': _expectString(source, 'degree'),
    'fieldOfStudy': _expectString(source, 'fieldOfStudy'),
    'dateRange': _parseDateRange(source['dateRange']),
    'highlights': _parseStringList(_expectList(source, 'highlights')),
  };
}

Map<String, Object?> _projectProjectionToCanonical(
  Map<String, Object?> source,
) {
  _expectExactKeys(source, const {
    'id',
    'name',
    'role',
    'dateRange',
    'summary',
    'highlights',
  });
  return {
    'id': _expectEntityId(source, 'id'),
    'name': _expectString(source, 'name'),
    'role': _expectString(source, 'role'),
    'dateRange': _parseDateRange(source['dateRange']),
    'summary': _expectString(source, 'summary'),
    'highlights': _parseStringList(_expectList(source, 'highlights')),
    'links': <Object?>[],
  };
}

Map<String, Object?> _skillProjectionToCanonical(Map<String, Object?> source) {
  _expectExactKeys(source, const {'id', 'name', 'skills'});
  return {
    'id': _expectEntityId(source, 'id'),
    'name': _expectString(source, 'name'),
    'skills': _parseStringList(_expectList(source, 'skills')),
  };
}

Map<String, Object?> _certificationProjectionToCanonical(
  Map<String, Object?> source,
) {
  _expectExactKeys(source, const {
    'id',
    'name',
    'issuer',
    'issuedOn',
    'expiresOn',
  });
  return {
    'id': _expectEntityId(source, 'id'),
    'name': _expectString(source, 'name'),
    'issuer': _expectString(source, 'issuer'),
    'issuedOn': _parseResumeDate(source['issuedOn']),
    'expiresOn': _parseResumeDate(source['expiresOn']),
    'credentialId': '',
    'credentialUrl': '',
  };
}

Map<String, Object?> _languageProjectionToCanonical(
  Map<String, Object?> source,
) {
  _expectExactKeys(source, const {'id', 'name', 'proficiency'});
  return {
    'id': _expectEntityId(source, 'id'),
    'name': _expectString(source, 'name'),
    'proficiency': _expectString(source, 'proficiency'),
  };
}

Map<String, Object?> _customSectionProjectionToCanonical(
  Map<String, Object?> source,
) {
  _expectExactKeys(source, const {'id', 'title', 'items'});
  return {
    'id': _expectEntityId(source, 'id'),
    'title': _expectString(source, 'title'),
    'items': _parseObjectList(_expectList(source, 'items'), (item) {
      _expectExactKeys(item, const {'id', 'title', 'description'});
      return {
        'id': _expectEntityId(item, 'id'),
        'title': _expectString(item, 'title'),
        'description': _expectString(item, 'description'),
      };
    }),
  };
}

Object? _parseDateRange(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is! Map<String, Object?>) {
    throw const RemoteResumeAiResponseException();
  }
  _expectExactKeys(value, const {'start', 'end', 'isCurrent'});
  final isCurrent = value['isCurrent'];
  if (isCurrent is! bool) {
    throw const RemoteResumeAiResponseException();
  }
  return {
    'start': _parseResumeDate(value['start']),
    'end': _parseResumeDate(value['end']),
    'isCurrent': isCurrent,
  };
}

Object? _parseResumeDate(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is! Map<String, Object?>) {
    throw const RemoteResumeAiResponseException();
  }
  _expectExactKeys(value, const {'year', 'month'});
  final year = value['year'];
  final month = value['month'];
  if (year is! int || (month != null && month is! int)) {
    throw const RemoteResumeAiResponseException();
  }
  return {'year': year, 'month': month};
}

List<Map<String, Object?>> _parseObjectList(
  List<Object?> source,
  Map<String, Object?> Function(Map<String, Object?> item) parseItem,
) {
  return source
      .map((item) {
        if (item is! Map<String, Object?>) {
          throw const RemoteResumeAiResponseException();
        }
        return parseItem(item);
      })
      .toList(growable: false);
}

void _validateSourceReferences(
  List<Object?> sourceReferences,
  Map<String, Object?> candidateProjection,
  Set<String> knownFragmentIds,
) {
  if (sourceReferences.isEmpty || sourceReferences.length > 100) {
    throw const RemoteResumeAiResponseException();
  }
  for (final reference in sourceReferences) {
    if (reference is! Map<String, Object?>) {
      throw const RemoteResumeAiResponseException();
    }
    _expectExactKeys(reference, const {'path', 'fragmentIds'});
    final path = _expectNonEmptyString(reference, 'path');
    _resolveJsonPointer(candidateProjection, path);
    final fragmentIds = _parseStringList(_expectList(reference, 'fragmentIds'));
    if (fragmentIds.isEmpty ||
        fragmentIds.any(
          (fragmentId) => !knownFragmentIds.contains(fragmentId),
        )) {
      throw const RemoteResumeAiResponseException();
    }
  }
}

Object? _resolveJsonPointer(Map<String, Object?> root, String pointer) {
  if (!pointer.startsWith('/') || pointer == '/') {
    throw const RemoteResumeAiResponseException();
  }
  Object? currentValue = root;
  for (final encodedSegment in pointer.substring(1).split('/')) {
    if (RegExp(r'~(?![01])').hasMatch(encodedSegment)) {
      throw const RemoteResumeAiResponseException();
    }
    final segment = encodedSegment.replaceAll('~1', '/').replaceAll('~0', '~');
    if (currentValue is Map<String, Object?>) {
      if (!currentValue.containsKey(segment)) {
        throw const RemoteResumeAiResponseException();
      }
      currentValue = currentValue[segment];
      continue;
    }
    if (currentValue is List<Object?>) {
      final index = int.tryParse(segment);
      if (index == null || index < 0 || index >= currentValue.length) {
        throw const RemoteResumeAiResponseException();
      }
      currentValue = currentValue[index];
      continue;
    }
    throw const RemoteResumeAiResponseException();
  }
  return currentValue;
}

List<String> _parseMissingInformation(
  List<Object?> source, {
  int maximumItems = 30,
}) {
  if (source.length > maximumItems) {
    throw const RemoteResumeAiResponseException();
  }
  return source
      .map((item) {
        if (item is! Map<String, Object?>) {
          throw const RemoteResumeAiResponseException();
        }
        _expectExactKeys(item, const {'path', 'question'});
        final path = _expectNonEmptyString(item, 'path');
        final question = _expectNonEmptyString(item, 'question');
        return path == '/'
            ? question
            : '${resumeReviewFieldLabel(path)}：$question';
      })
      .toList(growable: false);
}

List<String> _parseStringList(List<Object?> source) {
  return source
      .map((value) {
        if (value is! String || value.trim().isEmpty) {
          throw const RemoteResumeAiResponseException();
        }
        return value;
      })
      .toList(growable: false);
}

List<String> _parseBoundedStringList(
  List<Object?> source, {
  required int maximumItems,
  required int maximumCharacters,
}) {
  if (source.length > maximumItems) {
    throw const RemoteResumeAiResponseException();
  }
  return source
      .map((value) {
        if (value is! String ||
            value.trim().isEmpty ||
            value.runes.length > maximumCharacters) {
          throw const RemoteResumeAiResponseException();
        }
        return value.trim();
      })
      .toList(growable: false);
}

ResumePatch _buildBasicCandidatePatch(
  ResumeData baseContent,
  ResumeData candidateContent,
) {
  final operations = <ResumePatchOperation>[];
  void replaceTextIfChanged(
    String path,
    String oldValue,
    String newValue, {
    ResumeChangeCategory category = ResumeChangeCategory.wording,
  }) {
    if (oldValue == newValue) {
      return;
    }
    operations.add(
      ResumePatchOperation(
        type: PatchOperationType.replace,
        path: path,
        oldValue: oldValue,
        newValue: newValue,
        reason: '根据用户提供的碎片信息整理基础简历。',
        source: 'remoteAi',
        category: category,
      ),
    );
  }

  replaceTextIfChanged(
    '/profile/headline',
    baseContent.profile.headline,
    candidateContent.profile.headline,
  );
  replaceTextIfChanged(
    '/profile/location',
    baseContent.profile.location,
    candidateContent.profile.location,
    category: ResumeChangeCategory.fact,
  );
  for (final field in [
    (
      'fullName',
      baseContent.profile.fullName,
      candidateContent.profile.fullName,
    ),
    ('phone', baseContent.profile.phone, candidateContent.profile.phone),
    ('email', baseContent.profile.email, candidateContent.profile.email),
  ]) {
    replaceTextIfChanged(
      '/profile/${field.$1}',
      field.$2,
      field.$3,
      category: ResumeChangeCategory.fact,
    );
  }
  final candidateJson = candidateContent.toJson();
  for (final collectionName in const [
    'workExperiences',
    'educations',
    'projects',
    'skillGroups',
    'certifications',
    'languages',
    'customSections',
  ]) {
    final collectionItems = candidateJson[collectionName]! as List<Object?>;
    for (final collectionItem in collectionItems) {
      operations.add(
        ResumePatchOperation(
          type: PatchOperationType.add,
          path: '/$collectionName/-',
          oldValue: null,
          newValue: collectionItem,
          reason: '根据用户提供的碎片信息整理并归入对应区段。',
          source: 'remoteAi',
          category: ResumeChangeCategory.fact,
        ),
      );
    }
  }
  if (operations.isEmpty) {
    throw const RemoteResumeAiResponseException();
  }
  return ResumePatch(operations);
}

String _personalFieldLabel(RemotePersonalDataField field) => switch (field) {
  RemotePersonalDataField.fullName => '姓名',
  RemotePersonalDataField.phone => '手机号',
  RemotePersonalDataField.email => '邮箱',
  RemotePersonalDataField.preciseAddress => '精确地址',
};

Map<String, Object?> _expectMap(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value is! Map<String, Object?>) {
    throw const RemoteResumeAiResponseException();
  }
  return value;
}

List<Object?> _expectList(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value is! List<Object?>) {
    throw const RemoteResumeAiResponseException();
  }
  return value;
}

String _expectString(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value is! String) {
    throw const RemoteResumeAiResponseException();
  }
  return value;
}

String _expectNonEmptyString(Map<String, Object?> source, String key) {
  final value = _expectString(source, key);
  if (value.trim().isEmpty) {
    throw const RemoteResumeAiResponseException();
  }
  return value;
}

String _expectBoundedText(
  Map<String, Object?> source,
  String key,
  int maximumCharacters,
) {
  final value = _expectNonEmptyString(source, key).trim();
  if (value.runes.length > maximumCharacters) {
    throw const RemoteResumeAiResponseException();
  }
  return value;
}

String _expectEntityId(Map<String, Object?> source, String key) {
  final value = _expectNonEmptyString(source, key);
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]*$').hasMatch(value) ||
      value.length > 64) {
    throw const RemoteResumeAiResponseException();
  }
  return value;
}

void _expectExactKeys(Map<String, Object?> source, Set<String> expectedKeys) {
  final actualKeys = source.keys.toSet();
  if (actualKeys.difference(expectedKeys).isNotEmpty ||
      expectedKeys.difference(actualKeys).isNotEmpty) {
    throw const RemoteResumeAiResponseException();
  }
}

final class _RemoteAiIds {
  int _counter = 0;

  String next(String namespace) {
    _counter++;
    return '$namespace-${DateTime.now().toUtc().microsecondsSinceEpoch}-$_counter';
  }
}
