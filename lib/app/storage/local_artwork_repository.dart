import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'ai_research_record.dart';
import 'attachment_record.dart';
import 'artwork_collection_query.dart';
import 'artwork_record.dart';

class LocalArtworkInsertConflictException implements Exception {
  LocalArtworkInsertConflictException(Iterable<String> artworkIds)
    : artworkIds = List.unmodifiable(artworkIds);

  final List<String> artworkIds;

  @override
  String toString() {
    final ids = artworkIds.join(', ');
    return 'Artwork records already exist or repeat in this import: $ids';
  }
}

enum AttachmentLineageFailure { missingSource, crossArtworkSource }

class AttachmentLineageException implements Exception {
  const AttachmentLineageException(this.failure, this.message);

  final AttachmentLineageFailure failure;
  final String message;

  @override
  String toString() => message;
}

class LocalArtworkRepository {
  LocalArtworkRepository._(this._database) : collectionSnapshotObserver = null;
  LocalArtworkRepository.forDatabase(
    this._database, {
    this.collectionSnapshotObserver,
  });

  final Database _database;
  final ArtworkCollectionSnapshotObserver? collectionSnapshotObserver;

  static const _databaseName = 'my_art_collection.db';
  static const _schemaVersion = 8;

  static Future<LocalArtworkRepository> open() async {
    final directory = await getApplicationDocumentsDirectory();
    final databasePath = p.join(directory.path, _databaseName);
    final database = await openAt(databasePath);
    return LocalArtworkRepository._(database);
  }

  static Future<Database> openAt(String path) {
    return openDatabase(
      path,
      version: _schemaVersion,
      onCreate: _createSchema,
      onUpgrade: _upgradeSchema,
    );
  }

  static Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE artworks (
        artwork_id TEXT PRIMARY KEY,
        record_state TEXT NOT NULL,
        lifecycle_status TEXT NOT NULL DEFAULT 'active',
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
        money_amount TEXT,
        money_currency_code TEXT,
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

    await _createAttachmentsSchema(db);
    await _createAiResearchSchema(db);
  }

