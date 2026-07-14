import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../storage/attachment_record.dart';
import '../storage/artwork_record.dart';
import '../storage/local_artwork_repository.dart';
import '../storage/local_attachment_store.dart';
import 'archive_export_service.dart';
import 'export_artifact_store.dart';

class PdfReportService {
  PdfReportService({
    required this.repository,
    required this.attachmentStore,
    required this.artifactStore,
    this.clock = DateTime.now,
    Future<ByteData> Function(String asset)? fontLoader,
  }) : fontLoader = fontLoader ?? rootBundle.load;

  static const _maxEmbeddedImageBytes = 20 * 1024 * 1024;

  final LocalArtworkRepository repository;
  final LocalAttachmentStore attachmentStore;
  final ExportArtifactStore artifactStore;
  final DateTime Function() clock;
  final Future<ByteData> Function(String asset) fontLoader;

  Future<ExportArtifact> generate(
    String artworkId, {
    ExportCancellationToken? cancellationToken,
    ExportProgressCallback? onProgress,
  }) async {
    final token = cancellationToken ?? ExportCancellationToken();
    final createdAt = clock().toUtc();
    final id = ExportArtifactStore.reportId(artworkId, createdAt);
    final staging = await artifactStore.stagingFile(
      ExportArtifactKind.report,
      id,
    );
    try {
      token.throwIfCancelled();
      final record = await repository.get(artworkId);
      if (record == null) {
        throw const ExportIntegrityException(
          'This artwork record is no longer available.',
        );
      }
      final attachments = await repository.allAttachmentsForArtwork(artworkId);
      final attachmentFingerprint = _attachmentFingerprint(attachments);
      final warnings = <String>[];
      final images = <_ReportImage>[];
      var embeddedBytes = 0;
      var completed = 0;
      for (final attachment in attachments) {
        token.throwIfCancelled();
        if (!attachment.isOriginalCapture) {
          completed++;
          continue;
        }
        final isSupportedImage =
            attachment.mimeType == 'image/jpeg' ||
            attachment.mimeType == 'image/png';
        if (attachment.lifecycleStatus != AttachmentLifecycleStatus.active ||
            !isSupportedImage) {
          completed++;
          continue;
        }
        final status = await attachmentStore.payloadStatus(attachment);
        if (status != AttachmentPayloadStatus.available) {
          warnings.add('A listed image was unavailable and was not embedded.');
          completed++;
          continue;
        }
        if (embeddedBytes + attachment.fileSizeBytes > _maxEmbeddedImageBytes) {
          warnings.add(
            'Some available images were not embedded to keep the report size bounded.',
          );
          completed++;
          continue;
        }
        final bytes = await attachmentStore.fileFor(attachment).readAsBytes();
        embeddedBytes += bytes.length;
        images.add(_ReportImage(attachment: attachment, bytes: bytes));
        completed++;
        onProgress?.call(
          ExportProgress(
            completedItems: completed,
            totalItems: attachments.length + 1,
            bytesProcessed: embeddedBytes,
            totalBytes: _maxEmbeddedImageBytes,
          ),
        );
      }
      token.throwIfCancelled();
      final document = await _buildDocument(
        record: record,
        attachments: attachments,
        images: images,
        createdAt: createdAt,
        warnings: warnings,
      );
      final bytes = await document.save();
      token.throwIfCancelled();
      final current = await repository.get(artworkId);
      final currentAttachments = await repository.allAttachmentsForArtwork(
        artworkId,
      );
      if (current == null ||
          current.updatedAt != record.updatedAt ||
          _attachmentFingerprint(currentAttachments) != attachmentFingerprint) {
        throw const ExportIntegrityException(
          'This artwork changed while the report was being prepared. Please retry.',
        );
      }
      await staging.writeAsBytes(bytes, flush: true);
      onProgress?.call(
        ExportProgress(
          completedItems: attachments.length + 1,
          totalItems: attachments.length + 1,
          bytesProcessed: embeddedBytes,
          totalBytes: _maxEmbeddedImageBytes,
        ),
      );
      return artifactStore.commit(
        kind: ExportArtifactKind.report,
        id: id,
        staging: staging,
        createdAt: createdAt,
        warnings: warnings.toSet().toList(),
        subjectId: artworkId,
      );
    } on Object {
      await artifactStore.discard(staging);
      rethrow;
    }
  }

