// C2PA content credential detection (SPEC §4.3).
//
// Files that carry C2PA content credentials must not have XMP embedded: doing
// so invalidates the signature. This detector only looks for the container
// markers, it does not parse the manifest.

import 'dart:io';
import 'dart:typed_data';

import 'media_format.dart';
import 'xmp_jpeg.dart';
import 'xmp_png.dart';
import 'xmp_webp.dart';

/// Result of a C2PA detection scan.
enum C2paStatus {
  /// No C2PA signature found in the file.
  none,

  /// C2PA content credentials detected.
  detected,
}

/// Scans [bytes] for C2PA content credentials.
C2paStatus detectC2pa(Uint8List bytes, MediaFormat format) {
  switch (format) {
    case MediaFormat.jpeg:
      return _detectJpeg(bytes);
    case MediaFormat.png:
      return _detectPng(bytes);
    case MediaFormat.webp:
      return _detectWebp(bytes);
    case MediaFormat.other:
      return C2paStatus.none;
  }
}

/// Scans an open file for C2PA content credentials.
///
/// Only container headers and the APP11 payload are read, so this is safe for
/// very large files.
Future<C2paStatus> detectC2paFromFile(
  RandomAccessFile file,
  MediaFormat format,
) async {
  switch (format) {
    case MediaFormat.jpeg:
      for (final segment in await scanJpegSegmentsFromFile(file)) {
        if (segment.marker != 0xEB) continue;
        await file.setPosition(segment.payloadStart);
        final data = await file.read(
          segment.payloadStop - segment.payloadStart,
        );
        if (_hasC2paJumbf(data)) return C2paStatus.detected;
      }
      return C2paStatus.none;
    case MediaFormat.png:
      for (final chunk in await scanPngChunksFromFile(file)) {
        if (_isC2paPngChunk(chunk.type)) return C2paStatus.detected;
      }
      return C2paStatus.none;
    case MediaFormat.webp:
      for (final chunk in await scanWebpChunksFromFile(file)) {
        if (chunk.fourCc == 'C2PA') return C2paStatus.detected;
      }
      return C2paStatus.none;
    case MediaFormat.other:
      return C2paStatus.none;
  }
}

C2paStatus _detectJpeg(Uint8List bytes) {
  for (final segment in scanJpegSegments(bytes)) {
    if (segment.marker != 0xEB) continue;
    if (_hasC2paJumbf(
      bytes.sublist(segment.payloadStart, segment.payloadStop),
    )) {
      return C2paStatus.detected;
    }
  }
  return C2paStatus.none;
}

C2paStatus _detectPng(Uint8List bytes) {
  for (final chunk in scanPngChunks(bytes)) {
    if (_isC2paPngChunk(chunk.type)) return C2paStatus.detected;
  }
  return C2paStatus.none;
}

C2paStatus _detectWebp(Uint8List bytes) {
  for (final chunk in scanWebpChunks(bytes)) {
    if (chunk.fourCc == 'C2PA') return C2paStatus.detected;
  }
  return C2paStatus.none;
}

bool _isC2paPngChunk(String type) =>
    type == 'caBX' || type == 'c2Ch' || type == 'c2Sp';

/// The JUMBF UUID that identifies a C2PA manifest box.
const List<int> _c2paUuid = [
  0x00, 0x1c, 0x7d, 0x0c, //
  0x80, 0x00, //
  0x11, 0xea, //
  0xb6, 0x0d, //
  0x17, 0xb8, 0x83, 0xa6, 0x0f, 0x0d,
];

bool _hasC2paJumbf(Uint8List data) {
  if (data.length >= 16) {
    var matches = true;
    for (var i = 0; i < 16; i++) {
      if (data[i] != _c2paUuid[i]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }

  // The label that follows the UUID is a null-terminated string.
  if (data.length > 16) {
    final label = String.fromCharCodes(
      data.sublist(16, data.length > 80 ? 80 : data.length),
    ).toLowerCase();
    if (label.contains('c2pa')) return true;
  }

  return false;
}
