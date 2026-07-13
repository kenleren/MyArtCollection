import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/external_references/external_reference_launch_gateway.dart';
import 'package:my_art_collection/app/external_references/external_reference_launch_gateway_native.dart';
import 'package:my_art_collection/app/external_references/external_reference_launch_gateway_web_policy.dart';
import 'package:my_art_collection/app/external_references/external_reference_launch_service.dart';
import 'package:my_art_collection/app/storage/artwork_record.dart';
import 'package:my_art_collection/app/storage/external_reference.dart';
import 'package:my_art_collection/app/storage/local_artwork_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('native gateway fails closed without fallback', () {
    test('unsupported mode never launches', () async {
      final launcher = _FakeNativeLauncher(supported: false);
      final gateway = NativeExternalReferenceLaunchGateway(launcher: launcher);

      expect(
        await gateway.launchExternal(Uri.parse('https://example.com')),
        isFalse,
      );
      expect(launcher.supportCalls, 1);
      expect(launcher.launchCalls, 0);
    });

    test('support exception never launches', () async {
      final launcher = _FakeNativeLauncher(throwOnSupport: true);
      final gateway = NativeExternalReferenceLaunchGateway(launcher: launcher);

      expect(
        await gateway.launchExternal(Uri.parse('https://example.com')),
        isFalse,
      );
      expect(launcher.supportCalls, 1);
      expect(launcher.launchCalls, 0);
    });

    test('false and exception each make one external launch attempt', () async {
      for (final throws in [false, true]) {
        final launcher = _FakeNativeLauncher(
          supported: true,
          launchResult: false,
          throwOnLaunch: throws,
        );
        final gateway = NativeExternalReferenceLaunchGateway(
          launcher: launcher,
        );

        expect(
          await gateway.launchExternal(Uri.parse('https://example.com')),
          isFalse,
        );
        expect(launcher.supportCalls, 1);
        expect(launcher.launchCalls, 1);
      }
    });
  });

  group('web gateway reserves synchronously and never falls back', () {
    test(
      'false and exception each create only one isolated reservation',
      () async {
        for (final throws in [false, true]) {
          var calls = 0;
          final reservation = _RecordingReservation(
            result: false,
            throws: throws,
          );
          final gateway = WebExternalReferenceLaunchGateway(() {
            calls++;
            return reservation;
          });

          final reserved = gateway.reserveExternalLaunch();
          expect(
            calls,
            1,
            reason: 'the popup attempt must occur in the gesture stack',
          );
          expect(gateway.requiresSynchronousReservation, isTrue);
          if (throws) {
            await expectLater(
              reserved!.launch(Uri.parse('https://example.com')),
              throwsA(isA<StateError>()),
            );
          } else {
            expect(
              await reserved!.launch(Uri.parse('https://example.com')),
              isFalse,
            );
          }
          expect(calls, 1);
          expect(reservation.launchCalls, 1);
        }
      },
    );
  });

  group('launch service reloads and revalidates at tap time', () {
    late Directory tempDirectory;
    late Database database;
    late LocalArtworkRepository repository;
    late _RecordingGateway gateway;
    late ExternalReferenceLaunchService service;

    setUp(() async {
      tempDirectory = await Directory.systemTemp.createTemp('external-launch-');
      database = await LocalArtworkRepository.openAt(
        p.join(tempDirectory.path, 'test.db'),
      );
      repository = LocalArtworkRepository.forDatabase(database);
      await repository.create(_artwork('artwork-1'));
      await repository.addManualExternalReference(
        referenceId: 'reference-1',
        artworkId: 'artwork-1',
        type: ExternalReferenceType.galleryOrArtist,
        label: 'Gallery',
        url: 'https://example.com/object',
        transactionTime: DateTime.utc(2026, 7, 13, 8),
      );
      gateway = _RecordingGateway();
      service = ExternalReferenceLaunchService(
        referenceLoader: repository.getExternalReference,
        gateway: gateway,
      );
    });

    tearDown(() async {
      await repository.close();
      await tempDirectory.delete(recursive: true);
    });

    test('opens the reloaded canonical row exactly once', () async {
      await service.open(
        referenceId: 'reference-1',
        expectedUrl: 'https://example.com/object',
      );

      expect(gateway.uris, [Uri.parse('https://example.com/object')]);
    });

    test('web reservation is made before the asynchronous reload', () async {
      final reservation = _RecordingReservation();
      gateway = _RecordingGateway(
        target: ExternalReferenceLaunchTarget.web,
        reservation: reservation,
      );
      service = ExternalReferenceLaunchService(
        referenceLoader: repository.getExternalReference,
        gateway: gateway,
      );

      final open = service.open(
        referenceId: 'reference-1',
        expectedUrl: 'https://example.com/object',
      );
      expect(gateway.reservationCalls, 1);
      expect(reservation.launchCalls, 0);
      await open;
      expect(reservation.uris, [Uri.parse('https://example.com/object')]);
      expect(reservation.closeCalls, 0);
    });

    test('missing and stale rows fail locally without gateway calls', () async {
      await expectLater(
        service.open(
          referenceId: 'missing',
          expectedUrl: 'https://example.com/object',
        ),
        throwsA(isA<ExternalReferenceLaunchException>()),
      );
      await expectLater(
        service.open(
          referenceId: 'reference-1',
          expectedUrl: 'https://example.com/stale',
        ),
        throwsA(isA<ExternalReferenceLaunchException>()),
      );
      expect(gateway.uris, isEmpty);
    });

    test('invalid or noncanonical stored URL fails locally', () async {
      await database.update(
        'external_references',
        {'url': 'http://example.com'},
        where: 'reference_id = ?',
        whereArgs: ['reference-1'],
      );

      await expectLater(
        service.open(
          referenceId: 'reference-1',
          expectedUrl: 'http://example.com',
        ),
        throwsA(
          isA<ExternalReferenceLaunchException>().having(
            (error) => error.failure,
            'failure',
            ExternalReferenceLaunchFailure.staleOrInvalid,
          ),
        ),
      );
      expect(gateway.uris, isEmpty);
    });

    test(
      'gateway false and exception are one failed attempt without retry',
      () async {
        for (final throws in [false, true]) {
          gateway = _RecordingGateway(result: false, throws: throws);
          service = ExternalReferenceLaunchService(
            referenceLoader: repository.getExternalReference,
            gateway: gateway,
          );

          await expectLater(
            service.open(
              referenceId: 'reference-1',
              expectedUrl: 'https://example.com/object',
            ),
            throwsA(
              isA<ExternalReferenceLaunchException>().having(
                (error) => error.failure,
                'failure',
                ExternalReferenceLaunchFailure.openFailed,
              ),
            ),
          );
          expect(gateway.uris, hasLength(1));
        }
      },
    );

    test(
      'web reservation closes for stale, invalid, false and exception paths',
      () async {
        for (final scenario in ['stale', 'invalid', 'false', 'exception']) {
          final reservation = _RecordingReservation(
            result: scenario != 'false',
            throws: scenario == 'exception',
          );
          gateway = _RecordingGateway(
            target: ExternalReferenceLaunchTarget.web,
            reservation: reservation,
          );
          service = ExternalReferenceLaunchService(
            referenceLoader: repository.getExternalReference,
            gateway: gateway,
          );
          if (scenario == 'invalid') {
            await database.update(
              'external_references',
              {'url': 'http://example.com'},
              where: 'reference_id = ?',
              whereArgs: ['reference-1'],
            );
          }
          await expectLater(
            service.open(
              referenceId: 'reference-1',
              expectedUrl: scenario == 'stale'
                  ? 'https://example.com/stale'
                  : scenario == 'invalid'
                  ? 'http://example.com'
                  : 'https://example.com/object',
            ),
            throwsA(isA<ExternalReferenceLaunchException>()),
          );
          expect(gateway.reservationCalls, 1, reason: scenario);
          expect(reservation.closeCalls, 1, reason: scenario);
          expect(
            reservation.launchCalls,
            scenario == 'stale' || scenario == 'invalid' ? 0 : 1,
          );
          if (scenario == 'invalid') {
            await database.update(
              'external_references',
              {'url': 'https://example.com/object'},
              where: 'reference_id = ?',
              whereArgs: ['reference-1'],
            );
          }
        }
      },
    );
  });
}

