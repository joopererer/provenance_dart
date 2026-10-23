// MetadataService and ProvenanceBuilder tests.
//
// Ported from EasySave's `metadata_service_test.dart`. The application
// specific parts — the `xhs` → `xiaohongshu` platform map, the localized
// platform display name and the "X authorId must be numeric" rule — stay in
// EasySave, so those tests are replaced by tests of the generic interface.

import 'dart:io';
import 'dart:typed_data';

import 'package:provenance_dart/provenance_dart.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  group('ProvenanceBuilder', () {
    test('builds a record from the download context', () {
      final record = ProvenanceBuilder(
        platform: 'xiaohongshu',
        capturedBy: 'EasySave/1.7.0',
        sourceId: 'abc123',
        sourceUrl: 'https://www.xiaohongshu.com/explore/abc123?utm_source=test',
        authorId: 'author1',
        authorName: 'Test User',
        title: 'Test Title',
        caption: 'Test Caption',
        publishedAt: DateTime.utc(2026, 10, 20, 10),
        itemIndex: 2,
        itemCount: 5,
        existingAssetId: 'existing-asset-id',
        creditPlatformName: '小红书',
      ).build();

      expect(record.assetId, 'existing-asset-id');
      expect(record.platform, 'xiaohongshu');
      expect(record.sourceId, 'abc123');
      expect(record.title, 'Test Title');
      expect(record.creators, ['Test User']);
      expect(record.description, 'Test Caption');
      expect(record.itemIndex, 2);
      expect(record.itemCount, 5);
      expect(record.publishedAt, DateTime.utc(2026, 10, 20, 10));
      expect(record.credit, 'Test User / 小红书');
    });

    test('itemIndex and itemCount are omitted for a single item', () {
      final record = ProvenanceBuilder(
        platform: 'xiaohongshu',
        capturedBy: 'EasySave/1.7.0',
        sourceId: 'abc123',
        itemIndex: 1,
        itemCount: 1,
      ).build();

      expect(record.itemIndex, isNull);
      expect(record.itemCount, isNull);
    });

    test('an existing assetId is reused', () {
      final record = ProvenanceBuilder(
        platform: 'xiaohongshu',
        capturedBy: 'EasySave/1.7.0',
        existingAssetId: 'my-asset-id-123',
      ).build();
      expect(record.assetId, 'my-asset-id-123');
    });

    test('a new assetId is a lowercase UUID v4', () {
      final record = ProvenanceBuilder(
        platform: 'web',
        capturedBy: 'EasySave/1.7.0',
      ).build();

      expect(
        record.assetId,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
            r'[0-9a-f]{12}$',
          ),
        ),
      );
    });

    test('no title or creator when none is supplied', () {
      final record = ProvenanceBuilder(
        platform: 'instagram',
        capturedBy: 'EasySave/1.7.0',
        sourceId: 'abc123',
      ).build();

      expect(record.title, isNull);
      expect(record.creators, isNull);
      expect(record.credit, isNull);
    });

    test('an author name becomes dc:creator and photoshop:Credit', () {
      final record = ProvenanceBuilder(
        platform: 'instagram',
        capturedBy: 'EasySave/1.7.0',
        authorName: 'Instagram User',
        creditPlatformName: 'Instagram',
      ).build();

      expect(record.creators, ['Instagram User']);
      expect(record.credit, 'Instagram User / Instagram');
    });

    test('no credit line without a platform display name', () {
      final record = ProvenanceBuilder(
        platform: 'instagram',
        capturedBy: 'EasySave/1.7.0',
        authorName: 'Instagram User',
      ).build();

      expect(record.creators, ['Instagram User']);
      expect(record.credit, isNull);
    });

    test('the source URL is normalized', () {
      final record = ProvenanceBuilder(
        platform: 'xiaohongshu',
        capturedBy: 'EasySave/1.7.0',
        sourceUrl:
            'https://www.xiaohongshu.com/explore/abc123'
            '?utm_source=test&utm_medium=test2&fbclid=abc123&igsh=xyz',
      ).build();

      expect(record.sourceUrl, 'https://www.xiaohongshu.com/explore/abc123');
    });

    test('a caption over 2000 characters is truncated with an ellipsis', () {
      final record = ProvenanceBuilder(
        platform: 'xiaohongshu',
        capturedBy: 'EasySave/1.7.0',
        caption: 'A' * 3000,
      ).build();

      expect(record.description!.length, maxDescriptionLength);
      expect(record.description, endsWith('…'));
    });

    test('itemIndex is 1-based and passed through unchanged', () {
      for (final index in const [1, 3, 7]) {
        final record = ProvenanceBuilder(
          platform: 'xiaohongshu',
          capturedBy: 'EasySave/1.7.0',
          itemIndex: index,
          itemCount: 10,
        ).build();
        expect(record.itemIndex, index);
      }
    });

    test('authorId is passed through unchanged', () {
      final record = ProvenanceBuilder(
        platform: 'x',
        capturedBy: 'EasySave/1.7.0',
        authorId: 'n8_AIart',
      ).build();
      expect(record.authorId, 'n8_AIart');
    });

    test('publishedAt is written with a timezone', () {
      final record = ProvenanceBuilder(
        platform: 'xiaohongshu',
        capturedBy: 'EasySave/1.7.0',
        publishedAt: DateTime.utc(2026, 10, 20, 10, 30, 45),
      ).build();

      expect(record.toXmpJson()['prov:publishedAt'], '2026-10-20T10:30:45Z');
    });

    test('capturedAt defaults to now and can be overridden', () {
      final now = DateTime.utc(2026, 10, 20, 12);
      final record = ProvenanceBuilder(
        platform: 'web',
        capturedBy: 'EasySave/1.7.0',
      ).build(now: now);

      expect(record.capturedAt, now);
      expect(record.metadataDate, now);
    });

    test('an injected assetId generator is used', () {
      final record = ProvenanceBuilder(
        platform: 'web',
        capturedBy: 'EasySave/1.7.0',
        assetIdGenerator: () => 'fixed-id',
      ).build();
      expect(record.assetId, 'fixed-id');
    });
  });

  group('generateAssetId', () {
    test('produces distinct lowercase UUID v4 values', () {
      final ids = {for (var i = 0; i < 100; i++) generateAssetId()};
      expect(ids, hasLength(100));
      for (final id in ids) {
        expect(id, matches(RegExp(r'^[0-9a-f-]{36}$')));
        expect(id[14], '4');
      }
    });
  });

  group('truncateDescription', () {
    test('leaves short text alone', () {
      expect(truncateDescription('short'), 'short');
    });

    test('truncates long text to the limit', () {
      final result = truncateDescription('x' * 5000);
      expect(result.length, maxDescriptionLength);
      expect(result, endsWith('…'));
    });
  });

  group('MetadataService.embedProvenance', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('provenance_service_');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('writes XMP into a JPEG file', () async {
      final path = '${dir.path}/test.jpg';
      await File(path).writeAsBytes(minimalJpeg());

      final result = await MetadataService.embedProvenance(
        filePath: path,
        provenance: sampleProvenance(),
      );

      expect(result.success, isTrue);
      expect(result.errorCode, isNull);
      expect(
        (await MetadataService.readEmbedded(path))!.assetId,
        sampleProvenance().assetId,
      );
    });

    test('writes XMP into a PNG file', () async {
      final path = '${dir.path}/test.png';
      await File(path).writeAsBytes(minimalPng());

      final result = await MetadataService.embedProvenance(
        filePath: path,
        provenance: sampleProvenance(),
      );

      expect(result.success, isTrue);
      expect(
        (await MetadataService.readEmbedded(path))!.assetId,
        sampleProvenance().assetId,
      );
    });

    test('writes XMP into a WebP file', () async {
      final path = '${dir.path}/test.webp';
      await File(path).writeAsBytes(minimalWebpVp8());

      final result = await MetadataService.embedProvenance(
        filePath: path,
        provenance: sampleProvenance(),
      );

      expect(result.success, isTrue);
      expect(
        (await MetadataService.readEmbedded(path))!.assetId,
        sampleProvenance().assetId,
      );
    });

    test('returns fileNotFound for a missing file', () async {
      final result = await MetadataService.embedProvenance(
        filePath: '${dir.path}/missing.jpg',
        provenance: sampleProvenance(),
      );

      expect(result.success, isFalse);
      expect(result.errorCode, EmbedErrorCode.fileNotFound);
    });

    test('returns formatUnsupported for an unknown container', () async {
      final path = '${dir.path}/file.bin';
      await File(path).writeAsBytes([0, 1, 2, 3]);

      final result = await MetadataService.embedProvenance(
        filePath: path,
        provenance: sampleProvenance(),
      );

      expect(result.success, isFalse);
      expect(result.errorCode, EmbedErrorCode.formatUnsupported);
      expect(result.isFormatError, isTrue);
    });

    test('a write failure is reported, not thrown', () async {
      final path = '${dir.path}/test.jpg';
      await File(path).writeAsBytes(minimalJpeg());

      final result = await MetadataService.embedProvenance(
        filePath: path,
        provenance: XmpProvenance(
          schema: '0.1',
          assetId: 'a',
          capturedAt: DateTime.utc(2026, 10, 20),
          capturedBy: 'b',
          metadataDate: DateTime.utc(2026, 10, 20),
          description: 'x' * (maxJpegXmpBytes * 2),
        ),
      );

      expect(result.success, isFalse);
      expect(result.errorCode, EmbedErrorCode.formatUnsupported);
      // The original file is untouched.
      expect(readJpegXmp(await File(path).readAsBytes()), isNull);
    });

    test('reads back the embedded provenance', () async {
      final path = '${dir.path}/test.jpg';
      await File(path).writeAsBytes(minimalJpeg());
      final record = sampleProvenance();

      await MetadataService.embedProvenance(filePath: path, provenance: record);

      expect(
        (await MetadataService.readProvenance(path))!.toJson(),
        equals(record.toJson()),
      );
    });

    test('preserves an existing assetId on re-embed', () async {
      final path = '${dir.path}/test.jpg';
      await File(path).writeAsBytes(minimalJpeg());

      await MetadataService.embedProvenance(
        filePath: path,
        provenance: sampleProvenance(assetId: 'original-id'),
      );
      await MetadataService.embedProvenance(
        filePath: path,
        provenance: sampleProvenance(assetId: 'new-id'),
      );

      expect(
        (await MetadataService.readEmbedded(path))!.assetId,
        'original-id',
      );
    });

    test('detectFormat reports the container', () async {
      final path = '${dir.path}/test.png';
      await File(path).writeAsBytes(minimalPng());
      expect(await MetadataService.detectFormat(path), MediaFormat.png);
    });

    test('detectFormat reports other for a missing file', () async {
      expect(
        await MetadataService.detectFormat('${dir.path}/missing.jpg'),
        MediaFormat.other,
      );
    });
  });

  group('MetadataService.embedProvenance with an EXIF-only APP1', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('provenance_exif_');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('writes XMP next to the EXIF segment', () async {
      final path = '${dir.path}/live.jpg';
      await File(path).writeAsBytes(jpegWithExifOnly());

      final result = await MetadataService.embedProvenance(
        filePath: path,
        provenance: sampleProvenance(),
      );

      expect(result.success, isTrue);
      expect(
        (await MetadataService.readEmbedded(path))!.assetId,
        sampleProvenance().assetId,
      );
    });

    test(
      'reading an EXIF-only file returns null instead of throwing',
      () async {
        final path = '${dir.path}/live.jpg';
        await File(path).writeAsBytes(jpegWithExifOnly());
        expect(await MetadataService.readProvenance(path), isNull);
      },
    );

    test('the EXIF segment is preserved byte-for-byte', () async {
      final path = '${dir.path}/live.jpg';
      final original = jpegWithExifOnly();
      await File(path).writeAsBytes(original);

      await MetadataService.embedProvenance(
        filePath: path,
        provenance: sampleProvenance(),
      );

      final written = await File(path).readAsBytes();
      final exif = _exifPayload(original);
      expect(_exifPayload(written), equals(exif));
    });
  });

  group(
    'MetadataService.embedProvenance with EXIF and XMP in either order',
    () {
      late Directory dir;

      setUp(() async {
        dir = await Directory.systemTemp.createTemp('provenance_order_');
      });

      tearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      test('EXIF then XMP: reads the XMP correctly', () async {
        final path = '${dir.path}/exif-first.jpg';
        await File(path).writeAsBytes(_jpegWithExifThenXmp());
        expect(
          (await MetadataService.readEmbedded(path))!.assetId,
          'xmp-asset',
        );
      });

      test('XMP then EXIF: reads the XMP correctly', () async {
        final path = '${dir.path}/xmp-first.jpg';
        await File(path).writeAsBytes(_jpegWithXmpThenExif());
        expect(
          (await MetadataService.readEmbedded(path))!.assetId,
          'xmp-asset',
        );
      });

      test('EXIF then XMP: writing preserves the EXIF bytes', () async {
        final path = '${dir.path}/exif-first.jpg';
        final original = _jpegWithExifThenXmp();
        await File(path).writeAsBytes(original);

        await MetadataService.embedProvenance(
          filePath: path,
          provenance: sampleProvenance(),
        );

        final written = await File(path).readAsBytes();
        expect(_exifPayload(written), equals(_exifPayload(original)));
        expect(
          (await MetadataService.readEmbedded(path))!.assetId,
          'xmp-asset',
        );
      });

      test('XMP then EXIF: writing preserves the EXIF bytes', () async {
        final path = '${dir.path}/xmp-first.jpg';
        final original = _jpegWithXmpThenExif();
        await File(path).writeAsBytes(original);

        await MetadataService.embedProvenance(
          filePath: path,
          provenance: sampleProvenance(),
        );

        final written = await File(path).readAsBytes();
        expect(_exifPayload(written), equals(_exifPayload(original)));
      });

      test('replacing the XMP segment preserves the EXIF segment', () async {
        final path = '${dir.path}/exif-first.jpg';
        final original = _jpegWithExifThenXmp();
        await File(path).writeAsBytes(original);

        await MetadataService.embedProvenance(
          filePath: path,
          provenance: sampleProvenance(metadataDate: DateTime.utc(2030, 1, 1)),
        );
        await MetadataService.embedProvenance(
          filePath: path,
          provenance: sampleProvenance(metadataDate: DateTime.utc(2031, 1, 1)),
        );

        final written = await File(path).readAsBytes();
        expect(_exifPayload(written), equals(_exifPayload(original)));
        expect(
          (await MetadataService.readEmbedded(path))!.metadataDate,
          DateTime.utc(2031, 1, 1),
        );
      });
    },
  );

  group('MetadataService C2PA handling', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('provenance_c2pa_');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('hasC2pa is false for a clean JPEG', () async {
      final path = '${dir.path}/clean.jpg';
      await File(path).writeAsBytes(minimalJpeg());
      expect(await MetadataService.hasC2pa(path), isFalse);
    });

    test('a C2PA signed file is skipped and left untouched', () async {
      final path = '${dir.path}/signed.jpg';
      final original = _jpegWithC2pa();
      await File(path).writeAsBytes(original);

      final result = await MetadataService.embedProvenance(
        filePath: path,
        provenance: sampleProvenance(),
      );

      expect(result.success, isTrue);
      expect(result.skippedC2pa, isTrue);
      expect(result.errorCode, EmbedErrorCode.c2paDetected);
      expect(await File(path).readAsBytes(), equals(original));
    });

    test('checkC2pa: false forces the embed', () async {
      final path = '${dir.path}/signed.jpg';
      await File(path).writeAsBytes(_jpegWithC2pa());

      final result = await MetadataService.embedProvenance(
        filePath: path,
        provenance: sampleProvenance(),
        checkC2pa: false,
      );

      expect(result.success, isTrue);
      expect(result.skippedC2pa, isFalse);
      expect(
        (await MetadataService.readEmbedded(path))!.assetId,
        sampleProvenance().assetId,
      );
    });
  });
}

