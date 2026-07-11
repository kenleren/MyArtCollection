import 'attachment_record.dart';
import 'artwork_record.dart';

enum ArtworkCollectionSort {
  recentlyUpdated('Recently updated'),
  title('Title'),
  artist('Artist'),
  acquisitionDate('Acquisition date');

  const ArtworkCollectionSort(this.label);

  final String label;
}

enum ArtworkCollectionSnapshotRead { artworks, fields, acceptedAttachmentRoles }

class ArtworkCollectionSnapshotObserver {
  const ArtworkCollectionSnapshotObserver({required this.onRead});

  final void Function(ArtworkCollectionSnapshotRead read) onRead;
}

class ArtworkCollectionQuery {
  const ArtworkCollectionQuery({
    this.searchTerm = '',
    this.sort = ArtworkCollectionSort.recentlyUpdated,
    this.locations = const {},
    this.recordStates = const {},
    this.lifecycleStatuses = const {},
    this.missingSupportingRecords = false,
  });

  final String searchTerm;
  final ArtworkCollectionSort sort;
  final Set<String> locations;
  final Set<ArtworkRecordState> recordStates;
  final Set<ArtworkLifecycleStatus> lifecycleStatuses;
  final bool missingSupportingRecords;

  int get selectedFilterCount =>
      locations.length +
      recordStates.length +
      lifecycleStatuses.length +
      (missingSupportingRecords ? 1 : 0);

  bool get hasConstraints =>
      searchTerm.trim().isNotEmpty || selectedFilterCount > 0;

  ArtworkCollectionQuery copyWith({
    String? searchTerm,
    ArtworkCollectionSort? sort,
    Set<String>? locations,
    Set<ArtworkRecordState>? recordStates,
    Set<ArtworkLifecycleStatus>? lifecycleStatuses,
    bool? missingSupportingRecords,
  }) {
    return ArtworkCollectionQuery(
      searchTerm: searchTerm ?? this.searchTerm,
      sort: sort ?? this.sort,
      locations: locations ?? this.locations,
      recordStates: recordStates ?? this.recordStates,
      lifecycleStatuses: lifecycleStatuses ?? this.lifecycleStatuses,
      missingSupportingRecords:
          missingSupportingRecords ?? this.missingSupportingRecords,
    );
  }

  ArtworkCollectionQuery clearFilters() {
    return ArtworkCollectionQuery(searchTerm: searchTerm, sort: sort);
  }

  ArtworkCollectionQuery clearAll() {
    return const ArtworkCollectionQuery();
  }
}

class ArtworkCollectionEntry {
  const ArtworkCollectionEntry({
    required this.record,
    required this.acceptedAttachments,
  });

  final ArtworkRecord record;
  final List<AttachmentRecord> acceptedAttachments;

  int get supportingAttachmentCount => acceptedAttachments
      .where(
        (attachment) =>
            attachment.role == AttachmentRole.supportingPhoto ||
            attachment.role == AttachmentRole.supportingDocument,
      )
      .length;

  AttachmentRecord? get primaryImageAttachment {
    final primaryId = record.primaryImageAttachmentId;
    if (primaryId == null) {
      return null;
    }
    for (final attachment in acceptedAttachments) {
      if (attachment.id == primaryId &&
          attachment.role == AttachmentRole.primaryArtworkPhoto) {
        return attachment;
      }
    }
    return null;
  }

  bool get isMissingSupportingRecords => hasMissingSupportingRecords(
    record,
    supportingAttachmentCount: supportingAttachmentCount,
  );
}

class ArtworkCollectionSnapshot {
  const ArtworkCollectionSnapshot({
    required this.entries,
    required this.totalRecordCount,
    required this.activeRecordCount,
    required this.availableLocations,
  });

  final List<ArtworkCollectionEntry> entries;
  final int totalRecordCount;
  final int activeRecordCount;
  final List<String> availableLocations;
}

bool hasMissingSupportingRecords(
  ArtworkRecord record, {
  required int supportingAttachmentCount,
}) {
  return record.lifecycleStatus == ArtworkLifecycleStatus.active &&
      record.recordState == ArtworkRecordState.missingDocuments &&
      supportingAttachmentCount == 0;
}

String normalizedCollectionText(String? value) =>
    value?.trim().toLowerCase() ?? '';
