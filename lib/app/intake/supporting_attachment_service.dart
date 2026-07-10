import 'dart:io';

import 'package:image_picker/image_picker.dart';

import '../storage/attachment_record.dart';
import '../storage/artwork_record.dart';
import '../storage/local_artwork_repository.dart';
import '../storage/local_attachment_store.dart';
import 'artwork_intake_service.dart';
import 'attachment_viewer_gateway.dart';
import 'artwork_image_picker.dart';
import 'supporting_document_picker.dart';

class SupportingAttachmentResult {
  const SupportingAttachmentResult({
    required this.record,
    required this.attachment,
  });

  final ArtworkRecord record;
  final AttachmentRecord attachment;
}

class SupportingAttachmentService {
  SupportingAttachmentService({
    required this.picker,
    SupportingDocumentPicker? documentPicker,
    AttachmentViewerGateway? viewer,
    required this.repository,
    required this.attachmentStore,
    DateTime Function()? now,
    String Function()? idFactory,
  }) : documentPicker =
           documentPicker ?? const SystemSupportingDocumentPicker(),
       viewer = viewer ?? const SystemAttachmentViewerGateway(),
       _now = now ?? DateTime.now,
       _idFactory = idFactory ?? _timestampId;

  final ArtworkImagePicker picker;
  final SupportingDocumentPicker documentPicker;
  final AttachmentViewerGateway viewer;
  final LocalArtworkRepository repository;
  final LocalAttachmentStore attachmentStore;
  final DateTime Function() _now;
  final String Function() _idFactory;

  Future<SupportingAttachmentResult> importSupportingPhoto(
    String artworkId,
  ) async {
    final selected = await picker.pick(ArtworkImagePickMode.gallery);
    return _savePickedPhoto(
      artworkId: artworkId,
      pickedFile: selected,
      capturedAt: null,
      emptyMessage: 'Supporting photo import was cancelled.',
    );
  }

  Future<SupportingAttachmentResult> captureSupportingPhoto(
    String artworkId,
  ) async {
    final selected = await picker.pick(ArtworkImagePickMode.camera);
    return _savePickedPhoto(
      artworkId: artworkId,
      pickedFile: selected,
      capturedAt: _now(),
      emptyMessage: 'Supporting photo capture was cancelled.',
    );
  }

  Future<SupportingAttachmentResult> importSupportingDocument({
    required String artworkId,
    required AttachmentType type,
    String? notes,
  }) async {
    if (type == AttachmentType.photo) {
      throw ArgumentError.value(type, 'type', 'Use photo intake for photos.');
    }
    final selected = await documentPicker.pickDocument();
    if (selected == null) {
      throw ArtworkIntakeException(
        ArtworkIntakeFailure.cancelled,
        'Supporting document import was cancelled.',
      );
    }
    return _savePickedDocument(
      artworkId: artworkId,
      pickedFile: selected,
      type: type,
      notes: notes,
    );
  }

  Future<SupportingAttachmentResult> replaceSupportingDocument({
    required String attachmentId,
    required AttachmentType type,
    String? notes,
  }) async {
    if (type == AttachmentType.photo) {
      throw ArgumentError.value(type, 'type', 'Use photo intake for photos.');
    }
    final previous = await repository.getAttachment(attachmentId);
    if (previous == null || !previous.isSupportingDocument) {
      throw ArtworkIntakeException(
        ArtworkIntakeFailure.sourceUnavailable,
        'The supporting document could not be found.',
      );
    }
    final selected = await documentPicker.pickDocument();
    if (selected == null) {
      throw const ArtworkIntakeException(
        ArtworkIntakeFailure.cancelled,
        'Supporting document replacement was cancelled.',
      );
    }

    final replacement = await _savePickedDocument(
      artworkId: previous.artworkId,
      pickedFile: selected,
      type: type,
      notes: notes,
      previousAttachmentId: previous.id,
    );
    return replacement;
  }

  Future<void> removeSupportingDocument(String attachmentId) async {
    final attachment = await repository.getAttachment(attachmentId);
    if (attachment == null || !attachment.isSupportingDocument) {
      throw const ArtworkIntakeException(
        ArtworkIntakeFailure.sourceUnavailable,
        'The supporting document could not be found.',
      );
    }
    await repository.updateAttachmentLifecycle(
      attachmentId: attachment.id,
      lifecycleStatus: AttachmentLifecycleStatus.removed,
      updatedAt: _now(),
    );
  }

  Future<void> openSupportingDocument(String attachmentId) async {
    final attachment = await repository.getAttachment(attachmentId);
    if (attachment == null ||
        !attachment.isSupportingDocument ||
        attachment.lifecycleStatus == AttachmentLifecycleStatus.removed ||
        attachment.lifecycleStatus == AttachmentLifecycleStatus.superseded) {
      throw const ArtworkIntakeException(
        ArtworkIntakeFailure.sourceUnavailable,
        'The supporting document is unavailable.',
      );
    }
    final status = await attachmentStore.payloadStatus(attachment);
    if (status != AttachmentPayloadStatus.available) {
      await repository.updateAttachmentLifecycle(
        attachmentId: attachment.id,
        lifecycleStatus: AttachmentLifecycleStatus.unavailable,
        updatedAt: _now(),
      );
      throw ArtworkIntakeException(
        ArtworkIntakeFailure.sourceUnavailable,
        status == AttachmentPayloadStatus.checksumMismatch
            ? 'The saved document no longer matches its recorded checksum.'
            : 'The saved document file is unavailable.',
      );
    }
    try {
      await viewer.open(
        scopedUri: attachmentStore.scopedUriFor(attachment),
        mimeType: attachment.mimeType,
      );
    } on AttachmentViewerException catch (error) {
      throw ArtworkIntakeException(
        ArtworkIntakeFailure.pickerUnavailable,
        error.message,
      );
    }
  }

