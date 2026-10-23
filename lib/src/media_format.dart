// Container format detection from magic bytes.

import 'dart:io';
import 'dart:typed_data';

import 'xmp_mp4.dart';

/// A media container this package can read or write.
enum MediaFormat {
  /// JPEG: `FF D8`, XMP lives in an APP1 segment (SPEC §4.1).
  jpeg,

  /// PNG: `89 50 4E 47`, XMP lives in an `iTXt` chunk (SPEC §4.1).
  png,

  /// WebP: `RIFF....WEBP`, XMP lives in an `XMP ` chunk (SPEC §4.1).
  webp,

  /// MP4 or MOV: an ISO BMFF / QuickTime box chain, XMP lives in a top-level
  /// `uuid` box (SPEC §4.1).
  mp4,

  /// Any other format; provenance goes to a sidecar file (SPEC §4.1).
  other,
}

/// Detects the container format of [bytes] from its magic bytes.
MediaFormat detectFormat(Uint8List bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
    return MediaFormat.jpeg;
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0D &&
      bytes[5] == 0x0A &&
      bytes[6] == 0x1A &&
      bytes[7] == 0x0A) {
    return MediaFormat.png;
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return MediaFormat.webp;
  }
  if (isMp4Header(bytes)) return MediaFormat.mp4;
  return MediaFormat.other;
}

/// Detects the container format of an open file from its first 16 bytes.
///
/// Only the header is read, so this is safe for very large files. Sixteen
/// bytes are enough to see a 64-bit box header (`size == 1` plus `largesize`).
Future<MediaFormat> detectFormatFromFile(RandomAccessFile file) async {
  await file.setPosition(0);
  final header = await file.read(16);
  return detectFormat(header);
}
