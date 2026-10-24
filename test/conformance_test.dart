// Conformance with provenance-spec 0.1.6 (SPEC §10).
//
// The six requirements of §10:
//   1. every read case of `test-vectors/` matches its `*.expected.json`;
//   2. a write followed by a read returns the same fields;
//   3. foreign namespace fields survive a write;
//   4. an existing `prov:assetId` never changes;
//   5. a write does not change the decoded pixels;
//   6. URL normalization passes every case of `urls.json`.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:provenance_dart/provenance_dart.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';
import 'support/vectors.dart';

/// Describes the first difference outside the XMP segment, or `null`.
String? _compareBytesOutsideXmp(
  Uint8List original,
  Uint8List modified,
  String format,
) {
  final a = _stripXmp(original, format);
  final b = _stripXmp(modified, format);
  if (a.length != b.length) {
    return 'length outside XMP differs: ${a.length} vs ${b.length}';
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return 'byte $i differs: '
          '0x${a[i].toRadixString(16)} vs 0x${b[i].toRadixString(16)}';
    }
  }
  return null;
}

/// Removes the XMP payload from [bytes], keeping everything else.
///
/// Container-level length fields are zeroed too, because they legitimately
/// change when the XMP payload changes size.
Uint8List _stripXmp(Uint8List bytes, String format) {
  final out = BytesBuilder(copy: false);
  switch (format) {
    case 'JPEG':
      final segments = scanJpegSegments(bytes);
      out.add(bytes.sublist(0, 2));
      for (final segment in segments) {
        if (segment.marker == 0xE1 && _isXmpSegment(bytes, segment)) continue;
        out.add(bytes.sublist(segment.start, segment.stop));
      }
      out.add(bytes.sublist(segments.isEmpty ? 2 : segments.last.stop));
    case 'PNG':
      out.add(bytes.sublist(0, 8));
      for (final chunk in scanPngChunks(bytes)) {
        if (chunk.type == 'iTXt' && _isXmpChunk(bytes, chunk)) continue;
        out.add(bytes.sublist(chunk.start, chunk.stop));
      }
    case 'WebP':
      final header = Uint8List.fromList(bytes.sublist(0, 12));
      for (var i = 4; i < 8; i++) {
        header[i] = 0;
      }
      out.add(header);
      for (final chunk in scanWebpChunks(bytes)) {
        if (chunk.fourCc == webpXmpFourCc) continue;
        out.add(bytes.sublist(chunk.start, chunk.stop));
      }
  }
  return out.toBytes();
}

bool _isXmpSegment(Uint8List bytes, JpegSegment segment) {
  if (segment.payloadStop - segment.payloadStart < xmpApp1Header.length) {
    return false;
  }
  for (var i = 0; i < xmpApp1Header.length; i++) {
    if (bytes[segment.payloadStart + i] != xmpApp1Header[i]) return false;
  }
  return true;
}

bool _isXmpChunk(Uint8List bytes, PngChunk chunk) {
  final data = bytes.sublist(chunk.dataStart, chunk.dataStop);
  final end = data.indexOf(0);
  if (end <= 0) return false;
  return utf8.decode(data.sublist(0, end), allowMalformed: true) ==
      pngXmpKeyword;
}

/// Decodes [bytes] and returns its pixel bytes, or `null` for the synthetic
/// fixtures that `package:image` cannot decode.
Uint8List? _pixels(Uint8List bytes) {
  try {
    final decoded = img.decodeImage(bytes);
    return decoded?.getBytes(order: img.ChannelOrder.rgba);
  } on Exception {
    return null;
  }
}

