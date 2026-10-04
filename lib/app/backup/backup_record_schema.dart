import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../import/archive_inspection_json.dart';
import '../storage/artwork_group.dart';
import '../storage/external_reference.dart';
import '../external_references/external_reference_url_codec.dart';
import 'backup_record_bundle.dart';

class BackupColumn {
  const BackupColumn(this.name, this.type, this.nullable);
  final String name;
  final String type;
  final bool nullable;
}

class BackupTable {
  const BackupTable(this.name, this.keys, this.limit, this.columns);
  final String name;
  final List<String> keys;
  final int limit;
  final List<BackupColumn> columns;
}

const backupRecordTables = <BackupTable>[
  BackupTable(
    'artworks',
    ['artwork_id'],
    4096,
    [
      BackupColumn('artwork_id', 'TEXT', false),
      BackupColumn('record_state', 'TEXT', false),
      BackupColumn('lifecycle_status', 'TEXT', false),
      BackupColumn('primary_image_attachment_id', 'TEXT', true),
      BackupColumn('created_at', 'TEXT', false),
      BackupColumn('updated_at', 'TEXT', false),
    ],
  ),
  BackupTable(
    'artwork_fields',
    ['artwork_id', 'field_key'],
    65536,
    [
      BackupColumn('artwork_id', 'TEXT', false),
      BackupColumn('field_key', 'TEXT', false),
      BackupColumn('value', 'TEXT', false),
      BackupColumn('money_amount', 'TEXT', true),
      BackupColumn('money_currency_code', 'TEXT', true),
      BackupColumn('source_state', 'TEXT', false),
      BackupColumn('source_note', 'TEXT', false),
      BackupColumn('last_confirmed_at', 'TEXT', true),
    ],
  ),
  BackupTable(
    'artwork_groups',
    ['group_id'],
    1024,
    [
      BackupColumn('group_id', 'TEXT', false),
      BackupColumn('name', 'TEXT', false),
      BackupColumn('normalized_name', 'TEXT', false),
      BackupColumn('sort_order', 'INTEGER', false),
      BackupColumn('created_at', 'TEXT', false),
      BackupColumn('updated_at', 'TEXT', false),
    ],
  ),
  BackupTable(
    'artwork_group_memberships',
    ['artwork_id', 'group_id'],
    32768,
    [
      BackupColumn('artwork_id', 'TEXT', false),
      BackupColumn('group_id', 'TEXT', false),
      BackupColumn('created_at', 'TEXT', false),
    ],
  ),
  BackupTable(
    'artwork_preferences',
    ['artwork_id'],
    4096,
    [
      BackupColumn('artwork_id', 'TEXT', false),
      BackupColumn('is_favorite', 'INTEGER', false),
      BackupColumn('updated_at', 'TEXT', false),
    ],
  ),
  BackupTable(
    'attachments',
    ['attachment_id'],
    2048,
    [
      BackupColumn('attachment_id', 'TEXT', false),
      BackupColumn('artwork_id', 'TEXT', false),
      BackupColumn('attachment_type', 'TEXT', false),
      BackupColumn('attachment_role', 'TEXT', false),
      BackupColumn('file_name', 'TEXT', false),
      BackupColumn('mime_type', 'TEXT', false),
      BackupColumn('file_size_bytes', 'INTEGER', false),
      BackupColumn('imported_at', 'TEXT', false),
      BackupColumn('captured_at', 'TEXT', true),
      BackupColumn('source_state', 'TEXT', false),
      BackupColumn('relative_path', 'TEXT', false),
      BackupColumn('checksum', 'TEXT', false),
      BackupColumn('lifecycle_status', 'TEXT', false),
      BackupColumn('lifecycle_updated_at', 'TEXT', true),
      BackupColumn('superseded_by_attachment_id', 'TEXT', true),
      BackupColumn('derived_from_attachment_id', 'TEXT', true),
      BackupColumn('transform_summary', 'TEXT', true),
      BackupColumn('extraction_summary', 'TEXT', true),
      BackupColumn('notes', 'TEXT', true),
    ],
  ),
  BackupTable(
    'ai_draft_jobs',
    ['draft_job_id'],
    8192,
    [
      BackupColumn('draft_job_id', 'TEXT', false),
      BackupColumn('artwork_id', 'TEXT', false),
      BackupColumn('primary_image_attachment_id', 'TEXT', true),
      BackupColumn('status', 'TEXT', false),
      BackupColumn('created_at', 'TEXT', false),
      BackupColumn('updated_at', 'TEXT', false),
      BackupColumn('completed_at', 'TEXT', true),
      BackupColumn('device_model', 'TEXT', true),
      BackupColumn('prompt_version', 'TEXT', true),
      BackupColumn('visual_summary', 'TEXT', true),
      BackupColumn('signature_notes', 'TEXT', true),
      BackupColumn('subject_matter', 'TEXT', true),
      BackupColumn('medium_hint', 'TEXT', true),
      BackupColumn('style_period_hint', 'TEXT', true),
      BackupColumn('condition_notes', 'TEXT', true),
      BackupColumn('search_terms_json', 'TEXT', false),
      BackupColumn('error_message', 'TEXT', true),
    ],
  ),
  BackupTable(
    'research_jobs',
    ['research_job_id'],
    8192,
    [
      BackupColumn('research_job_id', 'TEXT', false),
      BackupColumn('artwork_id', 'TEXT', false),
      BackupColumn('status', 'TEXT', false),
      BackupColumn('created_at', 'TEXT', false),
      BackupColumn('updated_at', 'TEXT', false),
      BackupColumn('completed_at', 'TEXT', true),
      BackupColumn('consent_summary', 'TEXT', false),
      BackupColumn('query_summary', 'TEXT', true),
      BackupColumn('provider', 'TEXT', true),
      BackupColumn('error_message', 'TEXT', true),
    ],
  ),
  BackupTable(
    'research_source_hits',
    ['source_hit_id'],
    16384,
    [
      BackupColumn('source_hit_id', 'TEXT', false),
      BackupColumn('research_job_id', 'TEXT', false),
      BackupColumn('source_name', 'TEXT', false),
      BackupColumn('source_type', 'TEXT', false),
      BackupColumn('confidence', 'TEXT', false),
      BackupColumn('source_url', 'TEXT', true),
      BackupColumn('object_id', 'TEXT', true),
      BackupColumn('title', 'TEXT', true),
      BackupColumn('artist', 'TEXT', true),
      BackupColumn('date_text', 'TEXT', true),
      BackupColumn('medium', 'TEXT', true),
      BackupColumn('dimensions', 'TEXT', true),
      BackupColumn('image_url', 'TEXT', true),
      BackupColumn('match_reason', 'TEXT', true),
      BackupColumn('raw_snippet', 'TEXT', true),
    ],
  ),
  BackupTable(
    'candidate_attributions',
    ['candidate_id'],
    16384,
    [
      BackupColumn('candidate_id', 'TEXT', false),
      BackupColumn('research_job_id', 'TEXT', false),
      BackupColumn('source_hit_id', 'TEXT', true),
      BackupColumn('title', 'TEXT', true),
      BackupColumn('artist', 'TEXT', true),
      BackupColumn('year', 'TEXT', true),
      BackupColumn('medium', 'TEXT', true),
      BackupColumn('confidence', 'TEXT', false),
      BackupColumn('match_reason', 'TEXT', false),
      BackupColumn('field_sources_json', 'TEXT', false),
    ],
  ),
  BackupTable(
    'comparable_value_signals',
    ['signal_id'],
    16384,
    [
      BackupColumn('signal_id', 'TEXT', false),
      BackupColumn('research_job_id', 'TEXT', false),
      BackupColumn('source_hit_id', 'TEXT', true),
      BackupColumn('kind', 'TEXT', false),
      BackupColumn('label', 'TEXT', false),
      BackupColumn('source_name', 'TEXT', false),
      BackupColumn('source_url', 'TEXT', true),
      BackupColumn('amount_low', 'TEXT', true),
      BackupColumn('amount_high', 'TEXT', true),
      BackupColumn('currency', 'TEXT', true),
      BackupColumn('signal_date', 'TEXT', true),
      BackupColumn('caveat', 'TEXT', false),
    ],
  ),
  BackupTable(
    'external_references',
    ['reference_id'],
    16384,
    [
      BackupColumn('reference_id', 'TEXT', false),
      BackupColumn('artwork_id', 'TEXT', false),
      BackupColumn('reference_type', 'TEXT', false),
      BackupColumn('label', 'TEXT', true),
      BackupColumn('url', 'TEXT', false),
      BackupColumn('origin', 'TEXT', false),
      BackupColumn('review_state', 'TEXT', false),
      BackupColumn('last_confirmed_at', 'TEXT', true),
      BackupColumn('created_at', 'TEXT', false),
      BackupColumn('updated_at', 'TEXT', false),
      BackupColumn('sort_order', 'INTEGER', false),
    ],
  ),
];

