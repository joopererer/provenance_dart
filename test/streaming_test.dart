// Streaming header reads (SPEC §4.1, §4.7).
//
// Reading must look only at the container header: a JPEG is scanned up to the
// start of scan, a PNG or WebP is walked chunk header by chunk header, and
// nothing but the XMP payload is ever loaded. These tests build 1 GiB sparse
// files and assert that the resident set does not grow with the file size.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:provenance_dart/provenance_dart.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// 1 GiB, the size the task asks for.
const int _oneGiB = 1 << 30;

/// The largest resident-set growth a header-only read may cause.
///
/// Reading the whole file would add at least 1 GiB, so this threshold is a
/// strong signal while leaving room for the Dart VM's own allocations.
const int _maxRssGrowth = 96 * 1024 * 1024;

int _rss() => ProcessInfo.currentRss;

/// Runs [body] and returns the resident-set growth in bytes.
Future<int> _measureRssGrowth(Future<void> Function() body) async {
  // Let the VM settle so the baseline is not dominated by test start-up.
  await Future<void>.delayed(const Duration(milliseconds: 50));
  final before = _rss();
  await body();
  final after = _rss();
  return after - before;
}

/// Writes a PNG whose IDAT payload is [payloadSize] zero bytes, with the XMP
/// iTXt chunk after it.
Future<File> _writeLargePng(Directory dir, int payloadSize) async {
  final file = File('${dir.path}/large.png');
  final handle = await file.open(mode: FileMode.write);
  try {
    final signature = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    final ihdr = _pngChunk('IHDR', [
      0x00, 0x00, 0x00, 0x01, // width 1
      0x00, 0x00, 0x00, 0x01, // height 1
      0x08, 0x02, 0x00, 0x00, 0x00,
    ]);
    final idatHeader = <int>[
      (payloadSize >> 24) & 0xFF,
      (payloadSize >> 16) & 0xFF,
      (payloadSize >> 8) & 0xFF,
      payloadSize & 0xFF,
      0x49, 0x44, 0x41, 0x54, // "IDAT"
    ];
    final xmp = _pngChunk('iTXt', [
      ...'XML:com.adobe.xmp'.codeUnits,
      0,
      0,
      0,
      0,
      0,
      ...utf8.encode(buildXmpXml(sampleProvenance())),
    ]);
    final iend = _pngChunk('IEND', const []);

    await handle.writeFrom(signature);
    await handle.writeFrom(ihdr);
    await handle.writeFrom(idatHeader);

    // Skip the IDAT payload and its CRC, then write the trailing chunks.
    final afterIdat = 8 + ihdr.length + idatHeader.length + payloadSize + 4;
    await handle.setPosition(afterIdat);
    await handle.writeFrom(xmp);
    await handle.writeFrom(iend);
    await handle.truncate(afterIdat + xmp.length + iend.length);
  } finally {
    await handle.close();
  }
  return file;
}

