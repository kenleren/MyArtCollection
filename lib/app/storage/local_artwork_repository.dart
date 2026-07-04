import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'artwork_record.dart';

class LocalArtworkRepository {
  LocalArtworkRepository._(this._database);
  LocalArtworkRepository.forDatabase(this._database);

  final Database _database;

  static const _databaseName = 'my_art_collection.db';
  static const _schemaVersion = 1;

  static Future<LocalArtworkRepository> open() async {
    final directory = await getApplicationDocumentsDirectory();
    final databasePath = p.join(directory.path, _databaseName);
    final database = await openAt(databasePath);
    return LocalArtworkRepository._(database);
  }

  static Future<Database> openAt(String path) {
    return openDatabase(path, version: _schemaVersion, onCreate: _createSchema);
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
      await txn.delete(
        'artwork_fields',
        where: 'artwork_id = ?',
        whereArgs: [id],
      );
      await txn.delete('artworks', where: 'artwork_id = ?', whereArgs: [id]);
    });
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
      'source_state': field.source.name,
      'source_note': field.note,
      'last_confirmed_at': field.lastConfirmedAt?.toUtc().toIso8601String(),
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

  static DateTime _parseRequiredDate(String value) {
    return DateTime.parse(value).toLocal();
  }

  static DateTime? _parseDate(String? value) {
    return value == null ? null : DateTime.parse(value).toLocal();
  }
}
