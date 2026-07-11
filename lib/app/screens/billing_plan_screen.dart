import 'package:flutter/material.dart';

import '../app_dependencies.dart';
import '../billing/entitlement_plan.dart';
import '../billing/play_billing_adapter.dart';

/// A presentation-only surface over the fail-Free billing adapter.
class BillingPlanScreen extends StatefulWidget {
  const BillingPlanScreen({super.key});

  @override
  State<BillingPlanScreen> createState() => _BillingPlanScreenState();
}

class _BillingPlanScreenState extends State<BillingPlanScreen> {
  EntitlementState _state = const EntitlementState(plan: EntitlementPlans.free);
  List<PlayProduct> _products = const [];
  _BillingAction _action = _BillingAction.idle;

  BillingManagementService? get _service =>
      AppDependencyScope.of(context).billingManagementService;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refresh();
  }

  Future<void> _refresh() async {
    final service = _service;
    if (service == null) return;
    setState(() => _action = _BillingAction.refreshing);
    await service.refreshForForeground();
    final values = await Future.wait<Object>([
      service.currentState(),
      service.products(),
    ]);
    if (!mounted) return;
    setState(() {
      _state = values[0] as EntitlementState;
      _products = values[1] as List<PlayProduct>;
      _action = _BillingAction.idle;
    });
  }

  Future<void> _restore() async {
    final service = _service;
    if (service == null) return;
    final acceptedByUser = await _showDisclosure();
    if (!acceptedByUser) return;
    setState(() => _action = _BillingAction.restoring);
    final accepted = await service.acceptBillingDisclosure();
    if (accepted) await service.restore();
    if (!mounted) return;
    await _refresh();
  }

  Future<void> _purchase(EntitlementPlan plan) async {
    final service = _service;
    if (service == null) return;
    final accepted = await _showDisclosure();
    if (!accepted) return;
    setState(() => _action = _BillingAction.pending);
    final disclosureAccepted = await service.acceptBillingDisclosure();
    if (!disclosureAccepted) {
      if (mounted) setState(() => _action = _BillingAction.unavailable);
      return;
    }
    final started = await service.purchase(plan);
    if (!mounted) return;
    setState(
      () => _action = started
          ? _BillingAction.verifying
          : _BillingAction.unavailable,
    );
    if (started) await _refresh();
  }

  Future<bool> _showDisclosure() async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Confirm subscription verification'),
            content: const Text(
              'To verify a Play subscription, Archivale will use the purchase confirmation with its verification service. Your collection records, artwork images, and supporting documents are not needed to verify a subscription. Subscription access is confirmed only after verification succeeds.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Continue'),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    final service = _service;
    return Scaffold(
      appBar: AppBar(title: const Text('Plan and billing')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _BillingPanel(
              icon: Icons.workspace_premium_outlined,
              title: '${_state.plan.name} plan',
              body: _lifecycleCopy(_state),
            ),
            const SizedBox(height: 12),
            if (_action != _BillingAction.idle)
              _BillingPanel(
                icon: _action.icon,
                title: _action.title,
                body: _action.body,
              ),
            if (_action != _BillingAction.idle) const SizedBox(height: 12),
            if (service == null)
              const _BillingPanel(
                icon: Icons.info_outline,
                title: 'Plan changes unavailable',
                body:
                    'This app session cannot connect to Play billing. Your existing artwork records remain available.',
              )
            else ...[
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _action == _BillingAction.idle ? _restore : null,
                  icon: const Icon(Icons.restore_outlined),
                  label: const Text('Restore purchases'),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _action == _BillingAction.idle ? _refresh : null,
                  icon: const Icon(Icons.refresh_outlined),
                  label: const Text('Refresh plan status'),
                ),
              ),
              const SizedBox(height: 12),
              const _BillingPanel(
                icon: Icons.lock_outline,
                title: 'Your existing archive stays available',
                body:
                    'A canceled, expired, paused, or unavailable plan does not remove existing artwork records, edits, reports, exports, or supporting documents.',
              ),
              const SizedBox(height: 16),
              Text(
                'Available plans',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              for (final plan in EntitlementPlans.all) ...[
                _PlanOffer(
                  plan: plan,
                  product: _productFor(plan),
                  currentPlanId: _state.plan.id,
                  isBusy: _action != _BillingAction.idle,
                  onPurchase: () => _purchase(plan),
                ),
                const SizedBox(height: 12),
              ],
            ],
          ],
        ),
      ),
    );
  }

  PlayProduct? _productFor(EntitlementPlan plan) {
    final productId = plan.playProductId;
    if (productId == null) return null;
    for (final product in _products) {
      if (product.id == productId) return product;
    }
    return null;
  }
}

