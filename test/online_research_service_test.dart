import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/research/online_research_service.dart';
import 'package:my_art_collection/app/storage/ai_research_record.dart';
import 'package:my_art_collection/app/storage/artwork_record.dart';
import 'package:my_art_collection/app/storage/local_artwork_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDir;
  late LocalArtworkRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'my_art_collection_online_research_test_',
    );
    repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(p.join(tempDir.path, 'records.db')),
    );
    await repository.create(_record('artwork-001'));
  });

  tearDown(() async {
    await repository.close();
    await tempDir.delete(recursive: true);
  });

  test('fixture client persists cited professional-source candidates', () async {
    final service = OnlineResearchService(
      repository: repository,
      client: FixtureProfessionalSourceResearchClient(
        now: () => DateTime.utc(2026, 7, 4, 14),
      ),
    );

    final job = await service.runResearch(
      const OnlineResearchRequest(
        artworkId: 'artwork-001',
        consentSummary:
            'User approved selected image and local draft notes for research.',
        querySummary: 'Oil on canvas with possible signature',
        searchTerms: ['oil', 'canvas'],
      ),
    );

    expect(job.status, ResearchJobStatus.completed);
    expect(job.provider, 'fixture-professional-source-search');
    expect(job.sourceHits, isNotEmpty);
    expect(
      job.sourceHits.single.sourceUrl,
      startsWith('https://www.metmuseum.org/'),
    );
    expect(job.sourceHits.single.sourceName, 'The Met Collection');
    expect(
      job.candidateAttributions.single.sourceHitId,
      job.sourceHits.single.id,
    );
    expect(
      job.candidateAttributions.single.fieldSources.values,
      everyElement(ArtworkFieldSource.aiSuggested),
    );
    expect(
      job.comparableValueSignals.single.kind,
      ComparableValueKind.noReliableComparable,
    );
    expect(
      job.comparableValueSignals.single.label,
      'No reliable comparable found',
    );
    expect(job.comparableValueSignals.single.amountLow, isNull);
    expect(job.comparableValueSignals.single.amountHigh, isNull);
    expect(job.comparableValueSignals.single.currency, isNull);
    expect(job.comparableValueSignals.single.signalDate, isNull);

    final persisted = await repository.getResearchJob(job.id);
    expect(persisted, isNotNull);
    expect(
      persisted!.sourceHits.single.sourceUrl,
      job.sourceHits.single.sourceUrl,
    );

    final artwork = await repository.get('artwork-001');
    expect(
      artwork!.field(ArtworkFieldKeys.artist)?.source,
      ArtworkFieldSource.unknown,
    );
  });

  test(
    'fixture client only displays amounts for explicit auction sources',
    () async {
      final service = OnlineResearchService(
        repository: repository,
        client: FixtureProfessionalSourceResearchClient(
          allowlist: const ProfessionalSourceAllowlist([
            ProfessionalSource(
              host: 'auction.example',
              name: 'Example Auction Results',
              type: ResearchSourceType.auctionHouse,
            ),
          ]),
          fixtureHits: [
            ResearchFixtureHit(
              sourceUrl: 'https://auction.example/lot/123',
              title: 'Interior Study',
              artist: 'Example Auction Artist',
              dateText: '2025',
              medium: 'Oil on canvas',
              matchReason:
                  'Auction lot shares subject, medium, and dimensions.',
              rawSnippet: 'Sold lot with published estimate range.',
              matchTerms: const ['auction-comparable'],
              comparableKind: ComparableValueKind.comparableSaleSignal,
              comparableAmountLow: '2200',
              comparableAmountHigh: '2800',
              comparableCurrency: 'USD',
              comparableSignalDate: DateTime.utc(2025, 5, 1),
              comparableCaveat:
                  'Comparable data may not apply to this artwork; confirm with an expert.',
            ),
          ],
          now: () => DateTime.utc(2026, 7, 4, 14),
        ),
      );

      final job = await service.runResearch(
        const OnlineResearchRequest(
          artworkId: 'artwork-001',
          consentSummary: 'User approved research.',
          querySummary: 'auction-comparable',
          searchTerms: ['auction-comparable'],
        ),
      );

      expect(job.sourceHits.single.sourceType, ResearchSourceType.auctionHouse);
      expect(
        job.comparableValueSignals.single.kind,
        ComparableValueKind.comparableSaleSignal,
      );
      expect(job.comparableValueSignals.single.label, 'Comparable sale signal');
      expect(job.comparableValueSignals.single.amountLow, '2200');
      expect(job.comparableValueSignals.single.amountHigh, '2800');
      expect(job.comparableValueSignals.single.currency, 'USD');
      expect(
        job.comparableValueSignals.single.signalDate,
        DateTime.utc(2025, 5, 1),
      );
    },
  );

  test(
    'fixture client returns no reliable comparable when no sources match',
    () async {
      final client = FixtureProfessionalSourceResearchClient(
        now: () => DateTime.utc(2026, 7, 4, 14),
      );

      final job = await client.research(
        const OnlineResearchRequest(
          artworkId: 'artwork-001',
          consentSummary: 'User approved research.',
          querySummary: 'bronze garden sculpture',
          searchTerms: ['bronze', 'garden'],
        ),
      );

      expect(job.sourceHits, isEmpty);
      expect(job.candidateAttributions, isEmpty);
      expect(
        job.comparableValueSignals.single.kind,
        ComparableValueKind.noReliableComparable,
      );
      expect(
        job.comparableValueSignals.single.label,
        'No reliable comparable found',
      );
    },
  );

  test('allowlist accepts exact hosts and subdomains only', () {
    final allowlist = ProfessionalSourceAllowlist.initial();

    expect(allowlist.isAllowed('https://metmuseum.org/art/collection'), isTrue);
    expect(
      allowlist.isAllowed(
        'https://collectionapi.metmuseum.org/public/collection/v1/search',
      ),
      isTrue,
    );
    expect(
      allowlist.isAllowed('https://metmuseum.org.evil.example/item'),
      isFalse,
    );
    expect(allowlist.isAllowed('https://evilmetmuseum.org/item'), isFalse);
    expect(allowlist.isAllowed('file:///tmp/source.json'), isFalse);
  });

  test('fixture client blocks disallowed configured source URLs', () async {
    final client = FixtureProfessionalSourceResearchClient(
      fixtureHits: const [
        ResearchFixtureHit(
          sourceUrl: 'https://metmuseum.org.evil.example/fake-object',
          title: 'Fake Object',
          artist: 'Unknown',
          dateText: 'Unknown',
          medium: 'Unknown',
          matchReason: 'Should never be accepted.',
          matchTerms: ['fake'],
        ),
      ],
    );

    expect(
      () => client.research(
        const OnlineResearchRequest(
          artworkId: 'artwork-001',
          consentSummary: 'User approved research.',
          querySummary: 'fake',
        ),
      ),
      throwsA(isA<DisallowedResearchSourceException>()),
    );
  });

  test(
    'mobile source and config do not contain embedded AI or search secrets',
    () async {
      final repoRoot = Directory.current;
      final scannedFiles = <File>[
        ..._mobileFilesUnder(Directory(p.join(repoRoot.path, 'lib'))),
        ..._mobileFilesUnder(Directory(p.join(repoRoot.path, 'android'))),
        ..._mobileFilesUnder(Directory(p.join(repoRoot.path, 'ios'))),
      ];
      final forbidden = RegExp(
        r'(AIza[0-9A-Za-z_-]{20,}|sk-[0-9A-Za-z_-]{20,}|'
        r'OPENAI_API_KEY|GEMINI_API_KEY|GOOGLE_API_KEY|'
        r'CUSTOM_SEARCH_KEY|SEARCH_API_KEY)',
      );

      for (final file in scannedFiles) {
        if (!await file.exists()) {
          continue;
        }
        final content = await file.readAsString();
        expect(content, isNot(contains(forbidden)), reason: file.path);
      }
    },
  );
}

