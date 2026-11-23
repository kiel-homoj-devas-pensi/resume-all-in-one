import 'package:entitlements/entitlements.dart';
import 'package:test/test.dart';

void main() {
  final policy = CapabilityAccessPolicy.mvp();

  group('本地免费能力', () {
    test('离线且没有权益或余额时仍允许本地检查与建议', () {
      final offlineContext = _context(networkEnabled: false);

      final validationDecision = policy.evaluate(
        ProductCapability.localResumeValidation,
        offlineContext,
      );
      final suggestionDecision = policy.evaluate(
        ProductCapability.localResumeSuggestion,
        offlineContext,
      );

      expect(validationDecision.status, AccessDecisionStatus.allowed);
      expect(suggestionDecision.status, AccessDecisionStatus.allowed);
      expect(validationDecision.requiredQuotaUnits, 0);
      expect(validationDecision.requiredCreditUnits, 0);
    });

    test('重复评估不消费 quota 或 credits', () {
      final evaluationContext = _context(
        entitlements: [_activeEntitlement(ProductCapability.cloudAiRewrite)],
        quotaSnapshots: [
          _quota(ProductCapability.cloudAiRewrite, remainingUnits: 1),
        ],
      );

      final firstDecision = policy.evaluate(
        ProductCapability.cloudAiRewrite,
        evaluationContext,
      );
      final secondDecision = policy.evaluate(
        ProductCapability.cloudAiRewrite,
        evaluationContext,
      );

      expect(firstDecision.status, AccessDecisionStatus.allowed);
      expect(secondDecision.status, AccessDecisionStatus.allowed);
      expect(evaluationContext.quotaSnapshots.single.remainingUnits, 1);
    });
  });

  group('远程能力阻断顺序', () {
    test('联网关闭优先于 entitlement 与余额检查', () {
      final decision = policy.evaluate(
        ProductCapability.cloudAiRewrite,
        _context(networkEnabled: false),
      );

      expect(decision.status, AccessDecisionStatus.networkDisabled);
    });

    test('没有 entitlement 时拒绝且不伪装成 quota 不足', () {
      final decision = policy.evaluate(
        ProductCapability.cloudAiRewrite,
        _context(
          quotaSnapshots: [
            _quota(ProductCapability.cloudAiRewrite, remainingUnits: 10),
          ],
        ),
      );

      expect(decision.status, AccessDecisionStatus.entitlementMissing);
    });

    test('尚未生效、过期、暂停与撤销返回各自状态', () {
      final cases = <Entitlement, AccessDecisionStatus>{
        _entitlement(
          status: EntitlementStatus.active,
          validFromUtc: _now.add(const Duration(minutes: 1)),
        ): AccessDecisionStatus.entitlementNotYetValid,
        _entitlement(status: EntitlementStatus.active, validUntilUtc: _now):
            AccessDecisionStatus.entitlementExpired,
        _entitlement(status: EntitlementStatus.suspended):
            AccessDecisionStatus.entitlementInactive,
        _entitlement(status: EntitlementStatus.revoked):
            AccessDecisionStatus.entitlementInactive,
      };

      for (final entitlementCase in cases.entries) {
        final decision = policy.evaluate(
          ProductCapability.cloudAiRewrite,
          _context(entitlements: [entitlementCase.key]),
        );
        expect(decision.status, entitlementCase.value);
      }
    });

    test('多条 entitlement 中有一条有效即可继续检查 quota', () {
      final decision = policy.evaluate(
        ProductCapability.cloudAiRewrite,
        _context(
          entitlements: [
            _entitlement(status: EntitlementStatus.revoked),
            _activeEntitlement(ProductCapability.cloudAiRewrite),
          ],
          quotaSnapshots: [
            _quota(ProductCapability.cloudAiRewrite, remainingUnits: 1),
          ],
        ),
      );

      expect(decision.status, AccessDecisionStatus.allowed);
    });
  });

  group('quota 决策', () {
    test('快照缺失、窗口失效和余额不足都拒绝', () {
      final entitlement = _activeEntitlement(ProductCapability.cloudAiRewrite);
      final contexts = [
        _context(entitlements: [entitlement]),
        _context(
          entitlements: [entitlement],
          quotaSnapshots: [
            QuotaSnapshot(
              capability: ProductCapability.cloudAiRewrite,
              remainingUnits: 5,
              windowStartsAtUtc: _now.subtract(const Duration(days: 2)),
              windowEndsAtUtc: _now.subtract(const Duration(days: 1)),
            ),
          ],
        ),
        _context(
          entitlements: [entitlement],
          quotaSnapshots: [
            _quota(ProductCapability.cloudAiRewrite, remainingUnits: 0),
          ],
        ),
      ];

      for (final quotaContext in contexts) {
        final decision = policy.evaluate(
          ProductCapability.cloudAiRewrite,
          quotaContext,
        );
        expect(decision.status, AccessDecisionStatus.quotaExceeded);
      }
    });

    test('余额恰好满足时允许并报告安全单位摘要', () {
      final decision = policy.evaluate(
        ProductCapability.cloudAiRewrite,
        _context(
          entitlements: [_activeEntitlement(ProductCapability.cloudAiRewrite)],
          quotaSnapshots: [
            _quota(ProductCapability.cloudAiRewrite, remainingUnits: 1),
          ],
        ),
      );

      expect(decision.status, AccessDecisionStatus.allowed);
      expect(decision.requiredQuotaUnits, 1);
      expect(decision.availableQuotaUnits, 1);
    });
  });

  group('credits 决策', () {
    test('快照缺失、过期和余额不足都拒绝', () {
      final entitlement = _activeEntitlement(ProductCapability.jobMatching);
      final contexts = [
        _context(entitlements: [entitlement]),
        _context(
          entitlements: [entitlement],
          creditSnapshot: CreditSnapshot(
            remainingUnits: 5,
            capturedAtUtc: _now.subtract(const Duration(days: 2)),
            expiresAtUtc: _now,
          ),
        ),
        _context(
          entitlements: [entitlement],
          creditSnapshot: CreditSnapshot(
            remainingUnits: 0,
            capturedAtUtc: _now.subtract(const Duration(minutes: 1)),
          ),
        ),
      ];

      for (final creditsContext in contexts) {
        final decision = policy.evaluate(
          ProductCapability.jobMatching,
          creditsContext,
        );
        expect(decision.status, AccessDecisionStatus.creditsInsufficient);
      }
    });

    test('余额恰好满足时允许并报告安全单位摘要', () {
      final decision = policy.evaluate(
        ProductCapability.jobMatching,
        _context(
          entitlements: [_activeEntitlement(ProductCapability.jobMatching)],
          creditSnapshot: CreditSnapshot(
            remainingUnits: 1,
            capturedAtUtc: _now.subtract(const Duration(minutes: 1)),
          ),
        ),
      );

      expect(decision.status, AccessDecisionStatus.allowed);
      expect(decision.requiredCreditUnits, 1);
      expect(decision.availableCreditUnits, 1);
    });
  });

  group('契约防御', () {
    test('未注册能力、重复规则和重复快照身份被明确拒绝', () {
      final validationOnlyPolicy = CapabilityAccessPolicy(
        rules: [
          CapabilityRule(
            capability: ProductCapability.localResumeValidation,
            requiresNetwork: false,
            requiresEntitlement: false,
          ),
        ],
      );

      expect(
        validationOnlyPolicy
            .evaluate(ProductCapability.jobMatching, _context())
            .status,
        AccessDecisionStatus.capabilityUnavailable,
      );
      expect(
        () => CapabilityAccessPolicy(
          rules: [
            CapabilityRule(
              capability: ProductCapability.localResumeValidation,
              requiresNetwork: false,
              requiresEntitlement: false,
            ),
            CapabilityRule(
              capability: ProductCapability.localResumeValidation,
              requiresNetwork: false,
              requiresEntitlement: false,
            ),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => _context(
          quotaSnapshots: [
            _quota(ProductCapability.cloudAiRewrite, remainingUnits: 1),
            _quota(ProductCapability.cloudAiRewrite, remainingUnits: 2),
          ],
        ),
        throwsArgumentError,
      );
      final duplicatedEntitlement = _activeEntitlement(
        ProductCapability.cloudAiRewrite,
      );
      expect(
        () => _context(
          entitlements: [duplicatedEntitlement, duplicatedEntitlement],
        ),
        throwsArgumentError,
      );
    });

    test('输入集合被冻结且时间和数值边界不接受脏数据', () {
      final mutableEntitlements = <Entitlement>[
        _activeEntitlement(ProductCapability.cloudAiRewrite),
      ];
      final evaluationContext = _context(entitlements: mutableEntitlements);
      mutableEntitlements.clear();

      expect(evaluationContext.entitlements, hasLength(1));
      expect(
        () => evaluationContext.entitlements.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => CreditSnapshot(remainingUnits: -1, capturedAtUtc: _now),
        throwsArgumentError,
      );
      expect(
        () => AccessEvaluationContext(
          networkEnabled: true,
          evaluatedAtUtc: DateTime(2026, 10, 2),
        ),
        throwsArgumentError,
      );
      expect(
        () => QuotaSnapshot(
          capability: ProductCapability.cloudAiRewrite,
          remainingUnits: 1,
          windowStartsAtUtc: _now,
          windowEndsAtUtc: _now,
        ),
        throwsArgumentError,
      );
    });
  });
}

final _now = DateTime.utc(2026, 10, 2, 12);

AccessEvaluationContext _context({
  bool networkEnabled = true,
  List<Entitlement> entitlements = const [],
  List<QuotaSnapshot> quotaSnapshots = const [],
  CreditSnapshot? creditSnapshot,
}) {
  return AccessEvaluationContext(
    networkEnabled: networkEnabled,
    evaluatedAtUtc: _now,
    entitlements: entitlements,
    quotaSnapshots: quotaSnapshots,
    creditSnapshot: creditSnapshot,
  );
}

Entitlement _activeEntitlement(ProductCapability capability) {
  return Entitlement(
    id: 'active-${capability.name}',
    capability: capability,
    source: EntitlementSource.synchronized,
    status: EntitlementStatus.active,
  );
}

Entitlement _entitlement({
  required EntitlementStatus status,
  DateTime? validFromUtc,
  DateTime? validUntilUtc,
}) {
  return Entitlement(
    id: 'entitlement-${status.name}-${validFromUtc ?? validUntilUtc ?? 'none'}',
    capability: ProductCapability.cloudAiRewrite,
    source: EntitlementSource.promotional,
    status: status,
    validFromUtc: validFromUtc,
    validUntilUtc: validUntilUtc,
  );
}

QuotaSnapshot _quota(
  ProductCapability capability, {
  required int remainingUnits,
}) {
  return QuotaSnapshot(
    capability: capability,
    remainingUnits: remainingUnits,
    windowStartsAtUtc: _now.subtract(const Duration(days: 1)),
    windowEndsAtUtc: _now.add(const Duration(days: 1)),
  );
}