class _PlanOffer extends StatelessWidget {
  const _PlanOffer({
    required this.plan,
    required this.product,
    required this.currentPlanId,
    required this.isBusy,
    required this.onPurchase,
  });

  final EntitlementPlan plan;
  final PlayProduct? product;
  final String currentPlanId;
  final bool isBusy;
  final VoidCallback onPurchase;

  @override
  Widget build(BuildContext context) {
    final isFree = plan.playProductId == null;
    final isCurrent = plan.id == currentPlanId;
    final title = isFree ? plan.name : product?.title ?? plan.name;
    return _BillingPanel(
      icon: isCurrent
          ? Icons.check_circle_outline
          : Icons.workspace_premium_outlined,
      title: title,
      body: isFree
          ? '${plan.activeArtworkLimitLabel}. ${plan.aiCreditsLabel}.'
          : product == null
          ? 'This plan is not available to purchase right now.'
          : '${product!.description}\n${product!.price}',
      action: isFree || isCurrent || product == null
          ? null
          : FilledButton(
              onPressed: isBusy ? null : onPurchase,
              child: const Text('Choose plan'),
            ),
    );
  }
}

class _BillingPanel extends StatelessWidget {
  const _BillingPanel({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(body),
            if (action != null) ...[const SizedBox(height: 12), action!],
          ],
        ),
      ),
    );
  }
}

String _lifecycleCopy(EntitlementState state) => switch (state.lifecycle) {
  EntitlementLifecycle.active =>
    'Your subscription is active. Your plan includes ${state.plan.activeArtworkLimitLabel.toLowerCase()}.',
  EntitlementLifecycle.grace =>
    'Your subscription is in a grace period. Your current plan remains available while Play resolves payment.',
  EntitlementLifecycle.canceledThroughExpiry =>
    'Your subscription is canceled and remains available through its current period.',
  EntitlementLifecycle.hold =>
    'Your subscription is on hold. Archivale has returned to Free access; your existing archive stays available.',
  EntitlementLifecycle.paused =>
    'Your subscription is paused. Archivale has returned to Free access; your existing archive stays available.',
  EntitlementLifecycle.expired =>
    'Your subscription has expired. Archivale has returned to Free access; your existing archive stays available.',
  EntitlementLifecycle.free =>
    state.billingStatus == EntitlementBillingStatus.unavailable
        ? 'Play billing is unavailable right now. Archivale is using Free access and your existing archive stays available.'
        : 'You are using Free access. Your existing archive stays available.',
};

enum _BillingAction {
  idle,
  refreshing,
  restoring,
  pending,
  verifying,
  unavailable;

  IconData get icon => switch (this) {
    idle => Icons.info_outline,
    refreshing || restoring => Icons.refresh_outlined,
    pending => Icons.hourglass_top_outlined,
    verifying => Icons.verified_outlined,
    unavailable => Icons.error_outline,
  };

  String get title => switch (this) {
    idle => '',
    refreshing => 'Refreshing plan status',
    restoring => 'Restoring purchases',
    pending => 'Purchase pending',
    verifying => 'Verifying subscription',
    unavailable => 'Plan change unavailable',
  };

  String get body => switch (this) {
    idle => '',
    refreshing => 'Checking the current Play purchase state.',
    restoring => 'Looking for purchases that can be restored.',
    pending =>
      'Play is still processing this purchase. Access changes only after verification succeeds.',
    verifying =>
      'Archivale is confirming this subscription. Access changes only after verification succeeds.',
    unavailable =>
      'Play billing or subscription verification is unavailable right now. Archivale remains on Free access.',
  };
}
