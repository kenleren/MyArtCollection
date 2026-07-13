part of 'local_artwork_repository.dart';

enum ExternalReferenceRepositoryFailure {
  duplicate,
  notFound,
  stale,
  invalidPermutation,
  invariant,
  capacity,
}

class ExternalReferenceRepositoryException implements Exception {
  const ExternalReferenceRepositoryException(this.failure, this.message);
  final ExternalReferenceRepositoryFailure failure;
  final String message;

  @override
  String toString() => message;
}

enum ExternalReferenceTransactionCheckpoint {
  reorderStaged,
  deleteRowRemoved,
  deleteSurvivorsStaged,
}

abstract class ExternalReferenceTransactionObserver {
  Future<void> onCheckpoint(ExternalReferenceTransactionCheckpoint checkpoint);
}

enum ExternalReferenceDeleteResult { deleted, notFound }

const _sqliteMaximumInteger = 9223372036854775807;

String _externalTimestampCheck(String column) =>
    "length($column) = 24 AND $column GLOB "
    "'[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T"
    "[0-9][0-9]:[0-9][0-9]:[0-9][0-9].[0-9][0-9][0-9]Z'";

Future<void> _createExternalReferencesSchema(Database db) async {
  await db.execute('''
    CREATE TABLE external_references (
      reference_id TEXT PRIMARY KEY
        CHECK (length(reference_id) BETWEEN 1 AND 128
          AND reference_id NOT GLOB '*[^A-Za-z0-9_-]*'),
      artwork_id TEXT NOT NULL
        CHECK (length(artwork_id) BETWEEN 1 AND 128
          AND artwork_id NOT GLOB '*[^A-Za-z0-9_-]*'),
      reference_type TEXT NOT NULL CHECK (reference_type IN (
        'gallery_or_artist', 'museum_or_institution',
        'auction_or_marketplace', 'exhibition_or_art_fair',
        'publication_or_catalogue', 'other'
      )),
      label TEXT CHECK (label IS NULL OR length(label) BETWEEN 1 AND 120),
      url TEXT NOT NULL CHECK (length(url) BETWEEN 1 AND 2048),
      origin TEXT NOT NULL CHECK (origin IN ('manual', 'ai_suggestion')),
      review_state TEXT NOT NULL CHECK (review_state IN ('suggested', 'confirmed')),
      last_confirmed_at TEXT CHECK (
        last_confirmed_at IS NULL OR (${_externalTimestampCheck('last_confirmed_at')})
      ),
      created_at TEXT NOT NULL CHECK (${_externalTimestampCheck('created_at')}),
      updated_at TEXT NOT NULL CHECK (${_externalTimestampCheck('updated_at')}),
      sort_order INTEGER NOT NULL CHECK (sort_order >= 0),
      FOREIGN KEY (artwork_id) REFERENCES artworks (artwork_id) ON DELETE CASCADE,
      UNIQUE (artwork_id, url),
      UNIQUE (artwork_id, sort_order),
      CHECK (
        (review_state = 'suggested' AND origin = 'ai_suggestion'
          AND last_confirmed_at IS NULL)
        OR (review_state = 'confirmed' AND last_confirmed_at IS NOT NULL)
      )
    )
  ''');
  await db.execute('''
    CREATE INDEX external_references_artwork_order_idx
    ON external_references (artwork_id, sort_order, created_at, reference_id)
  ''');
  await db.execute('''
    CREATE TRIGGER external_references_immutable_fields
    BEFORE UPDATE ON external_references
    WHEN NEW.reference_id != OLD.reference_id
      OR NEW.artwork_id != OLD.artwork_id
      OR NEW.origin != OLD.origin
      OR NEW.created_at != OLD.created_at
    BEGIN
      SELECT RAISE(ABORT, 'immutable external reference field');
    END
  ''');
}

