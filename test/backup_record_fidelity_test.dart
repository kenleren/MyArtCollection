import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/backup/backup_record_bundle.dart';
import 'package:my_art_collection/app/import/csv_artwork_import_service.dart';
import 'package:my_art_collection/app/research/online_research_service.dart';
import 'package:my_art_collection/app/storage/local_artwork_repository.dart';
import 'package:my_art_collection/app/storage/ai_research_record.dart';
import 'package:my_art_collection/app/backup/backup_record_codec.dart';
import 'package:my_art_collection/app/backup/backup_record_schema.dart';
import 'package:my_art_collection/app/backup/backup_record_snapshot.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/backup_record_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  test(
    'actual CSV amount-only and sanitized research evidence preserve writer semantics',
    () async {
      final f = await BackupRecordFixture.create(rich: false);
      addTearDown(f.close);
      final repo = LocalArtworkRepository.forDatabase(f.database);
      final parsed = CsvArtworkImportService(
        idFactory: () => 'writer-art',
        now: () => DateTime.utc(2026, 9, 29),
      ).previewFromString('Title,Purchase price\nSynthetic,100\n');
      await repo.create(parsed.rows.single.record!);
      final money = (await f.database.query(
        'artwork_fields',
        where: 'money_amount IS NOT NULL',
      )).single;
      expect(money['money_amount'], '100');
      expect(money['money_currency_code'], isNull);
      final now = DateTime.utc(2026, 9, 29);
      final service = OnlineResearchService(
        repository: repo,
        client: _SyntheticResearch(
          ResearchJob(
            id: 'writer-job',
            artworkId: 'csv-import-writer-art',
            status: ResearchJobStatus.completed,
            createdAt: now,
            updatedAt: now,
            consentSummary: 'Recorded synthetic approval',
            provider: 'Synthetic only',
            sourceHits: const [
              ResearchSourceHit(
                id: 'writer-hit',
                researchJobId: 'writer-job',
                sourceName: 'Auction',
                sourceType: ResearchSourceType.auctionHouse,
                confidence: ResearchConfidence.possible,
                sourceUrl: 'https://auction.example/lot/1',
                objectId: 'provider-id',
              ),
            ],
            comparableValueSignals: const [
              ComparableValueSignal(
                id: 'writer-value',
                researchJobId: 'writer-job',
                sourceHitId: 'writer-hit',
                kind: ComparableValueKind.publicEstimate,
                label: 'Estimate',
                sourceName: 'Auction',
                sourceUrl: 'https://auction.example/lot/1',
                amountLow: 'about 1,200',
                amountHigh: '2,000 – 3,000',
                currency: 'US dollars',
                caveat: 'Historical evidence only',
              ),
            ],
          ),
        ),
        allowlist: const ProfessionalSourceAllowlist([
          ProfessionalSource(
            host: 'auction.example',
            name: 'Auction',
            type: ResearchSourceType.auctionHouse,
          ),
        ]),
      );
      await service.runResearch(
        const OnlineResearchRequest(
          artworkId: 'csv-import-writer-art',
          consentSummary: 'Synthetic approval',
          querySummary: 'Synthetic query',
          consentState: ResearchConsentState.approved,
        ),
      );
      final evidence = (await f.database.query(
        'comparable_value_signals',
      )).single;
      expect(evidence['amount_low'], 'about 1,200');
      expect(evidence['amount_high'], '2,000 – 3,000');
      expect(evidence['currency'], 'US dollars');
      // The actual repository writer preserves provider-scoped identifiers as data.
      for (final objectId in ['', 'provider\u0000metadata', 'x' * 2048]) {
        await repo.upsertResearchJob(
          ResearchJob(
            id: 'metadata-job',
            artworkId: 'csv-import-writer-art',
            status: ResearchJobStatus.completed,
            createdAt: now,
            updatedAt: now,
            consentSummary: 'Historical',
            sourceHits: [
              ResearchSourceHit(
                id: 'metadata-hit',
                researchJobId: 'metadata-job',
                sourceName: 'Provider',
                sourceType: ResearchSourceType.unknown,
                confidence: ResearchConfidence.possible,
                objectId: objectId,
              ),
            ],
          ),
        );
        final result = await const BackupRecordCodec().decode(
          await const BackupRecordCodec().encode(
            await const BackupRecordSnapshot().capture(f.database),
          ),
        );
        expect(
          result.tables['research_source_hits']!
              .firstWhere((r) => r.values['source_hit_id'] == 'metadata-hit')
              .values['object_id'],
          objectId,
        );
        expect(
          result.tables['comparable_value_signals']!.single.values,
          evidence,
        );
        expect(
          result.tables['artwork_fields']!
              .firstWhere((r) => r.values['money_amount'] != null)
              .values,
          money,
        );
      }
    },
  );
  for (final version in <int?>[null, 5, 8, 9]) {
    test(
      'actual ${version ?? 'fresh'} schema10 SQLite to component preserves119 values',
      () async {
        final f = await BackupRecordFixture.create(fromVersion: version);
        addTearDown(f.close);
        final source = await const BackupRecordSnapshot().capture(f.database);
        final bytes = await const BackupRecordCodec().encode(source);
        final result = await const BackupRecordCodec().decode(bytes);
        expect(utf8.decode(bytes), isNot(contains('PRIVATE-PATH-SENTINEL')));
        var columns = 0;
        for (final table in backupRecordTables) {
          final schema = await f.database.rawQuery(
            'PRAGMA table_info(${table.name})',
          );
          expect(
            schema.map((r) => r['name']).toSet(),
            table.columns.map((c) => c.name).toSet(),
          );
          columns += schema.length;
          final sql = await f.database.query(
            table.name,
            orderBy: table.keys.map((k) => '$k COLLATE BINARY').join(','),
          );
          expect(result.tables[table.name], hasLength(sql.length));
          for (var i = 0; i < sql.length; i++) {
            final expected = {...sql[i]};
            if (table.name == 'attachments') {
              expected['relative_path'] = BackupDevicePath.reconstructLater;
            }
            expect(
              result.tables[table.name]![i].values,
              expected,
              reason: '${table.name}:$i compare raw SQLite, not re-export',
            );
          }
        }
        expect(columns, 120);
        expect(
          result.jobs.map((r) => r.originalStatus).toSet(),
          containsAll([
            'pending',
            'running',
            'queued',
            'pending_consent',
            'completed',
            'unavailable',
            'failed',
            'cancelled',
          ]),
        );
        expect(
          result.jobs.every((r) => r.executionDisposition == 'history_only'),
          isTrue,
        );
        expect(result.diagnostics.map((v) => v.attachmentId), [
          'child-of-removed',
        ]);
        expect(result.supportsCompleteRecovery, isFalse);
        expect(result.payloadCoverage, 'not_evaluated');
        expect(await const BackupRecordCodec().encode(result), bytes);
        expect(() => result.tables.clear(), throwsUnsupportedError);
        expect(
          () => result.tables['artworks']!.clear(),
          throwsUnsupportedError,
        );
        expect(
          () => result.tables['artworks']!.first.values.clear(),
          throwsUnsupportedError,
        );
      },
    );
  }
}

class _SyntheticResearch implements OnlineResearchClient {
  _SyntheticResearch(this.result);
  final ResearchJob result;
  @override
  Future<ResearchJob> research(OnlineResearchRequest request) async => result;
}