void main() {
  group('§10.1 read test vectors', () {
    const vectors = <String, String>{
      'xhs-item3.jpg': 'jpeg',
      'ig-item2.png': 'png',
      'x-single.webp': 'webp',
      'multiblock-elements.jpg': 'jpeg',
      'baidupan-single.jpg': 'jpeg',
      'exif-before-xmp.jpg': 'jpeg',
      'jpeg-ai-label.jpg': 'jpeg',
      'jpeg-existing-digitalsourcetype.jpg': 'jpeg',
      'mp4-ai-label.mp4': 'mp4',
    };

    for (final entry in vectors.entries) {
      test('${entry.key} matches its expected JSON', () async {
        final bytes = await readVector(entry.key);
        final record = switch (entry.value) {
          'jpeg' => readJpegXmp(bytes),
          'png' => readPngXmp(bytes),
          'mp4' => readMp4Xmp(bytes),
          _ => readWebpXmp(bytes),
        };
        expect(record, isNotNull, reason: 'no XMP read from ${entry.key}');
        expectJsonMatches(record!.toJson(), loadExpected(entry.key), entry.key);
      });
    }

    test('no-metadata.jpg has no provenance record', () async {
      final bytes = await readVector('no-metadata.jpg');
      expect(readJpegXmp(bytes), isNull);
    });

    test('local-video.mp4 sidecar matches its expected JSON', () async {
      final sidecar = vectorFile('local-video.mp4.xmp');
      final record = await readSidecarXmp(sidecar);
      expect(record, isNotNull);
      expectJsonMatches(
        record!.toJson(),
        loadExpected('local-video.mp4'),
        'local-video.mp4',
      );
    });

    test('local-video.mp4 sidecar is found from the media path', () async {
      final mediaPath = vectorFile('local-video.mp4').path;
      expect(sidecarPathFor(mediaPath), endsWith('local-video.mp4.xmp'));
      expect(await readSidecarFor(mediaPath), isNotNull);
    });

    test('every vector is readable through MetadataService', () async {
      for (final name in vectors.keys) {
        final record = await MetadataService.readProvenance(
          vectorFile(name).path,
        );
        expect(record, isNotNull, reason: name);
        expectJsonMatches(record!.toJson(), loadExpected(name), name);
      }
    });
  });

  group('§10.2 write then read round-trip', () {
    for (final name in const [
      'xhs-item3.jpg',
      'multiblock-elements.jpg',
      'baidupan-single.jpg',
      'exif-before-xmp.jpg',
    ]) {
      test('$name keeps every field after a write', () async {
        final bytes = (await readVector(name));
        final original = readJpegXmp(bytes)!;
        final written = writeJpegXmp(bytes, original.copyWith());
        final readBack = readJpegXmp(written)!;

        expect(readBack.toJson(), equals(original.toJson()));
      });
    }

    test('ig-item2.png keeps every field after a write', () async {
      final bytes = (await readVector('ig-item2.png'));
      final original = readPngXmp(bytes)!;
      final readBack = readPngXmp(writePngXmp(bytes, original.copyWith()))!;
      expect(readBack.toJson(), equals(original.toJson()));
    });

    test('x-single.webp keeps every field after a write', () async {
      final bytes = (await readVector('x-single.webp'));
      final original = readWebpXmp(bytes)!;
      final readBack = readWebpXmp(writeWebpXmp(bytes, original.copyWith()))!;
      expect(readBack.toJson(), equals(original.toJson()));
    });

    test('a changed metadataDate is the only observable difference', () async {
      final bytes = (await readVector('xhs-item3.jpg'));
      final original = readJpegXmp(bytes)!;
      final updated = original.copyWith(metadataDate: DateTime.utc(2030, 1, 1));
      final readBack = readJpegXmp(writeJpegXmp(bytes, updated))!;

      expect(readBack.metadataDate, DateTime.utc(2030, 1, 1));
      expect(readBack.assetId, original.assetId);
      expect(readBack.title, original.title);
      expect(readBack.toJson()['source'], equals(original.toJson()['source']));
    });

    test('a synthetic JPEG round-trips every field', () {
      final record = sampleProvenance();
      final readBack = readJpegXmp(writeJpegXmp(minimalJpeg(), record))!;
      expect(readBack.toJson(), equals(record.toJson()));
    });
  });

  group('§10.3 foreign fields survive a write', () {
    test('xhs-item3.jpg keeps photoshop:Headline', () async {
      final bytes = (await readVector('xhs-item3.jpg'));
      final original = readJpegXmp(bytes)!;
      expect(original.otherFields['photoshop:Headline'], isNotNull);

      final readBack = readJpegXmp(writeJpegXmp(bytes, original.copyWith()))!;
      expect(
        readBack.otherFields['photoshop:Headline'],
        original.otherFields['photoshop:Headline'],
      );
    });

    test('multiblock-elements.jpg keeps xmp:CreatorTool', () async {
      final bytes = (await readVector('multiblock-elements.jpg'));
      final original = readJpegXmp(bytes)!;
      expect(original.otherFields['xmp:CreatorTool'], 'SomeOtherTool 1.0');

      final readBack = readJpegXmp(writeJpegXmp(bytes, original.copyWith()))!;
      expect(readBack.otherFields['xmp:CreatorTool'], 'SomeOtherTool 1.0');
    });

    test('ig-item2.png keeps its foreign fields', () async {
      final bytes = (await readVector('ig-item2.png'));
      final original = readPngXmp(bytes)!;
      final readBack = readPngXmp(writePngXmp(bytes, original.copyWith()))!;
      expect(readBack.otherFields, equals(original.otherFields));
    });

    test('x-single.webp keeps its foreign fields', () async {
      final bytes = (await readVector('x-single.webp'));
      final original = readWebpXmp(bytes)!;
      final readBack = readWebpXmp(writeWebpXmp(bytes, original.copyWith()))!;
      expect(readBack.otherFields, equals(original.otherFields));
    });

    test('unknown namespaces added before a write are preserved', () {
      const xml =
          '<?xpacket begin="\uFEFF"?>'
          '<x:xmpmeta xmlns:x="adobe:ns:meta/">'
          '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
          '<rdf:Description rdf:about="" '
          'xmlns:prov="https://joopererer.github.io/provenance-spec/ns/" '
          'xmlns:my="https://example.com/my-namespace/">'
          '<prov:assetId>keep-me</prov:assetId>'
          '<prov:capturedAt>2026-10-20T13:30:00Z</prov:capturedAt>'
          '<prov:capturedBy>TestApp/1.0.0</prov:capturedBy>'
          '<my:CustomField my:attr="value">custom text</my:CustomField>'
          '</rdf:Description></rdf:RDF></x:xmpmeta>';
      final updated = updateXmpXml(
        xml,
        parseXmpXml(xml)!.copyWith(metadataDate: DateTime.utc(2030, 1, 1)),
      );
      expect(updated, contains('<my:CustomField my:attr="value">'));
      expect(updated, contains('custom text'));
    });
  });

  group('§10.4 assetId stability', () {
    for (final name in const [
      'xhs-item3.jpg',
      'multiblock-elements.jpg',
      'baidupan-single.jpg',
      'exif-before-xmp.jpg',
    ]) {
      test(
        '$name keeps its assetId when a different one is supplied',
        () async {
          final bytes = (await readVector(name));
          final original = readJpegXmp(bytes)!;
          final clash = sampleProvenance(
            assetId: '00000000-0000-4000-8000-000000000000',
          );

          final readBack = readJpegXmp(writeJpegXmp(bytes, clash))!;
          expect(readBack.assetId, original.assetId);
        },
      );
    }

    test('png and webp also keep the file assetId', () async {
      for (final name in const ['ig-item2.png', 'x-single.webp']) {
        final bytes = (await readVector(name));
        final isPng = name.endsWith('.png');
        final original = isPng ? readPngXmp(bytes)! : readWebpXmp(bytes)!;
        final clash = sampleProvenance(
          assetId: '00000000-0000-4000-8000-000000000000',
        );
        final written = isPng
            ? writePngXmp(bytes, clash)
            : writeWebpXmp(bytes, clash);
        final readBack = isPng ? readPngXmp(written)! : readWebpXmp(written)!;
        expect(readBack.assetId, original.assetId, reason: name);
      }
    });

    test('existing capture fields are never overwritten', () async {
      final bytes = await readVector('baidupan-single.jpg');
      final original = readJpegXmp(bytes)!;
      final replacement = sampleProvenance();

      final readBack = readJpegXmp(writeJpegXmp(bytes, replacement))!;
      expect(readBack.platform, 'baidupan');
      expect(readBack.sourceId, '1092837465019283');
      expect(readBack.capturedBy, original.capturedBy);
      expect(readBack.capturedAt, original.capturedAt);
    });

    test('an absent capture field is filled in on write', () async {
      final bytes = await readVector('baidupan-single.jpg');
      expect(readJpegXmp(bytes)!.sourceUrl, isNull);

      final readBack = readJpegXmp(writeJpegXmp(bytes, sampleProvenance()))!;
      expect(readBack.sourceUrl, sampleProvenance().sourceUrl);
    });

    test('a null sourceUrl is not written, nor mirrored into dc:source', () {
      final record = XmpProvenance(
        schema: '0.1',
        assetId: '11111111-1111-4111-8111-111111111111',
        capturedAt: DateTime.utc(2026, 10, 20),
        capturedBy: 'TestApp/1.0.0',
        metadataDate: DateTime.utc(2026, 10, 20),
        platform: 'onedrive',
        sourceId: 'drive-id!item-id',
      );
      final written = writeJpegXmp(minimalJpeg(), record);
      final text = String.fromCharCodes(written);
      final readBack = readJpegXmp(written)!;

      expect(readBack.sourceUrl, isNull);
      expect(readBack.sourceId, 'drive-id!item-id');
      expect(text, isNot(contains('sourceUrl')));
      expect(text, isNot(contains('dc:source')));
    });
  });

  group('§10.5 a write does not change pixels', () {
    test('JPEG vectors decode to identical pixels', () async {
      for (final name in const ['xhs-item3.jpg', 'exif-before-xmp.jpg']) {
        final bytes = (await readVector(name));
        final before = _pixels(bytes);
        expect(before, isNotNull, reason: '$name must be decodable');

        final after = _pixels(writeJpegXmp(bytes, sampleProvenance()));
        expect(after, equals(before), reason: name);
      }
    });

    test('PNG vector decodes to identical pixels', () async {
      final bytes = (await readVector('ig-item2.png'));
      final before = _pixels(bytes);
      expect(before, isNotNull);
      expect(_pixels(writePngXmp(bytes, sampleProvenance())), equals(before));
    });

    test('WebP vector decodes to identical pixels', () async {
      final bytes = (await readVector('x-single.webp'));
      final before = _pixels(bytes);
      expect(before, isNotNull);
      expect(_pixels(writeWebpXmp(bytes, sampleProvenance())), equals(before));
    });

    test('a WebP VP8 upgrade keeps the bitstream byte-identical', () {
      final webp = minimalWebpVp8();
      final before = extractWebpChunk(webp, 'VP8 ');
      final after = extractWebpChunk(
        writeWebpXmp(webp, sampleProvenance()),
        'VP8 ',
      );
      expect(after, equals(before));
    });
  });

  group('§10.6 URL normalization', () {
    late List<dynamic> cases;

    setUpAll(() {
      final file = vectorFile('urls.json');
      cases =
          (jsonDecode(file.readAsStringSync()) as Map<String, dynamic>)['cases']
              as List<dynamic>;
    });

    test('every case of urls.json normalizes as expected', () {
      for (final testCase in cases) {
        expect(
          normalizeUrl(testCase['in'] as String),
          testCase['out'],
          reason:
              'platform ${testCase['platform']}\n'
              'input ${testCase['in']}',
        );
      }
    });

    test('normalization is idempotent', () {
      for (final testCase in cases) {
        final once = normalizeUrl(testCase['in'] as String);
        expect(normalizeUrl(once), once, reason: 'input ${testCase['in']}');
      }
    });
  });

  group('§4.7 bytes outside the XMP payload are untouched', () {
    test('JPEG: only the XMP APP1 segment changes', () async {
      for (final name in const [
        'xhs-item3.jpg',
        'multiblock-elements.jpg',
        'exif-before-xmp.jpg',
      ]) {
        final bytes = (await readVector(name));
        final written = writeJpegXmp(bytes, sampleProvenance());
        expect(
          _compareBytesOutsideXmp(bytes, written, 'JPEG'),
          isNull,
          reason: name,
        );
      }
    });

    test('PNG: only the XMP iTXt chunk changes', () async {
      final bytes = (await readVector('ig-item2.png'));
      expect(
        _compareBytesOutsideXmp(
          bytes,
          writePngXmp(bytes, sampleProvenance()),
          'PNG',
        ),
        isNull,
      );
    });

    test('WebP: only the XMP chunk changes', () async {
      final bytes = (await readVector('x-single.webp'));
      expect(
        _compareBytesOutsideXmp(
          bytes,
          writeWebpXmp(bytes, sampleProvenance()),
          'WebP',
        ),
        isNull,
      );
    });

    test('EXIF APP1 survives byte-for-byte', () async {
      final bytes = (await readVector('exif-before-xmp.jpg'));
      final written = writeJpegXmp(bytes, sampleProvenance());

      final originalExif = _firstExifPayload(bytes);
      final writtenExif = _firstExifPayload(written);
      expect(writtenExif, isNotNull);
      expect(writtenExif, equals(originalExif));
    });

    test('EXIF keeps its position in front of the XMP segment', () async {
      final bytes = (await readVector('exif-before-xmp.jpg'));
      final written = writeJpegXmp(bytes, sampleProvenance());

      final markers = [
        for (final segment in scanJpegSegments(written))
          if (segment.marker == 0xE1)
            _isXmpSegment(written, segment) ? 'XMP' : 'EXIF',
      ];
      expect(markers, ['EXIF', 'XMP']);
    });

    test('both APP1 segments are preserved on repeated writes', () async {
      final bytes = (await readVector('exif-before-xmp.jpg'));
      final once = writeJpegXmp(bytes, sampleProvenance());
      final twice = writeJpegXmp(
        once,
        sampleProvenance(metadataDate: DateTime.utc(2031)),
      );
      expect(_firstExifPayload(twice), equals(_firstExifPayload(bytes)));
      expect(readJpegXmp(twice)!.metadataDate, DateTime.utc(2031));
    });
  });

  group('temporary-file cleanup', () {
    test('no .provenance-tmp file remains after a write', () async {
      final dir = await Directory.systemTemp.createTemp('provenance_dart_');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/image.jpg';
      await File(path).writeAsBytes(await readVector('xhs-item3.jpg'));

      final result = await MetadataService.embedProvenance(
        filePath: path,
        provenance: sampleProvenance(),
      );
      expect(result.success, isTrue);
      final leftovers = await dir
          .list()
          .where((e) => e.path.contains('provenance-tmp'))
          .toList();
      expect(leftovers, isEmpty);
    });
  });
}

/// The payload of the first EXIF APP1 segment of [bytes], or `null`.
List<int>? _firstExifPayload(Uint8List bytes) {
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
