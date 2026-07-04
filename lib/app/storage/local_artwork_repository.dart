import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'attachment_record.dart';
import 'artwork_record.dart';

class LocalArtworkRepository {
  LocalArtworkRepository._(this._database);
  LocalArtworkRepository.forDatabase(this._database);

  final Database _database;

  static const _databaseName = 'my_art_collection.db';
  static const _schemaVersion = 2;

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
  }

  static Future<void> _upgradeSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await _createAttachmentsSchema(db);
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
      await txn.delete('attachments', where: 'artwork_id = ?', whereArgs: [id]);
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

  static DateTime _parseRequiredDate(String value) {
    return DateTime.parse(value).toLocal();
  }

  static DateTime? _parseDate(String? value) {
    return value == null ? null : DateTime.parse(value).toLocal();
  }
}
