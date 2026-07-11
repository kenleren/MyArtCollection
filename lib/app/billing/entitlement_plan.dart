class EntitlementPlan {
  const EntitlementPlan({
    required this.id,
    required this.name,
    required this.priceLabel,
    required this.activeArtworkLimit,
    required this.monthlyAiCredits,
    this.playProductId,
  });

  final String id;
  final String name;
  final String priceLabel;
  final int? activeArtworkLimit;
  final int monthlyAiCredits;
  final String? playProductId;

  bool canAddActiveArtworks({
    required int currentActiveArtworkCount,
    int additionalArtworkCount = 1,
  }) {
    final limit = activeArtworkLimit;
    if (limit == null) {
      return true;
    }
    return currentActiveArtworkCount + additionalArtworkCount <= limit;
  }

  int? remainingActiveArtworkSlots(int currentActiveArtworkCount) {
    final limit = activeArtworkLimit;
    if (limit == null) {
      return null;
    }
    final remaining = limit - currentActiveArtworkCount;
    return remaining < 0 ? 0 : remaining;
  }

  String get activeArtworkLimitLabel {
    final limit = activeArtworkLimit;
    return limit == null
        ? 'Unlimited active artworks'
        : '$limit active artworks';
  }

  String get aiCreditsLabel => '$monthlyAiCredits AI credits/month';
}

class EntitlementPlans {
  const EntitlementPlans._();

  static const free = EntitlementPlan(
    id: 'free',
    name: 'Free',
    priceLabel: 'USD 0',
    activeArtworkLimit: 5,
    monthlyAiCredits: 1,
  );

  static const starter = EntitlementPlan(
    id: 'starter',
    name: 'Starter',
    priceLabel: 'USD 2.99/month',
    activeArtworkLimit: 50,
    monthlyAiCredits: 10,
    playProductId: 'archivale_starter_monthly',
  );

  static const collector = EntitlementPlan(
    id: 'collector',
    name: 'Collector',
    priceLabel: 'USD 4.99/month',
    activeArtworkLimit: 200,
    monthlyAiCredits: 50,
    playProductId: 'archivale_collector_monthly',
  );

  static const archive = EntitlementPlan(
    id: 'archive',
    name: 'Archive',
    priceLabel: 'USD 9.99/month',
    activeArtworkLimit: null,
    monthlyAiCredits: 200,
    playProductId: 'archivale_archive_monthly',
  );

  static const all = <EntitlementPlan>[free, starter, collector, archive];
}

class EntitlementState {
  const EntitlementState({
    required this.plan,
    this.billingStatus = EntitlementBillingStatus.notConfigured,
    this.lifecycle = EntitlementLifecycle.free,
  });

  final EntitlementPlan plan;
  final EntitlementBillingStatus billingStatus;
  final EntitlementLifecycle lifecycle;
}

enum EntitlementBillingStatus { notConfigured, unavailable, available }

/// Sanitized subscription state for presentation only. This never carries
/// Play, identity, verification, or expiry data.
enum EntitlementLifecycle {
  active,
  grace,
  canceledThroughExpiry,
  hold,
  paused,
  expired,
  free,
}

abstract class EntitlementService {
  Future<EntitlementState> currentState();
}

/// Deterministic entitlement fixture for tests and previews.
class StaticEntitlementService implements EntitlementService {
  const StaticEntitlementService({
    this.state = const EntitlementState(plan: EntitlementPlans.free),
  });

  final EntitlementState state;

  @override
  Future<EntitlementState> currentState() async => state;
}