final backupRecordSchemaDigest = sha256
    .convert(
      utf8.encode(
        jsonEncode([
          'archivale-record-component-v1',
          10,
          'history_only',
          'device_path_not_portable',
          backupRecordEnums,
          'wire_nodes_plus_embedded_nodes_v1',
          for (final t in backupRecordTables)
            [
              t.name,
              t.keys,
              t.limit,
              for (final c in t.columns) [c.name, c.type, c.nullable],
            ],
        ]),
      ),
    )
    .toString();

/// Known create/upgrade DDL; comparison preserves literals and ignores column order.
const backupSchemaSql = <String, String>{
  'artworks': r'''CREATE TABLE artworks (
        artwork_id TEXT PRIMARY KEY,
        record_state TEXT NOT NULL,
        lifecycle_status TEXT NOT NULL DEFAULT 'active',
        primary_image_attachment_id TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )''',
  'artwork_fields': r'''CREATE TABLE artwork_fields (
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
      )''',
  'artwork_groups': r'''CREATE TABLE artwork_groups (
      group_id TEXT PRIMARY KEY, name TEXT NOT NULL, normalized_name TEXT NOT NULL UNIQUE,
      sort_order INTEGER NOT NULL UNIQUE CHECK(sort_order >= 0),
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL)''',
  'artwork_group_memberships': r'''CREATE TABLE artwork_group_memberships (
      artwork_id TEXT NOT NULL, group_id TEXT NOT NULL, created_at TEXT NOT NULL,
      PRIMARY KEY (artwork_id, group_id),
      FOREIGN KEY (artwork_id) REFERENCES artworks (artwork_id) ON DELETE CASCADE,
      FOREIGN KEY (group_id) REFERENCES artwork_groups (group_id) ON DELETE CASCADE)''',
  'artwork_preferences': r'''CREATE TABLE artwork_preferences (
      artwork_id TEXT PRIMARY KEY, is_favorite INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL,
      FOREIGN KEY (artwork_id) REFERENCES artworks (artwork_id) ON DELETE CASCADE)''',
  'attachments': r'''CREATE TABLE attachments (
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
      )''',
  'ai_draft_jobs': r'''CREATE TABLE ai_draft_jobs (
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
      )''',
  'research_jobs': r'''CREATE TABLE research_jobs (
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
      )''',
  'research_source_hits': r'''CREATE TABLE research_source_hits (
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
      )''',
  'candidate_attributions': r'''CREATE TABLE candidate_attributions (
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
      )''',
  'comparable_value_signals': r'''CREATE TABLE comparable_value_signals (
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
      )''',
  'external_references': r'''CREATE TABLE external_references (
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
        last_confirmed_at IS NULL OR (length(last_confirmed_at) = 24 AND last_confirmed_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9].[0-9][0-9][0-9]Z')
      ),
      created_at TEXT NOT NULL CHECK (length(created_at) = 24 AND created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9].[0-9][0-9][0-9]Z'),
      updated_at TEXT NOT NULL CHECK (length(updated_at) = 24 AND updated_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9].[0-9][0-9][0-9]Z'),
      sort_order INTEGER NOT NULL CHECK (sort_order >= 0),
      FOREIGN KEY (artwork_id) REFERENCES artworks (artwork_id) ON DELETE CASCADE,
      UNIQUE (artwork_id, url),
      UNIQUE (artwork_id, sort_order),
      CHECK (
        (review_state = 'suggested' AND origin = 'ai_suggestion'
          AND last_confirmed_at IS NULL)
        OR (review_state = 'confirmed' AND last_confirmed_at IS NOT NULL)
      )
    )''',
  'external_references_artwork_order_idx':
      r'''CREATE INDEX external_references_artwork_order_idx
    ON external_references (artwork_id, sort_order, created_at, reference_id)''',
  'external_references_immutable_fields':
      r'''CREATE TRIGGER external_references_immutable_fields
    BEFORE UPDATE ON external_references
    WHEN NEW.reference_id != OLD.reference_id
      OR NEW.artwork_id != OLD.artwork_id
      OR NEW.origin != OLD.origin
      OR NEW.created_at != OLD.created_at
    BEGIN
      SELECT RAISE(ABORT, 'immutable external reference field');
    END''',
  'artwork_fields_artwork_idx':
      r'''CREATE INDEX artwork_fields_artwork_idx ON artwork_fields (artwork_id)''',
  'artwork_group_memberships_group_artwork_idx':
      r'''CREATE INDEX artwork_group_memberships_group_artwork_idx ON artwork_group_memberships (group_id, artwork_id)''',
  'artwork_group_memberships_artwork_group_idx':
      r'''CREATE INDEX artwork_group_memberships_artwork_group_idx ON artwork_group_memberships (artwork_id, group_id)''',
  'attachments_artwork_idx':
      r'''CREATE INDEX attachments_artwork_idx ON attachments (artwork_id)''',
  'ai_draft_jobs_artwork_idx':
      r'''CREATE INDEX ai_draft_jobs_artwork_idx ON ai_draft_jobs (artwork_id)''',
  'research_jobs_artwork_idx':
      r'''CREATE INDEX research_jobs_artwork_idx ON research_jobs (artwork_id)''',
};

