import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/storage/artwork_record.dart';
import 'package:my_art_collection/app/storage/attachment_record.dart';
import 'package:my_art_collection/app/storage/local_artwork_repository.dart';
import 'package:my_art_collection/app/storage/local_attachment_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDir;
  late LocalAttachmentStore store;
  late LocalArtworkRepository repository;
  late List<int> syntheticHeicBytes;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    syntheticHeicBytes = await File(
      p.join('test', 'fixtures', 'synthetic-supporting-record.heic'),
    ).readAsBytes();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'my_art_collection_attachment_test_',
    );
    store = await LocalAttachmentStore.openAt(
      Directory(p.join(tempDir.path, 'private_files')),
    );
    repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(p.join(tempDir.path, 'records.db')),
    );

    await repository.create(_record('artwork-001'));
  });

  tearDown(() async {
    await repository.close();
    await tempDir.delete(recursive: true);
  });

  test(
    'saves app-private file and persists linked attachment metadata',
    () async {
      final source = File(p.join(tempDir.path, 'receipt.pdf'));
      final bytes = _pdfBytes;
      await source.writeAsBytes(bytes);

      final attachment = await store.saveImportedAttachment(
        artworkId: 'artwork-001',
        attachmentId: 'attachment-001',
        sourceFile: source,
        originalFileName: 'gallery-receipt-2025.pdf',
        mimeType: 'application/pdf',
        type: AttachmentType.receipt,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 4, 10),
        notes: 'Receipt supports purchase record, not authenticity.',
      );
      await repository.addAttachment(attachment);

      expect(await store.exists(attachment), isTrue);
      expect(attachment.relativePath, contains('artworks/artwork-001'));
      expect(attachment.relativePath, contains('attachments/attachment-001'));
      expect(attachment.relativePath, isNot(contains('gallery-receipt')));
      expect(attachment.checksum, sha256.convert(bytes).toString());

      final reloaded = await repository.attachmentsForArtwork('artwork-001');
      expect(reloaded, hasLength(1));
      expect(reloaded.single.artworkId, 'artwork-001');
      expect(reloaded.single.type, AttachmentType.receipt);
      expect(reloaded.single.role, AttachmentRole.supportingDocument);
      expect(reloaded.single.fileName, 'gallery-receipt-2025.pdf');
      expect(reloaded.single.mimeType, 'application/pdf');
      expect(reloaded.single.source, ArtworkFieldSource.userConfirmed);
      expect(reloaded.single.source.label, 'user-confirmed');
    },
  );

  test('reports missing app-private file without deleting metadata', () async {
    final source = File(p.join(tempDir.path, 'image.png'));
    await source.writeAsBytes(_pngBytes);

    final attachment = await store.saveImportedAttachment(
      artworkId: 'artwork-001',
      attachmentId: 'attachment-image',
      sourceFile: source,
      originalFileName: 'living-room.png',
      mimeType: 'image/png',
      type: AttachmentType.photo,
      source: ArtworkFieldSource.userConfirmed,
      importedAt: DateTime.utc(2026, 7, 4, 11),
    );
    await repository.addAttachment(attachment);

    await store.fileFor(attachment).delete();

    expect(await store.exists(attachment), isFalse);
    expect(await repository.getAttachment('attachment-image'), isNotNull);
  });

  test(
    'persists supporting photos without overwriting the primary artwork photo',
    () async {
      await repository.upsert(
        _record('artwork-001', primaryImageAttachmentId: 'attachment-primary'),
      );

      final primarySource = File(p.join(tempDir.path, 'primary.jpg'));
      await primarySource.writeAsBytes(_jpegBytes);
      final primary = await store.saveImportedAttachment(
        artworkId: 'artwork-001',
        attachmentId: 'attachment-primary',
        sourceFile: primarySource,
        originalFileName: 'primary.jpg',
        mimeType: 'image/jpeg',
        type: AttachmentType.photo,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 4, 10),
      );
      await repository.addAttachment(primary);

      final supportingSource = File(p.join(tempDir.path, 'detail.png'));
      await supportingSource.writeAsBytes(_pngBytes);
      final supporting = await store.saveImportedAttachment(
        artworkId: 'artwork-001',
        attachmentId: 'attachment-supporting',
        sourceFile: supportingSource,
        originalFileName: 'condition-detail.png',
        mimeType: 'image/png',
        type: AttachmentType.photo,
        role: AttachmentRole.supportingPhoto,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 4, 11),
        notes: 'Detail image supports condition notes.',
      );
      await repository.addAttachment(supporting);

      final reloadedRecord = await repository.get('artwork-001');
      expect(reloadedRecord!.primaryImageAttachmentId, 'attachment-primary');

      final attachments = await repository.attachmentsForArtwork('artwork-001');
      expect(
        attachments
            .singleWhere((attachment) => attachment.id == 'attachment-primary')
            .role,
        AttachmentRole.primaryArtworkPhoto,
      );
      expect(
        attachments
            .singleWhere(
              (attachment) => attachment.id == 'attachment-supporting',
            )
            .role,
        AttachmentRole.supportingPhoto,
      );
    },
  );

  test(
    'stores edited photo derivatives as new attachments with explicit lineage',
    () async {
      final primarySource = File(p.join(tempDir.path, 'primary-capture.jpg'));
      await primarySource.writeAsBytes(_jpegBytes);
      final primary = await store.saveImportedAttachment(
        artworkId: 'artwork-001',
        attachmentId: 'attachment-primary',
        sourceFile: primarySource,
        originalFileName: 'primary-capture.jpg',
        mimeType: 'image/jpeg',
        type: AttachmentType.photo,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 4, 9),
      );
      await repository.addAttachment(primary);

      final derivativeSource = File(p.join(tempDir.path, 'primary-edit.jpg'));
      final derivativeBytes = _jpegBytes;
      await derivativeSource.writeAsBytes(derivativeBytes);
      final derivative = await store.saveImportedAttachment(
        artworkId: 'artwork-001',
        attachmentId: 'attachment-primary-edit',
        sourceFile: derivativeSource,
        originalFileName: 'primary-edit.jpg',
        mimeType: 'image/jpeg',
        type: AttachmentType.photo,
        role: AttachmentRole.primaryArtworkPhoto,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 4, 10),
        derivedFromAttachmentId: 'attachment-primary',
        transformSummary: 'crop=4:3; rotate=90deg; straighten=1.5deg',
        notes: 'Edited locally from the original capture.',
      );
      await repository.addAttachment(derivative);

      expect(await store.exists(primary), isTrue);
      expect(await store.exists(derivative), isTrue);
      expect(derivative.derivedFromAttachmentId, 'attachment-primary');
      expect(
        derivative.transformSummary,
        'crop=4:3; rotate=90deg; straighten=1.5deg',
      );
      expect(derivative.isDerivative, isTrue);
      expect(derivative.isOriginalCapture, isFalse);

      final originalBytes = await store.fileFor(primary).readAsBytes();
      expect(originalBytes, _jpegBytes);
      final derivativeStoredBytes = await store
          .fileFor(derivative)
          .readAsBytes();
      expect(derivativeStoredBytes, derivativeBytes);

      final attachments = await repository.attachmentsForArtwork('artwork-001');
      expect(attachments, hasLength(2));
      final persistedDerivative = attachments.singleWhere(
        (attachment) => attachment.id == 'attachment-primary-edit',
      );
      expect(persistedDerivative.derivedFromAttachmentId, 'attachment-primary');
      expect(
        persistedDerivative.transformSummary,
        'crop=4:3; rotate=90deg; straighten=1.5deg',
      );
      expect(persistedDerivative.type, AttachmentType.photo);
      expect(persistedDerivative.role, AttachmentRole.primaryArtworkPhoto);
    },
  );

  test('rejects unsupported MIME types and over-limit imports', () async {
    await expectLater(
      store.saveImportedAttachment(
        artworkId: 'artwork-001',
        attachmentId: 'attachment-missing',
        sourceFile: File(p.join(tempDir.path, 'missing.pdf')),
        originalFileName: 'missing.pdf',
        mimeType: 'application/pdf',
        type: AttachmentType.receipt,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 4, 12),
      ),
      throwsA(
        isA<AttachmentImportException>().having(
          (error) => error.failure,
          'failure',
          AttachmentImportFailure.sourceMissing,
        ),
      ),
    );

    final unsupported = File(p.join(tempDir.path, 'note.txt'));
    await unsupported.writeAsString('not supported');

    await expectLater(
      store.saveImportedAttachment(
        artworkId: 'artwork-001',
        attachmentId: 'attachment-note',
        sourceFile: unsupported,
        originalFileName: 'note.txt',
        mimeType: 'text/plain',
        type: AttachmentType.otherSupportingDocument,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 4, 12),
      ),
      throwsA(
        isA<AttachmentImportException>().having(
          (error) => error.failure,
          'failure',
          AttachmentImportFailure.unsupportedMimeType,
        ),
      ),
    );

    final tooLarge = File(p.join(tempDir.path, 'too-large.png'));
    final handle = await tooLarge.open(mode: FileMode.write);
    await handle.truncate(
      LocalAttachmentStore.allowedMimeTypes['image/png']! + 1,
    );
    await handle.close();

    await expectLater(
      store.saveImportedAttachment(
        artworkId: 'artwork-001',
        attachmentId: 'attachment-large',
        sourceFile: tooLarge,
        originalFileName: 'too-large.png',
        mimeType: 'image/png',
        type: AttachmentType.photo,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 4, 12),
      ),
      throwsA(
        isA<AttachmentImportException>().having(
          (error) => error.failure,
          'failure',
          AttachmentImportFailure.fileTooLarge,
        ),
      ),
    );
  });

  test('rejects mismatched extensions and malformed signatures', () async {
    final pdfNamedImage = File(p.join(tempDir.path, 'mismatch.pdf'));
    await pdfNamedImage.writeAsBytes(_pngBytes);
    await expectLater(
      store.saveImportedAttachment(
        artworkId: 'artwork-001',
        attachmentId: 'attachment-mismatch',
        sourceFile: pdfNamedImage,
        originalFileName: 'mismatch.pdf',
        mimeType: 'image/png',
        type: AttachmentType.receipt,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 4, 12),
      ),
      throwsA(
        isA<AttachmentImportException>().having(
          (error) => error.failure,
          'failure',
          AttachmentImportFailure.mimeTypeMismatch,
        ),
      ),
    );

    final malformed = File(p.join(tempDir.path, 'malformed.png'));
    await malformed.writeAsBytes(const [1, 2, 3]);
    await expectLater(
      store.saveImportedAttachment(
        artworkId: 'artwork-001',
        attachmentId: 'attachment-malformed',
        sourceFile: malformed,
        originalFileName: 'malformed.png',
        mimeType: 'image/png',
        type: AttachmentType.photo,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 4, 12),
      ),
      throwsA(
        isA<AttachmentImportException>().having(
          (error) => error.failure,
          'failure',
          AttachmentImportFailure.malformedFile,
        ),
      ),
    );
    expect(
      await Directory(
        p.join(store.storageRoot.path, '.staging'),
      ).list().toList(),
      isEmpty,
    );
  });

  test(
    'rejects unsafe opaque identifiers before creating staging or payload paths',
    () async {
      final source = File(p.join(tempDir.path, 'safe-source.pdf'));
      await source.writeAsBytes(_pdfBytes);
      const invalidComponents = [
        '/absolute-path',
        '../escape',
        'part/child',
        r'part\\child',
        '.',
        '..',
        'encoded%2fseparator',
        '.staging',
        'attachment..partial',
      ];

      for (final invalidArtworkId in invalidComponents) {
        await expectLater(
          store.saveImportedAttachment(
            artworkId: invalidArtworkId,
            attachmentId: 'attachment-safe',
            sourceFile: source,
            originalFileName: 'safe-source.pdf',
            mimeType: 'application/pdf',
            type: AttachmentType.receipt,
            source: ArtworkFieldSource.userConfirmed,
            importedAt: DateTime.utc(2026, 7, 4, 12),
          ),
          throwsA(
            isA<AttachmentImportException>().having(
              (error) => error.failure,
              'failure',
              AttachmentImportFailure.invalidIdentifier,
            ),
          ),
        );
      }
      for (final invalidAttachmentId in invalidComponents) {
        await expectLater(
          store.saveImportedAttachment(
            artworkId: 'artwork-safe',
            attachmentId: invalidAttachmentId,
            sourceFile: source,
            originalFileName: 'safe-source.pdf',
            mimeType: 'application/pdf',
            type: AttachmentType.receipt,
            source: ArtworkFieldSource.userConfirmed,
            importedAt: DateTime.utc(2026, 7, 4, 12),
          ),
          throwsA(
            isA<AttachmentImportException>().having(
              (error) => error.failure,
              'failure',
              AttachmentImportFailure.invalidIdentifier,
            ),
          ),
        );
      }

      expect(
        await Directory(p.join(store.storageRoot.path, '.staging')).exists(),
        isFalse,
      );
      expect(
        await Directory(p.join(store.storageRoot.path, 'artworks')).exists(),
        isFalse,
      );
      expect(await File(p.join(tempDir.path, 'escape')).exists(), isFalse);
    },
  );

  test('rejects header-only and truncated approved-format files', () async {
    final malformedCases = <({String name, String mimeType, List<int> bytes})>[
      (
        name: 'header-only.pdf',
        mimeType: 'application/pdf',
        bytes: const [0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x34],
      ),
      (
        name: 'truncated.png',
        mimeType: 'image/png',
        bytes: _pngBytes.sublist(0, 24),
      ),
      (
        name: 'truncated.jpg',
        mimeType: 'image/jpeg',
        bytes: _jpegBytes.sublist(0, _jpegBytes.length - 2),
      ),
      (
        name: 'header-only.heic',
        mimeType: 'image/heic',
        bytes: const [
          0x00,
          0x00,
          0x00,
          0x14,
          0x66,
          0x74,
          0x79,
          0x70,
          0x68,
          0x65,
          0x69,
          0x63,
        ],
      ),
    ];

    for (final malformed in malformedCases) {
      final source = File(p.join(tempDir.path, malformed.name));
      await source.writeAsBytes(malformed.bytes);
      await expectLater(
        store.saveImportedAttachment(
          artworkId: 'artwork-001',
          attachmentId:
              'attachment-${p.basenameWithoutExtension(malformed.name)}',
          sourceFile: source,
          originalFileName: malformed.name,
          mimeType: malformed.mimeType,
          type: malformed.mimeType == 'application/pdf'
              ? AttachmentType.receipt
              : AttachmentType.photo,
          source: ArtworkFieldSource.userConfirmed,
          importedAt: DateTime.utc(2026, 7, 4, 12),
        ),
        throwsA(
          isA<AttachmentImportException>().having(
            (error) => error.failure,
            'failure',
            AttachmentImportFailure.malformedFile,
          ),
        ),
      );
    }
  });

  test('rejects allocation-bomb image dimensions before commit', () async {
    final bombCases = <({String name, String mimeType, List<int> bytes})>[
      (
        name: 'twenty-megapixel.png',
        mimeType: 'image/png',
        bytes: _pngWithDimensions(width: 5000, height: 4000),
      ),
      (
        name: 'twenty-megapixel.jpg',
        mimeType: 'image/jpeg',
        bytes: _jpegWithDimensions(_jpegBytes, width: 5000, height: 4000),
      ),
      (
        name: 'oversized-metadata.heic',
        mimeType: 'image/heic',
        bytes: _heicWithDimensions(
          syntheticHeicBytes,
          width: 5000,
          height: 4000,
        ),
      ),
    ];

    for (var index = 0; index < bombCases.length; index += 1) {
      final fixture = bombCases[index];
      final source = File(p.join(tempDir.path, fixture.name));
      await source.writeAsBytes(fixture.bytes);

      await expectLater(
        store.saveImportedAttachment(
          artworkId: 'artwork-001',
          attachmentId: 'attachment-dimension-bomb-$index',
          sourceFile: source,
          originalFileName: fixture.name,
          mimeType: fixture.mimeType,
          type: AttachmentType.photo,
          source: ArtworkFieldSource.userConfirmed,
          importedAt: DateTime.utc(2026, 7, 4, 12),
        ),
        throwsA(
          isA<AttachmentImportException>().having(
            (error) => error.failure,
            'failure',
            AttachmentImportFailure.malformedFile,
          ),
        ),
      );
    }

    expect(await repository.allAttachmentsForArtwork('artwork-001'), isEmpty);
    expect(
      await Directory(
        p.join(store.storageRoot.path, '.staging'),
      ).list().toList(),
      isEmpty,
    );
  });

  test(
    'rejects marker-shaped corrupt PDF PNG and JPEG payloads without commits',
    () async {
      final malformedCases =
          <({String name, String mimeType, List<int> bytes})>[
            (
              name: 'marker-shaped.pdf',
              mimeType: 'application/pdf',
              bytes: latin1.encode(
                '%PDF-1.4\n1 0 obj\n<<>>\nendobj\nstartxref\n0\n%%EOF\n',
              ),
            ),
            (
              name: 'marker-shaped.png',
              mimeType: 'image/png',
              bytes: const [
                0x89,
                0x50,
                0x4e,
                0x47,
                0x0d,
                0x0a,
                0x1a,
                0x0a,
                0x00,
                0x00,
                0x00,
                0x0d,
                0x49,
                0x48,
                0x44,
                0x52,
                0x00,
                0x00,
                0x00,
                0x01,
                0x00,
                0x00,
                0x00,
                0x01,
                0x08,
                0x02,
                0x00,
                0x00,
                0x00,
                0x00,
                0x00,
                0x00,
                0x00,
                0x00,
                0x00,
                0x00,
                0x00,
                0x49,
                0x45,
                0x4e,
                0x44,
                0x00,
                0x00,
                0x00,
                0x00,
              ],
            ),
            (
              name: 'marker-shaped.jpg',
              mimeType: 'image/jpeg',
              bytes: const [
                0xff,
                0xd8,
                0xff,
                0xc0,
                0x00,
                0x0b,
                0x08,
                0x00,
                0x01,
                0x00,
                0x01,
                0x01,
                0x01,
                0x11,
                0x00,
                0xff,
                0xda,
                0x00,
                0x08,
                0x00,
                0x00,
                0x00,
                0x3f,
                0x00,
                0x00,
                0xff,
                0xd9,
              ],
            ),
          ];

      for (final malformed in malformedCases) {
        final source = File(p.join(tempDir.path, malformed.name));
        await source.writeAsBytes(malformed.bytes);
        await expectLater(
          store.saveImportedAttachment(
            artworkId: 'artwork-001',
            attachmentId:
                'attachment-${p.basenameWithoutExtension(malformed.name)}',
            sourceFile: source,
            originalFileName: malformed.name,
            mimeType: malformed.mimeType,
            type: malformed.mimeType == 'application/pdf'
                ? AttachmentType.receipt
                : AttachmentType.photo,
            source: ArtworkFieldSource.userConfirmed,
            importedAt: DateTime.utc(2026, 7, 4, 12),
          ),
          throwsA(
            isA<AttachmentImportException>().having(
              (error) => error.failure,
              'failure',
              AttachmentImportFailure.malformedFile,
            ),
          ),
        );
      }

      expect(await repository.allAttachmentsForArtwork('artwork-001'), isEmpty);
      expect(
        await Directory(
          p.join(store.storageRoot.path, '.staging'),
        ).list().toList(),
        isEmpty,
      );
    },
  );

  test('imports and reopens genuine approved-format fixtures', () async {
    final fixtures = <({String name, String mimeType, List<int> bytes})>[
      (name: 'genuine.pdf', mimeType: 'application/pdf', bytes: _pdfBytes),
      (name: 'genuine.png', mimeType: 'image/png', bytes: _pngBytes),
      (name: 'genuine.jpg', mimeType: 'image/jpeg', bytes: _jpegBytes),
      (
        name: 'synthetic.heic',
        mimeType: 'image/heic',
        bytes: syntheticHeicBytes,
      ),
      (
        name: 'synthetic.heif',
        mimeType: 'image/heif',
        bytes: syntheticHeicBytes,
      ),
    ];

    for (var index = 0; index < fixtures.length; index += 1) {
      final fixture = fixtures[index];
      final source = File(p.join(tempDir.path, fixture.name));
      await source.writeAsBytes(fixture.bytes);
      final attachment = await store.saveImportedAttachment(
        artworkId: 'artwork-001',
        attachmentId: 'attachment-genuine-$index',
        sourceFile: source,
        originalFileName: fixture.name,
        mimeType: fixture.mimeType,
        type: fixture.mimeType == 'application/pdf'
            ? AttachmentType.receipt
            : AttachmentType.photo,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 4, 12),
      );

      expect(await store.fileFor(attachment).readAsBytes(), fixture.bytes);
      expect(
        await store.payloadStatus(attachment),
        AttachmentPayloadStatus.available,
      );
    }
  });
}

