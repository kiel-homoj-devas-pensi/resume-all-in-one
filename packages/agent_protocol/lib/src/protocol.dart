import 'json_support.dart';
import 'tool.dart';

enum AgentPrivacyMode { localOnly }

enum AgentRiskLevel { low, medium, high }

enum AgentNextAction { none, reviewPatch, retry }

final class AgentRequest {
  AgentRequest({
    required this.requestId,
    required this.conversationId,
    required this.resumeVersionId,
    required this.intent,
    JsonObject constraints = const {},
    required this.privacyMode,
  }) : constraints = freezeProtocolObject(constraints) {
    _requireText(requestId, 'requestId');
    _requireText(conversationId, 'conversationId');
    _requireText(resumeVersionId, 'resumeVersionId');
    _requireText(intent, 'intent');
  }

  final String requestId;
  final String conversationId;
  final String resumeVersionId;
  final String intent;
  final JsonObject constraints;
  final AgentPrivacyMode privacyMode;

  factory AgentRequest.fromJson(JsonObject json, [String path = r'$']) {
    requireProtocolFields(
      json,
      path,
      required: const {
        'requestId',
        'conversationId',
        'resumeVersionId',
        'intent',
        'constraints',
        'privacyMode',
      },
    );
    return AgentRequest(
      requestId: readProtocolString(json['requestId'], '$path/requestId'),
      conversationId: readProtocolString(
        json['conversationId'],
        '$path/conversationId',
      ),
      resumeVersionId: readProtocolString(
        json['resumeVersionId'],
        '$path/resumeVersionId',
      ),
      intent: readProtocolString(json['intent'], '$path/intent'),
      constraints: readProtocolObject(json['constraints'], '$path/constraints'),
      privacyMode: readProtocolEnum(
        json['privacyMode'],
        '$path/privacyMode',
        AgentPrivacyMode.values,
      ),
    );
  }

  JsonObject toJson() => {
    'requestId': requestId,
    'conversationId': conversationId,
    'resumeVersionId': resumeVersionId,
    'intent': intent,
    'constraints': deepCopyProtocolJson(constraints),
    'privacyMode': privacyMode.name,
  };
}

final class AgentPlan {
  AgentPlan({
    required List<ToolCall> actions,
    required this.requiresConfirmation,
    required this.riskLevel,
  }) : actions = List<ToolCall>.unmodifiable(actions) {
    if (this.actions.isEmpty) {
      throw ArgumentError.value(actions, 'actions', '不能为空');
    }
  }

  final List<ToolCall> actions;
  final bool requiresConfirmation;
  final AgentRiskLevel riskLevel;

  factory AgentPlan.fromJson(JsonObject json, [String path = r'$']) {
    requireProtocolFields(
      json,
      path,
      required: const {'actions', 'requiresConfirmation', 'riskLevel'},
    );
    final source = readProtocolList(json['actions'], '$path/actions');
    return AgentPlan(
      actions: source.indexed
          .map(
            (entry) => ToolCall.fromJson(
              readProtocolObject(entry.$2, '$path/actions/${entry.$1}'),
              '$path/actions/${entry.$1}',
            ),
          )
          .toList(),
      requiresConfirmation: readProtocolBool(
        json['requiresConfirmation'],
        '$path/requiresConfirmation',
      ),
      riskLevel: readProtocolEnum(
        json['riskLevel'],
        '$path/riskLevel',
        AgentRiskLevel.values,
      ),
    );
  }

  JsonObject toJson() => {
    'actions': actions.map((action) => action.toJson()).toList(),
    'requiresConfirmation': requiresConfirmation,
    'riskLevel': riskLevel.name,
  };
}

final class AgentResponse {
  AgentResponse({
    required this.summary,
    JsonObject? proposedPatch,
    List<String> citations = const [],
    List<String> warnings = const [],
    required this.nextAction,
  }) : proposedPatch = proposedPatch == null
           ? null
           : freezeProtocolObject(proposedPatch),
       citations = List<String>.unmodifiable(citations),
       warnings = List<String>.unmodifiable(warnings) {
    _requireText(summary, 'summary');
  }

  final String summary;
  final JsonObject? proposedPatch;
  final List<String> citations;
  final List<String> warnings;
  final AgentNextAction nextAction;

  factory AgentResponse.fromJson(JsonObject json, [String path = r'$']) {
    requireProtocolFields(
      json,
      path,
      required: const {
        'summary',
        'proposedPatch',
        'citations',
        'warnings',
        'nextAction',
      },
    );
    final patch = json['proposedPatch'];
    return AgentResponse(
      summary: readProtocolString(json['summary'], '$path/summary'),
      proposedPatch: patch == null
          ? null
          : readProtocolObject(patch, '$path/proposedPatch'),
      citations: readProtocolStringList(json['citations'], '$path/citations'),
      warnings: readProtocolStringList(json['warnings'], '$path/warnings'),
      nextAction: readProtocolEnum(
        json['nextAction'],
        '$path/nextAction',
        AgentNextAction.values,
      ),
    );
  }

  JsonObject toJson() => {
    'summary': summary,
    'proposedPatch': deepCopyProtocolJson(proposedPatch),
    'citations': citations.toList(),
    'warnings': warnings.toList(),
    'nextAction': nextAction.name,
  };
}

void _requireText(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, '不能为空');
  }
}
