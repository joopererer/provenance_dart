// Merging embedded metadata with a sidecar file (SPEC §4.4).
//
// A field present on only one side is taken from that side. Only a conflicting
// field uses the rule: capture fields keep the embedded value, user fields take
// the value of the newer `xmp:MetadataDate`.
//
// The exhaustive per-field coverage lives in field_merge_test.dart.

import 'dart:io';

import 'package:provenance_dart/provenance_dart.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

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
  Map<String, String> otherFields = const {},
}) => XmpProvenance(
  schema: '0.1',
  assetId: assetId,
  capturedAt: DateTime.utc(2026, 10, 20, 10),
  capturedBy: capturedBy,
  metadataDate: metadataDate,
  platform: platform,
  sourceId: sourceId,
  title: title,
  creators: creators,
  description: description,
  subject: subject,
  rating: rating,
  otherFields: otherFields,
);

void main() {
  group('one side only', () {
    test('returns the embedded record unchanged', () {
      final embedded = _record(metadataDate: DateTime.utc(2026, 10, 20));
      expect(mergeProvenance(embedded, null), same(embedded));
    });

    test('returns the sidecar record unchanged', () {
      final sidecar = _record(metadataDate: DateTime.utc(2026, 10, 20));
      expect(mergeProvenance(null, sidecar), same(sidecar));
    });

    test('returns null when neither side has metadata', () {
      expect(mergeProvenance(null, null), isNull);
    });
  });

  group('capture fields come from the embedded metadata', () {
    test('assetId, capturedBy and source fields are the embedded ones', () {
      final embedded = _record(
        metadataDate: DateTime.utc(2026, 10, 20),
        assetId: 'embedded-asset',
        capturedBy: 'Embedded/1.0.0',
        platform: 'xiaohongshu',
        sourceId: 'note-1',
      );
      final sidecar = _record(
        metadataDate: DateTime.utc(2026, 10, 25),
        assetId: 'sidecar-asset',
        capturedBy: 'Sidecar/2.0.0',
        platform: 'instagram',
        sourceId: 'shortcode',
      );

      final merged = mergeProvenance(embedded, sidecar)!;
      expect(merged.assetId, 'embedded-asset');
      expect(merged.capturedBy, 'Embedded/1.0.0');
      expect(merged.platform, 'xiaohongshu');
      expect(merged.sourceId, 'note-1');
    });

    test('capture fields win even when the sidecar is newer', () {
      final embedded = _record(
        metadataDate: DateTime.utc(2026, 10, 20),
        capturedBy: 'Embedded/1.0.0',
      );
      final sidecar = _record(
        metadataDate: DateTime.utc(2030, 1, 1),
        capturedBy: 'Sidecar/9.9.9',
      );
      expect(mergeProvenance(embedded, sidecar)!.capturedBy, 'Embedded/1.0.0');
    });
  });

  group('user fields come from the newer metadataDate', () {
    test('the embedded side wins when it is newer', () {
      final embedded = _record(
        metadataDate: DateTime.utc(2026, 10, 25),
        title: 'embedded title',
        subject: ['embedded'],
        rating: 5,
      );
      final sidecar = _record(
        metadataDate: DateTime.utc(2026, 10, 20),
        title: 'sidecar title',
        subject: ['sidecar'],
        rating: 1,
      );

      final merged = mergeProvenance(embedded, sidecar)!;
      expect(merged.title, 'embedded title');
      expect(merged.subject, ['embedded']);
      expect(merged.rating, 5);
      expect(merged.metadataDate, DateTime.utc(2026, 10, 25));
    });

    test('the sidecar wins when it is newer', () {
      final embedded = _record(
        metadataDate: DateTime.utc(2026, 10, 20),
        title: 'embedded title',
        subject: ['embedded'],
        rating: 1,
      );
      final sidecar = _record(
        metadataDate: DateTime.utc(2026, 10, 25),
        title: 'sidecar title',
        subject: ['sidecar'],
        rating: 5,
      );

      final merged = mergeProvenance(embedded, sidecar)!;
      expect(merged.title, 'sidecar title');
      expect(merged.subject, ['sidecar']);
      expect(merged.rating, 5);
      expect(merged.metadataDate, DateTime.utc(2026, 10, 25));
    });

    test('equal metadataDate keeps the embedded user fields', () {
      final date = DateTime.utc(2026, 10, 20);
      final embedded = _record(metadataDate: date, title: 'embedded');
      final sidecar = _record(metadataDate: date, title: 'sidecar');
      expect(mergeProvenance(embedded, sidecar)!.title, 'embedded');
    });

    test(
      'a user field missing on the winning side is taken from the other',
      () {
        final embedded = _record(
          metadataDate: DateTime.utc(2026, 10, 20),
          title: 'embedded title',
        );
        final sidecar = _record(
          metadataDate: DateTime.utc(2026, 10, 25),
          description: 'sidecar description',
        );

        final merged = mergeProvenance(embedded, sidecar)!;
        expect(merged.description, 'sidecar description');
        expect(merged.title, 'embedded title');
      },
    );

    test('every user field is merged independently', () {
      final embedded = _record(
        metadataDate: DateTime.utc(2026, 10, 20),
        title: 'embedded title',
        creators: ['embedded author'],
        description: 'embedded description',
        subject: ['embedded tag'],
        rating: 2,
      );
      final sidecar = _record(
        metadataDate: DateTime.utc(2026, 10, 25),
        title: 'sidecar title',
        creators: ['sidecar author'],
        description: 'sidecar description',
        subject: ['sidecar tag'],
        rating: 4,
      );

      final merged = mergeProvenance(embedded, sidecar)!;
      expect(merged.title, 'sidecar title');
      expect(merged.creators, ['sidecar author']);
      expect(merged.description, 'sidecar description');
      expect(merged.subject, ['sidecar tag']);
      expect(merged.rating, 4);
    });
  });

  group('foreign fields', () {
    test('both sides contribute, the embedded side winning on a clash', () {
      final embedded = _record(
        metadataDate: DateTime.utc(2026, 10, 20),
        otherFields: {'photoshop:Headline': 'embedded', 'xmp:CreatorTool': 'A'},
      );
      final sidecar = _record(
        metadataDate: DateTime.utc(2026, 10, 25),
        otherFields: {'photoshop:Headline': 'sidecar', 'xmp:Label': 'B'},
      );

      final merged = mergeProvenance(embedded, sidecar)!;
      expect(merged.otherFields['photoshop:Headline'], 'embedded');
      expect(merged.otherFields['xmp:CreatorTool'], 'A');
      expect(merged.otherFields['xmp:Label'], 'B');
    });
  });

  group('date text survives the merge', () {
    test('the embedded capturedAt text is written back unchanged', () {
      final embedded = parseXmpXml(
        '<x:xmpmeta xmlns:x="adobe:ns:meta/">'
        '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
        '<rdf:Description rdf:about="" '
        'xmlns:prov="https://joopererer.github.io/provenance-spec/ns/" '
        'xmlns:xmp="http://ns.adobe.com/xap/1.0/" '
        'prov:assetId="a" prov:capturedAt="2026-10-20T15:30:00+02:00" '
        'prov:capturedBy="b" xmp:MetadataDate="2026-10-20T15:30:00+02:00"/>'
        '</rdf:RDF></x:xmpmeta>',
      )!;
      final sidecar = _record(metadataDate: DateTime.utc(2026, 10, 25));

      final merged = mergeProvenance(embedded, sidecar)!;
      expect(merged.toJson()['capturedAt'], '2026-10-20T15:30:00+02:00');
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
}
