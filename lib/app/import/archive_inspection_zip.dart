import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:crypto/crypto.dart';

import '../export/archive_attachment_payload_contract.dart';
import 'archive_inspection.dart';
import 'archive_inspection_deflate.dart';

const inspectionStructuredPaths = [
  'manifest.json',
  'records/artworks.json',
  'records/external_references.json',
  'records/attachments.json',
  'records/groupings.json',
];

Never invalidInspection() => throw const ArchiveInspectionException(
  ArchiveInspectionFailure.invalidArchive,
);
void inspectionLimit(bool exceeded) {
  if (exceeded) {
    throw const ArchiveInspectionException(
      ArchiveInspectionFailure.unsupportedResourceLimit,
    );
  }
}

class InspectedZipEntry {
  InspectedZipEntry({
    required this.name,
    required this.offset,
    required this.compressed,
    required this.expanded,
    required this.method,
    required this.crc,
    required this.flags,
    required this.time,
    required this.date,
    required this.version,
  });
  final String name;
  final int offset,
      compressed,
      expanded,
      method,
      crc,
      flags,
      time,
      date,
      version;
  late int dataOffset;
  late String sha256Hex;
  Uint8List? metadata;
}

/// Restricted single-disk ZIP profile. Parses fixed headers before allocating
/// variable data. ZIP64, descriptors, encryption and unusual metadata are not
/// emitted by the bounded current exporter and are explicitly unsupported.
class InspectionZipReader {
  InspectionZipReader(this.file, this.length, this.cancellation);
  final RandomAccessFile file;
  final int length;
  final ArchiveInspectionCancellation cancellation;

  Future<Uint8List> _read(int offset, int count) async {
    cancellation.check();
    if (offset < 0 || count < 0 || offset + count > length) invalidInspection();
    await file.setPosition(offset);
    final result = await file.read(count);
    if (result.length != count) invalidInspection();
    return result;
  }

  Future<List<InspectedZipEntry>> read() async {
    if (length < 22) invalidInspection();
    // EOCD plus the maximum uint16 comment; this is a fixed allocation ceiling.
    final tailStart = max(0, length - 65557);
    final tail = await _read(tailStart, length - tailStart);
    var end = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (_u32(tail, i) == 0x06054b50 &&
          i + 22 + _u16(tail, i + 20) == tail.length) {
        end = i;
        break;
      }
    }
    if (end < 0) invalidInspection();
    final count = _u16(tail, end + 10);
    inspectionLimit(count > ArchiveInspectionLimits.entries);
    final centralSize = _u32(tail, end + 12);
    final centralOffset = _u32(tail, end + 16);
    if (_u16(tail, end + 4) != 0 ||
        _u16(tail, end + 6) != 0 ||
        _u16(tail, end + 8) != count ||
        count == 0 ||
        centralOffset + centralSize != tailStart + end) {
      invalidInspection();
    }
    final entries = <InspectedZipEntry>[];
    final names = <String>{};
    var cursor = centralOffset;
    var totalExpanded = 0;
    var totalMetadata = 0;
    for (var i = 0; i < count; i++) {
      if (cursor + 46 > centralOffset + centralSize) invalidInspection();
      final header = await _read(cursor, 46);
      if (_u32(header, 0) != 0x02014b50) invalidInspection();
      final flags = _u16(header, 8);
      final method = _u16(header, 10);
      final nameSize = _u16(header, 28);
      final extraSize = _u16(header, 30);
      final commentSize = _u16(header, 32);
      inspectionLimit(nameSize > ArchiveInspectionLimits.pathBytes);
      if ((flags & ~0x800) != 0 ||
          (method != 0 && method != 8) ||
          extraSize != 0 ||
          commentSize != 0 ||
          _u16(header, 34) != 0 ||
          _u16(header, 6) > 20) {
        throw const ArchiveInspectionException(
          ArchiveInspectionFailure.unsupportedZipFeature,
        );
      }
      final mode = (_u32(header, 38) >> 16) & 0xf000;
      if (mode != 0 && mode != 0x8000 || (_u32(header, 38) & 0x10) != 0) {
        invalidInspection();
      }
      if (cursor + 46 + nameSize > centralOffset + centralSize) {
        invalidInspection();
      }
      final name = utf8.decode(
        await _read(cursor + 46, nameSize),
        allowMalformed: false,
      );
      inspectionLimit(
        name.split('/').length > ArchiveInspectionLimits.pathDepth,
      );
      if ((!inspectionStructuredPaths.contains(name) &&
              !isApprovedArchivePayloadPath(name)) ||
          !names.add(name)) {
        invalidInspection();
      }
      final expanded = _u32(header, 24);
      final compressed = _u32(header, 20);
      final isMetadata = inspectionStructuredPaths.contains(name);
      final cap = name == 'manifest.json'
          ? ArchiveInspectionLimits.manifestBytes
          : isMetadata
          ? ArchiveInspectionLimits.structuredEntryBytes
          : ArchiveInspectionLimits.payloadBytes;
      inspectionLimit(
        expanded > cap || compressed > ArchiveInspectionLimits.inputBytes,
      );
      totalExpanded += expanded;
      if (isMetadata) totalMetadata += expanded;
      inspectionLimit(
        totalExpanded > ArchiveInspectionLimits.expandedBytes ||
            totalMetadata > ArchiveInspectionLimits.structuredTotalBytes,
      );
      if (method == 0 && compressed != expanded) invalidInspection();
      entries.add(
        InspectedZipEntry(
          name: name,
          offset: _u32(header, 42),
          compressed: compressed,
          expanded: expanded,
          method: method,
          crc: _u32(header, 16),
          flags: flags,
          time: _u16(header, 12),
          date: _u16(header, 14),
          version: _u16(header, 6),
        ),
      );
      cursor += 46 + nameSize;
    }
    if (cursor != centralOffset + centralSize) invalidInspection();

