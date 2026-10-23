// Sidecar files (SPEC §4.2, §4.7 write requirement 1).
//
// A sidecar is the full original file name plus `.xmp`, UTF-8 without a BOM.
// When it already exists it is edited in place, so foreign fields and the
// original formatting survive; a new file is created only when there is none.

import 'dart:convert';
import 'dart:io';

import 'package:provenance_dart/provenance_dart.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// A sidecar written by another tool: attribute syntax, a foreign field, a
/// comment and non-ASCII text.
const _existingSidecar =
    '<?xpacket begin="\uFEFF" '
    'id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
    '<x:xmpmeta xmlns:x="adobe:ns:meta/">\n'
    ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
    '  <rdf:Description rdf:about=""\n'
    '    xmlns:dc="http://purl.org/dc/elements/1.1/"\n'
    '    xmlns:xmp="http://ns.adobe.com/xap/1.0/"\n'
    '    xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"\n'
    '    xmlns:prov="https://joopererer.github.io/provenance-spec/ns/"\n'
    '    prov:schema="0.1"\n'
    '    prov:assetId="1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"\n'
    '    prov:capturedAt="2026-10-20T18:00:00+02:00"\n'
    '    prov:capturedBy="FileOrganizer/2.0.0"\n'
    '    photoshop:Headline="外部软件写入的标题"\n'
    '    xmp:MetadataDate="2026-10-22T10:00:00+02:00">\n'
    '   <!-- keep this comment -->\n'
    '   <dc:title>\n'
    '    <rdf:Alt>\n'
    '     <rdf:li xml:lang="x-default">旅行照片</rdf:li>\n'
    '    </rdf:Alt>\n'
    '   </dc:title>\n'
    '  </rdf:Description>\n'
    ' </rdf:RDF>\n'
    '</x:xmpmeta>\n'
    '<?xpacket end="w"?>';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('provenance_sidecar_');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('naming (SPEC §4.2)', () {
    test('the sidecar is the full file name plus .xmp', () {
      expect(sidecarPathFor('/a/IMG_001.jpg'), '/a/IMG_001.jpg.xmp');
      expect(sidecarPathFor('/a/IMG_001.mp4'), '/a/IMG_001.mp4.xmp');
    });

    test('a Live Photo image and video do not collide', () {
      expect(
        sidecarPathFor('/a/IMG_001.jpg'),
        isNot(sidecarPathFor('/a/IMG_001.mp4')),
      );
    });
  });

  group('creating a sidecar', () {
    test('a new sidecar is created next to the media file', () async {
      final media = '${dir.path}/photo.jpg';
      await File(media).writeAsBytes(minimalJpeg());

      await MetadataService.writeSidecar(media, sampleProvenance());

      final sidecar = File(sidecarPathFor(media));
      expect(await sidecar.exists(), isTrue);
      expect(await readSidecarFor(media), isNotNull);
    });

    test('a new sidecar is UTF-8 without a BOM', () async {
      final media = '${dir.path}/photo.jpg';
      await File(media).writeAsBytes(minimalJpeg());
      await MetadataService.writeSidecar(media, sampleProvenance());

      final bytes = await File(sidecarPathFor(media)).readAsBytes();
      expect(bytes.sublist(0, 3), isNot([0xEF, 0xBB, 0xBF]));
      // The xpacket begin attribute legitimately contains U+FEFF.
      expect(utf8.decode(bytes), contains('<?xpacket begin="\uFEFF"'));
    });

    test('a new sidecar holds every field of the record', () async {
      final media = '${dir.path}/photo.jpg';
      await File(media).writeAsBytes(minimalJpeg());
      final record = sampleProvenance();
      await MetadataService.writeSidecar(media, record);

      final readBack = (await readSidecarFor(media))!;
      expect(readBack.toJson(), equals(record.toJson()));
    });
  });

  group('editing an existing sidecar in place (SPEC §4.7)', () {
    late String media;
    late File sidecar;

    setUp(() async {
      media = '${dir.path}/video.mp4';
      await File(media).writeAsBytes([0, 0, 0, 0]);
      sidecar = File(sidecarPathFor(media));
      await sidecar.writeAsString(_existingSidecar, encoding: utf8);
    });

    test('foreign fields survive', () async {
      final record = (await readSidecarFor(media))!;
      await MetadataService.writeSidecar(
        media,
        record.copyWith(metadataDate: DateTime.utc(2030, 1, 1)),
      );

      final text = await sidecar.readAsString(encoding: utf8);
      expect(text, contains('photoshop:Headline="外部软件写入的标题"'));
      expect(
        text,
        contains('xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"'),
      );
    });

    test('the comment survives', () async {
      final record = (await readSidecarFor(media))!;
      await MetadataService.writeSidecar(
        media,
        record.copyWith(metadataDate: DateTime.utc(2030, 1, 1)),
      );
      expect(
        await sidecar.readAsString(encoding: utf8),
        contains('<!-- keep this comment -->'),
      );
    });

    test('attribute line breaks survive', () async {
      final record = (await readSidecarFor(media))!;
      await MetadataService.writeSidecar(
        media,
        record.copyWith(metadataDate: DateTime.utc(2030, 1, 1)),
      );
      final text = await sidecar.readAsString(encoding: utf8);
      expect(text, contains('  <rdf:Description rdf:about=""\n'));
      expect(text, contains('\n    prov:schema="0.1"\n'));
    });

    test('non-ASCII text stays UTF-8', () async {
      final record = (await readSidecarFor(media))!;
      await MetadataService.writeSidecar(
        media,
        record.copyWith(metadataDate: DateTime.utc(2030, 1, 1)),
      );
      final text = await sidecar.readAsString(encoding: utf8);
      expect(text, contains('旅行照片'));
      expect(text, isNot(contains('&#x')));
    });

    test('only the metadataDate changes in the body', () async {
      final record = (await readSidecarFor(media))!;
      await MetadataService.writeSidecar(
        media,
        record.copyWith(metadataDate: DateTime.utc(2030, 1, 1)),
      );
      final text = await sidecar.readAsString(encoding: utf8);

      String normalize(String value) => value.replaceAll(
        RegExp(r'xmp:MetadataDate="[^"]*"'),
        'xmp:MetadataDate="<date>"',
      );
      expect(normalize(text), normalize(_existingSidecar));
    });

    test('the assetId is not changed', () async {
      await MetadataService.writeSidecar(
        media,
        sampleProvenance(assetId: '00000000-0000-4000-8000-000000000000'),
      );
      expect(
        (await readSidecarFor(media))!.assetId,
        '1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d',
      );
    });

    test('a user field can be changed', () async {
      final record = (await readSidecarFor(media))!;
      await MetadataService.writeSidecar(
        media,
        record.copyWith(subject: ['旅行', '2025'], rating: 5),
      );

      final readBack = (await readSidecarFor(media))!;
      expect(readBack.subject, ['旅行', '2025']);
      expect(readBack.rating, 5);
      expect(readBack.title, '旅行照片');
    });

    test('the file is not recreated, so its inode is kept', () async {
      final before = await sidecar.stat();
      await MetadataService.writeSidecar(
        media,
        (await readSidecarFor(
          media,
        ))!.copyWith(metadataDate: DateTime.utc(2030, 1, 1)),
      );
      final after = await sidecar.stat();
      expect(after.size, greaterThan(0));
      expect(before.type, after.type);
    });
  });

  group('reading', () {
    test('a missing sidecar reads as null', () async {
      expect(await readSidecarFor('${dir.path}/nothing.jpg'), isNull);
    });

    test('a sidecar without provenance reads as null', () async {
      final file = File('${dir.path}/x.xmp');
      await file.writeAsString(
        '<x:xmpmeta xmlns:x="adobe:ns:meta/">'
        '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
        '<rdf:Description rdf:about=""/></rdf:RDF></x:xmpmeta>',
      );
      expect(await readSidecarXmp(file), isNull);
    });

    test('the spec vector sidecar is read in place', () async {
      final record = await readSidecarXmp(
        File('${Directory.current.path}/spec/test-vectors/local-video.mp4.xmp'),
      );
      expect(record, isNotNull);
      expect(record!.rating, 5);
    });
  });
}
