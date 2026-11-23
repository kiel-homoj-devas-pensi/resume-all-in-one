const currentAccessPolicyVersion = '0.1.0';

enum ProductCapability {
  localResumeValidation,
  localResumeSuggestion,
  cloudAiRewrite,
  jobMatching,
}

enum EntitlementSource { localGrant, promotional, synchronized }

enum EntitlementStatus { active, suspended, revoked }

enum AccessDecisionStatus {
  allowed,
  capabilityUnavailable,
  networkDisabled,
  entitlementMissing,
  entitlementNotYetValid,
  entitlementExpired,
  entitlementInactive,
  quotaExceeded,
  creditsInsufficient,
}

final class CapabilityRule {
  CapabilityRule({
    required this.capability,
    required this.requiresNetwork,
    required this.requiresEntitlement,
    this.requiredQuotaUnits = 0,
    this.requiredCreditUnits = 0,
  }) {
    if (requiredQuotaUnits < 0) {
      throw ArgumentError.value(
        requiredQuotaUnits,
        'requiredQuotaUnits',
        '不能小于 0',
      );
    }
    if (requiredCreditUnits < 0) {
      throw ArgumentError.value(
        requiredCreditUnits,
        'requiredCreditUnits',
        '不能小于 0',
      );
    }
  }

  final ProductCapability capability;
  final bool requiresNetwork;
  final bool requiresEntitlement;
  final int requiredQuotaUnits;
  final int requiredCreditUnits;
}

final class Entitlement {
  Entitlement({
    required this.id,
    required this.capability,
    required this.source,
    required this.status,
    this.validFromUtc,
    this.validUntilUtc,
  }) {
    _requireText(id, 'id');
    _requireUtc(validFromUtc, 'validFromUtc');
    _requireUtc(validUntilUtc, 'validUntilUtc');
    if (validFromUtc != null &&
        validUntilUtc != null &&
        !validUntilUtc!.isAfter(validFromUtc!)) {
      throw ArgumentError('validUntilUtc 必须晚于 validFromUtc');
    }
  }

  final String id;
  final ProductCapability capability;
  final EntitlementSource source;
  final EntitlementStatus status;
  final DateTime? validFromUtc;
  final DateTime? validUntilUtc;
}

final class QuotaSnapshot {
  QuotaSnapshot({
    required this.capability,
    required this.remainingUnits,
    required this.windowStartsAtUtc,
    required this.windowEndsAtUtc,
  }) {
    if (remainingUnits < 0) {
      throw ArgumentError.value(remainingUnits, 'remainingUnits', '不能小于 0');
    }
    _requireUtc(windowStartsAtUtc, 'windowStartsAtUtc');
    _requireUtc(windowEndsAtUtc, 'windowEndsAtUtc');
    if (!windowEndsAtUtc.isAfter(windowStartsAtUtc)) {
      throw ArgumentError('windowEndsAtUtc 必须晚于 windowStartsAtUtc');
    }
  }

  final ProductCapability capability;
  final int remainingUnits;
  final DateTime windowStartsAtUtc;
  final DateTime windowEndsAtUtc;
}

final class CreditSnapshot {
  CreditSnapshot({
    required this.remainingUnits,
    required this.capturedAtUtc,
    this.expiresAtUtc,
  }) {
    if (remainingUnits < 0) {
      throw ArgumentError.value(remainingUnits, 'remainingUnits', '不能小于 0');
    }
    _requireUtc(capturedAtUtc, 'capturedAtUtc');
    _requireUtc(expiresAtUtc, 'expiresAtUtc');
    if (expiresAtUtc != null && !expiresAtUtc!.isAfter(capturedAtUtc)) {
      throw ArgumentError('expiresAtUtc 必须晚于 capturedAtUtc');
    }
  }

  final int remainingUnits;
  final DateTime capturedAtUtc;
  final DateTime? expiresAtUtc;
}

final class AccessEvaluationContext {
  AccessEvaluationContext({
    required this.networkEnabled,
    required this.evaluatedAtUtc,
    List<Entitlement> entitlements = const [],
    List<QuotaSnapshot> quotaSnapshots = const [],
    this.creditSnapshot,
  }) : entitlements = List<Entitlement>.unmodifiable(entitlements),
       quotaSnapshots = List<QuotaSnapshot>.unmodifiable(quotaSnapshots) {
    _requireUtc(evaluatedAtUtc, 'evaluatedAtUtc');
    final entitlementIds = <String>{};
    for (final entitlement in this.entitlements) {
      if (!entitlementIds.add(entitlement.id)) {
        throw ArgumentError.value(
          entitlements,
          'entitlements',
          'entitlement ID 不能重复',
        );
      }
    }
    final quotaCapabilities = <ProductCapability>{};
    for (final quotaSnapshot in this.quotaSnapshots) {
      if (!quotaCapabilities.add(quotaSnapshot.capability)) {
        throw ArgumentError.value(
          quotaSnapshots,
          'quotaSnapshots',
          '同一能力不能有重复 quota 快照',
        );
      }
    }
  }

  final bool networkEnabled;
  final DateTime evaluatedAtUtc;
  final List<Entitlement> entitlements;
  final List<QuotaSnapshot> quotaSnapshots;
  final CreditSnapshot? creditSnapshot;
}

final class AccessDecision {
  const AccessDecision({
    required this.capability,
    required this.status,
    required this.reason,
    required this.requiredQuotaUnits,
    required this.requiredCreditUnits,
    this.availableQuotaUnits,
    this.availableCreditUnits,
  });

  final ProductCapability capability;
  final AccessDecisionStatus status;
  final String reason;
  final int requiredQuotaUnits;
  final int requiredCreditUnits;
  final int? availableQuotaUnits;
  final int? availableCreditUnits;

  bool get isAllowed => status == AccessDecisionStatus.allowed;
}

void _requireText(String text, String name) {
  if (text.trim().isEmpty) {
    throw ArgumentError.value(text, name, '不能为空');
  }
}

void _requireUtc(DateTime? time, String name) {
  if (time != null && !time.isUtc) {
    throw ArgumentError.value(time, name, '必须是 UTC 时间');
  }
}
