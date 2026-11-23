import 'package:agent_protocol/agent_protocol.dart';
import 'package:resume_domain/resume_domain.dart';

import 'confirmation_gate.dart';
import 'registry.dart';

final class ReadResumeTool implements AgentTool {
  ReadResumeTool(this._repository);

  final ResumeRepository _repository;

  @override
  final ToolDescriptor descriptor = _descriptor(
    name: 'read_resume',
    permission: ToolPermission.resumeRead,
    access: ToolAccess.read,
    requiredProperties: const {'versionId': _stringSchema},
    outputProperties: const {
      'version': {'type': 'object'},
    },
  );

  @override
  Future<ToolOutcome> execute(
    JsonObject arguments, {
    required AgentCancellationToken cancellationToken,
  }) async {
    final versionId = _singleVersionId(arguments);
    if (cancellationToken.isCancelled) {
      return _cancelled();
    }
    final version = await _repository.findVersion(versionId);
    if (version == null) {
      return _notFound();
    }
    return ToolOutcome(
      status: ToolResultStatus.success,
      data: {'version': version.toJson()},
    );
  }
}

final class ValidateResumeTool implements AgentTool {
  ValidateResumeTool(
    this._repository, {
    ResumeValidator validator = const ResumeValidator(),
  }) : _validator = validator;

  final ResumeRepository _repository;
  final ResumeValidator _validator;

  @override
  final ToolDescriptor descriptor = _descriptor(
    name: 'validate_resume',
    permission: ToolPermission.resumeRead,
    access: ToolAccess.read,
    requiredProperties: const {'versionId': _stringSchema},
    outputProperties: const {
      'isValid': {'type': 'boolean'},
      'validationIssues': {'type': 'array'},
    },
  );

  @override
  Future<ToolOutcome> execute(
    JsonObject arguments, {
    required AgentCancellationToken cancellationToken,
  }) async {
    final versionId = _singleVersionId(arguments);
    if (cancellationToken.isCancelled) {
      return _cancelled();
    }
    final version = await _repository.findVersion(versionId);
    if (version == null) {
      return _notFound();
    }
    final validation = _validator.validate(version.content);
    final issues = validation.issues.map(_protocolIssue).toList();
    return ToolOutcome(
      status: ToolResultStatus.success,
      data: {
        'isValid': validation.isValid,
        'validationIssues': issues.map((issue) => issue.toJson()).toList(),
      },
      validationIssues: issues,
    );
  }
}

final class FindRepeatedContentTool implements AgentTool {
  FindRepeatedContentTool(
    this._repository, {
    ResumeValidator validator = const ResumeValidator(),
  }) : _validator = validator;

  final ResumeRepository _repository;
  final ResumeValidator _validator;

  @override
  final ToolDescriptor descriptor = _descriptor(
    name: 'find_repeated_content',
    permission: ToolPermission.resumeRead,
    access: ToolAccess.read,
    requiredProperties: const {'versionId': _stringSchema},
    outputProperties: const {
      'versionId': _stringSchema,
      'repeatedGroups': {'type': 'array'},
      'repeatedGroupCount': {'type': 'integer'},
      'repeatedOccurrenceCount': {'type': 'integer'},
    },
  );

  @override
  Future<ToolOutcome> execute(
    JsonObject arguments, {
    required AgentCancellationToken cancellationToken,
  }) async {
    final versionId = _singleVersionId(arguments);
    if (cancellationToken.isCancelled) {
      return _cancelled();
    }
    final resumeVersion = await _repository.findVersion(versionId);
    if (resumeVersion == null) {
      return _notFound();
    }

    final validation = _validator.validate(resumeVersion.content);
    final validationIssues = validation.issues.map(_protocolIssue).toList();
    if (!validation.isValid) {
      return ToolOutcome(
        status: ToolResultStatus.invalidCall,
        validationIssues: validationIssues,
        error: const ToolError(
          code: 'validation_failed',
          message: '目标版本未通过 Canonical validation',
        ),
      );
    }

    final repeatedGroups = _findRepeatedContent(resumeVersion.content);
    return ToolOutcome(
      status: ToolResultStatus.success,
      data: {
        'versionId': resumeVersion.id,
        'repeatedGroups': repeatedGroups
            .map((repeatedGroup) => repeatedGroup.toJson())
            .toList(),
        'repeatedGroupCount': repeatedGroups.length,
        'repeatedOccurrenceCount': repeatedGroups.fold<int>(
          0,
          (count, repeatedGroup) => count + repeatedGroup.paths.length,
        ),
      },
      validationIssues: validationIssues,
    );
  }
}