extension ExternalReferencePersistence on LocalArtworkRepository {
  Future<List<ExternalReferenceRecord>> externalReferencesForArtwork(
    String artworkId,
  ) async {
    validateExternalReferenceId(artworkId);
    final rows = await _database.query(
      'external_references',
      where: 'artwork_id = ?',
      whereArgs: [artworkId],
      orderBy: 'sort_order ASC, created_at ASC, reference_id ASC',
    );
    return rows.map(_externalReferenceFromRow).toList(growable: false);
  }

  Future<ExternalReferenceRecord?> getExternalReference(
    String referenceId,
  ) async {
    validateExternalReferenceId(referenceId);
    final rows = await _database.query(
      'external_references',
      where: 'reference_id = ?',
      whereArgs: [referenceId],
      limit: 1,
    );
    return rows.isEmpty ? null : _externalReferenceFromRow(rows.single);
  }

  Future<ExternalReferenceRecord> addManualExternalReference({
    required String referenceId,
    required String artworkId,
    required ExternalReferenceType type,
    required String? label,
    required String url,
    required DateTime transactionTime,
  }) => _addExternalReference(
    referenceId: referenceId,
    artworkId: artworkId,
    type: type,
    label: label,
    url: url,
    origin: ExternalReferenceOrigin.manual,
    reviewState: ExternalReferenceReviewState.confirmed,
    transactionTime: transactionTime,
  );

  Future<ExternalReferenceRecord> saveExternalReferenceSuggestion({
    required String referenceId,
    required String artworkId,
    required ExternalReferenceType type,
    required String? label,
    required String url,
    required DateTime transactionTime,
  }) => _addExternalReference(
    referenceId: referenceId,
    artworkId: artworkId,
    type: type,
    label: label,
    url: url,
    origin: ExternalReferenceOrigin.aiSuggestion,
    reviewState: ExternalReferenceReviewState.suggested,
    transactionTime: transactionTime,
  );

  Future<ExternalReferenceRecord> _addExternalReference({
    required String referenceId,
    required String artworkId,
    required ExternalReferenceType type,
    required String? label,
    required String url,
    required ExternalReferenceOrigin origin,
    required ExternalReferenceReviewState reviewState,
    required DateTime transactionTime,
  }) async {
    validateExternalReferenceId(referenceId);
    validateExternalReferenceId(artworkId);
    final canonicalLabel = normalizeExternalReferenceLabel(label);
    final canonicalUrl = const ExternalReferenceUrlCodec().canonicalize(url);
    final timestamp = ExternalReferenceTimestampCodec.normalize(
      transactionTime,
    );
    late ExternalReferenceRecord inserted;
    await _database.transaction((txn) async {
      final duplicate = await txn.query(
        'external_references',
        columns: ['reference_id'],
        where: 'reference_id = ? OR (artwork_id = ? AND url = ?)',
        whereArgs: [referenceId, artworkId, canonicalUrl],
        limit: 1,
      );
      if (duplicate.isNotEmpty) throw _duplicate;
      final maximumRows = await txn.rawQuery(
        'SELECT MAX(sort_order) AS maximum_order '
        'FROM external_references WHERE artwork_id = ?',
        [artworkId],
      );
      final maximum = maximumRows.single['maximum_order'] as int?;
      if (maximum == _sqliteMaximumInteger) {
        throw const ExternalReferenceRepositoryException(
          ExternalReferenceRepositoryFailure.capacity,
          'No additional external reference position is available.',
        );
      }
      inserted = ExternalReferenceRecord(
        id: referenceId,
        artworkId: artworkId,
        type: type,
        label: canonicalLabel,
        url: canonicalUrl,
        origin: origin,
        reviewState: reviewState,
        lastConfirmedAt: reviewState == ExternalReferenceReviewState.confirmed
            ? timestamp
            : null,
        createdAt: timestamp,
        updatedAt: timestamp,
        sortOrder: maximum == null ? 0 : maximum + 1,
      );
      inserted.validateStructure();
      await txn.insert('external_references', _externalReferenceRow(inserted));
    });
    return inserted;
  }

