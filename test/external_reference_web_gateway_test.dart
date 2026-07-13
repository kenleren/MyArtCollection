@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/external_references/external_reference_launch_gateway.dart';
import 'package:my_art_collection/app/external_references/external_reference_launch_gateway_web.dart';
import 'package:my_art_collection/app/external_references/external_reference_launch_gateway_web_policy.dart';
import 'package:my_art_collection/app/external_references/external_reference_launch_service.dart';
import 'package:my_art_collection/app/storage/external_reference.dart';
import 'package:web/web.dart' as web;

const _canonicalUrl = 'https://example.com/object';

void main() {
  test('conditional gateway selects the synchronous web implementation', () {
    final gateway = createSystemExternalReferenceLaunchGateway();
    expect(gateway.target, ExternalReferenceLaunchTarget.web);
    expect(gateway.requiresSynchronousReservation, isTrue);
  });

  test(
    'production reservation rejects a closed tab before link launch',
    () async {
      WebExternalReferenceLaunchReservation? reservation;
      var navigationAttempts = 0;
      _clickDomButton(() {
        reservation = reserveIsolatedBlankTab(
          navigator: (reserved, uri) {
            navigationAttempts++;
            return true;
          },
        );
      });

      expect(reservation, isNotNull);
      reservation!.close();
      expect(reservation!.isClosed, isTrue);
      expect(await reservation!.launch(Uri.parse(_canonicalUrl)), isFalse);
      expect(navigationAttempts, 0);
    },
  );

  test(
    'service reserves synchronously then navigates without opener or referrer',
    () async {
      final destination = Uri.parse(
        web.window.location.href,
      ).resolve('/favicon.ico?external-reference-harness=1');
      final reload = Completer<ExternalReferenceRecord?>();
      final harness = _BrowserLaunchHarness(
        destination: destination,
        useFrame: true,
      );
      addTearDown(harness.dispose);
      final service = ExternalReferenceLaunchService(
        referenceLoader: (_) => reload.future,
        gateway: harness.gateway,
      );
      Future<void>? launchResult;
      _clickDomButton(() {
        launchResult = expectLater(
          service.open(referenceId: 'reference-1', expectedUrl: _canonicalUrl),
          completes,
        );
      });

      expect(harness.reservationCalls, 1);
      expect(harness.navigationAttempts, 0);
      expect(harness.fallbackCalls, 0);
      expect(harness.reservation!.delegate.hasNoOpener, isTrue);

      reload.complete(_reference(_canonicalUrl));
      await launchResult;
      await _waitForLocation(
        harness.reservation!.delegate,
        destination.toString(),
      );
      expect(harness.navigationAttempts, 1);
      expect(harness.reservation!.launchCalls, 1);
      expect(harness.fallbackCalls, 0);
      expect(harness.reservation!.delegate.hasNoOpener, isTrue);
      expect(harness.reservation!.delegate.documentReferrer, isEmpty);
    },
  );

  test(
    'closed reserved tab fails before anchor click or replacement attempt',
    () async {
      final reload = Completer<ExternalReferenceRecord?>();
      final harness = _BrowserLaunchHarness();
      final service = ExternalReferenceLaunchService(
        referenceLoader: (_) => reload.future,
        gateway: harness.gateway,
      );
      Future<void>? launchResult;
      _clickDomButton(() {
        launchResult = expectLater(
          service.open(referenceId: 'reference-1', expectedUrl: _canonicalUrl),
          throwsA(
            isA<ExternalReferenceLaunchException>().having(
              (error) => error.failure,
              'failure',
              ExternalReferenceLaunchFailure.openFailed,
            ),
          ),
        );
      });

      expect(harness.reservationCalls, 1);
      harness.reservation!.delegate.close();
      expect(harness.reservation!.delegate.isClosed, isTrue);
      reload.complete(_reference(_canonicalUrl));

      await launchResult;
      expect(harness.navigationAttempts, 0);
      expect(harness.reservation!.launchCalls, 1);
      expect(harness.reservationCalls, 1);
      expect(harness.fallbackCalls, 0);
    },
  );

  for (final scenario in _FailureScenario.values) {
    test(
      '${scenario.name} closes one reservation without fallback or extra attempt',
      () async {
        final harness = _BrowserLaunchHarness(
          linkResult: scenario != _FailureScenario.falseResult,
          throwOnLaunch: scenario == _FailureScenario.exception,
        );
        final service = ExternalReferenceLaunchService(
          referenceLoader: (_) => switch (scenario) {
            _FailureScenario.stale => Future<ExternalReferenceRecord?>.value(
              _reference(_canonicalUrl),
            ),
            _FailureScenario.invalid => Future<ExternalReferenceRecord?>.value(
              _reference('http://example.com/object'),
            ),
            _FailureScenario.repository =>
              Future<ExternalReferenceRecord?>.error(
                StateError('repository failed'),
              ),
            _FailureScenario.falseResult || _FailureScenario.exception =>
              Future<ExternalReferenceRecord?>.value(_reference(_canonicalUrl)),
          },
          gateway: harness.gateway,
        );
        Future<void>? launchResult;
        _clickDomButton(() {
          launchResult = expectLater(
            service.open(
              referenceId: 'reference-1',
              expectedUrl: scenario == _FailureScenario.stale
                  ? 'https://example.com/stale'
                  : scenario == _FailureScenario.invalid
                  ? 'http://example.com/object'
                  : _canonicalUrl,
            ),
            throwsA(isA<ExternalReferenceLaunchException>()),
            reason: scenario.name,
          );
        });

        await launchResult;
        expect(harness.reservationCalls, 1, reason: scenario.name);
        expect(harness.fallbackCalls, 0, reason: scenario.name);
        expect(harness.reservation!.closeCalls, 1, reason: scenario.name);
        expect(
          harness.reservation!.delegate.isClosed,
          isTrue,
          reason: scenario.name,
        );
        expect(harness.reservation!.launchCalls, switch (scenario) {
          _FailureScenario.stale ||
          _FailureScenario.invalid ||
          _FailureScenario.repository => 0,
          _FailureScenario.falseResult || _FailureScenario.exception => 1,
        }, reason: scenario.name);
        expect(
          harness.navigationAttempts,
          scenario == _FailureScenario.falseResult ? 1 : 0,
          reason: scenario.name,
        );
      },
    );
  }
}

