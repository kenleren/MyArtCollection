import 'dart:async';
import 'package:my_art_collection/app/account/firebase_account_service.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';

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

  setUpAll(() async {
    if (const bool.fromEnvironment('CAPTURE_BILLING_VISUALS')) {
      await (FontLoader(
        'Roboto',
      )..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'))).load();
      final icons = File(
        '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      );
      if (icons.existsSync()) {
        final bytes = await icons.readAsBytes();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
    }
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async => fixture = await _BillingFixture.create());
  tearDown(() => fixture.dispose());

  testWidgets('a restored paid plan cannot start a second subscription', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    fixture.service.state = const EntitlementState(
      plan: EntitlementPlans.starter,
      billingStatus: EntitlementBillingStatus.available,
      lifecycle: EntitlementLifecycle.active,
    );
    fixture.service.productsValue = const [
      PlayProduct(
        id: 'archivale_collector_monthly',
        title: 'Collector',
        description: 'Up to 200 active artworks',
        price: 'NOK 59.00',
      ),
    ];
    await _pump(tester, fixture);
    expect(
      find.text('Manage your existing subscription', skipOffstage: false),
      findsOneWidget,
    );
    await _capture(tester, fixture, 'account-restored-plan-360.png');
    final choose = find.widgetWithText(
      FilledButton,
      'Choose plan',
      skipOffstage: false,
    );
    await tester.scrollUntilVisible(
      choose,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.widget<FilledButton>(choose).onPressed, isNull);
    expect(fixture.service.purchases, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'temporary verification failure keeps Restore available and purchase blocked',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      fixture.service.state = const EntitlementState(
        plan: EntitlementPlans.free,
        billingStatus: EntitlementBillingStatus.unavailable,
        presentation: EntitlementPresentation.unavailable,
      );
      fixture.service.productsValue = const [
        PlayProduct(
          id: 'archivale_starter_monthly',
          title: 'Starter',
          description: 'Up to 50 active artworks',
          price: 'NOK 35.00',
        ),
      ];
      await _pump(tester, fixture);
      expect(find.text('Subscription check unavailable'), findsOneWidget);
      final restore = find.widgetWithText(OutlinedButton, 'Restore purchases');
      expect(tester.widget<OutlinedButton>(restore).onPressed, isNotNull);
      await _capture(tester, fixture, 'account-restore-unavailable-360.png');
      final choose = find.widgetWithText(
        FilledButton,
        'Choose plan',
        skipOffstage: false,
      );
      await tester.scrollUntilVisible(
        choose,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.widget<FilledButton>(choose).onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );

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

  testWidgets('mobile sign-in cancellation starts no purchase or restore', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    fixture.service.disclosureResult = false;
    fixture.service.accountStatus = PaidAccountStatus.canceled;
    await _pump(tester, fixture);
    await tester.ensureVisible(
      find.widgetWithText(OutlinedButton, 'Restore purchases'),
    );
    await tester.tap(find.widgetWithText(OutlinedButton, 'Restore purchases'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Sign in with Google to purchase or restore'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'stores an account reference and sends it to Google Play',
      ),
      findsOneWidget,
    );
    await _capture(tester, fixture, 'google-routing-disclosure-360.png');
    await tester.drag(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(SingleChildScrollView),
      ),
      const Offset(0, -420),
    );
    await tester.pumpAndSettle();
    await _capture(tester, fixture, 'google-routing-disclosure-bottom-360.png');
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    expect(fixture.service.restoreCalls, 0);
    expect(fixture.service.purchases, isEmpty);
    await tester.drag(
      find.byKey(const ValueKey('billing-plan-scrollable')),
      const Offset(0, 600),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sign-in canceled'), findsOneWidget);
    await _capture(tester, fixture, 'google-routing-canceled-360.png');
    expect(tester.takeException(), isNull);
  });

  testWidgets('collision requires explicit sign-in to existing account', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    fixture.service.accountStatus = PaidAccountStatus.existingAccount;
    await _pump(tester, fixture);
    await _capture(tester, fixture, 'google-collision-360.png');
    final recover = find.widgetWithText(
      OutlinedButton,
      'Sign in to existing account',
    );
    await tester.ensureVisible(recover);
    await tester.tap(recover);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    expect(fixture.service.existingAccountRequested, isTrue);
    expect(fixture.service.restoreCalls, 1);
    expect(fixture.service.purchases, isEmpty);
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
        EntitlementPresentation.recoveryExhausted,
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

      fixture.service.publish(
        const EntitlementState(
          plan: EntitlementPlans.free,
          billingStatus: EntitlementBillingStatus.available,
          presentation: EntitlementPresentation.recoveryExhausted,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Restore purchases'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Refresh plan status'),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('no-result recovery keeps unresolved purchase choices disabled', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    fixture.service.state = const EntitlementState(
      plan: EntitlementPlans.free,
      billingStatus: EntitlementBillingStatus.available,
      presentation: EntitlementPresentation.playPending,
    );
    fixture.service.productsValue = const <PlayProduct>[
      PlayProduct(
        id: 'archivale_starter_monthly',
        title: 'Starter monthly',
        description: 'Up to 50 active artworks',
        price: 'NOK 35.00',
      ),
    ];
    await _pump(tester, fixture);
    await tester.scrollUntilVisible(find.text('Restore purchases'), 300);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Restore purchases'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(OutlinedButton, 'Refresh plan status'),
    );
    await tester.pumpAndSettle();

    expect(fixture.service.restoreCalls, 1);
    expect(fixture.service.foregroundRefreshes, greaterThanOrEqualTo(2));
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Choose plan'),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('recovery exhaustion checks before showing disclosure', (
    tester,
  ) async {
    fixture.service.state = const EntitlementState(
      plan: EntitlementPlans.free,
      billingStatus: EntitlementBillingStatus.available,
      presentation: EntitlementPresentation.playPending,
    );
    fixture.service.canRecoverValue = false;
    await _pump(tester, fixture);
    await tester.scrollUntilVisible(find.text('Restore purchases'), 300);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Restore purchases'));
    await tester.pumpAndSettle();

    expect(fixture.service.recoveryChecks, 1);
    expect(fixture.service.disclosureCalls, 0);
    expect(fixture.service.restoreCalls, 0);
    expect(find.text('Confirm subscription verification'), findsNothing);
  });

  testWidgets('stale async billing load cannot overwrite a Free fallback', (
    tester,
  ) async {
    fixture.service.state = const EntitlementState(
      plan: EntitlementPlans.starter,
      billingStatus: EntitlementBillingStatus.available,
      lifecycle: EntitlementLifecycle.active,
    );
    final products = Completer<List<PlayProduct>>();
    fixture.service.productsNext = () => products.future;
    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.billing,
        dependencies: fixture.dependencies,
      ),
    );
    await tester.pump();

    fixture.service.publish(
      const EntitlementState(
        plan: EntitlementPlans.free,
        billingStatus: EntitlementBillingStatus.unavailable,
      ),
    );
    await tester.pump();
    products.complete(const <PlayProduct>[]);
    await tester.pumpAndSettle();

    expect(find.text('Free plan', skipOffstage: false), findsOneWidget);
    expect(find.textContaining('Play billing is unavailable'), findsOneWidget);
  });
}

Future<void> _pump(WidgetTester tester, _BillingFixture fixture) async {
  await tester.pumpWidget(
    RepaintBoundary(
      key: fixture.captureKey,
      child: ArchivaleApp(
        initialRoute: AppRoutes.billing,
        dependencies: fixture.dependencies,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _capture(
  WidgetTester tester,
  _BillingFixture fixture,
  String name,
) async {
  if (!const bool.fromEnvironment('CAPTURE_BILLING_VISUALS')) return;
  final boundary =
      fixture.captureKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
  boundary.markNeedsPaint();
  await tester.pump();
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final output = File('build/billing-identity-visuals/$name');
    await output.parent.create(recursive: true);
    await output.writeAsBytes(bytes!.buffer.asUint8List());
  });
}

class _BillingFixture {
  _BillingFixture(this.directory, this.repository, this.attachmentStore);

  final GlobalKey captureKey = GlobalKey();
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
  int recoveryChecks = 0;
  bool canRecoverValue = true;
  bool disclosureResult = true;
  bool existingAccountRequested = false;
  FutureOr<List<PlayProduct>> Function()? productsNext;
  final List<String> purchases = [];
  final StreamController<EntitlementState> _stateChanges =
      StreamController<EntitlementState>.broadcast();

  @override
  Stream<EntitlementState> get stateChanges => _stateChanges.stream;

  @override
  Future<bool> canRecover() async {
    recoveryChecks++;
    return canRecoverValue;
  }

  void publish(EntitlementState next) {
    state = next;
    _stateChanges.add(next);
  }

  @override
  PaidAccountStatus accountStatus = PaidAccountStatus.idle;

  @override
  Future<bool> acceptBillingDisclosure({
    bool useExistingAccount = false,
  }) async {
    disclosureCalls++;
    existingAccountRequested = useExistingAccount;
    return disclosureResult;
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
    return await (productsNext?.call() ?? productsValue);
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