  Future<ExternalReferenceRecord> confirmExternalReference({
    required String referenceId,
    required DateTime expectedUpdatedAt,
    required DateTime transactionTime,
  }) async {
    validateExternalReferenceId(referenceId);
    late ExternalReferenceRecord result;
    await _database.transaction((txn) async {
      final existing = await _loadExternalReference(txn, referenceId);
      if (existing == null) throw _notFound;
      _requireCurrent(existing, expectedUpdatedAt);
      if (existing.reviewState == ExternalReferenceReviewState.confirmed) {
        result = existing;
        return;
      }
      final timestamp = ExternalReferenceTimestampCodec.normalize(
        transactionTime,
      );
      final changed = await txn.update(
        'external_references',
        {
          'review_state': ExternalReferenceReviewState.confirmed.storageValue,
          'last_confirmed_at': ExternalReferenceTimestampCodec.format(
            timestamp,
          ),
          'updated_at': ExternalReferenceTimestampCodec.format(timestamp),
        },
        where: 'reference_id = ? AND updated_at = ? AND review_state = ?',
        whereArgs: [
          referenceId,
          existing.updatedAtText,
          ExternalReferenceReviewState.suggested.storageValue,
        ],
      );
      if (changed != 1) throw _stale;
      result = existing.copyWith(
        reviewState: ExternalReferenceReviewState.confirmed,
        lastConfirmedAt: timestamp,
        updatedAt: timestamp,
      );
    });
    return result;
  }

  Future<ExternalReferenceRecord> editExternalReference({
    required String referenceId,
    required ExternalReferenceType type,
    required String? label,
    required String url,
    required DateTime expectedUpdatedAt,
    required DateTime transactionTime,
  }) async {
    final canonicalLabel = normalizeExternalReferenceLabel(label);
    final canonicalUrl = const ExternalReferenceUrlCodec().canonicalize(url);
    late ExternalReferenceRecord result;
    await _database.transaction((txn) async {
      final existing = await _loadExternalReference(txn, referenceId);
      if (existing == null) throw _notFound;
      _requireCurrent(existing, expectedUpdatedAt);
      if (existing.type == type &&
          existing.label == canonicalLabel &&
          existing.url == canonicalUrl) {
        result = existing;
        return;
      }
      final duplicate = await txn.query(
        'external_references',
        columns: ['reference_id'],
        where: 'artwork_id = ? AND url = ? AND reference_id != ?',
        whereArgs: [existing.artworkId, canonicalUrl, referenceId],
        limit: 1,
      );
      if (duplicate.isNotEmpty) throw _duplicate;
      final timestamp = ExternalReferenceTimestampCodec.normalize(
        transactionTime,
      );
      final changed = await txn.update(
        'external_references',
        {
          'reference_type': type.storageValue,
          'label': canonicalLabel,
          'url': canonicalUrl,
          'review_state': ExternalReferenceReviewState.confirmed.storageValue,
          'last_confirmed_at': ExternalReferenceTimestampCodec.format(
            timestamp,
          ),
          'updated_at': ExternalReferenceTimestampCodec.format(timestamp),
        },
        where: 'reference_id = ? AND updated_at = ?',
        whereArgs: [referenceId, existing.updatedAtText],
      );
      if (changed != 1) throw _stale;
      result = existing.copyWith(
        type: type,
        label: canonicalLabel,
        clearLabel: canonicalLabel == null,
        url: canonicalUrl,
        reviewState: ExternalReferenceReviewState.confirmed,
        lastConfirmedAt: timestamp,
        updatedAt: timestamp,
      );
    });
    return result;
  }

