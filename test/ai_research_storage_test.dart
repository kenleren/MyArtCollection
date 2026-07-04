import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/storage/ai_research_record.dart';
import 'package:my_art_collection/app/storage/artwork_record.dart';
import 'package:my_art_collection/app/storage/local_artwork_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDir;
  late String databasePath;
  late LocalArtworkRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'my_art_collection_ai_research_test_',
    );
    databasePath = p.join(tempDir.path, 'records.db');
    repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(databasePath),
    );
    await repository.create(_record('artwork-001'));
  });

  tearDown(() async {
    await repository.close();
    await tempDir.delete(recursive: true);
  });

  Future<void> reopenRepository() async {
    await repository.close();
    repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(databasePath),
    );
  }

  test('persists on-device AI draft jobs without confirming fields', () async {
    await repository.upsertAiDraftJob(
      AiDraftJob(
        id: 'draft-job-001',
        artworkId: 'artwork-001',
        primaryImageAttachmentId: 'attachment-primary',
        status: AiDraftJobStatus.completed,
        createdAt: DateTime.utc(2026, 7, 4, 12),
        updatedAt: DateTime.utc(2026, 7, 4, 12, 1),
        completedAt: DateTime.utc(2026, 7, 4, 12, 1),
        deviceModel: 'Pixel 10 Pro XL',
        promptVersion: 'on-device-v1',
        visualSummary: 'Framed interior scene with visible signature.',
        signatureNotes: 'Signature may read J. Solberg.',
        subjectMatter: 'Interior study',
        mediumHint: 'Oil on canvas',
        stylePeriodHint: 'Late twentieth century style hint',
        conditionNotes: 'No obvious tears visible in the photo.',
        searchTerms: const ['J. Solberg interior', 'oil canvas interior'],
      ),
    );

    await reopenRepository();

    final draftJob = await repository.getAiDraftJob('draft-job-001');
    expect(draftJob, isNotNull);
    expect(draftJob!.status, AiDraftJobStatus.completed);
    expect(draftJob.searchTerms, [
      'J. Solberg interior',
      'oil canvas interior',
    ]);
    expect(draftJob.visualSummary, contains('Framed interior'));

    final artwork = await repository.get('artwork-001');
    expect(artwork!.field(ArtworkFieldKeys.artist)?.value, 'Unknown');
    expect(
      artwork.field(ArtworkFieldKeys.artist)?.source,
      ArtworkFieldSource.unknown,
    );
  });

  test('persists source-backed research candidates and value signals', () async {
    await repository.upsertResearchJob(
      ResearchJob(
        id: 'research-job-001',
        artworkId: 'artwork-001',
        status: ResearchJobStatus.completed,
        createdAt: DateTime.utc(2026, 7, 4, 13),
        updatedAt: DateTime.utc(2026, 7, 4, 13, 2),
        completedAt: DateTime.utc(2026, 7, 4, 13, 2),
        consentSummary:
            'User approved sending selected image and draft notes for research.',
        querySummary: 'J. Solberg interior oil canvas',
        provider: 'fixture-professional-source-search',
        sourceHits: const [
          ResearchSourceHit(
            id: 'source-hit-001',
            researchJobId: 'research-job-001',
            sourceName: 'Example Museum Collection',
            sourceType: ResearchSourceType.museumCollection,
            confidence: ResearchConfidence.possible,
            sourceUrl: 'https://museum.example/object/123',
            objectId: '123',
            title: 'Interior Study',
            artist: 'J. Solberg',
            dateText: 'circa 1980',
            medium: 'Oil on canvas',
            dimensions: '50 x 70 cm',
            matchReason: 'Visible signature and subject are similar.',
            rawSnippet: 'Collection record snippet.',
          ),
        ],
        candidateAttributions: const [
          CandidateAttribution(
            id: 'candidate-001',
            researchJobId: 'research-job-001',
            sourceHitId: 'source-hit-001',
            title: 'Interior Study',
            artist: 'J. Solberg',
            year: 'circa 1980',
            medium: 'Oil on canvas',
            confidence: ResearchConfidence.possible,
            matchReason: 'Museum record shares signature and subject.',
            fieldSources: {
              ArtworkFieldKeys.title: ArtworkFieldSource.aiSuggested,
              ArtworkFieldKeys.artist: ArtworkFieldSource.aiSuggested,
            },
          ),
        ],
        comparableValueSignals: [
          ComparableValueSignal(
            id: 'value-signal-001',
            researchJobId: 'research-job-001',
            sourceHitId: 'source-hit-001',
            kind: ComparableValueKind.comparableSaleSignal,
            label: 'Comparable sale signal',
            sourceName: 'Example Auction Archive',
            sourceUrl: 'https://auction.example/lot/456',
            amountLow: '2200',
            amountHigh: '2800',
            currency: 'USD',
            signalDate: DateTime.utc(2025, 5, 1),
            caveat:
                'Comparable data may not apply to this artwork; confirm with an expert.',
          ),
        ],
      ),
    );

    await reopenRepository();

    final researchJob = await repository.getResearchJob('research-job-001');
    expect(researchJob, isNotNull);
    expect(researchJob!.status, ResearchJobStatus.completed);
    expect(researchJob.sourceHits, hasLength(1));
    expect(
      researchJob.sourceHits.single.sourceName,
      'Example Museum Collection',
    );
    expect(researchJob.candidateAttributions, hasLength(1));
    expect(
      researchJob.candidateAttributions.single.fieldSources[ArtworkFieldKeys
          .artist],
      ArtworkFieldSource.aiSuggested,
    );
    expect(researchJob.comparableValueSignals, hasLength(1));
    expect(
      researchJob.comparableValueSignals.single.label,
      'Comparable sale signal',
    );
    expect(
      researchJob.comparableValueSignals.single.caveat,
      contains('may not apply'),
    );

    final artwork = await repository.get('artwork-001');
    expect(artwork!.field(ArtworkFieldKeys.artist)?.value, 'Unknown');
    expect(
      artwork.field(ArtworkFieldKeys.artist)?.source,
      ArtworkFieldSource.unknown,
    );
  });

  test('deletes AI research rows when artwork is deleted', () async {
    await repository.upsertAiDraftJob(
      AiDraftJob(
        id: 'draft-job-delete',
        artworkId: 'artwork-001',
        status: AiDraftJobStatus.completed,
        createdAt: DateTime.utc(2026, 7, 4, 13),
        updatedAt: DateTime.utc(2026, 7, 4, 13),
        visualSummary: 'Research draft to delete.',
      ),
    );
    await repository.upsertResearchJob(
      ResearchJob(
        id: 'research-job-delete',
        artworkId: 'artwork-001',
        status: ResearchJobStatus.completed,
        createdAt: DateTime.utc(2026, 7, 4, 13),
        updatedAt: DateTime.utc(2026, 7, 4, 13),
        consentSummary: 'User approved research.',
        sourceHits: const [
          ResearchSourceHit(
            id: 'source-hit-delete',
            researchJobId: 'research-job-delete',
            sourceName: 'Example Museum Collection',
            sourceType: ResearchSourceType.museumCollection,
            confidence: ResearchConfidence.possible,
          ),
        ],
        candidateAttributions: const [
          CandidateAttribution(
            id: 'candidate-delete',
            researchJobId: 'research-job-delete',
            confidence: ResearchConfidence.possible,
            matchReason: 'Candidate to delete.',
          ),
        ],
        comparableValueSignals: const [
          ComparableValueSignal(
            id: 'value-delete',
            researchJobId: 'research-job-delete',
            kind: ComparableValueKind.noReliableComparable,
            label: 'No reliable comparable found',
            sourceName: 'Professional-source search',
            caveat: 'No source-backed comparable was available.',
          ),
        ],
      ),
    );

    await repository.delete('artwork-001');

    expect(await repository.getAiDraftJob('draft-job-delete'), isNull);
    expect(await repository.getResearchJob('research-job-delete'), isNull);

    final rawDatabase = await databaseFactoryFfi.openDatabase(databasePath);
    addTearDown(rawDatabase.close);
    expect(await rawDatabase.query('research_source_hits'), isEmpty);
    expect(await rawDatabase.query('candidate_attributions'), isEmpty);
    expect(await rawDatabase.query('comparable_value_signals'), isEmpty);
  });

  test('upgrades v2 databases with AI research tables available', () async {
    await repository.close();
    await databaseFactoryFfi.deleteDatabase(databasePath);

    final legacyDatabase = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(version: 2, onCreate: _createV2Schema),
    );
    await legacyDatabase.insert('artworks', {
      'artwork_id': 'legacy-artwork-001',
      'record_state': 'draft',
      'primary_image_attachment_id': null,
      'created_at': DateTime.utc(2026, 7, 4, 8).toIso8601String(),
      'updated_at': DateTime.utc(2026, 7, 4, 8).toIso8601String(),
    });
    await legacyDatabase.close();

    repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(databasePath),
    );

    expect(await repository.get('legacy-artwork-001'), isNotNull);
    await repository.upsertAiDraftJob(
      AiDraftJob(
        id: 'legacy-draft-job',
        artworkId: 'legacy-artwork-001',
        status: AiDraftJobStatus.unavailable,
        createdAt: DateTime.utc(2026, 7, 4, 8, 1),
        updatedAt: DateTime.utc(2026, 7, 4, 8, 1),
        errorMessage: 'On-device AI unavailable on this device.',
      ),
    );

    final draftJob = await repository.getAiDraftJob('legacy-draft-job');
    expect(draftJob, isNotNull);
    expect(draftJob!.status, AiDraftJobStatus.unavailable);
  });
}