bool backupShape(Map value, Iterable<String> keys) =>
    value.length == keys.length && keys.every(value.containsKey);

int compareBackupRows(BackupTable table, BackupRecordRow a, BackupRecordRow b) {
  for (final key in table.keys) {
    final left = a.values[key], right = b.values[key];
    final comparison = left is String && right is String
        ? compareBackupText(left, right)
        : left is int && right is int
        ? left.compareTo(right)
        : invalidBackupRecords();
    if (comparison != 0) return comparison;
  }
  return 0;
}

String backupRowKey(BackupTable table, BackupRecordRow row) =>
    jsonEncode([for (final key in table.keys) row.values[key]]);

void _timestamp(String text, {bool external = false}) {
  final expression = external
      ? r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$'
      : r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.(\d{3}|\d{6})Z$';
  if (!RegExp(expression).hasMatch(text)) invalidBackupRecords();
  final date = DateTime.tryParse(text);
  if (date == null || date.year < 1 || date.year > 9999) invalidBackupRecords();
  // Component comparison rejects DateTime's overflow normalization. Precision is retained.
  final expected = date.toUtc().toIso8601String();
  if (expected != text &&
      !(text.length == 27 &&
          text.endsWith('000Z') &&
          expected == '${text.substring(0, 23)}Z')) {
    invalidBackupRecords();
  }
}