class _FakeNativeLauncher implements NativeExternalLauncher {
  _FakeNativeLauncher({
    this.supported = true,
    this.launchResult = true,
    this.throwOnSupport = false,
    this.throwOnLaunch = false,
  });

  final bool supported;
  final bool launchResult;
  final bool throwOnSupport;
  final bool throwOnLaunch;
  int supportCalls = 0;
  int launchCalls = 0;

  @override
  Future<bool> supportsExternalApplication() async {
    supportCalls++;
    if (throwOnSupport) throw StateError('unsupported');
    return supported;
  }

  @override
  Future<bool> launchExternalApplication(Uri uri) async {
    launchCalls++;
    if (throwOnLaunch) throw StateError('launch failed');
    return launchResult;
  }
}

class _RecordingGateway implements ExternalReferenceLaunchGateway {
  _RecordingGateway({
    this.target = ExternalReferenceLaunchTarget.native,
    this.result = true,
    this.throws = false,
    this.reservation,
  });

  @override
  final ExternalReferenceLaunchTarget target;
  final bool result;
  final bool throws;
  final _RecordingReservation? reservation;
  final List<Uri> uris = [];
  int reservationCalls = 0;

  @override
  bool get requiresSynchronousReservation =>
      target == ExternalReferenceLaunchTarget.web;

  @override
  ExternalReferenceLaunchReservation? reserveExternalLaunch() {
    reservationCalls++;
    return reservation;
  }

  @override
  Future<bool> launchExternal(Uri uri) async {
    uris.add(uri);
    if (throws) throw StateError('launch failed');
    return result;
  }
}

class _RecordingReservation implements ExternalReferenceLaunchReservation {
  _RecordingReservation({this.result = true, this.throws = false});

  final bool result;
  final bool throws;
  final List<Uri> uris = [];
  int launchCalls = 0;
  int closeCalls = 0;

  @override
  Future<bool> launch(Uri uri) async {
    launchCalls++;
    uris.add(uri);
    if (throws) throw StateError('launch failed');
    return result;
  }

  @override
  void close() => closeCalls++;
}

ArtworkRecord _artwork(String id) => ArtworkRecord(
  id: id,
  recordState: ArtworkRecordState.verifiedByYou,
  createdAt: DateTime.utc(2026, 7, 13),
  updatedAt: DateTime.utc(2026, 7, 13),
  fields: const {},
);
