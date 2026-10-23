// XMP parsing and per-format read/write tests (SPEC §4.7 read requirements).

import 'dart:typed_data';

import 'package:provenance_dart/provenance_dart.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

String _xmp(String body, {String provPrefix = 'prov'}) =>
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<x:xmpmeta xmlns:x="adobe:ns:meta/">'
    '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" '
    'xmlns:$provPrefix="https://joopererer.github.io/provenance-spec/ns/">'
    '<rdf:Description rdf:about="">$body</rdf:Description>'
    '</rdf:RDF></x:xmpmeta>';

const _required =
    '<prov:schema>0.1</prov:schema>'
    '<prov:assetId>asset-1</prov:assetId>'
    '<prov:capturedAt>2026-10-20T10:00:00Z</prov:capturedAt>'
    '<prov:capturedBy>TestApp/1.0.0</prov:capturedBy>';

void main() {
  group('XmpProvenance JSON round-trip', () {
    test('toJson/fromJson preserves every field', () {
      final record = sampleProvenance();
      final restored = XmpProvenance.fromJson(record.toJson());

      expect(restored.toJson(), equals(record.toJson()));
    });

    test('fromJson accepts namespace-qualified XMP names', () {
      final record = sampleProvenance();
      final restored = XmpProvenance.fromJson(record.toXmpJson());

      expect(restored.assetId, record.assetId);
      expect(restored.title, record.title);
      expect(restored.subject, record.subject);
    });

    test('fromJson throws when a required field is missing', () {
      expect(
        () => XmpProvenance.fromJson({'assetId': 'x'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson throws on an unparsable date', () {
      expect(
        () => XmpProvenance.fromJson({
          'assetId': 'x',
          'capturedBy': 'y',
          'capturedAt': 'not-a-date',
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('a missing metadataDate falls back to capturedAt', () {
      final record = XmpProvenance.fromJson({
        'assetId': 'x',
        'capturedBy': 'y',
        'capturedAt': '2026-10-20T10:00:00Z',
      });
      expect(record.metadataDate, record.capturedAt);
    });

    test('date text read from a file is written back unchanged', () {
      final record = parseXmpXml(_xmp(_required))!;
      expect(record.toJson()['capturedAt'], '2026-10-20T10:00:00Z');
    });
  });

  group('§4.7.4 fields are identified by namespace URI', () {
    test('canonical prov prefix', () {
      final record = parseXmpXml(_xmp(_required))!;
      expect(record.assetId, 'asset-1');
      expect(record.capturedBy, 'TestApp/1.0.0');
    });

    for (final prefix in const ['zz', 'ns1', 'pv', 'x']) {
      test('prefix "$prefix" bound to the prov URI is recognized', () {
        final xml = _xmp(
          '<$prefix:schema>0.1</$prefix:schema>'
          '<$prefix:assetId>asset-$prefix</$prefix:assetId>'
          '<$prefix:capturedAt>2026-10-20T10:00:00Z</$prefix:capturedAt>'
          '<$prefix:capturedBy>TestApp/1.0.0</$prefix:capturedBy>',
          provPrefix: prefix,
        );
        expect(parseXmpXml(xml)!.assetId, 'asset-$prefix');
      });
    }

    test('a prov prefix bound to a different URI is not recognized', () {
      const xml =
          '<?xml version="1.0"?>'
          '<x:xmpmeta xmlns:x="adobe:ns:meta/">'
          '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
          '<rdf:Description rdf:about="" '
          'xmlns:prov="https://example.com/not-the-spec/">'
          '<prov:schema>0.1</prov:schema>'
          '<prov:assetId>wrong</prov:assetId>'
          '<prov:capturedAt>2026-10-20T10:00:00Z</prov:capturedAt>'
          '<prov:capturedBy>TestApp/1.0.0</prov:capturedBy>'
          '</rdf:Description></rdf:RDF></x:xmpmeta>';

      expect(parseXmpXml(xml), isNull);
      expect(parseXmpFields(xml).isEmpty, isTrue);
    });

    test('two prefixes for the same URI are both read', () {
      const xml =
          '<?xml version="1.0"?>'
          '<x:xmpmeta xmlns:x="adobe:ns:meta/">'
          '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" '
          'xmlns:prov="https://joopererer.github.io/provenance-spec/ns/" '
          'xmlns:zz="https://joopererer.github.io/provenance-spec/ns/">'
          '<rdf:Description rdf:about="">'
          '<prov:schema>0.1</prov:schema>'
          '<zz:assetId>shared</zz:assetId>'
          '<prov:capturedAt>2026-10-20T10:00:00Z</prov:capturedAt>'
          '<prov:capturedBy>TestApp/1.0.0</prov:capturedBy>'
          '</rdf:Description></rdf:RDF></x:xmpmeta>';

      expect(parseXmpXml(xml)!.assetId, 'shared');
    });
  });

  group('§4.7.1 attribute syntax', () {
    test('scalar fields are read from attributes', () {
      const xml =
          '<?xml version="1.0"?>'
          '<x:xmpmeta xmlns:x="adobe:ns:meta/">'
          '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
          '<rdf:Description rdf:about="" '
          'xmlns:prov="https://joopererer.github.io/provenance-spec/ns/" '
          'xmlns:xmp="http://ns.adobe.com/xap/1.0/" '
          'prov:schema="0.1" prov:assetId="attr-asset" '
          'prov:capturedAt="2026-10-20T10:00:00Z" '
          'prov:capturedBy="TestApp/1.0.0" xmp:Rating="5"/>'
          '</rdf:RDF></x:xmpmeta>';

      final record = parseXmpXml(xml)!;
      expect(record.assetId, 'attr-asset');
      expect(record.rating, 5);
    });
  });

  group('§4.7.2 child-element syntax', () {
    test('scalar fields are read from child elements', () {
      expect(parseXmpXml(_xmp(_required))!.assetId, 'asset-1');
    });

    test('dc:title uses rdf:Alt with xml:lang', () {
      final xml = _xmp(
        '$_required'
        '<dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<rdf:Alt><rdf:li xml:lang="x-default">标题</rdf:li>'
        '<rdf:li xml:lang="en">Title</rdf:li></rdf:Alt></dc:title>',
      );
      expect(parseXmpXml(xml)!.title, '标题');
    });

    test('dc:creator uses rdf:Seq', () {
      final xml = _xmp(
        '$_required'
        '<dc:creator xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<rdf:Seq><rdf:li>A</rdf:li><rdf:li>B</rdf:li></rdf:Seq>'
        '</dc:creator>',
      );
      expect(parseXmpXml(xml)!.creators, ['A', 'B']);
    });

    test('dc:subject uses rdf:Bag', () {
      final xml = _xmp(
        '$_required'
        '<dc:subject xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<rdf:Bag><rdf:li>tag1</rdf:li><rdf:li>tag2</rdf:li></rdf:Bag>'
        '</dc:subject>',
      );
      expect(parseXmpXml(xml)!.subject, ['tag1', 'tag2']);
    });
  });

  group('§4.7.3 several rdf:Description blocks', () {
    test('fields from all blocks are merged', () {
      const xml =
          '<?xml version="1.0"?>'
          '<x:xmpmeta xmlns:x="adobe:ns:meta/">'
          '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
          '<rdf:Description rdf:about="" '
          'xmlns:prov="https://joopererer.github.io/provenance-spec/ns/">'
          '<prov:schema>0.1</prov:schema>'
          '<prov:assetId>multi</prov:assetId>'
          '<prov:capturedAt>2026-10-20T10:00:00Z</prov:capturedAt>'
          '<prov:capturedBy>TestApp/1.0.0</prov:capturedBy>'
          '</rdf:Description>'
          '<rdf:Description rdf:about="" '
          'xmlns:dc="http://purl.org/dc/elements/1.1/">'
          '<dc:title><rdf:Alt><rdf:li xml:lang="x-default">T</rdf:li>'
          '</rdf:Alt></dc:title>'
          '</rdf:Description>'
          '<rdf:Description rdf:about="" '
          'xmlns:xmp="http://ns.adobe.com/xap/1.0/">'
          '<xmp:Rating>3</xmp:Rating>'
          '</rdf:Description>'
          '</rdf:RDF></x:xmpmeta>';

      final record = parseXmpXml(xml)!;
      expect(record.assetId, 'multi');
      expect(record.title, 'T');
      expect(record.rating, 3);
    });
  });

  group('§4.7.5 XML entities are decoded', () {
    test('attribute entities', () {
      final xml = _xmp(
        '$_required'
        '<dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<rdf:Alt><rdf:li xml:lang="x-default">'
        'a &amp; b &lt; c &quot;d&quot;'
        '</rdf:li></rdf:Alt></dc:title>',
      );
      expect(parseXmpXml(xml)!.title, 'a & b < c "d"');
    });

    test('numeric character references', () {
      final xml = _xmp(
        '$_required'
        '<dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<rdf:Alt><rdf:li xml:lang="x-default">'
        '&#x4E2D;&#25991;'
        '</rdf:li></rdf:Alt></dc:title>',
      );
      expect(parseXmpXml(xml)!.title, '中文');
    });
  });

  group('tolerant reading', () {
    test('a package without provenance fields yields no record', () {
      final xml = _xmp(
        '<photoshop:Headline '
        'xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">'
        'only a headline</photoshop:Headline>',
      );
      expect(parseXmpXml(xml), isNull);
      expect(
        parseXmpFields(xml).otherFields['photoshop:Headline'],
        'only a headline',
      );
    });

    test('an unparsable date makes the record null instead of throwing', () {
      final xml = _xmp(
        '<prov:schema>0.1</prov:schema>'
        '<prov:assetId>a</prov:assetId>'
        '<prov:capturedAt>yesterday</prov:capturedAt>'
        '<prov:capturedBy>b</prov:capturedBy>',
      );
      expect(parseXmpXml(xml), isNull);
    });

    test('malformed XML throws a FormatException', () {
      expect(() => parseXmpFields('<not-closed>'), throwsA(anything));
    });
  });

  group('JPEG XMP', () {
    test('write then read', () {
      final record = sampleProvenance();
      final readBack = readJpegXmp(writeJpegXmp(minimalJpeg(), record))!;
      expect(readBack.toJson(), equals(record.toJson()));
    });

    test('a file without XMP reads as null', () {
      expect(readJpegXmp(minimalJpeg()), isNull);
    });

    test('an EXIF-only APP1 segment is skipped, not decoded', () {
      final bytes = jpegWithExifOnly();
      expect(readJpegXmp(bytes), isNull);
      expect(readJpegXmpText(bytes), isNull);
    });

    test('XMP is inserted after the last APPn segment', () {
      final written = writeJpegXmp(minimalJpeg(), sampleProvenance());
      final markers = scanJpegSegments(written).map((s) => s.marker).toList();
      expect(markers.first, 0xE0); // APP0 stays first
      expect(markers, contains(0xE1));
    });

    test('a non-JPEG input throws', () {
      expect(
        () => scanJpegSegments(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<FormatException>()),
      );
    });

    test('an oversized package is rejected', () {
      final huge = XmpProvenance(
        schema: '0.1',
        assetId: sampleProvenance().assetId,
        capturedAt: DateTime.utc(2026, 10, 20),
        capturedBy: 'TestApp/1.0.0',
        metadataDate: DateTime.utc(2026, 10, 20),
        description: 'x' * (maxJpegXmpBytes),
      );
      expect(
        () => writeJpegXmp(minimalJpeg(), huge),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('PNG XMP', () {
    test('write then read', () {
      final record = sampleProvenance();
      final readBack = readPngXmp(writePngXmp(minimalPng(), record))!;
      expect(readBack.toJson(), equals(record.toJson()));
    });

    test('a file without XMP reads as null', () {
      expect(readPngXmp(minimalPng()), isNull);
    });

    test('the XMP chunk is inserted before IEND', () {
      final written = writePngXmp(minimalPng(), sampleProvenance());
      final types = scanPngChunks(written).map((c) => c.type).toList();
      expect(types.last, 'IEND');
      expect(types, contains('iTXt'));
    });

    test('a non-PNG input throws', () {
      expect(
        () => scanPngChunks(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('WebP XMP', () {
    test('write then read on an extended file', () {
      final record = sampleProvenance();
      final readBack = readWebpXmp(
        writeWebpXmp(minimalWebpExtended(), record),
      )!;
      expect(readBack.toJson(), equals(record.toJson()));
    });

    test('a file without XMP reads as null', () {
      expect(readWebpXmp(minimalWebpVp8()), isNull);
    });

    test('a non-WebP input throws', () {
      expect(
        () => scanWebpChunks(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('format detection', () {
    test('detects JPEG, PNG and WebP from magic bytes', () {
      expect(detectFormat(minimalJpeg()), MediaFormat.jpeg);
      expect(detectFormat(minimalPng()), MediaFormat.png);
      expect(detectFormat(minimalWebpVp8()), MediaFormat.webp);
      expect(detectFormat(Uint8List.fromList([0, 1, 2])), MediaFormat.other);
    });
  });
}