  static Future<void> _upgradeSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await _createAttachmentsSchema(db);
    }
    if (oldVersion < 3) {
      await _createAiResearchSchema(db);
    }
    if (oldVersion < 4) {
      await db.execute(
        "ALTER TABLE artworks ADD COLUMN lifecycle_status TEXT NOT NULL DEFAULT 'active'",
      );
    }
    if (oldVersion < 5) {
      await db.execute(
        'ALTER TABLE artwork_fields ADD COLUMN money_amount TEXT',
      );
      await db.execute(
        'ALTER TABLE artwork_fields ADD COLUMN money_currency_code TEXT',
      );
    }
    if (oldVersion >= 2 && oldVersion < 6) {
      await db.execute(
        "ALTER TABLE attachments ADD COLUMN attachment_role TEXT NOT NULL DEFAULT 'supporting_document'",
      );
      await _backfillAttachmentRoles(db);
    }
    if (oldVersion >= 2 && oldVersion < 7) {
      await db.execute(
        'ALTER TABLE attachments ADD COLUMN derived_from_attachment_id TEXT',
      );
      await db.execute(
        'ALTER TABLE attachments ADD COLUMN transform_summary TEXT',
      );
    }
    if (oldVersion >= 2 && oldVersion < 8) {
      await db.execute(
        "ALTER TABLE attachments ADD COLUMN lifecycle_status TEXT NOT NULL DEFAULT 'active'",
      );
      await db.execute(
        'ALTER TABLE attachments ADD COLUMN lifecycle_updated_at TEXT',
      );
      await db.execute(
        'ALTER TABLE attachments ADD COLUMN superseded_by_attachment_id TEXT',
      );
    }
  }

  static Future<void> _createAttachmentsSchema(Database db) async {
    await db.execute('''
      CREATE TABLE attachments (
        attachment_id TEXT PRIMARY KEY,
        artwork_id TEXT NOT NULL,
        attachment_type TEXT NOT NULL,
        attachment_role TEXT NOT NULL,
        file_name TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        file_size_bytes INTEGER NOT NULL,
        imported_at TEXT NOT NULL,
        captured_at TEXT,
        source_state TEXT NOT NULL,
        relative_path TEXT NOT NULL,
        checksum TEXT NOT NULL,
        lifecycle_status TEXT NOT NULL DEFAULT 'active',
        lifecycle_updated_at TEXT,
        superseded_by_attachment_id TEXT,
        derived_from_attachment_id TEXT,
        transform_summary TEXT,
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
  }

  static Future<void> _backfillAttachmentRoles(Database db) async {
    await db.rawUpdate('''
      UPDATE attachments
      SET attachment_role = 'primary_artwork_photo'
      WHERE attachment_type = 'photo'
        AND attachment_id IN (
          SELECT primary_image_attachment_id
          FROM artworks
          WHERE primary_image_attachment_id IS NOT NULL
        )
    ''');

    await db.rawUpdate('''
      UPDATE attachments
      SET attachment_role = 'supporting_photo'
      WHERE attachment_type = 'photo'
        AND attachment_role != 'primary_artwork_photo'
    ''');
  }

  static Future<void> _createAiResearchSchema(Database db) async {
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

  Future<void> close() => _database.close();

  Future<void> create(ArtworkRecord record) => createAll([record]);

  Future<void> createAll(Iterable<ArtworkRecord> records) async {
    final batch = List<ArtworkRecord>.unmodifiable(records);
    if (batch.isEmpty) {
      return;
    }

    final batchIds = <String>{};
    final repeatedBatchIds = <String>{};
    for (final record in batch) {
      if (!batchIds.add(record.id)) {
        repeatedBatchIds.add(record.id);
      }
    }
    if (repeatedBatchIds.isNotEmpty) {
      throw LocalArtworkInsertConflictException(repeatedBatchIds);
    }

    await _database.transaction((txn) async {
      final existingIds = await _existingArtworkIds(txn, batchIds);
      if (existingIds.isNotEmpty) {
        throw LocalArtworkInsertConflictException(existingIds);
      }

      for (final record in batch) {
        await _insertRecord(txn, record);
      }
    });
  }

  Future<void> upsert(ArtworkRecord record) async {
    await _database.transaction((txn) async {
      await txn.insert(
        'artworks',
        _recordRow(record),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      await txn.delete(
        'artwork_fields',
        where: 'artwork_id = ?',
        whereArgs: [record.id],
      );

      for (final entry in record.fields.entries) {
        await txn.insert('artwork_fields', _fieldRow(record.id, entry));
      }
    });
  }

  Future<void> _insertRecord(Transaction txn, ArtworkRecord record) async {
    await txn.insert('artworks', _recordRow(record));

    for (final entry in record.fields.entries) {
      await txn.insert('artwork_fields', _fieldRow(record.id, entry));
    }
  }

  Future<Set<String>> _existingArtworkIds(
    Transaction txn,
    Set<String> artworkIds,
  ) async {
    final rows = await txn.query(
      'artworks',
      columns: ['artwork_id'],
      where: 'artwork_id IN (${List.filled(artworkIds.length, '?').join(',')})',
      whereArgs: artworkIds.toList(growable: false),
    );

    return rows.map((row) => row['artwork_id'] as String).toSet();
  }

  Future<ArtworkRecord?> get(String id) async {
    final rows = await _database.query(
      'artworks',
      where: 'artwork_id = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (rows.isEmpty) {
      return null;
    }

    final fields = await _fieldsForArtwork(id);
    return _recordFromRows(rows.single, fields);
  }

  Future<List<ArtworkRecord>> list() async {
    final snapshot = await queryCollection();
    return snapshot.entries
        .map((entry) => entry.record)
        .toList(growable: false);
  }

  Future<ArtworkCollectionSnapshot> queryCollection({
    ArtworkCollectionQuery query = const ArtworkCollectionQuery(),
  }) async {
    collectionSnapshotObserver?.onRead(ArtworkCollectionSnapshotRead.artworks);
    final artworkRows = await _database.query('artworks');
    if (artworkRows.isEmpty) {
      return const ArtworkCollectionSnapshot(
        entries: [],
        totalRecordCount: 0,
        activeRecordCount: 0,
        availableLocations: [],
      );
    }

    final artworkIds = artworkRows
        .map((row) => row['artwork_id'] as String)
        .toList(growable: false);
    final placeholders = List.filled(artworkIds.length, '?').join(',');
    collectionSnapshotObserver?.onRead(ArtworkCollectionSnapshotRead.fields);
    final fieldRows = await _database.query(
      'artwork_fields',
      where: 'artwork_id IN ($placeholders)',
      whereArgs: artworkIds,
      orderBy: 'artwork_id ASC, field_key ASC',
    );
    collectionSnapshotObserver?.onRead(
      ArtworkCollectionSnapshotRead.acceptedAttachmentRoles,
    );
    final attachmentRows = await _database.query(
      'attachments',
      where: 'artwork_id IN ($placeholders) AND attachment_role IN (?, ?, ?)',
      whereArgs: [
        ...artworkIds,
        AttachmentRole.primaryArtworkPhoto.storageValue,
        AttachmentRole.supportingPhoto.storageValue,
        AttachmentRole.supportingDocument.storageValue,
      ],
      orderBy: 'artwork_id ASC, imported_at DESC',
    );

    final fieldsByArtwork = <String, Map<String, ArtworkFieldValue>>{};
    for (final row in fieldRows) {
      final artworkId = row['artwork_id'] as String;
      fieldsByArtwork.putIfAbsent(artworkId, () => {})[row['field_key']
          as String] = _fieldFromRow(
        row,
      );
    }
    final attachmentsByArtwork = <String, List<AttachmentRecord>>{};
    for (final row in attachmentRows) {
      final artworkId = row['artwork_id'] as String;
      attachmentsByArtwork
          .putIfAbsent(artworkId, () => [])
          .add(_attachmentFromRow(row));
    }

    final allEntries = artworkRows
        .map((row) {
          final artworkId = row['artwork_id'] as String;
          return ArtworkCollectionEntry(
            record: _recordFromRows(
              row,
              fieldsByArtwork[artworkId] ?? const {},
            ),
            acceptedAttachments: List.unmodifiable(
              attachmentsByArtwork[artworkId] ?? const [],
            ),
          );
        })
        .toList(growable: false);
    final availableLocations = _availableCollectionLocations(allEntries);
    final entries = allEntries
        .where((entry) => _matchesCollectionQuery(entry, query))
        .toList();
    entries.sort(
      (left, right) => _compareCollectionEntries(left, right, query.sort),
    );

    return ArtworkCollectionSnapshot(
      entries: List.unmodifiable(entries),
      totalRecordCount: allEntries.length,
      activeRecordCount: allEntries
          .where(
            (entry) =>
                entry.record.lifecycleStatus == ArtworkLifecycleStatus.active,
          )
          .length,
      availableLocations: availableLocations,
    );
  }

  Future<void> delete(String id) async {
    await _database.transaction((txn) async {
      final researchJobRows = await txn.query(
        'research_jobs',
        columns: ['research_job_id'],
        where: 'artwork_id = ?',
        whereArgs: [id],
      );
      final researchJobIds = researchJobRows
          .map((row) => row['research_job_id'] as String)
          .toList();

      for (final researchJobId in researchJobIds) {
        await txn.delete(
          'research_source_hits',
          where: 'research_job_id = ?',
          whereArgs: [researchJobId],
        );
        await txn.delete(
          'candidate_attributions',
          where: 'research_job_id = ?',
          whereArgs: [researchJobId],
        );
        await txn.delete(
          'comparable_value_signals',
          where: 'research_job_id = ?',
          whereArgs: [researchJobId],
        );
      }

      await txn.delete('attachments', where: 'artwork_id = ?', whereArgs: [id]);
      await txn.delete(
        'ai_draft_jobs',
        where: 'artwork_id = ?',
        whereArgs: [id],
      );
      await txn.delete(
        'research_jobs',
        where: 'artwork_id = ?',
        whereArgs: [id],
      );
      await txn.delete(
        'artwork_fields',
        where: 'artwork_id = ?',
        whereArgs: [id],
      );
      await txn.delete('artworks', where: 'artwork_id = ?', whereArgs: [id]);
    });
  }

  Future<void> addAttachment(AttachmentRecord attachment) async {
    await _database.transaction((txn) async {
      await _validateAttachmentLineage(txn, attachment);
      await txn.insert(
        'attachments',
        _attachmentRow(attachment),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<List<AttachmentRecord>> attachmentsForArtwork(String artworkId) async {
    final rows = await _database.query(
      'attachments',
      where: "artwork_id = ? AND lifecycle_status IN ('active', 'unavailable')",
      whereArgs: [artworkId],
      orderBy: 'imported_at DESC',
    );

    return rows.map(_attachmentFromRow).toList();
  }

  Future<List<AttachmentRecord>> allAttachmentsForArtwork(
    String artworkId,
  ) async {
    final rows = await _database.query(
      'attachments',
      where: 'artwork_id = ?',
      whereArgs: [artworkId],
      orderBy: 'imported_at DESC',
    );
    return rows.map(_attachmentFromRow).toList();
  }

  Future<void> updateAttachmentLifecycle({
    required String attachmentId,
    required AttachmentLifecycleStatus lifecycleStatus,
    required DateTime updatedAt,
    String? supersededByAttachmentId,
  }) async {
    await _database.update(
      'attachments',
      {
        'lifecycle_status': lifecycleStatus.storageValue,
        'lifecycle_updated_at': updatedAt.toUtc().toIso8601String(),
        'superseded_by_attachment_id': supersededByAttachmentId,
      },
      where: 'attachment_id = ?',
      whereArgs: [attachmentId],
    );
  }

  Future<void> replaceAttachment({
    required String previousAttachmentId,
    required AttachmentRecord replacement,
    required DateTime replacedAt,
  }) async {
    await _database.transaction((txn) async {
      final previousRows = await txn.query(
        'attachments',
        where: 'attachment_id = ?',
        whereArgs: [previousAttachmentId],
        limit: 1,
      );
      if (previousRows.isEmpty ||
          previousRows.single['artwork_id'] != replacement.artworkId) {
        throw StateError('The supporting attachment is no longer available.');
      }
      await _validateAttachmentLineage(txn, replacement);
      await txn.insert('attachments', _attachmentRow(replacement));
      await txn.update(
        'attachments',
        {
          'lifecycle_status': AttachmentLifecycleStatus.superseded.storageValue,
          'lifecycle_updated_at': replacedAt.toUtc().toIso8601String(),
          'superseded_by_attachment_id': replacement.id,
        },
        where: 'attachment_id = ?',
        whereArgs: [previousAttachmentId],
      );
    });
  }

  Future<AttachmentRecord?> getAttachment(String attachmentId) async {
    final rows = await _database.query(
      'attachments',
      where: 'attachment_id = ?',
      whereArgs: [attachmentId],
      limit: 1,
    );

    return rows.isEmpty ? null : _attachmentFromRow(rows.single);
  }

  Future<void> upsertAiDraftJob(AiDraftJob job) async {
    await _database.insert(
      'ai_draft_jobs',
      _aiDraftJobRow(job),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<AiDraftJob?> getAiDraftJob(String jobId) async {
    final rows = await _database.query(
      'ai_draft_jobs',
      where: 'draft_job_id = ?',
      whereArgs: [jobId],
      limit: 1,
    );

    return rows.isEmpty ? null : _aiDraftJobFromRow(rows.single);
  }

  Future<List<AiDraftJob>> aiDraftJobsForArtwork(String artworkId) async {
    final rows = await _database.query(
      'ai_draft_jobs',
      where: 'artwork_id = ?',
      whereArgs: [artworkId],
      orderBy: 'updated_at DESC',
    );

    return rows.map(_aiDraftJobFromRow).toList();
  }

  Future<void> upsertResearchJob(ResearchJob job) async {
    await _database.transaction((txn) async {
      await txn.insert(
        'research_jobs',
        _researchJobRow(job),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      await txn.delete(
        'research_source_hits',
        where: 'research_job_id = ?',
        whereArgs: [job.id],
      );
      await txn.delete(
        'candidate_attributions',
        where: 'research_job_id = ?',
        whereArgs: [job.id],
      );
      await txn.delete(
        'comparable_value_signals',
        where: 'research_job_id = ?',
        whereArgs: [job.id],
      );

      for (final sourceHit in job.sourceHits) {
        await txn.insert('research_source_hits', _sourceHitRow(sourceHit));
      }
      for (final candidate in job.candidateAttributions) {
        await txn.insert(
          'candidate_attributions',
          _candidateAttributionRow(candidate),
        );
      }
      for (final signal in job.comparableValueSignals) {
        await txn.insert(
          'comparable_value_signals',
          _comparableValueSignalRow(signal),
        );
      }
    });
  }

  Future<ResearchJob?> getResearchJob(String jobId) async {
    final rows = await _database.query(
      'research_jobs',
      where: 'research_job_id = ?',
      whereArgs: [jobId],
      limit: 1,
    );

    return rows.isEmpty ? null : _researchJobFromRow(rows.single);
  }

  Future<List<ResearchJob>> researchJobsForArtwork(String artworkId) async {
    final rows = await _database.query(
      'research_jobs',
      where: 'artwork_id = ?',
      whereArgs: [artworkId],
      orderBy: 'updated_at DESC',
    );

    final jobs = <ResearchJob>[];
    for (final row in rows) {
      jobs.add(await _researchJobFromRow(row));
    }
    return jobs;
  }

  Map<String, Object?> _recordRow(ArtworkRecord record) {
    return {
      'artwork_id': record.id,
      'record_state': record.recordState.name,
      'lifecycle_status': record.lifecycleStatus.storageValue,
      'primary_image_attachment_id': record.primaryImageAttachmentId,
      'created_at': record.createdAt.toUtc().toIso8601String(),
      'updated_at': record.updatedAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _fieldRow(
    String artworkId,
    MapEntry<String, ArtworkFieldValue> entry,
  ) {
    final field = entry.value;

    return {
      'artwork_id': artworkId,
      'field_key': entry.key,
      'value': field.value,
      'money_amount': field.moneyAmount,
      'money_currency_code': field.moneyCurrencyCode,
      'source_state': field.source.label,
      'source_note': field.note,
      'last_confirmed_at': field.lastConfirmedAt?.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _attachmentRow(AttachmentRecord attachment) {
    return {
      'attachment_id': attachment.id,
      'artwork_id': attachment.artworkId,
      'attachment_type': attachment.type.storageValue,
      'attachment_role': attachment.role.storageValue,
      'file_name': attachment.fileName,
      'mime_type': attachment.mimeType,
      'file_size_bytes': attachment.fileSizeBytes,
      'imported_at': attachment.importedAt.toUtc().toIso8601String(),
      'captured_at': attachment.capturedAt?.toUtc().toIso8601String(),
      'derived_from_attachment_id': attachment.derivedFromAttachmentId,
      'transform_summary': attachment.transformSummary,
      'source_state': attachment.source.label,
      'relative_path': attachment.relativePath,
      'checksum': attachment.checksum,
      'lifecycle_status': attachment.lifecycleStatus.storageValue,
      'lifecycle_updated_at': attachment.lifecycleUpdatedAt
          ?.toUtc()
          .toIso8601String(),
      'superseded_by_attachment_id': attachment.supersededByAttachmentId,
      'extraction_summary': attachment.extractionSummary,
      'notes': attachment.notes,
    };
  }

  Future<void> _validateAttachmentLineage(
    Transaction txn,
    AttachmentRecord attachment,
  ) async {
    final sourceAttachmentId = attachment.derivedFromAttachmentId;
    if (sourceAttachmentId == null) {
      return;
    }

    final sourceRows = await txn.query(
      'attachments',
      columns: ['artwork_id'],
      where: 'attachment_id = ?',
      whereArgs: [sourceAttachmentId],
      limit: 1,
    );

    if (sourceRows.isEmpty) {
      throw AttachmentLineageException(
        AttachmentLineageFailure.missingSource,
        'Attachment ${attachment.id} cannot derive from missing attachment '
        '$sourceAttachmentId.',
      );
    }

    final sourceArtworkId = sourceRows.single['artwork_id'] as String;
    if (sourceArtworkId != attachment.artworkId) {
      throw AttachmentLineageException(
        AttachmentLineageFailure.crossArtworkSource,
        'Attachment ${attachment.id} can only derive from an attachment in '
        'the same artwork.',
      );
    }
  }

  Map<String, Object?> _aiDraftJobRow(AiDraftJob job) {
    return {
      'draft_job_id': job.id,
      'artwork_id': job.artworkId,
      'primary_image_attachment_id': job.primaryImageAttachmentId,
      'status': job.status.storageValue,
      'created_at': job.createdAt.toUtc().toIso8601String(),
      'updated_at': job.updatedAt.toUtc().toIso8601String(),
      'completed_at': job.completedAt?.toUtc().toIso8601String(),
      'device_model': job.deviceModel,
      'prompt_version': job.promptVersion,
      'visual_summary': job.visualSummary,
      'signature_notes': job.signatureNotes,
      'subject_matter': job.subjectMatter,
      'medium_hint': job.mediumHint,
      'style_period_hint': job.stylePeriodHint,
      'condition_notes': job.conditionNotes,
      'search_terms_json': jsonEncode(job.searchTerms),
      'error_message': job.errorMessage,
    };
  }

  Map<String, Object?> _researchJobRow(ResearchJob job) {
    return {
      'research_job_id': job.id,
      'artwork_id': job.artworkId,
      'status': job.status.storageValue,
      'created_at': job.createdAt.toUtc().toIso8601String(),
      'updated_at': job.updatedAt.toUtc().toIso8601String(),
      'completed_at': job.completedAt?.toUtc().toIso8601String(),
      'consent_summary': job.consentSummary,
      'query_summary': job.querySummary,
      'provider': job.provider,
      'error_message': job.errorMessage,
    };
  }

  Map<String, Object?> _sourceHitRow(ResearchSourceHit hit) {
    return {
      'source_hit_id': hit.id,
      'research_job_id': hit.researchJobId,
      'source_name': hit.sourceName,
      'source_type': hit.sourceType.storageValue,
      'confidence': hit.confidence.storageValue,
      'source_url': hit.sourceUrl,
      'object_id': hit.objectId,
      'title': hit.title,
      'artist': hit.artist,
      'date_text': hit.dateText,
      'medium': hit.medium,
      'dimensions': hit.dimensions,
      'image_url': hit.imageUrl,
      'match_reason': hit.matchReason,
      'raw_snippet': hit.rawSnippet,
    };
  }

  Map<String, Object?> _candidateAttributionRow(
    CandidateAttribution candidate,
  ) {
    return {
      'candidate_id': candidate.id,
      'research_job_id': candidate.researchJobId,
      'source_hit_id': candidate.sourceHitId,
      'title': candidate.title,
      'artist': candidate.artist,
      'year': candidate.year,
      'medium': candidate.medium,
      'confidence': candidate.confidence.storageValue,
      'match_reason': candidate.matchReason,
      'field_sources_json': jsonEncode({
        for (final entry in candidate.fieldSources.entries)
          entry.key: entry.value.label,
      }),
    };
  }

  Map<String, Object?> _comparableValueSignalRow(ComparableValueSignal signal) {
    return {
      'signal_id': signal.id,
      'research_job_id': signal.researchJobId,
      'source_hit_id': signal.sourceHitId,
      'kind': signal.kind.storageValue,
      'label': signal.label,
      'source_name': signal.sourceName,
      'source_url': signal.sourceUrl,
      'amount_low': signal.amountLow,
      'amount_high': signal.amountHigh,
      'currency': signal.currency,
      'signal_date': signal.signalDate?.toUtc().toIso8601String(),
      'caveat': signal.caveat,
    };
  }

  Future<Map<String, ArtworkFieldValue>> _fieldsForArtwork(String id) async {
    final rows = await _database.query(
      'artwork_fields',
      where: 'artwork_id = ?',
      whereArgs: [id],
      orderBy: 'field_key ASC',
    );

    return {
      for (final row in rows) row['field_key'] as String: _fieldFromRow(row),
    };
  }

  ArtworkFieldValue _fieldFromRow(Map<String, Object?> row) {
    return ArtworkFieldValue(
      value: row['value'] as String,
      source: ArtworkFieldSource.fromStorage(row['source_state'] as String),
      note: row['source_note'] as String,
      lastConfirmedAt: _parseDate(row['last_confirmed_at'] as String?),
      moneyAmount: row['money_amount'] as String?,
      moneyCurrencyCode: row['money_currency_code'] as String?,
    );
  }

  ArtworkRecord _recordFromRows(
    Map<String, Object?> row,
    Map<String, ArtworkFieldValue> fields,
  ) {
    return ArtworkRecord(
      id: row['artwork_id'] as String,
      recordState: ArtworkRecordState.fromStorage(
        row['record_state'] as String,
      ),
      lifecycleStatus: ArtworkLifecycleStatus.fromStorage(
        row['lifecycle_status'] as String?,
      ),
      createdAt: _parseRequiredDate(row['created_at'] as String),
      updatedAt: _parseRequiredDate(row['updated_at'] as String),
      primaryImageAttachmentId: row['primary_image_attachment_id'] as String?,
      fields: fields,
    );
  }

  AttachmentRecord _attachmentFromRow(Map<String, Object?> row) {
    final type = AttachmentType.fromStorage(row['attachment_type'] as String);

    return AttachmentRecord(
      id: row['attachment_id'] as String,
      artworkId: row['artwork_id'] as String,
      type: type,
      role: AttachmentRole.fromStorage(row['attachment_role'] as String?, type),
      fileName: row['file_name'] as String,
      mimeType: row['mime_type'] as String,
      fileSizeBytes: row['file_size_bytes'] as int,
      importedAt: _parseRequiredDate(row['imported_at'] as String),
      capturedAt: _parseDate(row['captured_at'] as String?),
      derivedFromAttachmentId: row['derived_from_attachment_id'] as String?,
      transformSummary: row['transform_summary'] as String?,
      source: ArtworkFieldSource.fromStorage(row['source_state'] as String),
      relativePath: row['relative_path'] as String,
      checksum: row['checksum'] as String,
      lifecycleStatus: AttachmentLifecycleStatus.fromStorage(
        row['lifecycle_status'] as String?,
      ),
      lifecycleUpdatedAt: _parseDate(row['lifecycle_updated_at'] as String?),
      supersededByAttachmentId: row['superseded_by_attachment_id'] as String?,
      extractionSummary: row['extraction_summary'] as String?,
      notes: row['notes'] as String?,
    );
  }

  AiDraftJob _aiDraftJobFromRow(Map<String, Object?> row) {
    return AiDraftJob(
      id: row['draft_job_id'] as String,
      artworkId: row['artwork_id'] as String,
      primaryImageAttachmentId: row['primary_image_attachment_id'] as String?,
      status: AiDraftJobStatus.fromStorage(row['status'] as String),
      createdAt: _parseRequiredDate(row['created_at'] as String),
      updatedAt: _parseRequiredDate(row['updated_at'] as String),
      completedAt: _parseDate(row['completed_at'] as String?),
      deviceModel: row['device_model'] as String?,
      promptVersion: row['prompt_version'] as String?,
      visualSummary: row['visual_summary'] as String?,
      signatureNotes: row['signature_notes'] as String?,
      subjectMatter: row['subject_matter'] as String?,
      mediumHint: row['medium_hint'] as String?,
      stylePeriodHint: row['style_period_hint'] as String?,
      conditionNotes: row['condition_notes'] as String?,
      searchTerms: _stringListFromJson(row['search_terms_json'] as String),
      errorMessage: row['error_message'] as String?,
    );
  }

  Future<ResearchJob> _researchJobFromRow(Map<String, Object?> row) async {
    final jobId = row['research_job_id'] as String;

    return ResearchJob(
      id: jobId,
      artworkId: row['artwork_id'] as String,
      status: ResearchJobStatus.fromStorage(row['status'] as String),
      createdAt: _parseRequiredDate(row['created_at'] as String),
      updatedAt: _parseRequiredDate(row['updated_at'] as String),
      completedAt: _parseDate(row['completed_at'] as String?),
      consentSummary: row['consent_summary'] as String,
      querySummary: row['query_summary'] as String?,
      provider: row['provider'] as String?,
      errorMessage: row['error_message'] as String?,
      sourceHits: await _sourceHitsForResearchJob(jobId),
      candidateAttributions: await _candidateAttributionsForResearchJob(jobId),
      comparableValueSignals: await _comparableSignalsForResearchJob(jobId),
    );
  }

  Future<List<ResearchSourceHit>> _sourceHitsForResearchJob(
    String researchJobId,
  ) async {
    final rows = await _database.query(
      'research_source_hits',
      where: 'research_job_id = ?',
      whereArgs: [researchJobId],
      orderBy: 'source_name ASC, source_hit_id ASC',
    );

    return rows.map(_sourceHitFromRow).toList();
  }

  Future<List<CandidateAttribution>> _candidateAttributionsForResearchJob(
    String researchJobId,
  ) async {
    final rows = await _database.query(
      'candidate_attributions',
      where: 'research_job_id = ?',
      whereArgs: [researchJobId],
      orderBy: 'candidate_id ASC',
    );

    return rows.map(_candidateAttributionFromRow).toList();
  }

  Future<List<ComparableValueSignal>> _comparableSignalsForResearchJob(
    String researchJobId,
  ) async {
    final rows = await _database.query(
      'comparable_value_signals',
      where: 'research_job_id = ?',
      whereArgs: [researchJobId],
      orderBy: 'signal_id ASC',
    );

    return rows.map(_comparableValueSignalFromRow).toList();
  }

  ResearchSourceHit _sourceHitFromRow(Map<String, Object?> row) {
    return ResearchSourceHit(
      id: row['source_hit_id'] as String,
      researchJobId: row['research_job_id'] as String,
      sourceName: row['source_name'] as String,
      sourceType: ResearchSourceType.fromStorage(row['source_type'] as String),
      confidence: ResearchConfidence.fromStorage(row['confidence'] as String),
      sourceUrl: row['source_url'] as String?,
      objectId: row['object_id'] as String?,
      title: row['title'] as String?,
      artist: row['artist'] as String?,
      dateText: row['date_text'] as String?,
      medium: row['medium'] as String?,
      dimensions: row['dimensions'] as String?,
      imageUrl: row['image_url'] as String?,
      matchReason: row['match_reason'] as String?,
      rawSnippet: row['raw_snippet'] as String?,
    );
  }

  CandidateAttribution _candidateAttributionFromRow(Map<String, Object?> row) {
    return CandidateAttribution(
      id: row['candidate_id'] as String,
      researchJobId: row['research_job_id'] as String,
      sourceHitId: row['source_hit_id'] as String?,
      title: row['title'] as String?,
      artist: row['artist'] as String?,
      year: row['year'] as String?,
      medium: row['medium'] as String?,
      confidence: ResearchConfidence.fromStorage(row['confidence'] as String),
      matchReason: row['match_reason'] as String,
      fieldSources: _fieldSourcesFromJson(row['field_sources_json'] as String),
    );
  }

  ComparableValueSignal _comparableValueSignalFromRow(
    Map<String, Object?> row,
  ) {
    return ComparableValueSignal(
      id: row['signal_id'] as String,
      researchJobId: row['research_job_id'] as String,
      sourceHitId: row['source_hit_id'] as String?,
      kind: ComparableValueKind.fromStorage(row['kind'] as String),
      label: row['label'] as String,
      sourceName: row['source_name'] as String,
      sourceUrl: row['source_url'] as String?,
      amountLow: row['amount_low'] as String?,
      amountHigh: row['amount_high'] as String?,
      currency: row['currency'] as String?,
      signalDate: _parseDate(row['signal_date'] as String?),
      caveat: row['caveat'] as String,
    );
  }

  static DateTime _parseRequiredDate(String value) {
    return DateTime.parse(value).toLocal();
  }

  static DateTime? _parseDate(String? value) {
    return value == null ? null : DateTime.parse(value).toLocal();
  }

  static List<String> _stringListFromJson(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! List) {
      return const [];
    }
    return decoded.whereType<String>().toList();
  }

  static Map<String, ArtworkFieldSource> _fieldSourcesFromJson(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic>) {
      return const {};
    }
    return {
      for (final entry in decoded.entries)
        if (entry.value is String)
          entry.key: ArtworkFieldSource.fromStorage(entry.value as String),
    };
  }
}

List<String> _availableCollectionLocations(
  List<ArtworkCollectionEntry> entries,
) {
  final valuesByNormalizedLocation = <String, String>{};
  for (final entry in entries) {
    final value = entry.record
        .field(ArtworkFieldKeys.currentLocation)
        ?.value
        .trim();
    if (value == null || value.isEmpty) {
      continue;
    }
    valuesByNormalizedLocation.putIfAbsent(
      normalizedCollectionText(value),
      () => value,
    );
  }
  final values = valuesByNormalizedLocation.values.toList();
  values.sort((left, right) {
    final normalized = normalizedCollectionText(
      left,
    ).compareTo(normalizedCollectionText(right));
    return normalized != 0 ? normalized : left.compareTo(right);
  });
  return List.unmodifiable(values);
}

bool _matchesCollectionQuery(
  ArtworkCollectionEntry entry,
  ArtworkCollectionQuery query,
) {
  final record = entry.record;
  final search = normalizedCollectionText(query.searchTerm);
  if (search.isNotEmpty) {
    const searchKeys = [
      ArtworkFieldKeys.title,
      ArtworkFieldKeys.artist,
      ArtworkFieldKeys.notes,
    ];
    final matchesSearch = searchKeys.any(
      (key) =>
          normalizedCollectionText(record.field(key)?.value).contains(search),
    );
    if (!matchesSearch) {
      return false;
    }
  }

  if (query.locations.isNotEmpty) {
    final selectedLocations = query.locations
        .map(normalizedCollectionText)
        .toSet();
    final location = normalizedCollectionText(
      record.field(ArtworkFieldKeys.currentLocation)?.value,
    );
    if (!selectedLocations.contains(location)) {
      return false;
    }
  }
  if (query.recordStates.isNotEmpty &&
      !query.recordStates.contains(record.recordState)) {
    return false;
  }
  if (query.lifecycleStatuses.isNotEmpty &&
      !query.lifecycleStatuses.contains(record.lifecycleStatus)) {
    return false;
  }
  if (query.missingSupportingRecords && !entry.isMissingSupportingRecords) {
    return false;
  }
  return true;
}

int _compareCollectionEntries(
  ArtworkCollectionEntry left,
  ArtworkCollectionEntry right,
  ArtworkCollectionSort sort,
) {
  final leftRecord = left.record;
  final rightRecord = right.record;
  final titleComparison = _compareDisplayValues(
    leftRecord.field(ArtworkFieldKeys.title)?.value,
    rightRecord.field(ArtworkFieldKeys.title)?.value,
  );

  int primaryComparison;
  int alternateComparison = 0;
  switch (sort) {
    case ArtworkCollectionSort.recentlyUpdated:
      primaryComparison = rightRecord.updatedAt.compareTo(leftRecord.updatedAt);
      break;
    case ArtworkCollectionSort.title:
      primaryComparison = titleComparison;
      alternateComparison = _compareDisplayValues(
        leftRecord.field(ArtworkFieldKeys.artist)?.value,
        rightRecord.field(ArtworkFieldKeys.artist)?.value,
      );
      break;
    case ArtworkCollectionSort.artist:
      primaryComparison = _compareDisplayValues(
        leftRecord.field(ArtworkFieldKeys.artist)?.value,
        rightRecord.field(ArtworkFieldKeys.artist)?.value,
      );
      alternateComparison = titleComparison;
      break;
    case ArtworkCollectionSort.acquisitionDate:
      final leftDate = _AcquisitionDate.tryParse(
        leftRecord.field(ArtworkFieldKeys.purchaseDate)?.value,
      );
      final rightDate = _AcquisitionDate.tryParse(
        rightRecord.field(ArtworkFieldKeys.purchaseDate)?.value,
      );
      primaryComparison = _compareAcquisitionDates(leftDate, rightDate);
      break;
  }

  if (primaryComparison != 0) {
    return primaryComparison;
  }
  if (sort == ArtworkCollectionSort.recentlyUpdated ||
      sort == ArtworkCollectionSort.acquisitionDate) {
    if (titleComparison != 0) {
      return titleComparison;
    }
  } else if (alternateComparison != 0) {
    return alternateComparison;
  }
  return leftRecord.id.compareTo(rightRecord.id);
}

int _compareDisplayValues(String? left, String? right) {
  final normalizedLeft = normalizedCollectionText(left);
  final normalizedRight = normalizedCollectionText(right);
  if (normalizedLeft.isEmpty != normalizedRight.isEmpty) {
    return normalizedLeft.isEmpty ? 1 : -1;
  }
  return normalizedLeft.compareTo(normalizedRight);
}

int _compareAcquisitionDates(_AcquisitionDate? left, _AcquisitionDate? right) {
  if (left == null || right == null) {
    if (left == null && right == null) {
      return 0;
    }
    return left == null ? 1 : -1;
  }
  final year = right.year.compareTo(left.year);
  if (year != 0) {
    return year;
  }
  final month = right.month.compareTo(left.month);
  if (month != 0) {
    return month;
  }
  return right.day.compareTo(left.day);
}

class _AcquisitionDate {
  const _AcquisitionDate(this.year, this.month, this.day);

  final int year;
  final int month;
  final int day;

  static _AcquisitionDate? tryParse(String? rawValue) {
    final value = rawValue?.trim() ?? '';
    final match = RegExp(
      r'^(\d{4})(?:-(\d{2})(?:-(\d{2}))?)?$',
    ).firstMatch(value);
    if (match == null) {
      return null;
    }
    final year = int.parse(match.group(1)!);
    final monthText = match.group(2);
    final dayText = match.group(3);
    if (year == 0) {
      return null;
    }
    if (monthText == null) {
      return _AcquisitionDate(year, 0, 0);
    }
    final month = int.parse(monthText);
    if (month < 1 || month > 12) {
      return null;
    }
    if (dayText == null) {
      return _AcquisitionDate(year, month, 0);
    }
    final day = int.parse(dayText);
    if (day < 1 || day > 31) {
      return null;
    }
    final parsed = DateTime.utc(year, month, day);
    if (parsed.year != year || parsed.month != month || parsed.day != day) {
      return null;
    }
    return _AcquisitionDate(year, month, day);
  }
}