ArtworkRecord _record(String id) {
  final now = DateTime.utc(2026, 7, 4, 12);

  return ArtworkRecord(
    id: id,
    recordState: ArtworkRecordState.needsReview,
    createdAt: now,
    updatedAt: now,
    fields: const {
      ArtworkFieldKeys.title: ArtworkFieldValue(
        value: 'Untitled artwork',
        source: ArtworkFieldSource.aiSuggested,
        note: 'Draft title placeholder. Confirm or edit after review.',
      ),
      ArtworkFieldKeys.artist: ArtworkFieldValue(
        value: 'Unknown',
        source: ArtworkFieldSource.unknown,
        note: 'Add the artist when known.',
      ),
    },
  );
}

Future<void> _createV2Schema(Database db, int version) async {
  await db.execute('''
    CREATE TABLE artworks (
      artwork_id TEXT PRIMARY KEY,
      record_state TEXT NOT NULL,
      primary_image_attachment_id TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');

  await db.execute('''
    CREATE TABLE artwork_fields (
      artwork_id TEXT NOT NULL,
      field_key TEXT NOT NULL,
      value TEXT NOT NULL,
      source_state TEXT NOT NULL,
      source_note TEXT NOT NULL,
      last_confirmed_at TEXT,
      PRIMARY KEY (artwork_id, field_key),
      FOREIGN KEY (artwork_id)
        REFERENCES artworks (artwork_id)
        ON DELETE CASCADE
    )
  ''');

  await db.execute('''
    CREATE TABLE attachments (
      attachment_id TEXT PRIMARY KEY,
      artwork_id TEXT NOT NULL,
      attachment_type TEXT NOT NULL,
      file_name TEXT NOT NULL,
      mime_type TEXT NOT NULL,
      file_size_bytes INTEGER NOT NULL,
      imported_at TEXT NOT NULL,
      captured_at TEXT,
      source_state TEXT NOT NULL,
      relative_path TEXT NOT NULL,
      checksum TEXT NOT NULL,
      extraction_summary TEXT,
      notes TEXT,
      FOREIGN KEY (artwork_id)
        REFERENCES artworks (artwork_id)
        ON DELETE CASCADE
    )
  ''');
}
