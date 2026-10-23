// JPEG XMP reading and writing (SPEC §4.1, §4.7).
//
// XMP lives in an APP1 segment whose payload starts with the 29-byte marker
// `http://ns.adobe.com/xap/1.0/\0`. Every other APP1 segment — EXIF in
// particular — must be skipped without being decoded as text, and must be
// preserved byte for byte on write (SPEC §4.7 read requirement 6 and write
// requirement 4).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'file_rewriter.dart';
import 'xmp_core.dart';
import 'xmp_model.dart';

/// The 29-byte marker that identifies an XMP APP1 segment.
final Uint8List xmpApp1Header = Uint8List.fromList(
  'http://ns.adobe.com/xap/1.0/\x00'.codeUnits,
);

/// The 6-byte marker that identifies an EXIF APP1 segment.
final Uint8List exifApp1Header = Uint8List.fromList(const [
  0x45,
  0x78,
  0x69,
  0x66,
  0x00,
  0x00,
]);

/// The largest XMP package a single APP1 segment may carry (SPEC §4.1).
const int maxJpegXmpBytes = 60 * 1024;

/// A JPEG header segment between SOI and the first SOS.
class JpegSegment {
  /// Creates a segment record.
  const JpegSegment({
    required this.marker,
    required this.start,
    required this.stop,
    required this.payloadStart,
    required this.payloadStop,
  });

  /// The marker byte, for example `0xE1` for APP1.
  final int marker;

  /// Offset of the `0xFF` that starts the segment.
  final int start;

  /// Offset just past the last byte of the segment.
  final int stop;

  /// Offset of the first payload byte.
  final int payloadStart;

  /// Offset just past the last payload byte.
  final int payloadStop;
}

/// Scans the header segments of [bytes], stopping at SOS or EOI.
///
/// Throws [FormatException] when [bytes] does not start with SOI.
List<JpegSegment> scanJpegSegments(Uint8List bytes) {
  if (bytes.length < 2 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
    throw const FormatException('Not a JPEG file');
  }

  final segments = <JpegSegment>[];
  var offset = 2;

  while (offset + 1 < bytes.length) {
    if (bytes[offset] != 0xFF) break;
    final marker = bytes[offset + 1];

    // Start of scan or end of image: the header is over.
    if (marker == 0xD9 || marker == 0xDA) break;

    // Standalone markers carry no length field.
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      segments.add(
        JpegSegment(
          marker: marker,
          start: offset,
          stop: offset + 2,
          payloadStart: offset + 2,
          payloadStop: offset + 2,
        ),
      );
      offset += 2;
      continue;
    }

    if (offset + 4 > bytes.length) break;
    final length = (bytes[offset + 2] << 8) | bytes[offset + 3];
    if (length < 2) break;
    final stop = offset + 2 + length;
    if (stop > bytes.length) break;

    segments.add(
      JpegSegment(
        marker: marker,
        start: offset,
        stop: stop,
        payloadStart: offset + 4,
        payloadStop: stop,
      ),
    );
    offset = stop;
  }

  return segments;
}

/// Scans the header segments of an open file, reading only the header.
///
/// The scan stops at SOS, so the image data is never read.
Future<List<JpegSegment>> scanJpegSegmentsFromFile(
  RandomAccessFile file,
) async {
  final length = await file.length();
  await file.setPosition(0);
  final soi = await file.read(2);
  if (soi.length < 2 || soi[0] != 0xFF || soi[1] != 0xD8) {
    throw const FormatException('Not a JPEG file');
  }

  final segments = <JpegSegment>[];
  var offset = 2;

  while (offset + 1 < length) {
    await file.setPosition(offset);
    final head = await file.read(4);
    if (head.length < 2) break;
    if (head[0] != 0xFF) break;
    final marker = head[1];

    if (marker == 0xD9 || marker == 0xDA) break;

    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      segments.add(
        JpegSegment(
          marker: marker,
          start: offset,
          stop: offset + 2,
          payloadStart: offset + 2,
          payloadStop: offset + 2,
        ),
      );
      offset += 2;
      continue;
    }

    if (head.length < 4) break;
    final segmentLength = (head[2] << 8) | head[3];
    if (segmentLength < 2) break;
    final stop = offset + 2 + segmentLength;
    if (stop > length) break;

    segments.add(
      JpegSegment(
        marker: marker,
        start: offset,
        stop: stop,
        payloadStart: offset + 4,
        payloadStop: stop,
      ),
    );
    offset = stop;
  }

  return segments;
}

/// Reads the provenance record from the XMP APP1 segment of [bytes].
///
/// Returns `null` when the file has no XMP segment. EXIF and other APP1
/// segments are skipped without being decoded.
XmpProvenance? readJpegXmp(Uint8List bytes) {
  for (final segment in scanJpegSegments(bytes)) {
    if (segment.marker != 0xE1) continue;
    if (!_hasHeader(bytes, segment, xmpApp1Header)) continue;
    final start = segment.payloadStart + xmpApp1Header.length;
    final xml = utf8.decode(
      bytes.sublist(start, segment.payloadStop),
      allowMalformed: true,
    );
    return parseXmpXml(xml);
  }
  return null;
}