enum _FailureScenario { stale, invalid, repository, falseResult, exception }

class _BrowserLaunchHarness {
  _BrowserLaunchHarness({
    this.destination,
    this.linkResult = true,
    this.throwOnLaunch = false,
    this.useFrame = false,
  }) : gateway = _CountingGateway() {
    gateway.delegate = WebExternalReferenceLaunchGateway(reserve);
  }

  final Uri? destination;
  final bool linkResult;
  final bool throwOnLaunch;
  final bool useFrame;
  final _CountingGateway gateway;
  web.HTMLIFrameElement? _frame;
  int reservationCalls = 0;
  int navigationAttempts = 0;
  _HarnessReservation? reservation;

  int get fallbackCalls => gateway.fallbackCalls;

  ExternalReferenceLaunchReservation? reserve() {
    reservationCalls++;
    bool navigator(web.Window reserved, Uri uri) {
      navigationAttempts++;
      if (!linkResult) return false;
      if (useFrame) {
        final frame = _frame;
        if (frame == null) return false;
        frame
          ..referrerPolicy = 'no-referrer'
          ..src = (destination ?? uri).toString();
        return true;
      }
      return navigateReservedExternalReference(reserved, destination ?? uri);
    }

    final WebExternalReferenceLaunchReservation? delegate;
    if (useFrame) {
      final frame = web.HTMLIFrameElement()
        ..src = 'about:blank'
        ..style.display = 'none';
      web.document.body?.append(frame);
      _frame = frame;
      final reserved = frame.contentWindow;
      delegate = reserved == null
          ? null
          : WebExternalReferenceLaunchReservation(
              reserved,
              navigator: navigator,
            );
    } else {
      delegate = reserveIsolatedBlankTab(navigator: navigator);
    }
    if (delegate == null) return null;
    reservation = _HarnessReservation(delegate, throwOnLaunch: throwOnLaunch);
    return reservation;
  }

  void dispose() {
    reservation?.delegate.close();
    _frame?.remove();
  }
}

class _CountingGateway implements ExternalReferenceLaunchGateway {
  _CountingGateway();

  WebExternalReferenceLaunchGateway? delegate;
  int fallbackCalls = 0;

  @override
  ExternalReferenceLaunchTarget get target => ExternalReferenceLaunchTarget.web;

  @override
  bool get requiresSynchronousReservation => true;

  @override
  ExternalReferenceLaunchReservation? reserveExternalLaunch() {
    final current = delegate;
    if (current == null) {
      throw StateError('Browser harness gateway was not initialized.');
    }
    return current.reserveExternalLaunch();
  }

  @override
  Future<bool> launchExternal(Uri uri) async {
    fallbackCalls++;
    return false;
  }
}

class _HarnessReservation implements ExternalReferenceLaunchReservation {
  _HarnessReservation(this.delegate, {required this.throwOnLaunch});

  final WebExternalReferenceLaunchReservation delegate;
  final bool throwOnLaunch;
  int launchCalls = 0;
  int closeCalls = 0;

  @override
  Future<bool> launch(Uri uri) {
    launchCalls++;
    if (throwOnLaunch) throw StateError('launch failed');
    return delegate.launch(uri);
  }

  @override
  void close() {
    closeCalls++;
    delegate.close();
  }
}

Future<void> _waitForLocation(
  WebExternalReferenceLaunchReservation reservation,
  String location,
) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    if (reservation.locationHref == location) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('Reserved tab did not reach the harness location.');
}

void _clickDomButton(void Function() onPressed) {
  final button = web.HTMLButtonElement()..textContent = 'Open reference';
  final listener = ((web.Event _) => onPressed()).toJS;
  button.addEventListener('click', listener);
  web.document.body?.append(button);
  button.click();
  button.removeEventListener('click', listener);
  button.remove();
}

ExternalReferenceRecord _reference(String url) => ExternalReferenceRecord(
  id: 'reference-1',
  artworkId: 'artwork-1',
  type: ExternalReferenceType.galleryOrArtist,
  label: 'Gallery',
  url: url,
  origin: ExternalReferenceOrigin.manual,
  reviewState: ExternalReferenceReviewState.confirmed,
  lastConfirmedAt: DateTime.utc(2026, 7, 13, 8),
  createdAt: DateTime.utc(2026, 7, 13, 8),
  updatedAt: DateTime.utc(2026, 7, 13, 8),
  sortOrder: 0,
);