// Frozen v1 vocabulary. Future app enum additions do not silently alter this format.
const backupRecordEnums = <String, List<String>>{
  'source_state': [
    'AI-suggested',
    'user-confirmed',
    'document-extracted',
    'unknown',
  ],
  'artworks.record_state': [
    'draft',
    'needsReview',
    'verifiedByYou',
    'missingDocuments',
  ],
  'artworks.lifecycle_status': ['active', 'sold', 'lost', 'stolen', 'removed'],
  'attachments.lifecycle_status': [
    'active',
    'unavailable',
    'superseded',
    'removed',
  ],
  'attachment_type': [
    'photo',
    'receipt',
    'certificate',
    'appraisal',
    'auction_record',
    'provenance_note',
    'other_supporting_document',
  ],
  'attachment_role': [
    'primary_artwork_photo',
    'supporting_photo',
    'supporting_document',
  ],
  'ai_draft_jobs.status': [
    'pending',
    'running',
    'completed',
    'unavailable',
    'failed',
  ],
  'research_jobs.status': [
    'pending_consent',
    'queued',
    'running',
    'completed',
    'failed',
    'cancelled',
  ],
  'source_type': [
    'museum_collection',
    'cultural_heritage_api',
    'gallery',
    'artist_foundation',
    'auction_house',
    'reference',
    'unknown',
  ],
  'confidence': ['possible', 'likely', 'insufficient_evidence'],
  'comparable_value_signals.kind': [
    'public_estimate',
    'comparable_sale_signal',
    'user_provided_insurance_value',
    'no_reliable_comparable',
  ],
  'reference_type': [
    'gallery_or_artist',
    'museum_or_institution',
    'auction_or_marketplace',
    'exhibition_or_art_fair',
    'publication_or_catalogue',
    'other',
  ],
  'origin': ['manual', 'ai_suggestion'],
  'review_state': ['suggested', 'confirmed'],
};
Iterable<String>? _enumValues(String table, String column) =>
    backupRecordEnums['$table.$column'] ?? backupRecordEnums[column];
const _localReferences = {
  'artwork_id',
  'group_id',
  'research_job_id',
  'source_hit_id',
  'primary_image_attachment_id',
  'derived_from_attachment_id',
  'superseded_by_attachment_id',
};