  Future<void> reorderExternalReferences({
    required String artworkId,
    required List<String> orderedReferenceIds,
    required Map<String, DateTime> expectedUpdatedAtById,
    required DateTime transactionTime,
  }) async {
    validateExternalReferenceId(artworkId);
    await _database.transaction((txn) async {
      final current = await _referencesForArtwork(txn, artworkId);
      _validateDense(current);
      final requested = orderedReferenceIds.toSet();
      if (orderedReferenceIds.length != current.length ||
          requested.length != current.length ||
          !requested.containsAll(current.map((row) => row.id))) {
        throw const ExternalReferenceRepositoryException(
          ExternalReferenceRepositoryFailure.invalidPermutation,
          'Reorder requires every reference exactly once.',
        );
      }
      for (final row in current) {
        final expected = expectedUpdatedAtById[row.id];
        if (expected == null ||
            ExternalReferenceTimestampCodec.format(expected) !=
                row.updatedAtText) {
          throw _stale;
        }
      }
      final oldIndexes = {for (final row in current) row.id: row.sortOrder};
      final changed = <String, int>{};
      for (var index = 0; index < orderedReferenceIds.length; index++) {
        final id = orderedReferenceIds[index];
        if (oldIndexes[id] != index) changed[id] = index;
      }
      if (changed.isEmpty) return;
      ExternalReferenceOrderCapacity.validate(current.length, changed.values);
      for (final entry in changed.entries) {
        final affected = await txn.rawUpdate(
          'UPDATE external_references SET sort_order = ? '
          'WHERE reference_id = ? AND artwork_id = ?',
          [current.length + entry.value, entry.key, artworkId],
        );
        if (affected != 1) throw _stale;
      }
      await externalReferenceTransactionObserver?.onCheckpoint(
        ExternalReferenceTransactionCheckpoint.reorderStaged,
      );
      final timestamp = ExternalReferenceTimestampCodec.format(transactionTime);
      for (final entry in changed.entries) {
        final affected = await txn.rawUpdate(
          'UPDATE external_references SET sort_order = ?, updated_at = ? '
          'WHERE reference_id = ? AND artwork_id = ?',
          [entry.value, timestamp, entry.key, artworkId],
        );
        if (affected != 1) throw _stale;
      }
    });
  }

  Future<ExternalReferenceDeleteResult> deleteExternalReference({
    required String artworkId,
    required String referenceId,
    required DateTime expectedUpdatedAt,
    required DateTime transactionTime,
  }) async {
    validateExternalReferenceId(artworkId);
    validateExternalReferenceId(referenceId);
    return _database.transaction((txn) async {
      final current = await _referencesForArtwork(txn, artworkId);
      _validateDense(current);
      final index = current.indexWhere((row) => row.id == referenceId);
      if (index < 0) return ExternalReferenceDeleteResult.notFound;
      _requireCurrent(current[index], expectedUpdatedAt);
      final changed = current.skip(index + 1).toList(growable: false);
      ExternalReferenceOrderCapacity.validate(
        current.length,
        changed.map((row) => row.sortOrder - 1),
      );
      final deleted = await txn.delete(
        'external_references',
        where: 'reference_id = ? AND artwork_id = ? AND updated_at = ?',
        whereArgs: [referenceId, artworkId, current[index].updatedAtText],
      );
      if (deleted != 1) throw _stale;
      await externalReferenceTransactionObserver?.onCheckpoint(
        ExternalReferenceTransactionCheckpoint.deleteRowRemoved,
      );
      for (final survivor in changed) {
        final target = survivor.sortOrder - 1;
        final affected = await txn.rawUpdate(
          'UPDATE external_references SET sort_order = ? '
          'WHERE reference_id = ? AND artwork_id = ?',
          [current.length + target, survivor.id, artworkId],
        );
        if (affected != 1) throw _stale;
      }
      await externalReferenceTransactionObserver?.onCheckpoint(
        ExternalReferenceTransactionCheckpoint.deleteSurvivorsStaged,
      );
      final timestamp = ExternalReferenceTimestampCodec.format(transactionTime);
      for (final survivor in changed) {
        final affected = await txn.rawUpdate(
          'UPDATE external_references SET sort_order = ?, updated_at = ? '
          'WHERE reference_id = ? AND artwork_id = ?',
          [survivor.sortOrder - 1, timestamp, survivor.id, artworkId],
        );
        if (affected != 1) throw _stale;
      }
      return ExternalReferenceDeleteResult.deleted;
    });
  }

