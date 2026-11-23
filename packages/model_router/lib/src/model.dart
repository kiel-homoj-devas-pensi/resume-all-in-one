import 'dart:collection';

import 'package:agent_protocol/agent_protocol.dart';

const currentModelRoutingVersion = '0.1.0';

enum ModelTaskType { analysis, rewrite, toolPlanning }

enum ModelCapability { textGeneration, structuredOutput, toolCalling }

enum ProviderLocation { local, remote }

enum ModelPrivacyPolicy { localOnly, remoteAllowed }

enum ModelFinishReason { completed, lengthLimit, cancelled }

enum ModelProviderFailureKind {
  unavailable,
  timeout,
  rateLimited,
  quotaExceeded,
  invalidResponse,
  cancelled,
  unknown,
}

final class ModelCancellationToken {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() => _isCancelled = true;
}

final class ModelRequest {
  ModelRequest({
    required this.requestId,
    required this.taskType,
    required JsonObject input,
    required Set<ModelCapability> requiredCapabilities,
    JsonObject outputSchema = const {},
    List<ToolDescriptor> tools = const [],
    required this.contextBudgetTokens,
    this.estimatedQuotaUnits = 1,
    required this.privacyPolicy,
    ModelCancellationToken? cancellationToken,
  }) : input = _freezeObject(input),
       requiredCapabilities = Set<ModelCapability>.unmodifiable(
         requiredCapabilities,
       ),
       outputSchema = _freezeObject(outputSchema),
       tools = List<ToolDescriptor>.unmodifiable(tools),
       cancellationToken = cancellationToken ?? ModelCancellationToken() {
    _requireText(requestId, 'requestId');
    if (this.requiredCapabilities.isEmpty) {
      throw ArgumentError.value(
        requiredCapabilities,
        'requiredCapabilities',
        '不能为空',
      );
    }
    if (contextBudgetTokens <= 0) {
      throw ArgumentError.value(
        contextBudgetTokens,
        'contextBudgetTokens',
        '必须大于 0',
      );
    }
    if (estimatedQuotaUnits <= 0) {
      throw ArgumentError.value(
        estimatedQuotaUnits,
        'estimatedQuotaUnits',
        '必须大于 0',
      );
    }
    if (this.tools.isNotEmpty &&
        !this.requiredCapabilities.contains(ModelCapability.toolCalling)) {
      throw ArgumentError.value(
        requiredCapabilities,
        'requiredCapabilities',
        '声明工具时必须要求 toolCalling',
      );
    }
  }

  final String requestId;
  final ModelTaskType taskType;
  final JsonObject input;
  final Set<ModelCapability> requiredCapabilities;
  final JsonObject outputSchema;
  final List<ToolDescriptor> tools;
  final int contextBudgetTokens;
  final int estimatedQuotaUnits;
  final ModelPrivacyPolicy privacyPolicy;
  final ModelCancellationToken cancellationToken;
}

final class ModelUsage {
  ModelUsage({required this.inputTokens, required this.outputTokens}) {
    if (inputTokens < 0) {
      throw ArgumentError.value(inputTokens, 'inputTokens', '不能小于 0');
    }
    if (outputTokens < 0) {
      throw ArgumentError.value(outputTokens, 'outputTokens', '不能小于 0');
    }
  }

  final int inputTokens;
  final int outputTokens;

  int get totalTokens => inputTokens + outputTokens;
}

final class ModelResponse {
  ModelResponse({
    required this.text,
    JsonObject structuredData = const {},
    required this.usage,
    required this.finishReason,
    JsonObject providerMetadata = const {},
  }) : structuredData = _freezeObject(structuredData),
       providerMetadata = _freezeObject(providerMetadata);

  final String text;
  final JsonObject structuredData;
  final ModelUsage usage;
  final ModelFinishReason finishReason;
  final JsonObject providerMetadata;
}

final class ProviderDescriptor {
  ProviderDescriptor({
    required this.providerKey,
    required this.location,
    required Set<ModelCapability> capabilities,
  }) : capabilities = Set<ModelCapability>.unmodifiable(capabilities) {
    _requireText(providerKey, 'providerKey');
    if (this.capabilities.isEmpty) {
      throw ArgumentError.value(capabilities, 'capabilities', '不能为空');
    }
  }

  final String providerKey;
  final ProviderLocation location;
  final Set<ModelCapability> capabilities;
}

abstract interface class ModelProvider {
  ProviderDescriptor get descriptor;

  Future<ModelResponse> generate(ModelRequest request);

  Future<bool> healthCheck();
}

final class ModelProviderException implements Exception {
  const ModelProviderException({
    required this.kind,
    required this.message,
    this.retryable = false,
  });

  final ModelProviderFailureKind kind;
  final String message;
  final bool retryable;

  @override
  String toString() => 'ModelProviderException(${kind.name}): $message';
}

JsonObject _freezeObject(JsonObject value) {
  return _freezeJson(value) as JsonObject;
}

Object? _freezeJson(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is List<Object?>) {
    return List<Object?>.unmodifiable(value.map(_freezeJson));
  }
  if (value is Map<String, Object?>) {
    return UnmodifiableMapView<String, Object?>({
      for (final entry in value.entries) entry.key: _freezeJson(entry.value),
    });
  }
  throw ArgumentError.value(value, 'value', '只允许 JSON 值');
}

void _requireText(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, '不能为空');
  }
}