final _pdfBytes = _validPdfBytes();
final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAACXBIWXMAAAABAAAAAQBPJcTWAAAADklEQVR4nGNkAAMWCAUAADgABkRoBWYAAAAASUVORK5CYII=',
);
final _jpegBytes = base64Decode(
  '/9j/4AAQSkZJRgABAgAAAQABAAD//gAQTGF2YzYyLjI4LjEwMQD/2wBDAAgEBAQEBAUFBQUFBQYGBgYGBgYGBgYGBgYHBwcICAgHBwcGBgcHCAgICAkJCQgICAgJCQoKCgwMCwsODg4RERT/xABLAAEBAAAAAAAAAAAAAAAAAAAACAEBAAAAAAAAAAAAAAAAAAAAABABAAAAAAAAAAAAAAAAAAAAABEBAAAAAAAAAAAAAAAAAAAAAP/AABEIAAIAAgMBIgACEQADEQD/2gAMAwEAAhEDEQA/AJ/AB//Z',
);

List<int> _validPdfBytes() {
  const header = '%PDF-1.4\n';
  const catalog = '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n';
  const pages = '2 0 obj\n<< /Type /Pages /Count 0 /Kids [] >>\nendobj\n';
  final catalogOffset = header.length;
  final pagesOffset = catalogOffset + catalog.length;
  final xrefOffset = pagesOffset + pages.length;
  final source = StringBuffer(header)
    ..write(catalog)
    ..write(pages)
    ..write('xref\n0 3\n')
    ..write('0000000000 65535 f \n')
    ..write('${catalogOffset.toString().padLeft(10, '0')} 00000 n \n')
    ..write('${pagesOffset.toString().padLeft(10, '0')} 00000 n \n')
    ..write('trailer\n<< /Size 3 /Root 1 0 R >>\n')
    ..write('startxref\n$xrefOffset\n%%EOF\n');
  return latin1.encode(source.toString());
}

