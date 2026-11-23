import 'model.dart';

final class ProviderRegistration {
  ProviderRegistration({
    required this.provider,
    required this.modelId,
    this.priority = 0,
    this.enabled = true,
    this.metered = false,
  }) {
    if (modelId.trim().isEmpty) {
      throw ArgumentError.value(modelId, 'modelId', '不能为空');
    }
  }

  final ModelProvider provider;
  final String modelId;
  final int priority;
  final bool enabled;
  final bool metered;

  String get providerKey => provider.descriptor.providerKey;
}

final class ModelRegistry {
  ModelRegistry({required Iterable<ProviderRegistration> registrations}) {
    for (final registration in registrations) {
      final key = registration.providerKey;
      if (_registrations.containsKey(key)) {
        throw ArgumentError.value(key, 'registrations', 'Provider key 重复');
      }
      _registrations[key] = registration;
    }
  }

  final Map<String, ProviderRegistration> _registrations = {};

  List<ProviderRegistration> get registrations {
    final sortedRegistrations = _registrations.values.toList()
      ..sort((left, right) => left.providerKey.compareTo(right.providerKey));
    return List<ProviderRegistration>.unmodifiable(sortedRegistrations);
  }

  ProviderRegistration? find(String providerKey) {
    return _registrations[providerKey];
  }
}
