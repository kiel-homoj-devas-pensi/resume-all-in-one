import 'model.dart';
import 'registry.dart';

enum ModelRouteStatus {
  selected,
  cancelled,
  capabilityUnavailable,
  privacyRestricted,
  networkDisabled,
  quotaExceeded,
  providerUnavailable,
}

enum ModelCandidateStatus {
  selected,
  disabled,
  capabilityMismatch,
  privacyBlocked,
  networkBlocked,
  quotaBlocked,
  unhealthy,
}

final class ModelRoutingContext {
  ModelRoutingContext({
    required this.networkEnabled,
    required this.availableQuotaUnits,
  }) {
    if (availableQuotaUnits < 0) {
      throw ArgumentError.value(
        availableQuotaUnits,
        'availableQuotaUnits',
        '不能小于 0',
      );
    }
  }

  final bool networkEnabled;
  final int availableQuotaUnits;
}

final class ModelRouteAttempt {
  const ModelRouteAttempt({
    required this.providerKey,
    required this.status,
    required this.reason,
  });

  final String providerKey;
  final ModelCandidateStatus status;
  final String reason;
}

final class ModelRouteDecision {
  ModelRouteDecision({
    required this.status,
    required this.reason,
    this.selected,
    List<ModelRouteAttempt> attempts = const [],
  }) : attempts = List<ModelRouteAttempt>.unmodifiable(attempts) {
    if ((status == ModelRouteStatus.selected) != (selected != null)) {
      throw ArgumentError('selected 与路由状态不一致');
    }
  }

  final ModelRouteStatus status;
  final String reason;
  final ProviderRegistration? selected;
  final List<ModelRouteAttempt> attempts;

  bool get isSelected => status == ModelRouteStatus.selected;
}

final class ModelRouter {
  const ModelRouter(this._registry);

  final ModelRegistry _registry;

