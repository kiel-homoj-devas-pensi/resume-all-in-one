import 'dart:collection';

import 'model.dart';

final class CapabilityAccessPolicy {
  CapabilityAccessPolicy({required Iterable<CapabilityRule> rules})
    : _rulesByCapability = _freezeCapabilityRules(rules);

  factory CapabilityAccessPolicy.mvp() {
    return CapabilityAccessPolicy(
      rules: [
        CapabilityRule(
          capability: ProductCapability.localResumeValidation,
          requiresNetwork: false,
          requiresEntitlement: false,
        ),
        CapabilityRule(
          capability: ProductCapability.localResumeSuggestion,
          requiresNetwork: false,
          requiresEntitlement: false,
        ),
        CapabilityRule(
          capability: ProductCapability.cloudAiRewrite,
          requiresNetwork: true,
          requiresEntitlement: true,
          requiredQuotaUnits: 1,
        ),
        CapabilityRule(
          capability: ProductCapability.jobMatching,
          requiresNetwork: true,
          requiresEntitlement: true,
          requiredCreditUnits: 1,
        ),
      ],
    );
  }

  final Map<ProductCapability, CapabilityRule> _rulesByCapability;

  List<CapabilityRule> get rules =>
      List.unmodifiable(_rulesByCapability.values);

  AccessDecision evaluate(
    ProductCapability capability,
    AccessEvaluationContext context,
  ) {
    // 阻断顺序属于用户可见契约：先说明“功能不存在/需要联网”，再检查授权与资源，
    // 避免同一份快照因为实现细节变化而向用户显示不同的处理建议。
    final capabilityRule = _rulesByCapability[capability];
    if (capabilityRule == null) {
      return _decision(
        capability,
        AccessDecisionStatus.capabilityUnavailable,
        '当前策略未提供这项能力',
      );
    }
    if (capabilityRule.requiresNetwork && !context.networkEnabled) {
      return _decision(
        capability,
        AccessDecisionStatus.networkDisabled,
        '这项能力需要联网，但联网当前已关闭',
        rule: capabilityRule,
      );
    }

    if (capabilityRule.requiresEntitlement) {
      final entitlementDecision = _evaluateEntitlement(capabilityRule, context);
      if (entitlementDecision != null) {
        return entitlementDecision;
      }
    }

    final quotaDecision = _evaluateQuota(capabilityRule, context);
    if (quotaDecision != null) {
      return quotaDecision;
    }

    final creditsDecision = _evaluateCredits(capabilityRule, context);
    if (creditsDecision != null) {
      return creditsDecision;
    }

    final availableQuotaUnits = _currentQuotaSnapshot(
      capability,
      context,
    )?.remainingUnits;
    final availableCreditUnits = _currentCreditSnapshot(
      context,
    )?.remainingUnits;
    return _decision(
      capability,
      AccessDecisionStatus.allowed,
      '当前条件允许使用这项能力',
      rule: capabilityRule,
      availableQuotaUnits: availableQuotaUnits,
      availableCreditUnits: availableCreditUnits,
    );
  }

  AccessDecision? _evaluateEntitlement(
    CapabilityRule capabilityRule,
    AccessEvaluationContext context,
  ) {
    final capabilityEntitlements = context.entitlements
        .where(
          (entitlement) => entitlement.capability == capabilityRule.capability,
        )
        .toList(growable: false);
    if (capabilityEntitlements.isEmpty) {
      return _decision(
        capabilityRule.capability,
        AccessDecisionStatus.entitlementMissing,
        '当前没有这项能力的 entitlement',
        rule: capabilityRule,
      );
    }

    final activeEntitlements = capabilityEntitlements
        .where((entitlement) => entitlement.status == EntitlementStatus.active)
        .toList(growable: false);
    // 不同来源的授权可以并存；任意一条有效即可，旧的撤销记录不能覆盖新授权。
    if (activeEntitlements.any(
      (entitlement) => _isEntitlementValid(entitlement, context.evaluatedAtUtc),
    )) {
      return null;
    }
    if (activeEntitlements.any(
      (entitlement) =>
          entitlement.validFromUtc?.isAfter(context.evaluatedAtUtc) ?? false,
    )) {
      return _decision(
        capabilityRule.capability,
        AccessDecisionStatus.entitlementNotYetValid,
        '这项能力的 entitlement 尚未生效',
        rule: capabilityRule,
      );
    }
    if (activeEntitlements.any(
      (entitlement) =>
          entitlement.validUntilUtc != null &&
          !context.evaluatedAtUtc.isBefore(entitlement.validUntilUtc!),
    )) {
      return _decision(
        capabilityRule.capability,
        AccessDecisionStatus.entitlementExpired,
        '这项能力的 entitlement 已过期',
        rule: capabilityRule,
      );
    }
    return _decision(
      capabilityRule.capability,
      AccessDecisionStatus.entitlementInactive,
      '这项能力的 entitlement 已暂停或撤销',
      rule: capabilityRule,
    );
  }

