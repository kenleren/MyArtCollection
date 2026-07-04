import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'ai_research_record.dart';
import 'attachment_record.dart';
import 'artwork_record.dart';

class LocalArtworkRepository {
  LocalArtworkRepository._(this._database);
  LocalArtworkRepository.forDatabase(this._database);

  final Database _database;

  static const _databaseName = 'my_art_collection.db';
  static const _schemaVersion = 3;

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
  }

  static Future<void> _createAttachmentsSchema(Database db) async {
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

  Future<void> create(ArtworkRecord record) => upsert(record);

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
    final rows = await _database.query('artworks', orderBy: 'updated_at DESC');
    final records = <ArtworkRecord>[];

    for (final row in rows) {
      final id = row['artwork_id'] as String;
      records.add(_recordFromRows(row, await _fieldsForArtwork(id)));
    }

    return records;
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
    await _database.insert(
      'attachments',
      _attachmentRow(attachment),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<AttachmentRecord>> attachmentsForArtwork(String artworkId) async {
    final rows = await _database.query(
      'attachments',
      where: 'artwork_id = ?',
      whereArgs: [artworkId],
      orderBy: 'imported_at DESC',
    );

    return rows.map(_attachmentFromRow).toList();
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
      'file_name': attachment.fileName,
      'mime_type': attachment.mimeType,
      'file_size_bytes': attachment.fileSizeBytes,
      'imported_at': attachment.importedAt.toUtc().toIso8601String(),
      'captured_at': attachment.capturedAt?.toUtc().toIso8601String(),
      'source_state': attachment.source.label,
      'relative_path': attachment.relativePath,
      'checksum': attachment.checksum,
      'extraction_summary': attachment.extractionSummary,
      'notes': attachment.notes,
    };
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
      for (final row in rows)
        row['field_key'] as String: ArtworkFieldValue(
          value: row['value'] as String,
          source: ArtworkFieldSource.fromStorage(row['source_state'] as String),
          note: row['source_note'] as String,
          lastConfirmedAt: _parseDate(row['last_confirmed_at'] as String?),
        ),
    };
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
      createdAt: _parseRequiredDate(row['created_at'] as String),
      updatedAt: _parseRequiredDate(row['updated_at'] as String),
      primaryImageAttachmentId: row['primary_image_attachment_id'] as String?,
      fields: fields,
    );
  }

  AttachmentRecord _attachmentFromRow(Map<String, Object?> row) {
    return AttachmentRecord(
      id: row['attachment_id'] as String,
      artworkId: row['artwork_id'] as String,
      type: AttachmentType.fromStorage(row['attachment_type'] as String),
      fileName: row['file_name'] as String,
      mimeType: row['mime_type'] as String,
      fileSizeBytes: row['file_size_bytes'] as int,
      importedAt: _parseRequiredDate(row['imported_at'] as String),
      capturedAt: _parseDate(row['captured_at'] as String?),
      source: ArtworkFieldSource.fromStorage(row['source_state'] as String),
      relativePath: row['relative_path'] as String,
      checksum: row['checksum'] as String,
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