Iterable<File> _mobileFilesUnder(Directory directory) sync* {
  if (!directory.existsSync()) {
    return;
  }
  for (final entity in directory.listSync(recursive: true)) {
    if (entity is File && _isMobileSourceOrConfig(entity.path)) {
      yield entity;
    }
  }
}

bool _isMobileSourceOrConfig(String path) {
  const extensions = [
    '.dart',
    '.gradle',
    '.kts',
    '.kt',
    '.plist',
    '.properties',
    '.swift',
    '.xcconfig',
    '.xml',
  ];
  return extensions.any(path.endsWith);
}

ArtworkRecord _record(String id) {
  return ArtworkRecord(
    id: id,
    recordState: ArtworkRecordState.needsReview,
    createdAt: DateTime.utc(2026, 7, 4, 12),
    updatedAt: DateTime.utc(2026, 7, 4, 12),
    fields: const {
      ArtworkFieldKeys.title: ArtworkFieldValue(
        value: 'Untitled artwork',
        source: ArtworkFieldSource.unknown,
        note: 'Awaiting research.',
      ),
      ArtworkFieldKeys.artist: ArtworkFieldValue(
        value: 'Unknown',
        source: ArtworkFieldSource.unknown,
        note: 'Awaiting research.',
      ),
    },
  );
}
