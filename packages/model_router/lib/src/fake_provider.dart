import 'model.dart';

typedef FakeModelGenerator =
    Future<ModelResponse> Function(ModelRequest request);

final class FakeModelProvider implements ModelProvider {
  FakeModelProvider({
    required this.descriptor,
    this.healthy = true,
    this.healthCheckError,
    FakeModelGenerator? generate,
  }) : _generate = generate ?? _defaultGenerate;

  @override
  final ProviderDescriptor descriptor;
  final bool healthy;
  final Object? healthCheckError;
  final FakeModelGenerator _generate;

  int healthCheckCount = 0;
  int generateCount = 0;

  @override
  Future<bool> healthCheck() async {
    healthCheckCount++;
    final error = healthCheckError;
    if (error != null) {
      throw error;
    }
    return healthy;
  }

  @override
  Future<ModelResponse> generate(ModelRequest request) async {
    generateCount++;
    if (request.cancellationToken.isCancelled) {
      throw const ModelProviderException(
        kind: ModelProviderFailureKind.cancelled,
        message: '请求已取消',
      );
    }
    return _generate(request);
  }

  static Future<ModelResponse> _defaultGenerate(ModelRequest request) async {
    return ModelResponse(
      text: 'fake:${request.requestId}',
      usage: ModelUsage(inputTokens: 0, outputTokens: 0),
      finishReason: ModelFinishReason.completed,
      providerMetadata: const {'fake': true},
    );
  }
}