Future<BackupRecordBundle> validateBackupBundle(
  BackupRecordBundle input,
  BackupRecordCancellation cancellation,
) async {
  try {
    cancellation.check();
    if (!backupShape(input.tables, backupRecordTables.map((t) => t.name))) {
      invalidBackupRecords();
    }
    // Wire header (17), twelve table frames (84), trailer (9). Include
    // object/array nodes, keys and scalar values, plus embedded JSON trees.
    var totalRows = 0, textBytes = 0, totalValues = 110;
    var work = 0;
    Future<void> checkpoint() async {
      if ((++work & 31) == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      cancellation.check();
    }

    final lookup = <String, Map<String, BackupRecordRow>>{};
    for (final table in backupRecordTables) {
      final rows = input.tables[table.name]!;
      backupLimit(
        rows.length > table.limit ||
            (totalRows += rows.length) > BackupRecordLimits.rows,
      );
      final byId = <String, BackupRecordRow>{};
      lookup[table.name] = byId;
      BackupRecordRow? previous;
      for (final row in rows) {
        cancellation.check();
        await checkpoint();
        if (row.table != table.name ||
            !backupShape(row.values, table.columns.map((c) => c.name))) {
          invalidBackupRecords();
        }
        var rowBytes = 0;
        totalValues += 5; // Row envelope and values object.
        for (final column in table.columns) {
          final value = row.values[column.name];
          totalValues +=
              1 +
              (value is int
                  ? 5
                  : value is BackupDevicePath
                  ? 3
                  : 1);
          backupLimit(totalValues > BackupRecordLimits.values);
          if (column.name == 'relative_path') {
            if (value != BackupDevicePath.reconstructLater) {
              invalidBackupRecords();
            }
            continue;
          }
          if (value == null) {
            if (!column.nullable) invalidBackupRecords();
            continue;
          }
          if (column.type == 'INTEGER') {
            if (value is! int) invalidBackupRecords();
            if (value < 0 || (column.name == 'is_favorite' && value > 1)) {
              invalidBackupRecords();
            }
            continue;
          }
          if (value is! String) invalidBackupRecords();
          validateBackupText(value);
          final bytes = utf8.encode(value).length;
          rowBytes += bytes;
          textBytes += bytes;
          backupLimit(
            rowBytes > BackupRecordLimits.rowText ||
                textBytes > BackupRecordLimits.bytes,
          );
          if (table.keys.contains(column.name) ||
              _localReferences.contains(column.name)) {
            if (value.isEmpty || value.contains('\u0000')) {
              invalidBackupRecords();
            }
            backupLimit(bytes > BackupRecordLimits.id);
          }
          final enums = _enumValues(table.name, column.name);
          if (enums != null && !enums.contains(value)) invalidBackupRecords();
          if (column.name.endsWith('_at') || column.name == 'signal_date') {
            _timestamp(value, external: table.name == 'external_references');
          }
          if (column.name == 'search_terms_json' ||
              column.name == 'field_sources_json') {
            final encodedJson = Uint8List.fromList(utf8.encode(value));
            totalValues += await preflightBackupJson(encodedJson, cancellation);
            backupLimit(totalValues > BackupRecordLimits.values);
            final decoded = await decodeInspectionJson(
              encodedJson,
              cancellation,
            );
            if (decoded is List) backupLimit(decoded.length > 2048);
            if (decoded is Map) backupLimit(decoded.length > 2048);
            if (column.name == 'search_terms_json') {
              if (decoded is! List || decoded.any((v) => v is! String)) {
                invalidBackupRecords();
              }
              for (final item in decoded) {
                validateBackupText(item as String);
              }
            } else {
              if (decoded is! Map) invalidBackupRecords();
              for (final entry in decoded.entries) {
                if (entry.key is! String || entry.value is! String) {
                  invalidBackupRecords();
                }
                validateBackupText(
                  entry.key as String,
                  maximum: BackupRecordLimits.id,
                );
                validateBackupText(entry.value as String);
                if ((entry.key as String).isEmpty ||
                    (entry.key as String).contains('\u0000') ||
                    !backupRecordEnums['source_state']!.contains(entry.value)) {
                  invalidBackupRecords();
                }
              }
            }
            backupLimit(totalValues > BackupRecordLimits.values);
          }
        }
        if (previous != null && compareBackupRows(table, previous, row) >= 0) {
          invalidBackupRecords();
        }
        previous = row;
        byId[backupRowKey(table, row)] = row;
      }
    }
    BackupRecordRow reference(String table, Object? id) {
      final value = lookup[table]?[jsonEncode([id])];
      if (value == null) invalidBackupRecords();
      return value;
    }

    final names = <String>{}, groupOrder = <int>{};
    final urls = <String>{}, refOrder = <String>{};
    for (final table in backupRecordTables) {
      for (final row in input.tables[table.name]!) {
        cancellation.check();
        await checkpoint();
        final v = row.values;
        if (v.containsKey('artwork_id') && table.name != 'artworks') {
          reference('artworks', v['artwork_id']);
        }
        if (v.containsKey('group_id') && table.name != 'artwork_groups') {
          reference('artwork_groups', v['group_id']);
        }
        if (v.containsKey('research_job_id') && table.name != 'research_jobs') {
          reference('research_jobs', v['research_job_id']);
        }
        if (v['source_hit_id'] != null &&
            table.name != 'research_source_hits') {
          if (reference(
                'research_source_hits',
                v['source_hit_id'],
              ).values['research_job_id'] !=
              v['research_job_id']) {
            invalidBackupRecords();
          }
        }
        if (v['primary_image_attachment_id'] != null) {
          final image = reference(
            'attachments',
            v['primary_image_attachment_id'],
          ).values;
          if (image['artwork_id'] != v['artwork_id'] ||
              (table.name == 'artworks' &&
                  (image['attachment_type'] != 'photo' ||
                      image['attachment_role'] != 'primary_artwork_photo'))) {
            invalidBackupRecords();
          }
        }
        if (table.name == 'attachments') {
          if ((v['attachment_type'] == 'photo') !=
              (v['attachment_role'] != 'supporting_document')) {
            invalidBackupRecords();
          }
          for (final link in [
            'derived_from_attachment_id',
            'superseded_by_attachment_id',
          ]) {
            if (v[link] != null &&
                reference('attachments', v[link]).values['artwork_id'] !=
                    v['artwork_id']) {
              invalidBackupRecords();
            }
          }
        }
        if (table.name == 'artwork_groups') {
          if (normalizeArtworkGroupDisplayName(v['name']! as String) !=
                  v['name'] ||
              normalizeArtworkGroupName(v['name']! as String) !=
                  v['normalized_name'] ||
              !names.add(v['normalized_name']! as String) ||
              !groupOrder.add(v['sort_order']! as int)) {
            invalidBackupRecords();
          }
        }
        if (table.name == 'external_references') {
          validateExternalReferenceId(v['reference_id']! as String);
          validateExternalReferenceId(v['artwork_id']! as String);
          if (normalizeExternalReferenceLabel(v['label'] as String?) !=
                  v['label'] ||
              const ExternalReferenceUrlCodec().canonicalize(
                    v['url']! as String,
                  ) !=
                  v['url']) {
            invalidBackupRecords();
          }
          if (v['review_state'] == 'suggested'
              ? v['origin'] != 'ai_suggestion' || v['last_confirmed_at'] != null
              : v['last_confirmed_at'] == null) {
            invalidBackupRecords();
          }
          if (!urls.add(jsonEncode([v['artwork_id'], v['url']])) ||
              !refOrder.add(jsonEncode([v['artwork_id'], v['sort_order']]))) {
            invalidBackupRecords();
          }
        }
      }
    }
    final attachments = input.tables['attachments']!;
    final diagnostics = <BackupPayloadDiagnostic>[];
    for (final row in attachments) {
      cancellation.check();
      var removedAncestor = false;
      for (final link in [
        'derived_from_attachment_id',
        'superseded_by_attachment_id',
      ]) {
        final visited = <String>{row.values['attachment_id']! as String};
        var next = row.values[link];
        while (next != null) {
          cancellation.check();
          await checkpoint();
          if (!visited.add(next as String)) invalidBackupRecords();
          final parent = reference('attachments', next).values;
          if (link == 'derived_from_attachment_id' &&
              parent['lifecycle_status'] == 'removed') {
            removedAncestor = true;
          }
          next = parent[link];
        }
      }
      if (removedAncestor && row.values['lifecycle_status'] == 'active') {
        diagnostics.add(
          BackupPayloadDiagnostic(row.values['attachment_id']! as String),
        );
      }
    }
    cancellation.check();
    return BackupRecordBundle(
      input.tables,
      diagnostics: diagnostics,
      sourceSha256: input.sourceSha256,
    );
  } on BackupRecordException {
    rethrow;
  } catch (_) {
    invalidBackupRecords();
  }
}