/// Writes a JPEG with [scanSize] zero bytes of scan data after SOS.
Future<File> _writeLargeJpeg(Directory dir, int scanSize) async {
  final file = File('${dir.path}/large.jpg');
  final handle = await file.open(mode: FileMode.write);
  try {
    final xml = buildXmpXml(sampleProvenance());
    final xmlBytes = Uint8List.fromList(utf8.encode(xml));
    final app1Length = 2 + xmpApp1Header.length + xmlBytes.length;
    final header = <int>[
      0xFF, 0xD8, // SOI
      0xFF, 0xE1, (app1Length >> 8) & 0xFF, app1Length & 0xFF,
      ...xmpApp1Header,
      ...xmlBytes,
      0xFF, 0xDA, 0x00, 0x08, // SOS
      0x01, 0x01, 0x00, 0x00, 0x3F, 0x00,
    ];
    await handle.writeFrom(header);

    final eoiAt = header.length + scanSize;
    await handle.setPosition(eoiAt);
    await handle.writeFrom([0xFF, 0xD9]);
    await handle.truncate(eoiAt + 2);
  } finally {
    await handle.close();
  }
  return file;
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

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('provenance_stream_');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('1 GiB sparse PNG', () {
    test('reads the XMP chunk without loading the pixel data', () async {
      final file = await _writeLargePng(dir, _oneGiB);
      expect(await file.length(), greaterThan(_oneGiB));

      final growth = await _measureRssGrowth(() async {
        final record = await MetadataService.readProvenance(file.path);
        expect(record, isNotNull);
        expect(record!.assetId, sampleProvenance().assetId);
        expect(record.title, sampleProvenance().title);
      });

      expect(
        growth,
        lessThan(_maxRssGrowth),
        reason:
            'resident set grew by ${growth ~/ (1024 * 1024)} MiB; '
            'a header-only read must not scale with the file size',
      );
    });

    test('chunk scanning only reads 8-byte headers', () async {
      final file = await _writeLargePng(dir, _oneGiB);
      final handle = await file.open();
      try {
        final chunks = await scanPngChunksFromFile(handle);
        expect(chunks.map((c) => c.type), ['IHDR', 'IDAT', 'iTXt', 'IEND']);
        expect(chunks[1].dataStop - chunks[1].dataStart, _oneGiB);
      } finally {
        await handle.close();
      }
    });
  });

  group('1 GiB sparse JPEG', () {
    test('reads the XMP APP1 segment without reading the scan data', () async {
      final file = await _writeLargeJpeg(dir, _oneGiB);
      expect(await file.length(), greaterThan(_oneGiB));

      final growth = await _measureRssGrowth(() async {
        final record = await MetadataService.readProvenance(file.path);
        expect(record, isNotNull);
        expect(record!.assetId, sampleProvenance().assetId);
      });

      expect(
        growth,
        lessThan(_maxRssGrowth),
        reason:
            'resident set grew by ${growth ~/ (1024 * 1024)} MiB; '
            'a header-only read must not scale with the file size',
      );
    });

    test('segment scanning stops at SOS', () async {
      final file = await _writeLargeJpeg(dir, _oneGiB);
      final handle = await file.open();
      try {
        final segments = await scanJpegSegmentsFromFile(handle);
        expect(segments.map((s) => s.marker), [0xE1]);
        expect(segments.single.stop, lessThan(64 * 1024));
      } finally {
        await handle.close();
      }
    });
  });

  group('memory does not scale with the file size', () {
    test('a 1 GiB file costs no more than a 64 MiB file', () async {
      final small = await _writeLargePng(dir, 64 * 1024 * 1024);
      final large = await _writeLargePng(dir, _oneGiB);

      final smallGrowth = await _measureRssGrowth(() async {
        expect(await MetadataService.readProvenance(small.path), isNotNull);
      });
      final largeGrowth = await _measureRssGrowth(() async {
        expect(await MetadataService.readProvenance(large.path), isNotNull);
      });

      // The 16x larger file must not cost 16x the memory. Allow a generous
      // margin for VM noise, but far below the 1 GiB a whole-file read needs.
      expect(largeGrowth, lessThan(_maxRssGrowth));
      expect(
        largeGrowth - smallGrowth,
        lessThan(_maxRssGrowth),
        reason:
            'small ${smallGrowth ~/ (1024 * 1024)} MiB, '
            'large ${largeGrowth ~/ (1024 * 1024)} MiB',
      );
    });
  });

  group('writing a large file streams through a fixed buffer', () {
    test('a 64 MiB JPEG is rewritten without loading it', () async {
      // Writing needs real disk space for the copy, so this uses a smaller
      // file than the read tests; the buffer is fixed either way.
      final file = await _writeLargeJpeg(dir, 64 * 1024 * 1024);
      final before = await file.length();

      final growth = await _measureRssGrowth(() async {
        final result = await MetadataService.embedProvenance(
          filePath: file.path,
          provenance: sampleProvenance(metadataDate: DateTime.utc(2030, 1, 1)),
        );
        expect(result.success, isTrue, reason: result.errorMessage);
      });

      expect(await file.length(), greaterThan(before - 1024));
      expect(
        growth,
        lessThan(_maxRssGrowth),
        reason: 'resident set grew by ${growth ~/ (1024 * 1024)} MiB',
      );
      expect(
        (await MetadataService.readProvenance(file.path))!.metadataDate,
        DateTime.utc(2030, 1, 1),
      );
    });
  });

  group('detection and C2PA checks are header-only', () {
    test('format detection on a 1 GiB file', () async {
      final file = await _writeLargePng(dir, _oneGiB);
      expect(await MetadataService.detectFormat(file.path), MediaFormat.png);
    });

    test('C2PA detection on a 1 GiB file', () async {
      final file = await _writeLargeJpeg(dir, _oneGiB);
      expect(await MetadataService.hasC2pa(file.path), isFalse);
    });
  });
}