/// Reads the provenance record from an open file, reading only the header.
///
/// Returns `null` when the file has no XMP segment.
Future<XmpProvenance?> readJpegXmpFromFile(RandomAccessFile file) async {
  for (final segment in await scanJpegSegmentsFromFile(file)) {
    if (segment.marker != 0xE1) continue;
    if (!await _hasHeaderInFile(file, segment, xmpApp1Header)) continue;
    final start = segment.payloadStart + xmpApp1Header.length;
    await file.setPosition(start);
    final payload = await file.read(segment.payloadStop - start);
    return parseXmpXml(utf8.decode(payload, allowMalformed: true));
  }
  return null;
}

/// Returns the raw XMP text of the first XMP APP1 segment, or `null`.
String? readJpegXmpText(Uint8List bytes) {
  for (final segment in scanJpegSegments(bytes)) {
    if (segment.marker != 0xE1) continue;
    if (!_hasHeader(bytes, segment, xmpApp1Header)) continue;
    return utf8.decode(
      bytes.sublist(
        segment.payloadStart + xmpApp1Header.length,
        segment.payloadStop,
      ),
      allowMalformed: true,
    );
  }
  return null;
}

/// Writes [provenance] into the XMP APP1 segment of [bytes].
///
/// An existing XMP segment is replaced in place; otherwise a new segment is
/// inserted after the last APPn segment. EXIF and every other segment are
/// copied unchanged.
Uint8List writeJpegXmp(Uint8List bytes, XmpProvenance provenance) {
  final segments = scanJpegSegments(bytes);
  final existing = _findXmpSegment(bytes, segments);
  final currentXml = existing == null
      ? null
      : utf8.decode(
          bytes.sublist(
            existing.payloadStart + xmpApp1Header.length,
            existing.payloadStop,
          ),
          allowMalformed: true,
        );
  final plan = _planWrite(segments, existing, currentXml, provenance);

  final builder = BytesBuilder(copy: false)
    ..add(bytes.sublist(0, plan.start))
    ..add(plan.segment)
    ..add(bytes.sublist(plan.stop));
  return builder.toBytes();
}

/// Writes [provenance] into the XMP APP1 segment of the file at [path].
///
/// The file is rewritten through a temporary file, so a failure leaves the
/// original untouched. Only the header is read into memory.
Future<void> writeJpegXmpToFile(String path, XmpProvenance provenance) async {
  final file = await File(path).open();
  late final _WritePlan plan;
  try {
    final segments = await scanJpegSegmentsFromFile(file);
    JpegSegment? existing;
    for (final segment in segments) {
      if (segment.marker != 0xE1) continue;
      if (await _hasHeaderInFile(file, segment, xmpApp1Header)) {
        existing = segment;
        break;
      }
    }

    String? currentXml;
    if (existing != null) {
      final start = existing.payloadStart + xmpApp1Header.length;
      await file.setPosition(start);
      final payload = await file.read(existing.payloadStop - start);
      currentXml = utf8.decode(payload, allowMalformed: true);
    }

    plan = _planWrite(segments, existing, currentXml, provenance);
  } finally {
    await file.close();
  }

  await rewriteFile(path, [FileRegion(plan.start, plan.stop, plan.segment)]);
}

class _WritePlan {
  const _WritePlan(this.start, this.stop, this.segment);

  final int start;
  final int stop;
  final List<int> segment;
}

_WritePlan _planWrite(
  List<JpegSegment> segments,
  JpegSegment? existing,
  String? currentXml,
  XmpProvenance provenance,
) {
  final xml = currentXml == null
      ? buildXmpXml(provenance)
      : updateXmpXml(currentXml, provenance);
  final xmlBytes = utf8.encode(xml);
  if (xmlBytes.length >= maxJpegXmpBytes) {
    throw ArgumentError.value(
      xmlBytes.length,
      'provenance',
      'XMP package must stay below 60 KB for a JPEG APP1 segment (SPEC §4.1)',
    );
  }

  final length = 2 + xmpApp1Header.length + xmlBytes.length;
  final segment = <int>[
    0xFF,
    0xE1,
    (length >> 8) & 0xFF,
    length & 0xFF,
    ...xmpApp1Header,
    ...xmlBytes,
  ];

  if (existing != null) {
    return _WritePlan(existing.start, existing.stop, segment);
  }

  // Insert after the last APPn segment so that EXIF keeps its position.
  var insertAt = 2;
  for (final candidate in segments) {
    if (candidate.marker >= 0xE0 && candidate.marker <= 0xEF) {
      insertAt = candidate.stop;
    }
  }
  return _WritePlan(insertAt, insertAt, segment);
}

JpegSegment? _findXmpSegment(Uint8List bytes, List<JpegSegment> segments) {
  for (final segment in segments) {
    if (segment.marker != 0xE1) continue;
    if (_hasHeader(bytes, segment, xmpApp1Header)) return segment;
  }
  return null;
}

bool _hasHeader(Uint8List bytes, JpegSegment segment, Uint8List header) {
  if (segment.payloadStop - segment.payloadStart < header.length) return false;
  for (var i = 0; i < header.length; i++) {
    if (bytes[segment.payloadStart + i] != header[i]) return false;
  }
  return true;
}

Future<bool> _hasHeaderInFile(
  RandomAccessFile file,
  JpegSegment segment,
  Uint8List header,
) async {
  if (segment.payloadStop - segment.payloadStart < header.length) return false;
  await file.setPosition(segment.payloadStart);
  final bytes = await file.read(header.length);
  if (bytes.length < header.length) return false;
  for (var i = 0; i < header.length; i++) {
    if (bytes[i] != header[i]) return false;
  }
  return true;
}