  AccessDecision? _evaluateQuota(
    CapabilityRule capabilityRule,
    AccessEvaluationContext context,
  ) {
    if (capabilityRule.requiredQuotaUnits == 0) {
      return null;
    }
    final quotaSnapshot = _currentQuotaSnapshot(
      capabilityRule.capability,
      context,
    );
    if (quotaSnapshot == null ||
        quotaSnapshot.remainingUnits < capabilityRule.requiredQuotaUnits) {
      return _decision(
        capabilityRule.capability,
        AccessDecisionStatus.quotaExceeded,
        quotaSnapshot == null ? '当前没有有效的 quota 快照' : '可用 quota 不足',
        rule: capabilityRule,
        availableQuotaUnits: quotaSnapshot?.remainingUnits,
      );
    }
    return null;
  }

  AccessDecision? _evaluateCredits(
    CapabilityRule capabilityRule,
    AccessEvaluationContext context,
  ) {
    if (capabilityRule.requiredCreditUnits == 0) {
      return null;
    }
    final creditSnapshot = _currentCreditSnapshot(context);
    if (creditSnapshot == null ||
        creditSnapshot.remainingUnits < capabilityRule.requiredCreditUnits) {
      return _decision(
        capabilityRule.capability,
        AccessDecisionStatus.creditsInsufficient,
        creditSnapshot == null ? '当前没有有效的 credits 快照' : '可用 credits 不足',
        rule: capabilityRule,
        availableCreditUnits: creditSnapshot?.remainingUnits,
      );
    }
    return null;
  }

  QuotaSnapshot? _currentQuotaSnapshot(
    ProductCapability capability,
    AccessEvaluationContext context,
  ) {
    for (final quotaSnapshot in context.quotaSnapshots) {
      if (quotaSnapshot.capability == capability &&
          !context.evaluatedAtUtc.isBefore(quotaSnapshot.windowStartsAtUtc) &&
          context.evaluatedAtUtc.isBefore(quotaSnapshot.windowEndsAtUtc)) {
        return quotaSnapshot;
      }
    }
    return null;
  }

  CreditSnapshot? _currentCreditSnapshot(AccessEvaluationContext context) {
    final creditSnapshot = context.creditSnapshot;
    if (creditSnapshot == null ||
        context.evaluatedAtUtc.isBefore(creditSnapshot.capturedAtUtc) ||
        (creditSnapshot.expiresAtUtc != null &&
            !context.evaluatedAtUtc.isBefore(creditSnapshot.expiresAtUtc!))) {
      return null;
    }
    return creditSnapshot;
  }

  bool _isEntitlementValid(Entitlement entitlement, DateTime evaluatedAtUtc) {
    final hasStarted =
        entitlement.validFromUtc == null ||
        !evaluatedAtUtc.isBefore(entitlement.validFromUtc!);
    final hasNotExpired =
        entitlement.validUntilUtc == null ||
        evaluatedAtUtc.isBefore(entitlement.validUntilUtc!);
    return hasStarted && hasNotExpired;
  }

  AccessDecision _decision(
    ProductCapability capability,
    AccessDecisionStatus status,
    String reason, {
    CapabilityRule? rule,
    int? availableQuotaUnits,
    int? availableCreditUnits,
  }) {
    return AccessDecision(
      capability: capability,
      status: status,
      reason: reason,
      requiredQuotaUnits: rule?.requiredQuotaUnits ?? 0,
      requiredCreditUnits: rule?.requiredCreditUnits ?? 0,
      availableQuotaUnits: availableQuotaUnits,
      availableCreditUnits: availableCreditUnits,
    );
  }
}

Map<ProductCapability, CapabilityRule> _freezeCapabilityRules(
  Iterable<CapabilityRule> rules,
) {
  final rulesByCapability = <ProductCapability, CapabilityRule>{};
  for (final rule in rules) {
    if (rulesByCapability.containsKey(rule.capability)) {
      throw ArgumentError.value(rules, 'rules', '同一能力不能有重复规则');
    }
    rulesByCapability[rule.capability] = rule;
  }
  return UnmodifiableMapView(rulesByCapability);
}
