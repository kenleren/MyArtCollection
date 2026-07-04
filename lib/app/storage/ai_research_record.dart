import 'artwork_record.dart';

enum AiDraftJobStatus {
  pending('pending'),
  running('running'),
  completed('completed'),
  unavailable('unavailable'),
  failed('failed');

  const AiDraftJobStatus(this.storageValue);

  final String storageValue;

  static AiDraftJobStatus fromStorage(String value) {
    return AiDraftJobStatus.values.firstWhere(
      (status) => status.storageValue == value,
      orElse: () => AiDraftJobStatus.pending,
    );
  }
}

enum ResearchJobStatus {
  pendingConsent('pending_consent'),
  queued('queued'),
  running('running'),
  completed('completed'),
  failed('failed'),
  cancelled('cancelled');

  const ResearchJobStatus(this.storageValue);

  final String storageValue;

  static ResearchJobStatus fromStorage(String value) {
    return ResearchJobStatus.values.firstWhere(
      (status) => status.storageValue == value,
      orElse: () => ResearchJobStatus.pendingConsent,
    );
  }
}

enum ResearchSourceType {
  museumCollection('museum_collection'),
  culturalHeritageApi('cultural_heritage_api'),
  gallery('gallery'),
  artistFoundation('artist_foundation'),
  auctionHouse('auction_house'),
  reference('reference'),
  unknown('unknown');

  const ResearchSourceType(this.storageValue);

  final String storageValue;

  static ResearchSourceType fromStorage(String value) {
    return ResearchSourceType.values.firstWhere(
      (type) => type.storageValue == value,
      orElse: () => ResearchSourceType.unknown,
    );
  }
}

enum ResearchConfidence {
  possible('possible'),
  likely('likely'),
  insufficientEvidence('insufficient_evidence');

  const ResearchConfidence(this.storageValue);

  final String storageValue;

  static ResearchConfidence fromStorage(String value) {
    return ResearchConfidence.values.firstWhere(
      (confidence) => confidence.storageValue == value,
      orElse: () => ResearchConfidence.insufficientEvidence,
    );
  }
}

enum ComparableValueKind {
  publicEstimate('public_estimate'),
  comparableSaleSignal('comparable_sale_signal'),
  userProvidedInsuranceValue('user_provided_insurance_value'),
  noReliableComparable('no_reliable_comparable');

  const ComparableValueKind(this.storageValue);

  final String storageValue;

  static ComparableValueKind fromStorage(String value) {
    return ComparableValueKind.values.firstWhere(
      (kind) => kind.storageValue == value,
      orElse: () => ComparableValueKind.noReliableComparable,
    );
  }
}

extension ComparableValueKindDisplay on ComparableValueKind {
  String get displayLabel {
    return switch (this) {
      ComparableValueKind.publicEstimate => 'Public estimate found',
      ComparableValueKind.comparableSaleSignal => 'Comparable sale signal',
      ComparableValueKind.userProvidedInsuranceValue =>
        'User-provided insurance value',
      ComparableValueKind.noReliableComparable =>
        'No reliable comparable found',
    };
  }

  bool get canDisplayAmount {
    return switch (this) {
      ComparableValueKind.publicEstimate ||
      ComparableValueKind.comparableSaleSignal ||
      ComparableValueKind.userProvidedInsuranceValue => true,
      ComparableValueKind.noReliableComparable => false,
    };
  }
}

class AiDraftJob {
  const AiDraftJob({
    required this.id,
    required this.artworkId,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.primaryImageAttachmentId,
    this.completedAt,
    this.deviceModel,
    this.promptVersion,
    this.visualSummary,
    this.signatureNotes,
    this.subjectMatter,
    this.mediumHint,
    this.stylePeriodHint,
    this.conditionNotes,
    this.searchTerms = const [],
    this.errorMessage,
  });

  final String id;
  final String artworkId;
  final String? primaryImageAttachmentId;
  final AiDraftJobStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;
  final String? deviceModel;
  final String? promptVersion;
  final String? visualSummary;
  final String? signatureNotes;
  final String? subjectMatter;
  final String? mediumHint;
  final String? stylePeriodHint;
  final String? conditionNotes;
  final List<String> searchTerms;
  final String? errorMessage;
}

class ResearchSourceHit {
  const ResearchSourceHit({
    required this.id,
    required this.researchJobId,
    required this.sourceName,
    required this.sourceType,
    required this.confidence,
    this.sourceUrl,
    this.objectId,
    this.title,
    this.artist,
    this.dateText,
    this.medium,
    this.dimensions,
    this.imageUrl,
    this.matchReason,
    this.rawSnippet,
  });

  final String id;
  final String researchJobId;
  final String sourceName;
  final ResearchSourceType sourceType;
  final ResearchConfidence confidence;
  final String? sourceUrl;
  final String? objectId;
  final String? title;
  final String? artist;
  final String? dateText;
  final String? medium;
  final String? dimensions;
  final String? imageUrl;
  final String? matchReason;
  final String? rawSnippet;
}

class CandidateAttribution {
  const CandidateAttribution({
    required this.id,
    required this.researchJobId,
    required this.confidence,
    required this.matchReason,
    this.sourceHitId,
    this.title,
    this.artist,
    this.year,
    this.medium,
    this.fieldSources = const {},
  });

  final String id;
  final String researchJobId;
  final String? sourceHitId;
  final String? title;
  final String? artist;
  final String? year;
  final String? medium;
  final ResearchConfidence confidence;
  final String matchReason;
  final Map<String, ArtworkFieldSource> fieldSources;
}

class ComparableValueSignal {
  const ComparableValueSignal({
    required this.id,
    required this.researchJobId,
    required this.kind,
    required this.label,
    required this.sourceName,
    required this.caveat,
    this.sourceHitId,
    this.sourceUrl,
    this.amountLow,
    this.amountHigh,
    this.currency,
    this.signalDate,
  });

  final String id;
  final String researchJobId;
  final String? sourceHitId;
  final ComparableValueKind kind;
  final String label;
  final String sourceName;
  final String? sourceUrl;
  final String? amountLow;
  final String? amountHigh;
  final String? currency;
  final DateTime? signalDate;
  final String caveat;
}

class ResearchJob {
  const ResearchJob({
    required this.id,
    required this.artworkId,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    required this.consentSummary,
    this.completedAt,
    this.querySummary,
    this.provider,
    this.errorMessage,
    this.sourceHits = const [],
    this.candidateAttributions = const [],
    this.comparableValueSignals = const [],
  });

  final String id;
  final String artworkId;
  final ResearchJobStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;
  final String consentSummary;
  final String? querySummary;
  final String? provider;
  final String? errorMessage;
  final List<ResearchSourceHit> sourceHits;
  final List<CandidateAttribution> candidateAttributions;
  final List<ComparableValueSignal> comparableValueSignals;
}