    // Exact contiguous local layout excludes hidden, overlapping, reordered,
    // prefixed or trailing file records, and bounds every subsequent read.
    cursor = 0;
    for (final entry in entries) {
      if (entry.offset != cursor || cursor + 30 > centralOffset) {
        invalidInspection();
      }
      final local = await _read(cursor, 30);
      final nameSize = _u16(local, 26);
      inspectionLimit(nameSize > ArchiveInspectionLimits.pathBytes);
      if (_u32(local, 0) != 0x04034b50 ||
          _u16(local, 4) != entry.version ||
          _u16(local, 6) != entry.flags ||
          _u16(local, 8) != entry.method ||
          _u16(local, 10) != entry.time ||
          _u16(local, 12) != entry.date ||
          _u32(local, 14) != entry.crc ||
          _u32(local, 18) != entry.compressed ||
          _u32(local, 22) != entry.expanded ||
          _u16(local, 28) != 0) {
        invalidInspection();
      }
      if (utf8.decode(
            await _read(cursor + 30, nameSize),
            allowMalformed: false,
          ) !=
          entry.name) {
        invalidInspection();
      }
      entry.dataOffset = cursor + 30 + nameSize;
      cursor = entry.dataOffset + entry.compressed;
      if (cursor > centralOffset) invalidInspection();
    }
    if (cursor != centralOffset) invalidInspection();
    for (final entry in entries) {
      cancellation.check();
      await _consume(entry);
    }
    return entries;
  }

  Future<void> _consume(InspectedZipEntry entry) async {
    if (entry.method == 8) {
      await verifyInspectionDeflate(
        file,
        entry.dataOffset,
        entry.compressed,
        entry.expanded,
        cancellation,
      );
    }
    final digest = _DigestSink();
    final hash = sha256.startChunkedConversion(digest);
    final metadata = inspectionStructuredPaths.contains(entry.name)
        ? BytesBuilder(copy: false)
        : null;
    var crc = 0;
    var expanded = 0;
    void accept(List<int> chunk) {
      cancellation.check();
      // Checked before accumulating bytes or feeding metadata parsers.
      if (expanded + chunk.length > entry.expanded) invalidInspection();
      expanded += chunk.length;
      hash.add(chunk);
      crc = getCrc32(chunk, crc);
      metadata?.add(chunk);
    }

    final filter = entry.method == 8
        ? RawZLibFilter.inflateFilter(raw: true)
        : null;
    var cursor = entry.dataOffset;
    var remaining = entry.compressed;
    if (filter != null && remaining == 0) filter.process(const [], 0, 0);
    while (remaining > 0) {
      final chunk = await _read(
        cursor,
        min(remaining, ArchiveInspectionLimits.bufferBytes),
      );
      cursor += chunk.length;
      remaining -= chunk.length;
      if (filter == null) {
        accept(chunk);
      } else {
        filter.process(chunk, 0, chunk.length);
        while (true) {
          cancellation.check();
          final output = filter.processed(flush: false);
          if (output == null) break;
          accept(output);
          // Yield between native bounded output blocks so cancellation can run.
          await Future<void>.delayed(Duration.zero);
        }
      }
    }
    if (filter != null) {
      while (true) {
        cancellation.check();
        final output = filter.processed(end: true);
        if (output == null) break;
        accept(output);
      }
    }
    hash.close();
    if (expanded != entry.expanded || crc != entry.crc) invalidInspection();
    entry.sha256Hex = digest.value!.toString();
    entry.metadata = metadata?.takeBytes();
  }
}

class InspectionDigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

typedef _DigestSink = InspectionDigestSink;
int _u16(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint16(offset, Endian.little);
int _u32(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint32(offset, Endian.little);