  Future<ExternalReferenceRecord?> _loadExternalReference(
    Transaction txn,
    String id,
  ) async {
    final rows = await txn.query(
      'external_references',
      where: 'reference_id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : _externalReferenceFromRow(rows.single);
  }

  Future<List<ExternalReferenceRecord>> _referencesForArtwork(
    Transaction txn,
    String artworkId,
  ) async {
    final rows = await txn.query(
      'external_references',
      where: 'artwork_id = ?',
      whereArgs: [artworkId],
      orderBy: 'sort_order ASC, created_at ASC, reference_id ASC',
    );
    return rows.map(_externalReferenceFromRow).toList(growable: false);
  }

  void _validateDense(List<ExternalReferenceRecord> rows) {
    final ids = <String>{};
    for (var index = 0; index < rows.length; index++) {
      if (!ids.add(rows[index].id) || rows[index].sortOrder != index) {
        throw const ExternalReferenceRepositoryException(
          ExternalReferenceRepositoryFailure.invariant,
          'Stored external reference order is not dense.',
        );
      }
    }
  }

  void _requireCurrent(ExternalReferenceRecord row, DateTime expected) {
    if (row.updatedAtText != ExternalReferenceTimestampCodec.format(expected)) {
      throw _stale;
    }
  }
}

abstract final class ExternalReferenceOrderCapacity {
  static void validate(int count, Iterable<int> targets) {
    final base = BigInt.from(count);
    final maximum = BigInt.from(_sqliteMaximumInteger);
    for (final target in targets) {
      if (base + BigInt.from(target) > maximum) {
        throw const ExternalReferenceRepositoryException(
          ExternalReferenceRepositoryFailure.capacity,
          'No temporary external reference position is available.',
        );
      }
    }
  }
}

Map<String, Object?> _externalReferenceRow(ExternalReferenceRecord record) => {
  'reference_id': record.id,
  'artwork_id': record.artworkId,
  'reference_type': record.type.storageValue,
  'label': record.label,
  'url': record.url,
  'origin': record.origin.storageValue,
  'review_state': record.reviewState.storageValue,
  'last_confirmed_at': record.lastConfirmedAtText,
  'created_at': record.createdAtText,
  'updated_at': record.updatedAtText,
  'sort_order': record.sortOrder,
};

ExternalReferenceRecord _externalReferenceFromRow(Map<String, Object?> row) {
  final record = ExternalReferenceRecord(
    id: row['reference_id'] as String,
    artworkId: row['artwork_id'] as String,
    type: ExternalReferenceType.parse(row['reference_type'] as String),
    label: row['label'] as String?,
    url: row['url'] as String,
    origin: ExternalReferenceOrigin.parse(row['origin'] as String),
    reviewState: ExternalReferenceReviewState.parse(
      row['review_state'] as String,
    ),
    lastConfirmedAt: row['last_confirmed_at'] == null
        ? null
        : ExternalReferenceTimestampCodec.parse(
            row['last_confirmed_at'] as String,
          ),
    createdAt: ExternalReferenceTimestampCodec.parse(
      row['created_at'] as String,
    ),
    updatedAt: ExternalReferenceTimestampCodec.parse(
      row['updated_at'] as String,
    ),
    sortOrder: row['sort_order'] as int,
  );
  record.validateStructure();
  final canonical = const ExternalReferenceUrlCodec().canonicalize(record.url);
  if (canonical != record.url ||
      normalizeExternalReferenceLabel(record.label) != record.label) {
    throw const ExternalReferenceRepositoryException(
      ExternalReferenceRepositoryFailure.invariant,
      'Stored external reference data is not canonical.',
    );
  }
  return record;
}

const _duplicate = ExternalReferenceRepositoryException(
  ExternalReferenceRepositoryFailure.duplicate,
  'This reference is already saved for the artwork.',
);
const _notFound = ExternalReferenceRepositoryException(
  ExternalReferenceRepositoryFailure.notFound,
  'The external reference is no longer available.',
);
const _stale = ExternalReferenceRepositoryException(
  ExternalReferenceRepositoryFailure.stale,
  'The external reference changed. Reload it and try again.',
);
