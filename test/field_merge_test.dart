// Field-by-field merging of embedded metadata and sidecars (SPEC §4.4).
//
// The rule is per field: a field on only one side is taken from that side,
// whatever its class. Only a real conflict — both sides present, different
// values — is resolved by "capture fields from the embedded metadata, user
// fields from the newer xmp:MetadataDate".

import 'dart:io';

import 'package:provenance_dart/provenance_dart.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

const String _xmpOpen =
    '<x:xmpmeta xmlns:x="adobe:ns:meta/">'
    '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">';

const String _xmpClose = '</rdf:RDF></x:xmpmeta>';

String _package(String body) => '$_xmpOpen$body$_xmpClose';

const String _descriptionOpen =
    '<rdf:Description rdf:about="" '
    'xmlns:prov="https://joopererer.github.io/provenance-spec/ns/" '
    'xmlns:dc="http://purl.org/dc/elements/1.1/" '
    'xmlns:xmp="http://ns.adobe.com/xap/1.0/" '
    'xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/" ';

/// A complete `prov` package.
String _provPackage({
  String assetId = 'embedded-asset',
  String capturedBy = 'Embedded/1.0.0',
  String capturedAt = '2026-10-20T13:30:00Z',
  String metadataDate = '2026-10-20T13:30:00Z',
  String? platform,
  String? sourceId,
  String? sourceUrl,
  String? title,
  int? rating,
}) => _package(
  '$_descriptionOpen'
  'prov:assetId="$assetId" prov:capturedAt="$capturedAt" '
  'prov:capturedBy="$capturedBy" xmp:MetadataDate="$metadataDate"'
  '${platform == null ? '' : ' prov:platform="$platform"'}'
  '${sourceId == null ? '' : ' prov:sourceId="$sourceId"'}'
  '${sourceUrl == null ? '' : ' prov:sourceUrl="$sourceUrl"'}'
  '${title == null ? '' : ' dc:title="$title"'}'
  '${rating == null ? '' : ' xmp:Rating="$rating"'}/>',
);

XmpProvenance _record({
  required DateTime metadataDate,
  String assetId = 'embedded-asset',
  String capturedBy = 'Embedded/1.0.0',
  String? title,
  List<String>? creators,
  String? description,
  List<String>? subject,
  int? rating,
  String? platform,
  String? sourceId,
  String? sourceUrl,
  DateTime? publishedAt,
  String? credit,
  Map<String, String> otherFields = const {},
}) => XmpProvenance(
  schema: '0.1',
  assetId: assetId,
  capturedAt: DateTime.utc(2026, 10, 20, 10),
  capturedBy: capturedBy,
  metadataDate: metadataDate,
  platform: platform,
  sourceId: sourceId,
  sourceUrl: sourceUrl,
  publishedAt: publishedAt,
  title: title,
  creators: creators,
  description: description,
  subject: subject,
  rating: rating,
  credit: credit,
  otherFields: otherFields,
);