  Future<pw.Document> _buildDocument({
    required ArtworkRecord record,
    required List<AttachmentRecord> attachments,
    required List<_ReportImage> images,
    required DateTime createdAt,
    required List<String> warnings,
  }) async {
    final confirmedFields = confirmedFieldsForReport(record);
    final title =
        record.field(ArtworkFieldKeys.title)?.source ==
            ArtworkFieldSource.userConfirmed
        ? record.field(ArtworkFieldKeys.title)!.value
        : 'Untitled artwork record';
    final regularFont = pw.Font.ttf(
      await fontLoader('assets/fonts/Roboto-Regular.ttf'),
    );
    final boldFont = pw.Font.ttf(
      await fontLoader('assets/fonts/Roboto-Bold.ttf'),
    );
    final document = pw.Document(
      theme: pw.ThemeData.withFont(base: regularFont, bold: boldFont),
      title: 'Archivale collector report - ${_pdfSafeText(title)}',
      author: 'Archivale',
      subject: 'Private collector record',
    );
    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(42),
        build: (context) => [
          pw.Text(
            'ARCHIVALE',
            style: pw.TextStyle(
              fontSize: 11,
              letterSpacing: 2,
              color: PdfColors.brown700,
            ),
          ),
          pw.SizedBox(height: 8),
          pw.Text(
            'Private collector report',
            style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          pw.Text(_pdfSafeText(title), style: const pw.TextStyle(fontSize: 17)),
          pw.SizedBox(height: 6),
          pw.Text('Report date: ${_date(createdAt)}'),
          pw.Text('Record state: ${record.recordState.label}'),
          pw.Text('Lifecycle: ${record.lifecycleStatus.label}'),
          pw.SizedBox(height: 18),
          _sectionTitle('User-confirmed details'),
          if (confirmedFields.isEmpty)
            pw.Text('No user-confirmed fields are available for this report.')
          else
            pw.Table(
              border: pw.TableBorder.all(color: PdfColors.grey400, width: .5),
              columnWidths: const {
                0: pw.FlexColumnWidth(1.2),
                1: pw.FlexColumnWidth(2.8),
              },
              children: [
                for (final entry in confirmedFields)
                  pw.TableRow(
                    children: [
                      _cell(_fieldLabel(entry.key), bold: true),
                      _cell(
                        '${_pdfSafeText(entry.value.value)}\nSource: User confirmed',
                      ),
                    ],
                  ),
              ],
            ),
          pw.SizedBox(height: 18),
          _sectionTitle('Available artwork and supporting images'),
          if (images.isEmpty)
            pw.Text('No verified, report-compatible images were available.')
          else
            for (final image in images) ...[
              pw.Container(
                constraints: const pw.BoxConstraints(maxHeight: 260),
                child: pw.Image(
                  pw.MemoryImage(image.bytes),
                  fit: pw.BoxFit.contain,
                ),
              ),
              pw.SizedBox(height: 4),
              pw.Text(_attachmentLabel(image.attachment)),
              pw.SizedBox(height: 12),
            ],
          _sectionTitle('Supporting record index'),
          if (attachments.isEmpty)
            pw.Text('No supporting records are attached.')
          else
            for (final attachment in attachments)
              pw.Bullet(
                text:
                    '${_attachmentLabel(attachment)} — Source: ${attachment.source.label} — ${attachment.lifecycleStatus.storageValue}',
              ),
          if (warnings.isNotEmpty) ...[
            pw.SizedBox(height: 14),
            _sectionTitle('Report notes'),
            for (final warning in warnings.toSet()) pw.Bullet(text: warning),
          ],
          pw.SizedBox(height: 18),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            color: PdfColors.brown50,
            child: pw.Text(
              'This report contains user-confirmed details and source-labeled supporting records. It does not determine authenticity, attribution, provenance, ownership, value, appraisal status, legal status, or insurance acceptance.',
              style: const pw.TextStyle(fontSize: 9),
            ),
          ),
        ],
        footer: (context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            'Page ${context.pageNumber} of ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
        ),
      ),
    );
    return document;
  }
}

List<MapEntry<String, ArtworkFieldValue>> confirmedFieldsForReport(
  ArtworkRecord record,
) =>
    record.fields.entries
        .where(
          (entry) =>
              entry.value.source == ArtworkFieldSource.userConfirmed &&
              entry.value.value.trim().isNotEmpty,
        )
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));

pw.Widget _sectionTitle(String value) => pw.Padding(
  padding: const pw.EdgeInsets.only(bottom: 7),
  child: pw.Text(
    value,
    style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold),
  ),
);

pw.Widget _cell(String value, {bool bold = false}) => pw.Padding(
  padding: const pw.EdgeInsets.all(7),
  child: pw.Text(
    value,
    style: pw.TextStyle(
      fontSize: 9,
      fontWeight: bold ? pw.FontWeight.bold : null,
    ),
  ),
);

String _fieldLabel(String key) => key
    .split('_')
    .map(
      (part) =>
          part.isEmpty ? part : '${part[0].toUpperCase()}${part.substring(1)}',
    )
    .join(' ');

String _attachmentLabel(AttachmentRecord attachment) =>
    '${_fieldLabel(attachment.type.storageValue)} (${_fieldLabel(attachment.role.storageValue)})';

String _date(DateTime value) {
  final utc = value.toUtc();
  return '${utc.year.toString().padLeft(4, '0')}-${utc.month.toString().padLeft(2, '0')}-${utc.day.toString().padLeft(2, '0')}';
}

String _attachmentFingerprint(List<AttachmentRecord> records) {
  final values =
      records
          .map(
            (record) => [
              record.id,
              record.type.storageValue,
              record.role.storageValue,
              record.lifecycleStatus.storageValue,
              record.checksum,
              record.fileSizeBytes,
            ].join('|'),
          )
          .toList()
        ..sort();
  return values.join('\n');
}

String _pdfSafeText(String value) {
  final output = StringBuffer();
  for (final rune in value.runes) {
    if (rune == 0x0a || rune == 0x0d || rune == 0x09 || rune >= 0x20) {
      output.writeCharCode(rune);
    }
  }
  return output.toString();
}

class _ReportImage {
  const _ReportImage({required this.attachment, required this.bytes});
  final AttachmentRecord attachment;
  final Uint8List bytes;
}