  Future<SupportingAttachmentResult> _savePickedDocument({
    required String artworkId,
    required dynamic pickedFile,
    required AttachmentType type,
    required String? notes,
    String? previousAttachmentId,
  }) async {
    final record = await repository.get(artworkId);
    if (record == null) {
      throw const ArtworkIntakeException(
        ArtworkIntakeFailure.sourceUnavailable,
        'The artwork record could not be found.',
      );
    }
    final attachmentId = 'attachment-${_idFactory()}';
    final mimeType = _mimeTypeForDocument(pickedFile.name, pickedFile.mimeType);
    AttachmentRecord? attachment;
    try {
      attachment = await attachmentStore.saveImportedAttachment(
        artworkId: artworkId,
        attachmentId: attachmentId,
        sourceFile: File(pickedFile.path),
        originalFileName: pickedFile.name,
        mimeType: mimeType,
        type: type,
        role: AttachmentRole.supportingDocument,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: _now(),
        notes:
            notes ??
            'User-provided supporting document. It does not prove authenticity.',
      );
      if (previousAttachmentId == null) {
        await repository.addAttachment(attachment);
      } else {
        await repository.replaceAttachment(
          previousAttachmentId: previousAttachmentId,
          replacement: attachment,
          replacedAt: _now(),
        );
      }
      return SupportingAttachmentResult(record: record, attachment: attachment);
    } on AttachmentImportException catch (error) {
      if (attachment != null) {
        await attachmentStore.discardPayload(attachment);
      }
      throw _asIntakeException(error);
    } on Exception {
      if (attachment != null) {
        await attachmentStore.discardPayload(attachment);
      }
      throw ArtworkIntakeException(
        ArtworkIntakeFailure.pickerUnavailable,
        'Could not finish the supporting document intake.',
      );
    }
  }

  Future<SupportingAttachmentResult> _savePickedPhoto({
    required String artworkId,
    required XFile? pickedFile,
    required DateTime? capturedAt,
    required String emptyMessage,
  }) async {
    if (pickedFile == null) {
      throw ArtworkIntakeException(
        ArtworkIntakeFailure.cancelled,
        emptyMessage,
      );
    }

    final record = await repository.get(artworkId);
    if (record == null) {
      throw const ArtworkIntakeException(
        ArtworkIntakeFailure.sourceUnavailable,
        'The artwork record could not be found.',
      );
    }

    final now = _now();
    final attachmentId = 'attachment-${_idFactory()}';
    final mimeType = pickedFile.mimeType ?? _mimeTypeForPath(pickedFile.path);
    AttachmentRecord? attachment;

    try {
      attachment = await attachmentStore.saveImportedAttachment(
        artworkId: artworkId,
        attachmentId: attachmentId,
        sourceFile: File(pickedFile.path),
        originalFileName: pickedFile.name,
        mimeType: mimeType,
        type: AttachmentType.photo,
        role: AttachmentRole.supportingPhoto,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: now,
        capturedAt: capturedAt,
        notes:
            'Supporting photo of a label, signature, reverse side, receipt, condition detail, or other supporting record.',
      );

      await repository.addAttachment(attachment);

      return SupportingAttachmentResult(record: record, attachment: attachment);
    } on AttachmentImportException catch (error) {
      if (attachment != null) {
        await attachmentStore.discardPayload(attachment);
      }
      throw _asIntakeException(error);
    } on ArtworkIntakeException {
      rethrow;
    } on Exception catch (error) {
      if (attachment != null) {
        await attachmentStore.discardPayload(attachment);
      }
      throw ArtworkIntakeException(
        ArtworkIntakeFailure.pickerUnavailable,
        'Could not finish the supporting photo intake: $error',
      );
    }
  }

  static String _mimeTypeForPath(String path) {
    final lowerPath = path.toLowerCase();
    if (lowerPath.endsWith('.png')) {
      return 'image/png';
    }
    if (lowerPath.endsWith('.heic')) {
      return 'image/heic';
    }
    if (lowerPath.endsWith('.heif')) {
      return 'image/heif';
    }
    return 'image/jpeg';
  }

  static String _mimeTypeForDocument(String fileName, String? pickerMimeType) {
    const allowed = LocalAttachmentStore.allowedMimeTypes;
    if (pickerMimeType != null && allowed.containsKey(pickerMimeType)) {
      return pickerMimeType;
    }
    final lowerName = fileName.toLowerCase();
    if (lowerName.endsWith('.pdf')) return 'application/pdf';
    return _mimeTypeForPath(lowerName);
  }

  static ArtworkIntakeException _asIntakeException(
    AttachmentImportException error,
  ) {
    return ArtworkIntakeException(switch (error.failure) {
      AttachmentImportFailure.invalidIdentifier =>
        ArtworkIntakeFailure.pickerUnavailable,
      AttachmentImportFailure.sourceMissing ||
      AttachmentImportFailure.unreadableSource =>
        ArtworkIntakeFailure.sourceUnavailable,
      AttachmentImportFailure.fileTooLarge => ArtworkIntakeFailure.fileTooLarge,
      AttachmentImportFailure.unsupportedMimeType ||
      AttachmentImportFailure.mimeTypeMismatch ||
      AttachmentImportFailure.malformedFile =>
        ArtworkIntakeFailure.unsupportedFile,
      AttachmentImportFailure.storageFailure =>
        ArtworkIntakeFailure.pickerUnavailable,
    }, error.message);
  }

  static String _timestampId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);
}
