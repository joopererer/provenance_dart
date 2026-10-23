// Comprehensive per-format read/write tests.
//
// Ported from EasySave's `xmp_comprehensive_test.dart`: foreign field
// preservation, assetId stability, byte preservation outside the metadata
// container, and the WebP VP8/VP8L → VP8X upgrade.

import 'dart:io';

import 'package:provenance_dart/provenance_dart.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  group('JPEG', () {
    test('foreign fields survive a rewrite', () {
      final first = sampleProvenance(
        otherFields: {'photoshop:Headline': 'Original Headline'},
      );
      final withFirst = writeJpegXmp(minimalJpeg(), first);
      expect(
        readJpegXmp(withFirst)!.otherFields['photoshop:Headline'],
        'Original Headline',
      );

      final second = sampleProvenance(metadataDate: DateTime.utc(2027));
      final readBack = readJpegXmp(writeJpegXmp(withFirst, second))!;
      expect(readBack.otherFields['photoshop:Headline'], 'Original Headline');
    });

    test('the assetId is preserved', () {
      final withFirst = writeJpegXmp(
        minimalJpeg(),
        sampleProvenance(assetId: 'original-id'),
      );
      final readBack = readJpegXmp(
        writeJpegXmp(withFirst, sampleProvenance(assetId: 'new-id')),
      )!;
      expect(readBack.assetId, 'original-id');
    });

    test('bytes outside the metadata segment are preserved', () {
      final jpeg = minimalJpeg();
      final written = writeJpegXmp(jpeg, sampleProvenance());

      expect(written.sublist(0, 2), jpeg.sublist(0, 2)); // SOI
      expect(
        written.sublist(written.length - 2),
        jpeg.sublist(jpeg.length - 2),
      );
    });

    test('the scan data is copied unchanged', () {
      final jpeg = minimalJpeg();
      final sos = scanJpegSegments(jpeg).last.stop;
      final written = writeJpegXmp(jpeg, sampleProvenance());
      final writtenSos = scanJpegSegments(written).last.stop;

      expect(
        written.sublist(writtenSos),
        jpeg.sublist(sos),
        reason: 'everything from SOS onwards must be identical',
      );
    });
  });

  group('PNG', () {
    test('foreign fields survive a rewrite', () {
      final first = sampleProvenance(
        otherFields: {'photoshop:Headline': 'PNG Headline'},
      );
      final withFirst = writePngXmp(minimalPng(), first);
      final readBack = readPngXmp(
        writePngXmp(
          withFirst,
          sampleProvenance(metadataDate: DateTime.utc(2027)),
        ),
      )!;
      expect(readBack.otherFields['photoshop:Headline'], 'PNG Headline');
    });

    test('the assetId is preserved', () {
      final withFirst = writePngXmp(
        minimalPng(),
        sampleProvenance(assetId: 'original-png-id'),
      );
      final readBack = readPngXmp(
        writePngXmp(withFirst, sampleProvenance(assetId: 'new-png-id')),
      )!;
      expect(readBack.assetId, 'original-png-id');
    });

    test('the signature and IEND are preserved', () {
      final png = minimalPng();
      final written = writePngXmp(png, sampleProvenance());

      expect(written.sublist(0, 8), png.sublist(0, 8));
      expect(
        written.sublist(written.length - 12),
        png.sublist(png.length - 12),
      );
    });

    test('the chunk CRCs are valid', () {
      final written = writePngXmp(minimalPng(), sampleProvenance());
      for (final chunk in scanPngChunks(written)) {
        final data = written.sublist(chunk.dataStart, chunk.dataStop);
        final expected = crc32([...chunk.type.codeUnits, ...data]);
        final actual =
            (written[chunk.dataStop] << 24) |
            (written[chunk.dataStop + 1] << 16) |
            (written[chunk.dataStop + 2] << 8) |
            written[chunk.dataStop + 3];
        expect(actual, expected, reason: 'CRC of ${chunk.type}');
      }
    });
  });

  group('WebP', () {
    test('reads XMP from an extended file', () {
      final written = writeWebpXmp(minimalWebpExtended(), sampleProvenance());
      expect(readWebpXmp(written)!.assetId, sampleProvenance().assetId);
    });

    test('upgrades a simple VP8 file to VP8X', () {
      final written = writeWebpXmp(minimalWebpVp8(), sampleProvenance());

      expect(String.fromCharCodes(written.sublist(12, 16)), 'VP8X');
      expect(written[20] & webpXmpFlag, webpXmpFlag);
      expect(readWebpXmp(written)!.assetId, sampleProvenance().assetId);
    });

    test('upgrades a simple VP8L file to VP8X', () {
      final written = writeWebpXmp(minimalWebpVp8l(), sampleProvenance());

      expect(String.fromCharCodes(written.sublist(12, 16)), 'VP8X');
      expect(readWebpXmp(written)!.assetId, sampleProvenance().assetId);
    });

    test('the VP8X canvas size is taken from the VP8 bitstream', () {
      final written = writeWebpXmp(minimalWebpVp8(), sampleProvenance());
      final vp8x = extractWebpChunk(written, 'VP8X')!;
      final width = vp8x[4] | (vp8x[5] << 8) | (vp8x[6] << 16);
      final height = vp8x[7] | (vp8x[8] << 8) | (vp8x[9] << 16);
      expect(width + 1, 1);
      expect(height + 1, 1);
    });

    test('foreign fields survive a rewrite', () {
      final first = sampleProvenance(
        otherFields: {'photoshop:Headline': 'WebP Headline'},
      );
      final withFirst = writeWebpXmp(minimalWebpVp8(), first);
      final readBack = readWebpXmp(
        writeWebpXmp(
          withFirst,
          sampleProvenance(metadataDate: DateTime.utc(2027)),
        ),
      )!;
      expect(readBack.otherFields['photoshop:Headline'], 'WebP Headline');
    });

    test('the assetId is preserved', () {
      final withFirst = writeWebpXmp(
        minimalWebpVp8(),
        sampleProvenance(assetId: 'original-webp-id'),
      );
      final readBack = readWebpXmp(
        writeWebpXmp(withFirst, sampleProvenance(assetId: 'new-webp-id')),
      )!;
      expect(readBack.assetId, 'original-webp-id');
    });

    test('the VP8 bitstream is byte-identical after a write', () {
      final webp = minimalWebpVp8();
      final before = extractWebpChunk(webp, 'VP8 ');
      final after = extractWebpChunk(
        writeWebpXmp(webp, sampleProvenance()),
        'VP8 ',
      );
      expect(after, equals(before));
    });

    test('the RIFF size field matches the file length', () {
      final written = writeWebpXmp(minimalWebpVp8(), sampleProvenance());
      final riffSize =
          written[4] |
          (written[5] << 8) |
          (written[6] << 16) |
          (written[7] << 24);
      expect(riffSize + 8, written.length);
    });

    test('an odd-sized XMP chunk is padded to an even length', () {
      // A one-character description makes the XML length odd.
      final record = sampleProvenance().copyWith(description: 'x');
      final written = writeWebpXmp(minimalWebpVp8(), record);
      final chunk = scanWebpChunks(
        written,
      ).firstWhere((c) => c.fourCc == webpXmpFourCc);
      final dataLength = chunk.dataStop - chunk.dataStart;
      expect(
        chunk.stop - chunk.start,
        8 + dataLength + (dataLength.isOdd ? 1 : 0),
      );
      expect(written.length.isEven, isTrue);
    });
  });

  group('cross-format', () {
    test('the same record round-trips through all three containers', () {
      final record = sampleProvenance();
      final expected = record.toJson();

      expect(
        readJpegXmp(writeJpegXmp(minimalJpeg(), record))!.toJson(),
        equals(expected),
      );
      expect(
        readPngXmp(writePngXmp(minimalPng(), record))!.toJson(),
        equals(expected),
      );
      expect(
        readWebpXmp(writeWebpXmp(minimalWebpVp8(), record))!.toJson(),
        equals(expected),
      );
    });

    test('a record with no source fields round-trips', () {
      final record = XmpProvenance(
        schema: '0.1',
        assetId: '11111111-1111-4111-8111-111111111111',
        capturedAt: DateTime.utc(2026, 10, 20),
        capturedBy: 'TestApp/1.0.0',
        metadataDate: DateTime.utc(2026, 10, 20),
        title: 'local import',
      );

      final readBack = readJpegXmp(writeJpegXmp(minimalJpeg(), record))!;
      expect(readBack.toJson(), equals(record.toJson()));
      expect(readBack.toJson().containsKey('source'), isFalse);
    });
  });

  group('file writers', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('provenance_writers_');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('writeJpegXmpToFile then readJpegXmpFromFile', () async {
      final path = '${dir.path}/a.jpg';
      await File(path).writeAsBytes(minimalJpeg());
      await writeJpegXmpToFile(path, sampleProvenance());

      final handle = await File(path).open();
      try {
        expect(
          (await readJpegXmpFromFile(handle))!.assetId,
          sampleProvenance().assetId,
        );
      } finally {
        await handle.close();
      }
    });

    test('writePngXmpToFile then readPngXmpFromFile', () async {
      final path = '${dir.path}/a.png';
      await File(path).writeAsBytes(minimalPng());
      await writePngXmpToFile(path, sampleProvenance());

      final handle = await File(path).open();
      try {
        expect(
          (await readPngXmpFromFile(handle))!.assetId,
          sampleProvenance().assetId,
        );
      } finally {
        await handle.close();
      }
    });

    test('writeWebpXmpToFile then readWebpXmpFromFile', () async {
      final path = '${dir.path}/a.webp';
      await File(path).writeAsBytes(minimalWebpVp8());
      await writeWebpXmpToFile(path, sampleProvenance());

      final handle = await File(path).open();
      try {
        expect(
          (await readWebpXmpFromFile(handle))!.assetId,
          sampleProvenance().assetId,
        );
      } finally {
        await handle.close();
      }
    });

    test('a failed write leaves the original file intact', () async {
      final path = '${dir.path}/a.jpg';
      final original = minimalJpeg();
      await File(path).writeAsBytes(original);

      await expectLater(
        writeJpegXmpToFile(
          path,
          XmpProvenance(
            schema: '0.1',
            assetId: 'a',
            capturedAt: DateTime.utc(2026, 10, 20),
            capturedBy: 'b',
            metadataDate: DateTime.utc(2026, 10, 20),
            description: 'x' * (maxJpegXmpBytes * 2),
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );

      expect(await File(path).readAsBytes(), equals(original));
    });
  });
}