List<int> _pngWithDimensions({required int width, required int height}) {
  final bytesPerRow = (width + 7) ~/ 8;
  final rawPixels = Uint8List((bytesPerRow + 1) * height);
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 1)
    ..setUint8(9, 0)
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);
  final result = BytesBuilder(copy: false)
    ..add(const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    ..add(_pngChunk('IHDR', header.buffer.asUint8List()))
    ..add(_pngChunk('IDAT', ZLibEncoder().convert(rawPixels)))
    ..add(_pngChunk('IEND', const []));
  return result.takeBytes();
}

List<int> _pngChunk(String type, List<int> payload) {
  final typeBytes = ascii.encode(type);
  final crcInput = BytesBuilder(copy: false)
    ..add(typeBytes)
    ..add(payload);
  final length = ByteData(4)..setUint32(0, payload.length);
  final crc = ByteData(4)..setUint32(0, _crc32(crcInput.takeBytes()));
  return <int>[
    ...length.buffer.asUint8List(),
    ...typeBytes,
    ...payload,
    ...crc.buffer.asUint8List(),
  ];
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit += 1) {
      crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

List<int> _heicWithDimensions(
  List<int> source, {
  required int width,
  required int height,
}) {
  final bytes = Uint8List.fromList(source);
  final ispe = ascii.encode('ispe');
  for (var index = 0; index + 15 < bytes.length; index += 1) {
    if (bytes[index] == ispe[0] &&
        bytes[index + 1] == ispe[1] &&
        bytes[index + 2] == ispe[2] &&
        bytes[index + 3] == ispe[3]) {
      final dimensions = ByteData.sublistView(bytes, index + 8, index + 16)
        ..setUint32(0, width)
        ..setUint32(4, height);
      assert(dimensions.lengthInBytes == 8);
      return bytes;
    }
  }
  throw StateError('Synthetic HEIC fixture is missing an ispe box.');
}

List<int> _jpegWithDimensions(
  List<int> source, {
  required int width,
  required int height,
}) {
  final bytes = Uint8List.fromList(source);
  for (var index = 0; index + 8 < bytes.length; index += 1) {
    if (bytes[index] == 0xff &&
        bytes[index + 1] >= 0xc0 &&
        bytes[index + 1] <= 0xcf &&
        bytes[index + 1] != 0xc4 &&
        bytes[index + 1] != 0xc8 &&
        bytes[index + 1] != 0xcc) {
      ByteData.sublistView(bytes, index + 5, index + 9)
        ..setUint16(0, height)
        ..setUint16(2, width);
      return bytes;
    }
  }
  throw StateError('Synthetic JPEG fixture is missing a frame marker.');
}

ArtworkRecord _record(String id, {String? primaryImageAttachmentId}) {
  final now = DateTime.utc(2026, 7, 4, 9);

  return ArtworkRecord(
    id: id,
    recordState: ArtworkRecordState.draft,
    primaryImageAttachmentId: primaryImageAttachmentId,
    createdAt: now,
    updatedAt: now,
    fields: const {
      ArtworkFieldKeys.title: ArtworkFieldValue(
        value: 'Blue Interior Study',
        source: ArtworkFieldSource.userConfirmed,
        note: 'User confirmed.',
      ),
    },
  );
}
