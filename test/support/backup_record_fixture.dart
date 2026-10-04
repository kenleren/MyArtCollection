import 'dart:io';

import 'package:my_art_collection/app/backup/backup_record_bundle.dart';
import 'package:my_art_collection/app/backup/backup_record_schema.dart';
import 'package:my_art_collection/app/storage/local_artwork_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class BackupRecordFixture {
  BackupRecordFixture(this.root, this.database);
  final Directory root;
  final Database database;
  static const time = '2026-09-29T12:00:00.123Z';
  static Future<BackupRecordFixture> create({
    int? fromVersion,
    bool rich = true,
  }) async {
    final root = await Directory.systemTemp.createTemp(
      'backup-record-synthetic-',
    );
    final path = '${root.path}/records.db';
    if (fromVersion != null) {
      final old = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: fromVersion,
          onCreate: (db, version) async {
            if (version == 5) {
              await _createV5Schema(db, version);
            } else {
              // Genuine schema8/9 omit later additive tables; base tables are from known DDL.
              final omitted = {
                'artwork_groups',
                'artwork_group_memberships',
                'artwork_preferences',
                if (version == 8) 'external_references',
              };
              for (final entry in backupSchemaSql.entries) {
                final table = RegExp(
                  r'(?:ON|TABLE)\s+(\w+)',
                  caseSensitive: false,
                ).firstMatch(entry.value)?.group(1);
                if (table != null && omitted.contains(table)) continue;
                await db.execute(entry.value);
              }
            }
          },
        ),
      );
      if (fromVersion == 5) {
        await old.insert('artworks', {
          'artwork_id': 'legacy-art',
          'record_state': 'draft',
          'lifecycle_status': 'active',
          'primary_image_attachment_id': 'legacy-photo',
          'created_at': time,
          'updated_at': time,
        });
        for (final id in ['legacy-photo', 'legacy-second', 'legacy-document']) {
          await old.insert('attachments', {
            'attachment_id': id,
            'artwork_id': 'legacy-art',
            'attachment_type': id == 'legacy-document' ? 'receipt' : 'photo',
            'file_name': 'legacy.jpg',
            'mime_type': 'image/jpeg',
            'file_size_bytes': 17,
            'imported_at': time,
            'captured_at': null,
            'source_state': 'unknown',
            'relative_path': 'PRIVATE-PATH-SENTINEL/legacy',
            'checksum': 'legacy-recorded',
            'extraction_summary': null,
            'notes': 'Before migration',
          });
        }
      }
      await old.close();
    }
    final fixture = BackupRecordFixture(
      root,
      await LocalArtworkRepository.openAt(path),
    );
    if (rich) await fixture.populate();
    return fixture;
  }

  Future<void> populate() async {
    await database.insert('artworks', {
      'artwork_id': 'art-1',
      'record_state': 'verifiedByYou',
      'lifecycle_status': 'active',
      'primary_image_attachment_id': 'original',
      'created_at': time,
      'updated_at': time,
    });
    await database.insert('artwork_fields', {
      'artwork_id': 'art-1',
      'field_key': 'custom-field',
      'value': 'Collector\nvalue',
      'money_amount': '100',
      'money_currency_code': null,
      'source_state': 'user-confirmed',
      'source_note': 'Source\u0000note',
      'last_confirmed_at': null,
    });
    await database.insert('artwork_groups', {
      'group_id': 'group-1',
      'name': 'Favorites',
      'normalized_name': 'favorites',
      'sort_order': 0,
      'created_at': time,
      'updated_at': time,
    });
    await database.insert('artwork_group_memberships', {
      'artwork_id': 'art-1',
      'group_id': 'group-1',
      'created_at': time,
    });
    await database.insert('artwork_preferences', {
      'artwork_id': 'art-1',
      'is_favorite': 0,
      'updated_at': time,
    });
    for (final id in [
      'original',
      'derivative',
      'superseded',
      'unavailable',
      'removed',
      'child-of-removed',
    ]) {
      await database.insert('attachments', {
        'attachment_id': id,
        'artwork_id': 'art-1',
        'attachment_type': 'photo',
        'attachment_role': id == 'original'
            ? 'primary_artwork_photo'
            : 'supporting_photo',
        'file_name': '$id.jpg',
        'mime_type': 'image/jpeg',
        'file_size_bytes': 4,
        'imported_at': time,
        'captured_at': '2026-09-28T12:00:00.123456Z',
        'source_state': 'user-confirmed',
        'relative_path': 'PRIVATE-PATH-SENTINEL/$id',
        'checksum': 'a' * 64,
        'lifecycle_status':
            ['superseded', 'removed', 'unavailable'].contains(id)
            ? id
            : 'active',
        'lifecycle_updated_at': time,
        'superseded_by_attachment_id': id == 'superseded' ? 'original' : null,
        'derived_from_attachment_id': id == 'derivative'
            ? 'original'
            : id == 'child-of-removed'
            ? 'removed'
            : null,
        'transform_summary': 'Unmodified history',
        'extraction_summary': 'Recorded summary',
        'notes': '',
      });
    }
    for (final status in [
      'pending',
      'running',
      'completed',
      'unavailable',
      'failed',
    ]) {
      await database.insert('ai_draft_jobs', {
        'draft_job_id': 'draft-$status',
        'artwork_id': 'art-1',
        'primary_image_attachment_id': 'original',
        'status': status,
        'created_at': time,
        'updated_at': time,
        'completed_at': status == 'completed' ? time : null,
        'device_model': 'synthetic',
        'prompt_version': 'v1',
        'visual_summary': 'Recorded $status',
        'signature_notes': 'Cautious',
        'subject_matter': 'Painting',
        'medium_hint': 'Unknown',
        'style_period_hint': 'Unknown',
        'condition_notes': 'Recorded',
        'search_terms_json': '[ "one", "two" ]',
        'error_message': 'Historical error',
      });
    }
    for (final status in [
      'pending_consent',
      'queued',
      'running',
      'completed',
      'failed',
      'cancelled',
    ]) {
      await database.insert('research_jobs', {
        'research_job_id': 'research-$status',
        'artwork_id': 'art-1',
        'status': status,
        'created_at': time,
        'updated_at': time,
        'completed_at': status == 'completed' ? time : null,
        'consent_summary': 'Historical only',
        'query_summary': 'Past query',
        'provider': 'Past provider',
        'error_message': 'Past error',
      });
    }
    await database.insert('research_source_hits', {
      'source_hit_id': 'hit-1',
      'research_job_id': 'research-completed',
      'source_name': 'Synthetic source',
      'source_type': 'auction_house',
      'confidence': 'possible',
      'source_url': 'https://example.com/source',
      'object_id': 'object-1',
      'title': 'Title',
      'artist': 'Artist',
      'date_text': 'Undated',
      'medium': 'Unknown',
      'dimensions': 'Recorded',
      'image_url': 'https://example.com/image',
      'match_reason': 'Cautious',
      'raw_snippet': 'Evidence',
    });
    await database.insert('candidate_attributions', {
      'candidate_id': 'candidate-1',
      'research_job_id': 'research-completed',
      'source_hit_id': 'hit-1',
      'title': 'Title',
      'artist': 'Artist',
      'year': 'Unknown',
      'medium': 'Unknown',
      'confidence': 'possible',
      'match_reason': 'Cautious',
      'field_sources_json': '{ "custom-field": "AI-suggested" }',
    });
    await database.insert('comparable_value_signals', {
      'signal_id': 'signal-1',
      'research_job_id': 'research-completed',
      'source_hit_id': 'hit-1',
      'kind': 'public_estimate',
      'label': 'Recorded estimate',
      'source_name': 'Synthetic source',
      'source_url': 'https://example.com/source',
      'amount_low': 'about 1,000',
      'amount_high': 'not reported',
      'currency': 'US dollars (reported)',
      'signal_date': time,
      'caveat': 'Not an appraisal',
    });
    await database.insert('external_references', {
      'reference_id': 'ref-1',
      'artwork_id': 'art-1',
      'reference_type': 'museum_or_institution',
      'label': null,
      'url': 'https://example.com/record',
      'origin': 'ai_suggestion',
      'review_state': 'suggested',
      'last_confirmed_at': null,
      'created_at': time,
      'updated_at': time,
      'sort_order': 0,
    });
  }

  Future<void> close() async {
    await database.close();
    await root.delete(recursive: true);
  }
}