final class BuildPatchTool implements AgentTool {
  BuildPatchTool(
    this._repository,
    this._confirmationGate, {
    ResumeValidator validator = const ResumeValidator(),
  }) : _validator = validator;

  final ResumeRepository _repository;
  final ConfirmationGate _confirmationGate;
  final ResumeValidator _validator;

  @override
  final ToolDescriptor descriptor = _descriptor(
    name: 'build_patch',
    permission: ToolPermission.resumePatchProposal,
    access: ToolAccess.proposeWrite,
    requiredProperties: const {
      'versionId': _stringSchema,
      'patch': {'type': 'object'},
    },
    outputProperties: const {
      'confirmationId': _stringSchema,
      'baseVersionId': _stringSchema,
      'patch': {'type': 'object'},
      'diff': {'type': 'object'},
      'riskLevel': _stringSchema,
    },
  );

  @override
  Future<ToolOutcome> execute(
    JsonObject arguments, {
    required AgentCancellationToken cancellationToken,
  }) async {
    _requireExactArguments(arguments, const {'versionId', 'patch'});
    final versionId = _argumentString(arguments, 'versionId');
    final patchJson = _argumentObject(arguments, 'patch');
    if (cancellationToken.isCancelled) {
      return _cancelled();
    }
    final version = await _repository.findVersion(versionId);
    if (version == null) {
      return _notFound();
    }

    try {
      final patch = ResumePatch.fromJson(patchJson);
      final updated = patch.apply(version.content, validator: _validator);
      final validation = _validator.validate(updated);
      final issues = validation.issues.map(_protocolIssue).toList();
      if (cancellationToken.isCancelled) {
        return _cancelled();
      }
      final diff = ResumeDiff.fromPatch(patch);
      final confirmationId = _confirmationGate.propose(
        baseVersion: version,
        patch: patch,
      );
      return ToolOutcome(
        status: ToolResultStatus.requiresConfirmation,
        data: {
          'confirmationId': confirmationId,
          'baseVersionId': version.id,
          'patch': patch.toJson(),
          'diff': diff.toJson(),
          'riskLevel': _riskLevel(patch).name,
        },
        validationIssues: issues,
      );
    } on ResumeValidationException catch (error) {
      final issues = error.result.issues.map(_protocolIssue).toList();
      return ToolOutcome(
        status: ToolResultStatus.invalidCall,
        validationIssues: issues,
        error: const ToolError(
          code: 'validation_failed',
          message: 'Patch 结果未通过 Canonical validation',
        ),
      );
    } on SchemaFormatException {
      return _invalidPatch();
    } on PatchApplyException {
      return _invalidPatch();
    } on ArgumentError {
      return _invalidPatch();
    }
  }
}

const JsonObject _stringSchema = {'type': 'string', 'minLength': 1};

ToolDescriptor _descriptor({
  required String name,
  required ToolPermission permission,
  required ToolAccess access,
  required JsonObject requiredProperties,
  required JsonObject outputProperties,
}) {
  return ToolDescriptor(
    name: name,
    version: currentAgentProtocolVersion,
    inputSchema: {
      'type': 'object',
      'additionalProperties': false,
      'required': requiredProperties.keys.toList(),
      'properties': requiredProperties,
    },
    outputSchema: {'type': 'object', 'properties': outputProperties},
    permission: permission,
    access: access,
    usesNetwork: false,
    retryable: true,
    timeoutMs: 5000,
    auditFields: const [
      'toolName',
      'toolVersion',
      'startedAt',
      'finishedAt',
      'offline',
      'idempotencyKey',
      'replayed',
    ],
  );
}

String _singleVersionId(JsonObject arguments) {
  _requireExactArguments(arguments, const {'versionId'});
  return _argumentString(arguments, 'versionId');
}

void _requireExactArguments(JsonObject arguments, Set<String> required) {
  for (final key in required) {
    if (!arguments.containsKey(key)) {
      throw ToolArgumentException('argument_missing', '缺少工具参数：$key');
    }
  }
  for (final key in arguments.keys) {
    if (!required.contains(key)) {
      throw ToolArgumentException('argument_unknown', '工具参数未声明：$key');
    }
  }
}