/// The payload of the first EXIF APP1 segment of [bytes], or `null`.
List<int>? _exifPayload(Uint8List bytes) {
  for (final segment in scanJpegSegments(bytes)) {
    if (segment.marker != 0xE1) continue;
    final payload = bytes.sublist(segment.payloadStart, segment.payloadStop);
    if (payload.length >= 6 &&
        payload[0] == 0x45 &&
        payload[1] == 0x78 &&
        payload[2] == 0x69 &&
        payload[3] == 0x66) {
      return payload;
    }
  }
  return null;
}

/// A JPEG with an EXIF APP1 segment followed by an XMP APP1 segment.
Uint8List _jpegWithExifThenXmp() {
  final exif = _exifSegment();
  final xmp = _xmpSegment();
  return Uint8List.fromList([
    0xFF,
    0xD8,
    ...exif,
    ...xmp,
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

/// A JPEG with an XMP APP1 segment followed by an EXIF APP1 segment.
Uint8List _jpegWithXmpThenExif() {
  final exif = _exifSegment();
  final xmp = _xmpSegment();
  return Uint8List.fromList([
    0xFF,
    0xD8,
    ...xmp,
    ...exif,
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

List<int> _exifSegment() {
  final payload = <int>[
    0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // "Exif\0\0"
    0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ];
  final length = 2 + payload.length;
  return [0xFF, 0xE1, (length >> 8) & 0xFF, length & 0xFF, ...payload];
}

List<int> _xmpSegment() {
  final xml = buildXmpXml(
    XmpProvenance(
      schema: '0.1',
      assetId: 'xmp-asset',
      capturedAt: DateTime.utc(2026, 10, 20),
      capturedBy: 'TestApp/1.0.0',
      metadataDate: DateTime.utc(2026, 10, 20),
    ),
  );
  final payload = <int>[...xmpApp1Header, ...xml.codeUnits];
  final length = 2 + payload.length;
  return [0xFF, 0xE1, (length >> 8) & 0xFF, length & 0xFF, ...payload];
}

/// A JPEG with a C2PA JUMBF APP11 segment.
Uint8List _jpegWithC2pa() {
  const uuid = [
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
  final payload = <int>[...uuid, ...'c2pa\x00'.codeUnits];
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