  Future<ModelRouteDecision> route(
    ModelRequest request,
    ModelRoutingContext context,
  ) async {
    if (request.cancellationToken.isCancelled) {
      return ModelRouteDecision(
        status: ModelRouteStatus.cancelled,
        reason: '请求已取消',
      );
    }

    final candidateAttempts = <ModelRouteAttempt>[];
    // 本地优先，其次按业务优先级；providerKey 只负责让同优先级结果稳定可复现。
    final orderedCandidates = _registry.registrations.toList()
      ..sort(_compareCandidates);
    var hasEnabledCandidate = false;
    var hasCapableCandidate = false;
    var hasPrivacyEligibleCandidate = false;
    var hasNetworkEligibleCandidate = false;
    var hasQuotaEligibleCandidate = false;

    for (final registration in orderedCandidates) {
      final descriptor = registration.provider.descriptor;
      if (!registration.enabled) {
        candidateAttempts.add(
          ModelRouteAttempt(
            providerKey: registration.providerKey,
            status: ModelCandidateStatus.disabled,
            reason: 'Provider 已禁用',
          ),
        );
        continue;
      }
      hasEnabledCandidate = true;

      if (!descriptor.capabilities.containsAll(request.requiredCapabilities)) {
        candidateAttempts.add(
          ModelRouteAttempt(
            providerKey: registration.providerKey,
            status: ModelCandidateStatus.capabilityMismatch,
            reason: 'Provider 能力不足',
          ),
        );
        continue;
      }
      hasCapableCandidate = true;

      final isRemote = descriptor.location == ProviderLocation.remote;
      if (isRemote && request.privacyPolicy == ModelPrivacyPolicy.localOnly) {
        candidateAttempts.add(
          ModelRouteAttempt(
            providerKey: registration.providerKey,
            status: ModelCandidateStatus.privacyBlocked,
            reason: '隐私策略只允许本地处理',
          ),
        );
        continue;
      }
      hasPrivacyEligibleCandidate = true;

      if (isRemote && !context.networkEnabled) {
        candidateAttempts.add(
          ModelRouteAttempt(
            providerKey: registration.providerKey,
            status: ModelCandidateStatus.networkBlocked,
            reason: '联网已关闭',
          ),
        );
        continue;
      }
      hasNetworkEligibleCandidate = true;

      if (registration.metered &&
          context.availableQuotaUnits < request.estimatedQuotaUnits) {
        candidateAttempts.add(
          ModelRouteAttempt(
            providerKey: registration.providerKey,
            status: ModelCandidateStatus.quotaBlocked,
            reason: '可用额度不足',
          ),
        );
        continue;
      }
      hasQuotaEligibleCandidate = true;

      if (request.cancellationToken.isCancelled) {
        return ModelRouteDecision(
          status: ModelRouteStatus.cancelled,
          reason: '请求已取消',
          attempts: candidateAttempts,
        );
      }

      var providerIsHealthy = false;
      try {
        providerIsHealthy = await registration.provider.healthCheck();
      } on Object {
        // Provider 的原始异常不进入路由结果，避免泄露 SDK 或连接细节。
        providerIsHealthy = false;
      }
      if (request.cancellationToken.isCancelled) {
        return ModelRouteDecision(
          status: ModelRouteStatus.cancelled,
          reason: '请求已取消',
          attempts: candidateAttempts,
        );
      }
      if (!providerIsHealthy) {
        candidateAttempts.add(
          ModelRouteAttempt(
            providerKey: registration.providerKey,
            status: ModelCandidateStatus.unhealthy,
            reason: 'Provider 当前不可用',
          ),
        );
        continue;
      }

      candidateAttempts.add(
        ModelRouteAttempt(
          providerKey: registration.providerKey,
          status: ModelCandidateStatus.selected,
          reason: '满足全部路由约束',
        ),
      );
      return ModelRouteDecision(
        status: ModelRouteStatus.selected,
        reason: descriptor.location == ProviderLocation.local
            ? '已选择本地 Provider'
            : '已选择远程 Provider',
        selected: registration,
        attempts: candidateAttempts,
      );
    }

    if (!hasEnabledCandidate) {
      return _failureDecision(
        ModelRouteStatus.providerUnavailable,
        '没有已启用的 Provider',
        candidateAttempts,
      );
    }
    if (!hasCapableCandidate) {
      return _failureDecision(
        ModelRouteStatus.capabilityUnavailable,
        '没有 Provider 覆盖请求所需能力',
        candidateAttempts,
      );
    }
    if (!hasPrivacyEligibleCandidate) {
      return _failureDecision(
        ModelRouteStatus.privacyRestricted,
        '隐私策略阻止使用远程 Provider',
        candidateAttempts,
      );
    }
    if (!hasNetworkEligibleCandidate) {
      return _failureDecision(
        ModelRouteStatus.networkDisabled,
        '联网关闭且没有可用的本地 Provider',
        candidateAttempts,
      );
    }
    if (!hasQuotaEligibleCandidate) {
      return _failureDecision(
        ModelRouteStatus.quotaExceeded,
        '可用额度不足',
        candidateAttempts,
      );
    }
    return _failureDecision(
      ModelRouteStatus.providerUnavailable,
      '所有合规 Provider 当前均不可用',
      candidateAttempts,
    );
  }

  static int _compareCandidates(
    ProviderRegistration left,
    ProviderRegistration right,
  ) {
    final locationOrder = left.provider.descriptor.location.index.compareTo(
      right.provider.descriptor.location.index,
    );
    if (locationOrder != 0) {
      return locationOrder;
    }
    final priorityOrder = right.priority.compareTo(left.priority);
    if (priorityOrder != 0) {
      return priorityOrder;
    }
    return left.providerKey.compareTo(right.providerKey);
  }

  ModelRouteDecision _failureDecision(
    ModelRouteStatus status,
    String reason,
    List<ModelRouteAttempt> attempts,
  ) {
    return ModelRouteDecision(
      status: status,
      reason: reason,
      attempts: attempts,
    );
  }
}