String _argumentString(JsonObject arguments, String key) {
  final value = arguments[key];
  if (value is! String || value.trim().isEmpty) {
    throw ToolArgumentException('argument_invalid', '工具参数 $key 必须是非空字符串');
  }
  return value;
}

JsonObject _argumentObject(JsonObject arguments, String key) {
  final value = arguments[key];
  if (value is! Map<String, Object?>) {
    throw ToolArgumentException('argument_invalid', '工具参数 $key 必须是对象');
  }
  return value;
}

ProtocolValidationIssue _protocolIssue(ValidationIssue issue) {
  return ProtocolValidationIssue(
    path: issue.path,
    severity: ProtocolValidationSeverity.values.byName(issue.severity.name),
    ruleId: issue.ruleId,
    message: issue.message,
    blocksAction: issue.blocksCommit,
  );
}

AgentRiskLevel _riskLevel(ResumePatch patch) {
  return patch.operations.any(
        (operation) => operation.category == ResumeChangeCategory.fact,
      )
      ? AgentRiskLevel.high
      : AgentRiskLevel.medium;
}

ToolOutcome _cancelled() {
  return ToolOutcome(
    status: ToolResultStatus.cancelled,
    error: const ToolError(code: 'cancelled', message: '调用已取消'),
  );
}

ToolOutcome _notFound() {
  return ToolOutcome(
    status: ToolResultStatus.notFound,
    error: const ToolError(code: 'version_not_found', message: '目标版本不存在'),
  );
}

ToolOutcome _invalidPatch() {
  return ToolOutcome(
    status: ToolResultStatus.invalidCall,
    error: const ToolError(code: 'patch_invalid', message: 'Patch 格式、路径或旧值无效'),
  );
}

List<_RepeatedContentGroup> _findRepeatedContent(ResumeData resumeContent) {
  final pathsByNormalizedText = <String, List<String>>{};

  void collectText(String text, String path) {
    final normalizedText = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalizedText.isEmpty) {
      return;
    }
    // LinkedHashMap 保留首次出现顺序，使结果稳定且便于测试和人工核对。
    pathsByNormalizedText.putIfAbsent(normalizedText, () => []).add(path);
  }

  for (final indexedExperience in resumeContent.workExperiences.indexed) {
    final experienceIndex = indexedExperience.$1;
    final workExperience = indexedExperience.$2;
    collectText(
      workExperience.summary,
      '/workExperiences/$experienceIndex/summary',
    );
    for (final indexedHighlight in workExperience.highlights.indexed) {
      collectText(
        indexedHighlight.$2,
        '/workExperiences/$experienceIndex/highlights/${indexedHighlight.$1}',
      );
    }
  }
  for (final indexedEducation in resumeContent.educations.indexed) {
    for (final indexedHighlight in indexedEducation.$2.highlights.indexed) {
      collectText(
        indexedHighlight.$2,
        '/educations/${indexedEducation.$1}/highlights/${indexedHighlight.$1}',
      );
    }
  }
  for (final indexedProject in resumeContent.projects.indexed) {
    final projectIndex = indexedProject.$1;
    final project = indexedProject.$2;
    collectText(project.summary, '/projects/$projectIndex/summary');
    for (final indexedHighlight in project.highlights.indexed) {
      collectText(
        indexedHighlight.$2,
        '/projects/$projectIndex/highlights/${indexedHighlight.$1}',
      );
    }
  }
  for (final indexedSection in resumeContent.customSections.indexed) {
    for (final indexedCustomItem in indexedSection.$2.items.indexed) {
      collectText(
        indexedCustomItem.$2.description,
        '/customSections/${indexedSection.$1}/items/${indexedCustomItem.$1}/description',
      );
    }
  }

  return pathsByNormalizedText.entries
      .where((textLocations) => textLocations.value.length > 1)
      .map(
        (textLocations) => _RepeatedContentGroup(
          text: textLocations.key,
          paths: textLocations.value,
        ),
      )
      .toList(growable: false);
}

final class _RepeatedContentGroup {
  _RepeatedContentGroup({required this.text, required List<String> paths})
    : paths = List.unmodifiable(paths);

  final String text;
  final List<String> paths;

  JsonObject toJson() => {'text': text, 'paths': paths};
}
