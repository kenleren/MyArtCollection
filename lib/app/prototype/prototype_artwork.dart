class PrototypeArtwork {
  const PrototypeArtwork({
    required this.id,
    required this.title,
    required this.artist,
    required this.year,
    required this.medium,
    required this.dimensions,
    this.edition,
    required this.purchasePrice,
    required this.location,
    required this.insuranceValue,
    required this.condition,
    required this.documents,
  });

  final String id;
  final PrototypeField title;
  final PrototypeField artist;
  final PrototypeField year;
  final PrototypeField medium;
  final PrototypeField dimensions;
  final PrototypeField? edition;
  final PrototypeField purchasePrice;
  final PrototypeField location;
  final PrototypeField insuranceValue;
  final PrototypeField condition;
  final List<PrototypeDocument> documents;
}

class PrototypeField {
  const PrototypeField({
    required this.label,
    required this.value,
    required this.source,
    required this.note,
  });

  final String label;
  final String value;
  final PrototypeSource source;
  final String note;
}

class PrototypeDocument {
  const PrototypeDocument({
    required this.type,
    required this.fileName,
    required this.source,
    required this.note,
  });

  final String type;
  final String fileName;
  final PrototypeSource source;
  final String note;
}

enum PrototypeSource {
  aiSuggested('AI-suggested'),
  userConfirmed('User confirmed'),
  documentExtracted('Document-extracted'),
  unknown('Unknown');

  const PrototypeSource(this.label);

  final String label;
}

const prototypeArtwork = PrototypeArtwork(
  id: 'sample-001',
  title: PrototypeField(
    label: 'Title',
    value: 'Blue Interior Study',
    source: PrototypeSource.aiSuggested,
    note: 'Possible title from image notes. Please confirm.',
  ),
  artist: PrototypeField(
    label: 'Artist',
    value: 'J. Solberg',
    source: PrototypeSource.aiSuggested,
    note: 'Signature may read J. Solberg.',
  ),
  year: PrototypeField(
    label: 'Year',
    value: 'Could not determine',
    source: PrototypeSource.unknown,
    note: 'Leave unknown or enter a year after review.',
  ),
  medium: PrototypeField(
    label: 'Medium',
    value: 'Likely oil on canvas',
    source: PrototypeSource.aiSuggested,
    note: 'Likely medium from visible surface texture.',
  ),
  dimensions: PrototypeField(
    label: 'Dimensions',
    value: '60 x 80 cm',
    source: PrototypeSource.documentExtracted,
    note: 'Looks extracted from attached receipt.',
  ),
  purchasePrice: PrototypeField(
    label: 'Purchase price',
    value: 'USD 1,800',
    source: PrototypeSource.documentExtracted,
    note: 'Receipt amount recorded for your private archive.',
  ),
  location: PrototypeField(
    label: 'Current location',
    value: 'Living room, north wall',
    source: PrototypeSource.userConfirmed,
    note: 'User confirmed.',
  ),
  insuranceValue: PrototypeField(
    label: 'User-provided insurance value',
    value: 'USD 2,400',
    source: PrototypeSource.userConfirmed,
    note: 'User-provided insurance values only.',
  ),
  condition: PrototypeField(
    label: 'Condition notes',
    value: 'Visible condition issue near lower right frame.',
    source: PrototypeSource.aiSuggested,
    note: 'Please confirm before report export.',
  ),
  documents: [
    PrototypeDocument(
      type: 'Receipt',
      fileName: 'gallery-receipt-2025.pdf',
      source: PrototypeSource.documentExtracted,
      note: 'Supports purchase record; does not prove authenticity.',
    ),
    PrototypeDocument(
      type: 'Provenance note',
      fileName: 'owner-note.txt',
      source: PrototypeSource.userConfirmed,
      note: 'User memory, kept as a private record.',
    ),
  ],
);
