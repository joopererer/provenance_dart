// Minimal container fixtures used by the unit tests.
//
// These are hand-built byte sequences, not real images: they only need to be
// structurally valid enough for the header scanners.

import 'dart:typed_data';

import 'package:provenance_dart/provenance_dart.dart';

/// A minimal JPEG: SOI, APP0, SOF0, SOS, EOI.
Uint8List minimalJpeg() => Uint8List.fromList([
  0xFF, 0xD8, // SOI
  0xFF, 0xE0, 0x00, 0x10, // APP0, length 16
  0x4A, 0x46, 0x49, 0x46, 0x00, // "JFIF\0"
  ...List.filled(9, 0),
  0xFF, 0xC0, 0x00, 0x0B, // SOF0, length 11
  0x08, 0x00, 0x01, 0x00, 0x01, // 8-bit, 1x1
  0x01, 0x01, 0x11, 0x00,
  0xFF, 0xDA, 0x00, 0x08, // SOS, length 8
  0x01, 0x01, 0x00, 0x00, 0x3F, 0x00,
  0xFF, 0xD9, // EOI
]);

/// A minimal JPEG whose only APP1 segment is EXIF (no XMP).
Uint8List jpegWithExifOnly() {
  final exif = <int>[
    0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // "Exif\0\0"
    0x4D, 0x4D, 0x00, 0x2A, // big-endian TIFF header
    0x00, 0x00, 0x00, 0x08, // IFD0 offset
    0x00, 0x00, // no entries
    0x00, 0x00, 0x00, 0x00, // next IFD
  ];
  final length = 2 + exif.length;
  return Uint8List.fromList([
    0xFF, 0xD8, // SOI
    0xFF, 0xE1, (length >> 8) & 0xFF, length & 0xFF, ...exif,
    0xFF, 0xDA, 0x00, 0x08, // SOS
    0x01, 0x01, 0x00, 0x00, 0x3F, 0x00,
    0xFF, 0xD9, // EOI
  ]);
}

/// A minimal PNG: signature, IHDR, IEND.
Uint8List minimalPng() => Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
  0x00, 0x00, 0x00, 0x0D, // IHDR length 13
  0x49, 0x48, 0x44, 0x52, // "IHDR"
  0x00, 0x00, 0x00, 0x01, // width 1
  0x00, 0x00, 0x00, 0x01, // height 1
  0x08, 0x02, 0x00, 0x00, 0x00, // 8-bit RGB
  0x90, 0x77, 0x53, 0xDE, // CRC
  0x00, 0x00, 0x00, 0x00, // IEND length 0
  0x49, 0x45, 0x4E, 0x44, // "IEND"
  0xAE, 0x42, 0x60, 0x82, // CRC
]);

/// A minimal simple-format (VP8) WebP, 1x1 pixel.
Uint8List minimalWebpVp8() => Uint8List.fromList([
  0x52, 0x49, 0x46, 0x46, // "RIFF"
  0x20, 0x00, 0x00, 0x00, // size - 8
  0x57, 0x45, 0x42, 0x50, // "WEBP"
  0x56, 0x50, 0x38, 0x20, // "VP8 "
  0x14, 0x00, 0x00, 0x00, // chunk size 20
  0x00, 0x00, 0x00, // frame tag
  0x9D, 0x01, 0x2A, // start code
  0x01, 0x00, 0x01, 0x00, // width 1, height 1
  ...List.filled(10, 0),
]);

/// A minimal simple-format (VP8L) WebP, 1x1 pixel.
Uint8List minimalWebpVp8l() => Uint8List.fromList([
  0x52, 0x49, 0x46, 0x46, // "RIFF"
  0x18, 0x00, 0x00, 0x00, // size - 8
  0x57, 0x45, 0x42, 0x50, // "WEBP"
  0x56, 0x50, 0x38, 0x4C, // "VP8L"
  0x0C, 0x00, 0x00, 0x00, // chunk size 12
  0x2F, // signature
  0x00, 0x00, 0x00, 0x00, // width 1, height 1
  ...List.filled(7, 0),
]);

/// A minimal extended-format (VP8X) WebP, 1x1 pixel.
Uint8List minimalWebpExtended() => Uint8List.fromList([
  0x52, 0x49, 0x46, 0x46, // "RIFF"
  0x30, 0x00, 0x00, 0x00, // size - 8
  0x57, 0x45, 0x42, 0x50, // "WEBP"
  0x56, 0x50, 0x38, 0x58, // "VP8X"
  0x0A, 0x00, 0x00, 0x00, // chunk size 10
  0x00, 0x00, 0x00, 0x00, // flags + reserved
  0x00, 0x00, 0x00, // canvas width - 1
  0x00, 0x00, 0x00, // canvas height - 1
  0x56, 0x50, 0x38, 0x20, // "VP8 "
  0x14, 0x00, 0x00, 0x00, // chunk size 20
  0x00, 0x00, 0x00,
  0x9D, 0x01, 0x2A,
  0x01, 0x00, 0x01, 0x00,
  ...List.filled(10, 0),
]);

/// A provenance record with every field set, for round-trip tests.
XmpProvenance sampleProvenance({
  String assetId = '3f0c6a2e-8d4b-4c1a-9a3e-2b7f5d9e1c40',
  DateTime? metadataDate,
  Map<String, String> otherFields = const {},
}) => XmpProvenance(
  schema: '0.1',
  assetId: assetId,
  capturedAt: DateTime.utc(2026, 10, 20, 13, 30),
  capturedBy: 'TestApp/1.0.0',
  metadataDate: metadataDate ?? DateTime.utc(2026, 10, 20, 13, 30),
  sourceUrl: 'https://www.xiaohongshu.com/explore/6ad2f7050000000012034042',
  platform: 'xiaohongshu',
  sourceId: '6ad2f7050000000012034042',
  itemIndex: 3,
  itemCount: 9,
  authorId: '5f1a2b3c000000000100abcd',
  publishedAt: DateTime.utc(2026, 10, 18, 1, 12),
  title: 'wow～ 好干净的奶白色',
  creators: const ['示例作者'],
  description: '示例正文 & 特殊字符 <测试> "引号"',
  subject: const ['家居', '奶白色'],
  rating: 4,
  credit: '示例作者 / 小红书',
  otherFields: otherFields,
);

/// Extracts the data of the RIFF chunk [fourCc] from [webp], or `null`.
Uint8List? extractWebpChunk(Uint8List webp, String fourCc) {
  var offset = 12;
  while (offset + 8 <= webp.length) {
    final code = String.fromCharCodes(webp.sublist(offset, offset + 4));
    final size =
        webp[offset + 4] |
        (webp[offset + 5] << 8) |
        (webp[offset + 6] << 16) |
        (webp[offset + 7] << 24);
    if (code == fourCc) {
      return webp.sublist(offset + 8, offset + 8 + size);
    }
    offset += 8 + size + (size.isOdd ? 1 : 0);
  }
  return null;
}
