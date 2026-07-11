import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:my_art_collection/app/app.dart';
import 'package:my_art_collection/app/app_dependencies.dart';
import 'package:my_art_collection/app/app_routes.dart';
import 'package:my_art_collection/app/ai/on_device_ai_draft_service.dart';
import 'package:my_art_collection/app/billing/entitlement_plan.dart';
import 'package:my_art_collection/app/billing/play_billing_adapter.dart';
import 'package:my_art_collection/app/intake/artwork_image_picker.dart';
import 'package:my_art_collection/app/storage/local_artwork_repository.dart';
import 'package:my_art_collection/app/storage/local_attachment_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late _BillingFixture fixture;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async => fixture = await _BillingFixture.create());
  tearDown(() => fixture.dispose());

  testWidgets('shows localized Play details and verifies after disclosure', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    fixture.service.productsValue = <PlayProduct>[
      const PlayProduct(
        id: 'archivale_starter_monthly',
        title: 'Starter monthly',
        description: 'Up to 50 active artworks',
        price: 'NOK 35.00',
      ),
    ];
    await _pump(tester, fixture);

    expect(fixture.service.productReads, greaterThan(0));
    expect(find.text('Starter monthly', skipOffstage: false), findsOneWidget);
    expect(
      find.textContaining('NOK 35.00', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.text('USD 2.99/month'), findsNothing);

    final choosePlan = find.widgetWithText(FilledButton, 'Choose plan');
    await tester.tap(choosePlan);
    await tester.pumpAndSettle();
    expect(find.text('Confirm subscription verification'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();

    expect(fixture.service.disclosureCalls, 1);
    expect(fixture.service.purchases, [EntitlementPlans.starter.id]);
  });

  testWidgets('restore and lifecycle fallback states remain honest', (
    tester,
  ) async {
    for (final entry in <(EntitlementLifecycle, String)>[
      (EntitlementLifecycle.grace, 'grace period'),
      (EntitlementLifecycle.canceledThroughExpiry, 'remains available'),
      (EntitlementLifecycle.hold, 'returned to Free access'),
      (EntitlementLifecycle.paused, 'returned to Free access'),
      (EntitlementLifecycle.expired, 'has expired'),
      (EntitlementLifecycle.free, 'using Free access'),
    ]) {
      fixture.service.state = EntitlementState(
        plan:
            entry.$1 == EntitlementLifecycle.grace ||
                entry.$1 == EntitlementLifecycle.canceledThroughExpiry
            ? EntitlementPlans.starter
            : EntitlementPlans.free,
        billingStatus: EntitlementBillingStatus.available,
        lifecycle: entry.$1,
      );
      await _pump(tester, fixture);
      expect(find.textContaining(entry.$2), findsOneWidget);
    }

    await tester.tap(find.widgetWithText(OutlinedButton, 'Restore purchases'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    expect(fixture.service.restoreCalls, 1);
  });

  testWidgets('refresh and unavailable state use only Free access', (
    tester,
  ) async {
    fixture.service.state = const EntitlementState(
      plan: EntitlementPlans.free,
      billingStatus: EntitlementBillingStatus.unavailable,
    );
    await _pump(tester, fixture);
    expect(find.textContaining('Play billing is unavailable'), findsOneWidget);

    await tester.tap(
      find.widgetWithText(OutlinedButton, 'Refresh plan status'),
    );
    await tester.pumpAndSettle();
    expect(fixture.service.foregroundRefreshes, greaterThanOrEqualTo(1));
  });

  testWidgets('published fallback replaces mounted paid status', (
    tester,
  ) async {
    fixture.service.state = const EntitlementState(
      plan: EntitlementPlans.starter,
      billingStatus: EntitlementBillingStatus.available,
      lifecycle: EntitlementLifecycle.active,
    );
    await _pump(tester, fixture);
    expect(find.text('Starter plan'), findsOneWidget);

    fixture.service.publish(
      const EntitlementState(
        plan: EntitlementPlans.free,
        billingStatus: EntitlementBillingStatus.unavailable,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Free plan', skipOffstage: false), findsOneWidget);
    expect(find.textContaining('Play billing is unavailable'), findsOneWidget);

    fixture.service.publish(
      const EntitlementState(
        plan: EntitlementPlans.free,
        billingStatus: EntitlementBillingStatus.available,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Free plan', skipOffstage: false), findsOneWidget);
    expect(find.textContaining('using Free access'), findsOneWidget);
  });

  testWidgets(
    'deferred purchase verification updates the mounted screen and blocks duplicate purchases',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      fixture.service.productsValue = const <PlayProduct>[
        PlayProduct(
          id: 'archivale_starter_monthly',
          title: 'Starter monthly',
          description: 'Up to 50 active artworks',
          price: 'NOK 35.00',
        ),
      ];
      await _pump(tester, fixture);

      await tester.scrollUntilVisible(find.text('Choose plan'), 300);
      await tester.tap(find.widgetWithText(FilledButton, 'Choose plan'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
      await tester.pumpAndSettle();

      expect(find.text('Verifying subscription'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Choose plan'),
            )
            .onPressed,
        isNull,
      );

      fixture.service.publish(
        const EntitlementState(
          plan: EntitlementPlans.free,
          billingStatus: EntitlementBillingStatus.available,
          presentation: EntitlementPresentation.playPending,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Purchase pending'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Choose plan'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Restore purchases'),
            )
            .onPressed,
        isNotNull,
      );

      fixture.service.publish(
        const EntitlementState(
          plan: EntitlementPlans.starter,
          billingStatus: EntitlementBillingStatus.available,
          lifecycle: EntitlementLifecycle.active,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Starter plan', skipOffstage: false), findsOneWidget);
      expect(find.text('Verifying subscription'), findsNothing);

      fixture.service.publish(
        const EntitlementState(
          plan: EntitlementPlans.free,
          billingStatus: EntitlementBillingStatus.available,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Free plan', skipOffstage: false), findsOneWidget);
      expect(find.text('Verifying subscription'), findsNothing);
    },
  );

  testWidgets(
    'sanitized recovery reasons retain Free authority and block purchase',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      fixture.service.productsValue = const <PlayProduct>[
        PlayProduct(
          id: 'archivale_starter_monthly',
          title: 'Starter monthly',
          description: 'Up to 50 active artworks',
          price: 'NOK 35.00',
        ),
      ];
      await _pump(tester, fixture);
      await tester.scrollUntilVisible(find.text('Choose plan'), 300);

      for (final presentation in <EntitlementPresentation>[
        EntitlementPresentation.verificationPending,
        EntitlementPresentation.inFlight,
        EntitlementPresentation.delayedVerification,
        EntitlementPresentation.acknowledgementRecovery,
      ]) {
        fixture.service.publish(
          EntitlementState(
            plan: EntitlementPlans.free,
            billingStatus: EntitlementBillingStatus.available,
            presentation: presentation,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Free plan', skipOffstage: false), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Choose plan'),
              )
              .onPressed,
          isNull,
        );
      }
    },
  );
}

Future<void> _pump(WidgetTester tester, _BillingFixture fixture) async {
  await tester.pumpWidget(
    ArchivaleApp(
      initialRoute: AppRoutes.billing,
      dependencies: fixture.dependencies,
    ),
  );
  await tester.pumpAndSettle();
}

class _BillingFixture {
  _BillingFixture(this.directory, this.repository, this.attachmentStore);

  final Directory directory;
  final LocalArtworkRepository repository;
  final LocalAttachmentStore attachmentStore;
  final _FakeBillingService service = _FakeBillingService();

  AppDependencies get dependencies => AppDependencies(
    artworkRepository: repository,
    attachmentStore: attachmentStore,
    imagePicker: _NoImagePicker(),
    entitlementService: service,
    billingManagementService: service,
    onDeviceAiDraftProvider: const DisabledOnDeviceAiDraftProvider(),
  );

  static Future<_BillingFixture> create() async {
    final directory = await Directory.systemTemp.createTemp('billing_ui_test_');
    final repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(p.join(directory.path, 'records.db')),
    );
    final store = await LocalAttachmentStore.openAt(
      Directory(p.join(directory.path, 'files')),
    );
    return _BillingFixture(directory, repository, store);
  }

  Future<void> dispose() async {
    await repository.close();
    await directory.delete(recursive: true);
  }
}

class _FakeBillingService implements BillingManagementService {
  EntitlementState state = const EntitlementState(
    plan: EntitlementPlans.free,
    billingStatus: EntitlementBillingStatus.available,
  );
  List<PlayProduct> productsValue = const [];
  int disclosureCalls = 0;
  int restoreCalls = 0;
  int foregroundRefreshes = 0;
  int productReads = 0;
  final List<String> purchases = [];
  final StreamController<EntitlementState> _stateChanges =
      StreamController<EntitlementState>.broadcast();

  @override
  Stream<EntitlementState> get stateChanges => _stateChanges.stream;

  void publish(EntitlementState next) {
    state = next;
    _stateChanges.add(next);
  }

  @override
  Future<bool> acceptBillingDisclosure() async {
    disclosureCalls++;
    return true;
  }

  @override
  Future<EntitlementState> currentState() async => state;

  @override
  void handleAccountChange() {
    state = const EntitlementState(plan: EntitlementPlans.free);
  }

  @override
  Future<bool> purchase(EntitlementPlan plan) async {
    purchases.add(plan.id);
    return true;
  }

  @override
  Future<List<PlayProduct>> products() async {
    productReads++;
    return productsValue;
  }

  @override
  Future<void> refreshForForeground() async => foregroundRefreshes++;

  @override
  Future<void> restore() async => restoreCalls++;
}

class _NoImagePicker implements ArtworkImagePicker {
  @override
  Future<XFile?> pick(ArtworkImagePickMode mode) async => null;

  @override
  Future<XFile?> retrieveLostImage() async => null;
}
