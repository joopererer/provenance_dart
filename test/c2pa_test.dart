// C2PA content credential detection (SPEC §4.3).
//
// Ported from EasySave's `c2pa_test.dart`. The fixtures are built in code so
// the test does not depend on binary files.

import 'dart:io';
import 'dart:typed_data';

import 'package:provenance_dart/provenance_dart.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';
import 'support/vectors.dart';

void main() {
  group('JPEG', () {
    test('detects a C2PA JUMBF APP11 segment', () {
      expect(detectC2pa(_c2paJpeg(), MediaFormat.jpeg), C2paStatus.detected);
    });

    test('a normal JPEG has no C2PA', () {
      expect(detectC2pa(minimalJpeg(), MediaFormat.jpeg), C2paStatus.none);
    });

    test('the spec vector has no C2PA', () async {
      final bytes = await readVector('xhs-item3.jpg');
      expect(detectC2pa(bytes, MediaFormat.jpeg), C2paStatus.none);
    });

    test('an APP11 segment without the C2PA label is ignored', () {
      final bytes = Uint8List.fromList([
        0xFF,
        0xD8,
        0xFF,
        0xEB,
        0x00,
        0x08,
        1,
        2,
        3,
        4,
        5,
        6,
        0xFF,
        0xDA,
        0x00,
        0x08,
        0x01,
        0x01,
        0x00,
        0x00,
        0x3F,
        0x00,
        0xFF,
        0xD9,
      ]);
      expect(detectC2pa(bytes, MediaFormat.jpeg), C2paStatus.none);
    });
  });

  group('PNG', () {
    test('detects a caBX chunk', () {
      expect(detectC2pa(_c2paPng(), MediaFormat.png), C2paStatus.detected);
    });

    test('a normal PNG has no C2PA', () {
      expect(detectC2pa(minimalPng(), MediaFormat.png), C2paStatus.none);
    });

    test('the spec vector has no C2PA', () async {
      final bytes = await readVector('ig-item2.png');
      expect(detectC2pa(bytes, MediaFormat.png), C2paStatus.none);
    });
  });

  group('WebP', () {
    test('detects a C2PA chunk', () {
      expect(detectC2pa(_c2paWebp(), MediaFormat.webp), C2paStatus.detected);
    });

    test('a normal WebP has no C2PA', () {
      expect(detectC2pa(minimalWebpVp8(), MediaFormat.webp), C2paStatus.none);
    });

    test('the spec vector has no C2PA', () async {
      final bytes = await readVector('x-single.webp');
      expect(detectC2pa(bytes, MediaFormat.webp), C2paStatus.none);
    });
  });

  group('other formats', () {
    test('an unknown format reports none', () {
      expect(
        detectC2pa(Uint8List.fromList([0, 1, 2, 3]), MediaFormat.other),
        C2paStatus.none,
      );
    });
  });

  group('file-based detection', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('provenance_c2pa_');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('detects C2PA in a JPEG file', () async {
      final path = '${dir.path}/signed.jpg';
      await File(path).writeAsBytes(_c2paJpeg());
      final handle = await File(path).open();
      try {
        expect(
          await detectC2paFromFile(handle, MediaFormat.jpeg),
          C2paStatus.detected,
        );
      } finally {
        await handle.close();
      }
    });

    test('detects C2PA in a PNG file', () async {
      final path = '${dir.path}/signed.png';
      await File(path).writeAsBytes(_c2paPng());
      final handle = await File(path).open();
      try {
        expect(
          await detectC2paFromFile(handle, MediaFormat.png),
          C2paStatus.detected,
        );
      } finally {
        await handle.close();
      }
    });

    test('detects C2PA in a WebP file', () async {
      final path = '${dir.path}/signed.webp';
      await File(path).writeAsBytes(_c2paWebp());
      final handle = await File(path).open();
      try {
        expect(
          await detectC2paFromFile(handle, MediaFormat.webp),
          C2paStatus.detected,
        );
      } finally {
        await handle.close();
      }
    });
  });
}

const _c2paUuid = [
  0x00,
  0x1c,
  0x7d,
  0x0c,
  0x80,
  0x00,
  0x11,
  0xea,
  0xb6,
  0x0d,
  0x17,
  0xb8,
  0x83,
  0xa6,
  0x0f,
  0x0d,
];

Uint8List _c2paJpeg() {
  final payload = <int>[..._c2paUuid, ...'c2pa\x00'.codeUnits];
  final length = 2 + payload.length;
  return Uint8List.fromList([
    0xFF,
    0xD8,
    0xFF,
    0xEB,
    (length >> 8) & 0xFF,
    length & 0xFF,
    ...payload,
    0xFF,
    0xDA,
    0x00,
    0x08,
    0x01,
    0x01,
    0x00,
    0x00,
    0x3F,
    0x00,
    0xFF,
    0xD9,
  ]);
}

Uint8List _c2paPng() {
  final out = BytesBuilder();
  out.add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  out.add(
    _pngChunk('IHDR', [
      0x00,
      0x00,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x08,
      0x02,
      0x00,
      0x00,
      0x00,
    ]),
  );
  out.add(_pngChunk('caBX', [0x00, 0x01, 0x02, 0x03]));
  out.add(_pngChunk('IEND', const []));
  return out.toBytes();
}

Uint8List _c2paWebp() {
  final chunks = BytesBuilder();
  chunks.add(
    _riffChunk('VP8X', [
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
    ]),
  );
  chunks.add(_riffChunk('C2PA', [0x01, 0x00]));
  final body = chunks.toBytes();

  final out = BytesBuilder();
  out.add([0x52, 0x49, 0x46, 0x46]);
  out.add(_u32le(4 + body.length));
  out.add([0x57, 0x45, 0x42, 0x50]);
  out.add(body);
  return out.toBytes();
}

List<int> _pngChunk(String type, List<int> data) {
  final typeBytes = type.codeUnits;
  final crc = crc32([...typeBytes, ...data]);
  return [
    (data.length >> 24) & 0xFF,
    (data.length >> 16) & 0xFF,
    (data.length >> 8) & 0xFF,
    data.length & 0xFF,
    ...typeBytes,
    ...data,
    (crc >> 24) & 0xFF,
    (crc >> 16) & 0xFF,
    (crc >> 8) & 0xFF,
    crc & 0xFF,
  ];
}

List<int> _riffChunk(String fourCc, List<int> data) => [
  ...fourCc.codeUnits,
  ..._u32le(data.length),
  ...data,
  if (data.length.isOdd) 0,
];

List<int> _u32le(int value) => [
  value & 0xFF,
  (value >> 8) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 24) & 0xFF,
];
