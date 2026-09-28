import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:my_art_collection/app/export/archive_export_service.dart';
import 'package:my_art_collection/app/export/export_artifact_store.dart';
import 'package:my_art_collection/app/storage/artwork_record.dart';
import 'package:my_art_collection/app/storage/attachment_record.dart';
import 'package:my_art_collection/app/storage/local_artwork_repository.dart';
import 'package:my_art_collection/app/storage/local_attachment_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class ArchiveInspectionFixture {
  ArchiveInspectionFixture._(
    this.root,
    this.database,
    this.repository,
    this.store,
    this.exports,
  );
  final Directory root;
  final Database database;
  final LocalArtworkRepository repository;
  final LocalAttachmentStore store;
  final ExportArtifactStore exports;
  Directory get scratch => Directory('${root.path}/scratch');
  static final time = DateTime.utc(2026, 7, 14, 9);
  static final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );

  static Future<ArchiveInspectionFixture> create({bool rich = false}) async {
    final root = await Directory.systemTemp.createTemp(
      'archive-inspection-test-',
    );
    final db = await LocalArtworkRepository.openAt('${root.path}/records.db');
    final repository = LocalArtworkRepository.forDatabase(db);
    final fixture = ArchiveInspectionFixture._(
      root,
      db,
      repository,
      await LocalAttachmentStore.openAt(Directory('${root.path}/attachments')),
      await ExportArtifactStore.openAt(Directory('${root.path}/exports')),
    );
    await fixture.scratch.create();
    await repository.create(
      ArtworkRecord(
        id: 'art-1',
        recordState: ArtworkRecordState.verifiedByYou,
        createdAt: time,
        updatedAt: time,
        fields: {
          'title': const ArtworkFieldValue(
            value: 'Collector title',
            source: ArtworkFieldSource.userConfirmed,
            note: 'Collector note',
          ),
          'custom-field': ArtworkFieldValue(
            value: 'Proposed',
            source: ArtworkFieldSource.aiSuggested,
            note: 'Unconfirmed',
            lastConfirmedAt: null,
            moneyAmount: '123.40',
            moneyCurrencyCode: 'NOK',
          ),
        },
      ),
    );
    if (rich) await fixture.populate();
    return fixture;
  }

  Future<void> populate() async {
    for (final id in [
      'original',
      'derivative',
      'removed',
      'superseded',
      'unavailable',
    ]) {
      final source = await File('${root.path}/$id.png').writeAsBytes(png);
      final attachment = await store.saveImportedAttachment(
        artworkId: 'art-1',
        attachmentId: id,
        sourceFile: source,
        originalFileName: '$id.png',
        mimeType: 'image/png',
        type: AttachmentType.photo,
        role: id == 'original'
            ? AttachmentRole.primaryArtworkPhoto
            : AttachmentRole.supportingPhoto,
        source: ArtworkFieldSource.documentExtracted,
        importedAt: time,
        capturedAt: time.subtract(const Duration(days: 1)),
        derivedFromAttachmentId: id == 'derivative' ? 'original' : null,
        transformSummary: id == 'derivative' ? 'Cropped carefully' : null,
        extractionSummary: 'Saved extracted text',
        notes: 'Keep this collector note: $id',
      );
      await repository.addAttachment(attachment);
      if (['removed', 'superseded', 'unavailable'].contains(id)) {
        await database.update(
          'attachments',
          {
            'lifecycle_status': id,
            'lifecycle_updated_at': time.toIso8601String(),
            'superseded_by_attachment_id': id == 'superseded'
                ? 'original'
                : null,
          },
          where: 'attachment_id = ?',
          whereArgs: [id],
        );
      }
    }
    await database.update(
      'artworks',
      {'primary_image_attachment_id': 'original'},
      where: 'artwork_id = ?',
      whereArgs: ['art-1'],
    );
    await database.insert('artwork_groups', {
      'group_id': 'group-1',
      'name': 'Favorites',
      'normalized_name': 'favorites',
      'sort_order': 0,
      'created_at': time.toIso8601String(),
      'updated_at': time.toIso8601String(),
    });
    await database.insert('artwork_group_memberships', {
      'artwork_id': 'art-1',
      'group_id': 'group-1',
      'created_at': time.toIso8601String(),
    });
    await repository.setFavorite(
      artworkId: 'art-1',
      isFavorite: false,
      now: time,
    );
    await database.insert('external_references', {
      'reference_id': 'ref-1',
      'artwork_id': 'art-1',
      'reference_type': 'museum_or_institution',
      'label': null,
      'url': 'https://example.com/record',
      'origin': 'ai_suggestion',
      'review_state': 'suggested',
      'last_confirmed_at': null,
      'created_at': time.toIso8601String(),
      'updated_at': time.toIso8601String(),
      'sort_order': 0,
    });
    await database.insert('ai_draft_jobs', {
      'draft_job_id': 'draft-1',
      'artwork_id': 'art-1',
      'status': 'completed',
      'created_at': time.toIso8601String(),
      'updated_at': time.toIso8601String(),
      'visual_summary': 'Persisted cautious draft',
      'search_terms_json': '["artwork"]',
    });
    await database.insert('research_jobs', {
      'research_job_id': 'research-1',
      'artwork_id': 'art-1',
      'status': 'completed',
      'created_at': time.toIso8601String(),
      'updated_at': time.toIso8601String(),
      'consent_summary': 'Historical consent only',
    });
    await database.insert('research_source_hits', {
      'source_hit_id': 'hit-1',
      'research_job_id': 'research-1',
      'source_name': 'Synthetic source',
      'source_type': 'museum_collection',
      'confidence': 'possible',
      'raw_snippet': 'Persisted supporting reference',
    });
    await database.insert('candidate_attributions', {
      'candidate_id': 'candidate-1',
      'research_job_id': 'research-1',
      'source_hit_id': 'hit-1',
      'confidence': 'possible',
      'match_reason': 'Cautious match',
      'field_sources_json': '{}',
    });
    await database.insert('comparable_value_signals', {
      'signal_id': 'signal-1',
      'research_job_id': 'research-1',
      'source_hit_id': 'hit-1',
      'kind': 'no_reliable_comparable',
      'label': 'No conclusion',
      'source_name': 'Synthetic source',
      'caveat': 'Not an appraisal',
    });
  }

  Future<File> export() async => (await ArchiveExportService(
    repository: repository,
    attachmentStore: store,
    artifactStore: exports,
    clock: () => time,
  ).generate()).file;
  Future<void> dispose() async {
    await repository.close();
    await root.delete(recursive: true);
  }
}

Future<Map<String, List<int>>> archiveEntries(File file) async {
  final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
  return {
    for (final entry in archive.files) entry.name: entry.content as List<int>,
  };
}

Future<File> writeArchive(
  Directory root,
  Map<String, List<int>> entries, {
  String name = 'modified.zip',
  bool rehash = true,
}) async {
  if (rehash && entries.containsKey('manifest.json')) {
    final manifest =
        jsonDecode(utf8.decode(entries['manifest.json']!))
            as Map<String, dynamic>;
    for (final row in manifest['files'] as List) {
      final bytes = entries[row['path']];
      if (bytes != null) {
        row['size_bytes'] = bytes.length;
        row['checksum_sha256'] = sha256.convert(bytes).toString();
      }
    }
    entries['manifest.json'] = utf8.encode(jsonEncode(manifest));
  }
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return File('${root.path}/$name').writeAsBytes(ZipEncoder().encode(archive));
}

void mutateJson(
  Map<String, List<int>> entries,
  String path,
  void Function(Map<String, dynamic>) mutate,
) {
  final value = jsonDecode(utf8.decode(entries[path]!)) as Map<String, dynamic>;
  mutate(value);
  entries[path] = utf8.encode(jsonEncode(value));
}
