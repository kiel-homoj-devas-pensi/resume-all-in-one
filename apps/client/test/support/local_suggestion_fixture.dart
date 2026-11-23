// Legacy deterministic suggestion fixtures; no production entry point uses this provider.
import 'package:agent_protocol/agent_protocol.dart';
import 'package:agent_runtime/agent_runtime.dart';
import 'package:local_storage/local_storage.dart';
import 'package:model_router/model_router.dart';
import 'package:resume_domain/resume_domain.dart';
import 'package:resume_all_in_one_client/src/local_resume_suggestion_service.dart';

LocalResumeSuggestionService createOfflineLocalResumeSuggestionService({
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
      providerKey: 'local-resume-suggestion',
      location: ProviderLocation.local,
      capabilities: const {ModelCapability.structuredOutput},
    ),
    generate: _buildLocalSuggestionResponse,
  );
  final router = ModelRouter(
    ModelRegistry(
      registrations: [
        ProviderRegistration(
          provider: localProvider,
          modelId: 'local-resume-suggestion-v0.1',
        ),
      ],
    ),
  );
  return LocalResumeSuggestionService(
    runtime: runtime,
    router: router,
    auditRepository: auditRepository,
    clock: clock,
    nextId: nextId,
  );
}

Future<ModelResponse> _buildLocalSuggestionResponse(
  ModelRequest request,
) async {
  final resumeJson = request.input['resume'];
  if (resumeJson is! Map<String, Object?>) {
    throw const ModelProviderException(
      kind: ModelProviderFailureKind.invalidResponse,
      message: '缺少 Canonical Resume 输入',
    );
  }
  final resumeContent = ResumeData.fromJson(resumeJson);
  final suggestedOperation =
      _firstWhitespaceSuggestion(resumeContent) ??
      _firstRepeatedHighlightSuggestion(resumeContent);
  final agentResponse = suggestedOperation == null
      ? AgentResponse(
          summary: '当前已保存版本没有可安全生成的本地建议。',
          nextAction: AgentNextAction.none,
        )
      : AgentResponse(
          summary: '发现 1 项可由你审阅的本地建议。',
          proposedPatch: ResumePatch([suggestedOperation]).toJson(),
          citations: [suggestedOperation.path],
          nextAction: AgentNextAction.reviewPatch,
        );
  return ModelResponse(
    text: agentResponse.summary,
    structuredData: agentResponse.toJson(),
    usage: ModelUsage(inputTokens: 0, outputTokens: 0),
    finishReason: ModelFinishReason.completed,
  );
}

ResumePatchOperation? _firstWhitespaceSuggestion(ResumeData resumeContent) {
  ResumePatchOperation? normalizeText(String text, String path) {
    final normalizedText = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalizedText.isEmpty || normalizedText == text) {
      return null;
    }
    return ResumePatchOperation(
      type: PatchOperationType.replace,
      path: path,
      oldValue: text,
      newValue: normalizedText,
      reason: '统一多余空白，避免导出排版出现不必要的间距。',
      source: '本地规则',
      category: ResumeChangeCategory.format,
    );
  }

  final headlineSuggestion = normalizeText(
    resumeContent.profile.headline,
    '/profile/headline',
  );
  if (headlineSuggestion != null) {
    return headlineSuggestion;
  }
  for (final indexedExperience in resumeContent.workExperiences.indexed) {
    final experienceIndex = indexedExperience.$1;
    final workExperience = indexedExperience.$2;
    final summarySuggestion = normalizeText(
      workExperience.summary,
      '/workExperiences/$experienceIndex/summary',
    );
    if (summarySuggestion != null) {
      return summarySuggestion;
    }
    final highlightSuggestion = _firstTextListNormalization(
      workExperience.highlights,
      '/workExperiences/$experienceIndex/highlights',
      normalizeText,
    );
    if (highlightSuggestion != null) {
      return highlightSuggestion;
    }
  }
  for (final indexedEducation in resumeContent.educations.indexed) {
    final highlightSuggestion = _firstTextListNormalization(
      indexedEducation.$2.highlights,
      '/educations/${indexedEducation.$1}/highlights',
      normalizeText,
    );
    if (highlightSuggestion != null) {
      return highlightSuggestion;
    }
  }
  for (final indexedProject in resumeContent.projects.indexed) {
    final projectIndex = indexedProject.$1;
    final project = indexedProject.$2;
    final summarySuggestion = normalizeText(
      project.summary,
      '/projects/$projectIndex/summary',
    );
    if (summarySuggestion != null) {
      return summarySuggestion;
    }
    final highlightSuggestion = _firstTextListNormalization(
      project.highlights,
      '/projects/$projectIndex/highlights',
      normalizeText,
    );
    if (highlightSuggestion != null) {
      return highlightSuggestion;
    }
  }
  for (final indexedSection in resumeContent.customSections.indexed) {
    for (final indexedCustomItem in indexedSection.$2.items.indexed) {
      final descriptionSuggestion = normalizeText(
        indexedCustomItem.$2.description,
        '/customSections/${indexedSection.$1}/items/${indexedCustomItem.$1}/description',
      );
      if (descriptionSuggestion != null) {
        return descriptionSuggestion;
      }
    }
  }
  return null;
}

ResumePatchOperation? _firstTextListNormalization(
  List<String> texts,
  String listPath,
  ResumePatchOperation? Function(String text, String path) normalizeText,
) {
  for (final indexedText in texts.indexed) {
    final suggestion = normalizeText(
      indexedText.$2,
      '$listPath/${indexedText.$1}',
    );
    if (suggestion != null) {
      return suggestion;
    }
  }
  return null;
}

ResumePatchOperation? _firstRepeatedHighlightSuggestion(
  ResumeData resumeContent,
) {
  ResumePatchOperation? findRepeatedHighlight(
    List<String> highlights,
    String listPath,
  ) {
    final seenHighlights = <String>{};
    for (final indexedHighlight in highlights.indexed) {
      final highlight = indexedHighlight.$2;
      if (highlight.isEmpty) {
        continue;
      }
      if (!seenHighlights.add(highlight)) {
        return ResumePatchOperation(
          type: PatchOperationType.remove,
          path: '$listPath/${indexedHighlight.$1}',
          oldValue: highlight,
          newValue: null,
          reason: '同一列表中已出现完全相同的内容，删除后出现的一项可减少重复。',
          source: '本地规则',
          category: ResumeChangeCategory.wording,
        );
      }
    }
    return null;
  }

  for (final indexedExperience in resumeContent.workExperiences.indexed) {
    final suggestion = findRepeatedHighlight(
      indexedExperience.$2.highlights,
      '/workExperiences/${indexedExperience.$1}/highlights',
    );
    if (suggestion != null) {
      return suggestion;
    }
  }
  for (final indexedEducation in resumeContent.educations.indexed) {
    final suggestion = findRepeatedHighlight(
      indexedEducation.$2.highlights,
      '/educations/${indexedEducation.$1}/highlights',
    );
    if (suggestion != null) {
      return suggestion;
    }
  }
  for (final indexedProject in resumeContent.projects.indexed) {
    final suggestion = findRepeatedHighlight(
      indexedProject.$2.highlights,
      '/projects/${indexedProject.$1}/highlights',
    );
    if (suggestion != null) {
      return suggestion;
    }
  }
  return null;
}