BackupRecordBundle editBackupRow(
  BackupRecordBundle original,
  String table,
  int index,
  Map<String, Object?> patch,
) => BackupRecordBundle({
  for (final entry in original.tables.entries)
    entry.key: [
      for (var i = 0; i < entry.value.length; i++)
        if (entry.key == table && i == index)
          BackupRecordRow(table, {...entry.value[i].values, ...patch})
        else
          entry.value[i],
    ],
});

// Historical fixture DDL copied from the existing repository migration tests.
Future<void> _createV1Schema(Database db, int version) async {
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

  await db.execute(
    'CREATE INDEX artwork_fields_artwork_idx ON artwork_fields (artwork_id)',
  );
}

Future<void> _createV3Schema(Database db, int version) async {
  await _createV1Schema(db, version);

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

  await db.execute(
    'CREATE INDEX attachments_artwork_idx ON attachments (artwork_id)',
  );

  await db.execute('''
    CREATE TABLE ai_draft_jobs (
      draft_job_id TEXT PRIMARY KEY,
      artwork_id TEXT NOT NULL,
      primary_image_attachment_id TEXT,
      status TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      completed_at TEXT,
      device_model TEXT,
      prompt_version TEXT,
      visual_summary TEXT,
      signature_notes TEXT,
      subject_matter TEXT,
      medium_hint TEXT,
      style_period_hint TEXT,
      condition_notes TEXT,
      search_terms_json TEXT NOT NULL,
      error_message TEXT,
      FOREIGN KEY (artwork_id)
        REFERENCES artworks (artwork_id)
        ON DELETE CASCADE
    )
  ''');

  await db.execute(
    'CREATE INDEX ai_draft_jobs_artwork_idx ON ai_draft_jobs (artwork_id)',
  );

  await db.execute('''
    CREATE TABLE research_jobs (
      research_job_id TEXT PRIMARY KEY,
      artwork_id TEXT NOT NULL,
      status TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      completed_at TEXT,
      consent_summary TEXT NOT NULL,
      query_summary TEXT,
      provider TEXT,
      error_message TEXT,
      FOREIGN KEY (artwork_id)
        REFERENCES artworks (artwork_id)
        ON DELETE CASCADE
    )
  ''');

  await db.execute(
    'CREATE INDEX research_jobs_artwork_idx ON research_jobs (artwork_id)',
  );

  await db.execute('''
    CREATE TABLE research_source_hits (
      source_hit_id TEXT PRIMARY KEY,
      research_job_id TEXT NOT NULL,
      source_name TEXT NOT NULL,
      source_type TEXT NOT NULL,
      confidence TEXT NOT NULL,
      source_url TEXT,
      object_id TEXT,
      title TEXT,
      artist TEXT,
      date_text TEXT,
      medium TEXT,
      dimensions TEXT,
      image_url TEXT,
      match_reason TEXT,
      raw_snippet TEXT,
      FOREIGN KEY (research_job_id)
        REFERENCES research_jobs (research_job_id)
        ON DELETE CASCADE
    )
  ''');

  await db.execute('''
    CREATE TABLE candidate_attributions (
      candidate_id TEXT PRIMARY KEY,
      research_job_id TEXT NOT NULL,
      source_hit_id TEXT,
      title TEXT,
      artist TEXT,
      year TEXT,
      medium TEXT,
      confidence TEXT NOT NULL,
      match_reason TEXT NOT NULL,
      field_sources_json TEXT NOT NULL,
      FOREIGN KEY (research_job_id)
        REFERENCES research_jobs (research_job_id)
        ON DELETE CASCADE
    )
  ''');

  await db.execute('''
    CREATE TABLE comparable_value_signals (
      signal_id TEXT PRIMARY KEY,
      research_job_id TEXT NOT NULL,
      source_hit_id TEXT,
      kind TEXT NOT NULL,
      label TEXT NOT NULL,
      source_name TEXT NOT NULL,
      source_url TEXT,
      amount_low TEXT,
      amount_high TEXT,
      currency TEXT,
      signal_date TEXT,
      caveat TEXT NOT NULL,
      FOREIGN KEY (research_job_id)
        REFERENCES research_jobs (research_job_id)
        ON DELETE CASCADE
    )
    ''');
}

Future<void> _createV4Schema(Database db, int version) async {
  await _createV3Schema(db, version);
  await db.execute(
    "ALTER TABLE artworks ADD COLUMN lifecycle_status TEXT NOT NULL DEFAULT 'active'",
  );
}

Future<void> _createV5Schema(Database db, int version) async {
  await _createV4Schema(db, version);
  await db.execute('ALTER TABLE artwork_fields ADD COLUMN money_amount TEXT');
  await db.execute(
    'ALTER TABLE artwork_fields ADD COLUMN money_currency_code TEXT',
  );
}