void main() {
  group('a field on one side only is taken from that side', () {
    test('capture fields missing from the embedded metadata come from the '
        'sidecar', () {
      final embedded = _record(metadataDate: DateTime.utc(2026, 10, 20));
      final sidecar = _record(
        metadataDate: DateTime.utc(2026, 10, 20),
        platform: 'xiaohongshu',
        sourceId: 'note-1',
        sourceUrl: 'https://www.xiaohongshu.com/explore/note-1',
        publishedAt: DateTime.utc(2026, 10, 18),
        credit: '作者 / 小红书',
      );

      final merged = mergeProvenance(embedded, sidecar)!;
      expect(merged.platform, 'xiaohongshu');
      expect(merged.sourceId, 'note-1');
      expect(merged.sourceUrl, 'https://www.xiaohongshu.com/explore/note-1');
      expect(merged.publishedAt, DateTime.utc(2026, 10, 18));
      expect(merged.credit, '作者 / 小红书');
    });

    test('capture fields only the embedded metadata has are kept', () {
      final embedded = _record(
        metadataDate: DateTime.utc(2026, 10, 20),
        platform: 'instagram',
        sourceId: 'shortcode',
      );
      final sidecar = _record(metadataDate: DateTime.utc(2026, 10, 25));

      final merged = mergeProvenance(embedded, sidecar)!;
      expect(merged.platform, 'instagram');
      expect(merged.sourceId, 'shortcode');
    });

    test('a user field only the embedded metadata has survives a newer '
        'sidecar', () {
      final embedded = _record(
        metadataDate: DateTime.utc(2026, 10, 20),
        title: 'embedded title',
        subject: ['embedded tag'],
      );
      final sidecar = _record(metadataDate: DateTime.utc(2030, 1, 1));

      final merged = mergeProvenance(embedded, sidecar)!;
      expect(merged.title, 'embedded title');
      expect(merged.subject, ['embedded tag']);
    });

    test('a user field only the sidecar has survives an older sidecar', () {
      final embedded = _record(
        metadataDate: DateTime.utc(2030, 1, 1),
        title: 'embedded title',
      );
      final sidecar = _record(
        metadataDate: DateTime.utc(2026, 10, 20),
        description: 'sidecar description',
      );

      final merged = mergeProvenance(embedded, sidecar)!;
      expect(merged.title, 'embedded title');
      expect(merged.description, 'sidecar description');
    });

    test('foreign fields from one side only are copied over', () {
      final embedded = _record(
        metadataDate: DateTime.utc(2026, 10, 20),
        otherFields: {'xmp:CreatorTool': 'Camera'},
      );
      final sidecar = _record(
        metadataDate: DateTime.utc(2026, 10, 20),
        otherFields: {'photoshop:Headline': 'Headline'},
      );

      final merged = mergeProvenance(embedded, sidecar)!;
      expect(merged.otherFields['xmp:CreatorTool'], 'Camera');
      expect(merged.otherFields['photoshop:Headline'], 'Headline');
    });
  });

  group('only a real conflict uses the conflict rule', () {
    test('identical values on both sides are not a conflict', () {
      final date = DateTime.utc(2026, 10, 20);
      final embedded = _record(
        metadataDate: date,
        title: 'same',
        platform: 'xiaohongshu',
      );
      final sidecar = _record(
        metadataDate: date,
        title: 'same',
        platform: 'xiaohongshu',
      );

      final merged = mergeProvenance(embedded, sidecar)!;
      expect(merged.title, 'same');
      expect(merged.platform, 'xiaohongshu');
    });

    test('a conflicting capture field keeps the embedded value even when the '
        'sidecar is newer', () {
      final embedded = _record(
        metadataDate: DateTime.utc(2026, 10, 20),
        platform: 'xiaohongshu',
      );
      final sidecar = _record(
        metadataDate: DateTime.utc(2030, 1, 1),
        platform: 'instagram',
      );

      expect(mergeProvenance(embedded, sidecar)!.platform, 'xiaohongshu');
    });

    test('a conflicting user field follows the newer MetadataDate', () {
      final embedded = _record(
        metadataDate: DateTime.utc(2026, 10, 20),
        title: 'embedded title',
      );
      final sidecar = _record(
        metadataDate: DateTime.utc(2026, 10, 25),
        title: 'sidecar title',
      );

      expect(mergeProvenance(embedded, sidecar)!.title, 'sidecar title');
    });

    test('the embedded side wins a conflict when MetadataDate is equal', () {
      final date = DateTime.utc(2026, 10, 20);
      final embedded = _record(metadataDate: date, title: 'embedded');
      final sidecar = _record(metadataDate: date, title: 'sidecar');

      expect(mergeProvenance(embedded, sidecar)!.title, 'embedded');
    });
  });

  group('mergeProvenanceXml — embedded XMP without prov fields', () {
    test('every capture field and the assetId come from the sidecar', () {
      // The embedded package has user fields only: a typical file that was
      // tagged in the Explorer and has no provenance metadata yet.
      final embeddedXml = _package(
        '$_descriptionOpen dc:title="Explorer title" xmp:Rating="3"/>',
      );
      final sidecarXml = _provPackage(
        assetId: 'sidecar-asset',
        capturedBy: 'Sidecar/2.0.0',
        platform: 'baidupan',
        sourceId: '1092837465019283',
      );

      final merged = mergeProvenanceXml(embeddedXml, sidecarXml)!;
      expect(merged.assetId, 'sidecar-asset');
      expect(merged.capturedBy, 'Sidecar/2.0.0');
      expect(merged.platform, 'baidupan');
      expect(merged.sourceId, '1092837465019283');
      // The embedded user fields stay, because the sidecar has none.
      expect(merged.title, 'Explorer title');
      expect(merged.rating, 3);
    });

    test('a sidecar with newer user fields wins only the user fields', () {
      final embeddedXml = _package(
        '$_descriptionOpen dc:title="Explorer title" '
        'xmp:MetadataDate="2026-10-20T10:00:00Z"/>',
      );
      final sidecarXml = _provPackage(
        assetId: 'sidecar-asset',
        metadataDate: '2026-10-25T10:00:00Z',
        title: 'Sidecar title',
      );

      final merged = mergeProvenanceXml(embeddedXml, sidecarXml)!;
      expect(merged.assetId, 'sidecar-asset');
      expect(merged.title, 'Sidecar title');
    });

    test('an embedded package with no XMP at all means the sidecar wins', () {
      final sidecarXml = _provPackage(assetId: 'sidecar-asset');
      final merged = mergeProvenanceXml(null, sidecarXml)!;
      expect(merged.assetId, 'sidecar-asset');
    });

    test('returns null when neither side has provenance metadata', () {
      final embeddedXml = _package(
        '$_descriptionOpen dc:title="Explorer title"/>',
      );
      expect(mergeProvenanceXml(embeddedXml, null), isNull);
    });

    test('unparseable embedded XML is treated as absent', () {
      final sidecarXml = _provPackage(assetId: 'sidecar-asset');
      final merged = mergeProvenanceXml('<not-xml', sidecarXml)!;
      expect(merged.assetId, 'sidecar-asset');
    });
  });

  group('mergeXmpFields', () {
    test('reports the metadataDate of the side that supplied the user '
        'fields', () {
      final embedded = _record(
        metadataDate: DateTime.utc(2026, 10, 20),
        title: 'embedded',
      );
      final sidecar = _record(
        metadataDate: DateTime.utc(2026, 10, 25),
        title: 'sidecar',
      );

      expect(
        mergeProvenance(embedded, sidecar)!.metadataDate,
        DateTime.utc(2026, 10, 25),
      );
      expect(
        mergeProvenance(sidecar, embedded)!.metadataDate,
        DateTime.utc(2026, 10, 25),
      );
    });

    test('works without a metadataDate on either side', () {
      final embeddedXml = _package(
        '$_descriptionOpen prov:assetId="a" '
        'prov:capturedAt="2026-10-20T10:00:00Z" prov:capturedBy="b" '
        'dc:title="embedded"/>',
      );
      final sidecarXml = _package(
        '$_descriptionOpen prov:platform="xiaohongshu"/>',
      );

      final merged = mergeProvenanceXml(embeddedXml, sidecarXml)!;
      expect(merged.assetId, 'a');
      expect(merged.platform, 'xiaohongshu');
      expect(merged.title, 'embedded');
    });
  });

  group('MetadataService.readProvenance', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('provenance_merge_');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('an embedded XMP without prov fields still yields the sidecar '
        'assetId and source', () async {
      final path = '${dir.path}/photo.jpg';
      final embeddedXml = _package(
        '$_descriptionOpen dc:title="Explorer title" xmp:Rating="3"/>',
      );
      await File(path).writeAsBytes(jpegWithRawXmp(minimalJpeg(), embeddedXml));

      final sidecar = _record(
        metadataDate: DateTime.utc(2026, 10, 25),
        assetId: 'sidecar-asset',
        capturedBy: 'EasySave/1.7.0',
        platform: 'xiaohongshu',
        sourceId: 'note-1',
        sourceUrl: 'https://www.xiaohongshu.com/explore/note-1',
      );
      await MetadataService.writeSidecar(path, sidecar);

      final merged = (await MetadataService.readProvenance(path))!;
      expect(merged.assetId, 'sidecar-asset');
      expect(merged.capturedBy, 'EasySave/1.7.0');
      expect(merged.platform, 'xiaohongshu');
      expect(merged.sourceId, 'note-1');
      expect(merged.sourceUrl, 'https://www.xiaohongshu.com/explore/note-1');
      expect(merged.title, 'Explorer title');
      expect(merged.rating, 3);
    });

    test('merges an embedded record with a newer sidecar', () async {
      final path = '${dir.path}/photo.jpg';
      final embedded = _record(
        metadataDate: DateTime.utc(2026, 10, 20),
        title: 'embedded title',
        platform: 'xiaohongshu',
        sourceId: 'note-1',
      );
      await File(path).writeAsBytes(writeJpegXmp(minimalJpeg(), embedded));

      final sidecar = _record(
        metadataDate: DateTime.utc(2026, 10, 25),
        title: 'sidecar title',
        rating: 5,
      );
      await MetadataService.writeSidecar(path, sidecar);

      final merged = (await MetadataService.readProvenance(path))!;
      expect(merged.title, 'sidecar title');
      expect(merged.rating, 5);
      expect(merged.platform, 'xiaohongshu');
      expect(merged.sourceId, 'note-1');
      expect(merged.assetId, embedded.assetId);
    });

    test('returns the embedded record when there is no sidecar', () async {
      final path = '${dir.path}/photo.jpg';
      final embedded = _record(
        metadataDate: DateTime.utc(2026, 10, 20),
        title: 'embedded title',
      );
      await File(path).writeAsBytes(writeJpegXmp(minimalJpeg(), embedded));

      final merged = (await MetadataService.readProvenance(path))!;
      expect(merged.title, 'embedded title');
    });

    test('returns the sidecar record when the file has no metadata', () async {
      final path = '${dir.path}/video.mp4';
      await File(path).writeAsBytes([0, 0, 0, 0]);
      final sidecar = _record(
        metadataDate: DateTime.utc(2026, 10, 20),
        title: 'sidecar only',
      );
      await MetadataService.writeSidecar(path, sidecar);

      final merged = (await MetadataService.readProvenance(path))!;
      expect(merged.title, 'sidecar only');
    });

    test('returns null when neither side has metadata', () async {
      final path = '${dir.path}/plain.jpg';
      await File(path).writeAsBytes(minimalJpeg());
      expect(await MetadataService.readProvenance(path), isNull);
    });

    test('readEmbedded and readSidecar read one side each', () async {
      final path = '${dir.path}/photo.jpg';
      await File(path).writeAsBytes(
        writeJpegXmp(
          minimalJpeg(),
          _record(metadataDate: DateTime.utc(2026, 10, 20), title: 'embedded'),
        ),
      );
      await MetadataService.writeSidecar(
        path,
        _record(metadataDate: DateTime.utc(2026, 10, 25), title: 'sidecar'),
      );

      expect((await MetadataService.readEmbedded(path))!.title, 'embedded');
      expect((await MetadataService.readSidecar(path))!.title, 'sidecar');
    });
  });

  group('date text survives the merge', () {
    test('the embedded capturedAt text is written back unchanged', () {
      final embedded = parseXmpXml(
        _package(
          '$_descriptionOpen prov:assetId="a" '
          'prov:capturedAt="2026-10-20T15:30:00+02:00" prov:capturedBy="b" '
          'xmp:MetadataDate="2026-10-20T15:30:00+02:00"/>',
        ),
      )!;
      final sidecar = _record(metadataDate: DateTime.utc(2026, 10, 25));

      final merged = mergeProvenance(embedded, sidecar)!;
      expect(merged.toJson()['capturedAt'], '2026-10-20T15:30:00+02:00');
    });

    test('a capture field taken from the sidecar keeps its own date text', () {
      final embeddedXml = _provPackage(assetId: 'a');
      final sidecarXml = _provPackage(
        assetId: 'a',
        metadataDate: '2026-10-25T10:00:00Z',
      ).replaceFirst('/>', ' prov:publishedAt="2026-10-18T03:12:00+02:00"/>');

      final merged = mergeProvenanceXml(embeddedXml, sidecarXml)!;
      expect(merged.publishedAt, DateTime.utc(2026, 10, 18, 1, 12));
      expect(
        merged.toJson()['source'],
        containsPair('publishedAt', '2026-10-18T03:12:00+02:00'),
      );
    });
  });
}
