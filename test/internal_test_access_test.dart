import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/billing/entitlement_plan.dart';

void main() {
  test('internal access admits large imports without a purchasable plan', () {
    const plan = EntitlementPlans.internalTest;
    expect(
      plan.canAddActiveArtworks(
        currentActiveArtworkCount: 500,
        additionalArtworkCount: 200,
      ),
      isTrue,
    );
    expect(plan.remainingActiveArtworkSlots(500), isNull);
    expect(plan.playProductId, isNull);
    expect(plan.monthlyAiCredits, 0);
    expect(EntitlementPlans.all, isNot(contains(plan)));
    expect(
      EntitlementPlans.free.canAddActiveArtworks(currentActiveArtworkCount: 5),
      isFalse,
    );
  });
}
