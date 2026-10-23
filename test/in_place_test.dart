// In-place XML editing (SPEC §4.7 write requirement 1).
//
// A write must splice the fields of this spec into the existing XML. Every
// other byte — foreign namespaces, attribute line breaks, comments, the
// xpacket header, non-ASCII text as UTF-8 rather than character references —
// has to survive verbatim, which is exactly what regenerating the package
// from a data model would destroy.

import 'package:provenance_dart/provenance_dart.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// An XMP package written the way exiftool and Adobe tools write it:
/// attribute syntax, attributes spread over several lines, a comment, a
/// foreign namespace and non-ASCII text.
const _attributeStylePackage =
    '<?xpacket begin="\uFEFF" '
    'id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
    '<x:xmpmeta xmlns:x="adobe:ns:meta/">\n'
    ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
    '  <rdf:Description rdf:about=""\n'
    '    xmlns:dc="http://purl.org/dc/elements/1.1/"\n'
    '    xmlns:xmp="http://ns.adobe.com/xap/1.0/"\n'
    '    xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"\n'
    '    xmlns:prov="https://joopererer.github.io/provenance-spec/ns/"\n'
    '    xmp:Rating="3"\n'
    '    prov:schema="0.1"\n'
    '    prov:assetId="3f0c6a2e-8d4b-4c1a-9a3e-2b7f5d9e1c40"\n'
    '    prov:capturedAt="2026-10-20T15:30:00+02:00"\n'
    '    prov:capturedBy="EasySave/1.7.0"\n'
    '    photoshop:Headline="不要改动这一行"\n'
    '    xmp:MetadataDate="2026-10-20T15:30:00+02:00">\n'
    '   <!-- a comment that must survive -->\n'
    '   <dc:title>\n'
    '    <rdf:Alt>\n'
    '     <rdf:li xml:lang="x-default">原始标题</rdf:li>\n'
    '    </rdf:Alt>\n'
    '   </dc:title>\n'
    '  </rdf:Description>\n'
    ' </rdf:RDF>\n'
    '</x:xmpmeta>\n'
    '<?xpacket end="w"?>';

void main() {
  group('only the metadata fields change', () {
    late String updated;

    setUp(() {
      updated = updateXmpXml(
        _attributeStylePackage,
        parseXmpXml(
          _attributeStylePackage,
        )!.copyWith(metadataDate: DateTime.utc(2030, 1, 1)),
      );
    });

    test('a changed value is the only difference in the body', () {
      String normalize(String text) => text.replaceAll(
        RegExp(r'xmp:MetadataDate="[^"]*"'),
        'xmp:MetadataDate="<date>"',
      );
      expect(normalize(updated), normalize(_attributeStylePackage));
      expect(updated, contains('xmp:MetadataDate="2030-01-01T00:00:00Z"'));
    });

    test('attribute line breaks outside the changed value survive', () {
      expect(updated, contains('  <rdf:Description rdf:about=""\n'));
      expect(updated, contains('\n    xmp:Rating="3"\n'));
      expect(updated, contains('\n    prov:schema="0.1"\n'));
      expect(updated, contains('\n    prov:assetId='));
      expect(updated, contains('\n    prov:capturedAt='));
    });

    test('foreign attributes and namespaces survive verbatim', () {
      expect(updated, contains('photoshop:Headline="不要改动这一行"'));
      expect(
        updated,
        contains('xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"'),
      );
    });

    test('the comment survives', () {
      expect(updated, contains('<!-- a comment that must survive -->'));
    });

    test('the xpacket header and trailer survive', () {
      expect(updated, startsWith('<?xpacket begin="\uFEFF" '));
      expect(updated, endsWith('<?xpacket end="w"?>'));
    });

    test('non-ASCII text stays UTF-8, not numeric references', () {
      expect(updated, contains('原始标题'));
      expect(updated, isNot(contains('&#x')));
    });

    test('indentation around the unchanged element survives', () {
      expect(updated, contains('   <dc:title>\n    <rdf:Alt>\n'));
    });

    test('the resulting package still parses to the same fields', () {
      final before = parseXmpXml(_attributeStylePackage)!;
      final after = parseXmpXml(updated)!;
      expect(after.assetId, before.assetId);
      expect(after.capturedAt, before.capturedAt);
      expect(after.rating, before.rating);
      expect(after.title, before.title);
      expect(after.otherFields, equals(before.otherFields));
      expect(after.metadataDate, DateTime.utc(2030, 1, 1));
    });
  });

  group('element syntax is edited in place', () {
    test('only the text of a scalar element changes', () {
      const xml =
          '<x:xmpmeta xmlns:x="adobe:ns:meta/">'
          '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
          '<rdf:Description rdf:about="" '
          'xmlns:prov="https://joopererer.github.io/provenance-spec/ns/" '
          'xmlns:xmp="http://ns.adobe.com/xap/1.0/">'
          '<prov:schema>0.1</prov:schema>'
          '<prov:assetId>a</prov:assetId>'
          '<prov:capturedAt>2026-10-20T10:00:00Z</prov:capturedAt>'
          '<prov:capturedBy>b</prov:capturedBy>'
          '<xmp:MetadataDate>2026-10-20T10:00:00Z</xmp:MetadataDate>'
          '<xmp:Rating>2</xmp:Rating>'
          '</rdf:Description></rdf:RDF></x:xmpmeta>';

      final updated = updateXmpXml(xml, parseXmpXml(xml)!.copyWith(rating: 5));

      expect(updated, contains('<xmp:Rating>5</xmp:Rating>'));
      expect(updated, isNot(contains('<xmp:Rating>2</xmp:Rating>')));
      expect(updated, contains('<prov:assetId>a</prov:assetId>'));
    });

    test('the rdf:Alt default language item is updated', () {
      const xml =
          '<x:xmpmeta xmlns:x="adobe:ns:meta/">'
          '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
          '<rdf:Description rdf:about="" '
          'xmlns:dc="http://purl.org/dc/elements/1.1/" '
          'xmlns:prov="https://joopererer.github.io/provenance-spec/ns/">'
          '<prov:assetId>a</prov:assetId>'
          '<prov:capturedAt>2026-10-20T10:00:00Z</prov:capturedAt>'
          '<prov:capturedBy>b</prov:capturedBy>'
          '<dc:title><rdf:Alt>'
          '<rdf:li xml:lang="x-default">old</rdf:li>'
          '<rdf:li xml:lang="de">alt</rdf:li>'
          '</rdf:Alt></dc:title>'
          '</rdf:Description></rdf:RDF></x:xmpmeta>';

      final updated = updateXmpXml(
        xml,
        parseXmpXml(xml)!.copyWith(title: 'new'),
      );

      expect(updated, contains('<rdf:li xml:lang="x-default">new</rdf:li>'));
      // Other languages written by other software are left alone.
      expect(updated, contains('<rdf:li xml:lang="de">alt</rdf:li>'));
    });

    test('an rdf:Seq is rewritten when the author list changes', () {
      const xml =
          '<x:xmpmeta xmlns:x="adobe:ns:meta/">'
          '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
          '<rdf:Description rdf:about="" '
          'xmlns:dc="http://purl.org/dc/elements/1.1/" '
          'xmlns:prov="https://joopererer.github.io/provenance-spec/ns/">'
          '<prov:assetId>a</prov:assetId>'
          '<prov:capturedAt>2026-10-20T10:00:00Z</prov:capturedAt>'
          '<prov:capturedBy>b</prov:capturedBy>'
          '<dc:creator><rdf:Seq><rdf:li>A</rdf:li></rdf:Seq></dc:creator>'
          '</rdf:Description></rdf:RDF></x:xmpmeta>';

      final updated = updateXmpXml(
        xml,
        parseXmpXml(xml)!.copyWith(creators: ['A', 'B']),
      );

      expect(
        updated,
        contains(
          '<dc:creator><rdf:Seq><rdf:li>A</rdf:li><rdf:li>B</rdf:li>'
          '</rdf:Seq></dc:creator>',
        ),
      );
    });

    test('a missing field is added to the first Description block', () {
      final updated = updateXmpXml(
        _attributeStylePackage,
        parseXmpXml(_attributeStylePackage)!.copyWith(subject: ['新标签']),
      );
      final record = parseXmpXml(updated)!;
      expect(record.subject, ['新标签']);
      expect(
        updated,
        contains('dc:subject'),
        reason: 'the new field must be in the package',
      );
      // The existing attribute block is still the only Description.
      expect('rdf:Description'.allMatches(updated).length, 2);
    });

    test('an unparsable package falls back to a fresh one', () {
      final updated = updateXmpXml('<broken', sampleProvenance());
      expect(parseXmpXml(updated)!.assetId, sampleProvenance().assetId);
    });
  });

  group('removeField', () {
    test('removes an attribute without leaving stray whitespace', () {
      final package = XmpPackage.parse(_attributeStylePackage);
      package.removeField(XmpField.rating);

      expect(package.text, isNot(contains('xmp:Rating')));
      expect(package.text, contains('\n    prov:schema="0.1"'));
      expect(parseXmpXml(package.text)!.rating, isNull);
    });

    test('removes a whole element', () {
      final package = XmpPackage.parse(_attributeStylePackage);
      package.removeField(XmpField.title);

      expect(package.text, isNot(contains('dc:title')));
      expect(parseXmpXml(package.text)!.title, isNull);
    });
  });

  group('escaping', () {
    test('attribute values escape the quote character in use', () {
      expect(escapeAttributeValue('a"b', '"'), 'a&quot;b');
      expect(escapeAttributeValue("a'b", "'"), 'a&apos;b');
      expect(escapeAttributeValue('a&b<c', '"'), 'a&amp;b&lt;c');
    });

    test('text escapes &, < and >', () {
      expect(escapeText('a & b < c > d'), 'a &amp; b &lt; c &gt; d');
    });

    test('a value with quotes and newlines survives a write', () {
      const tricky = 'line1\nline2 "quoted" & <tagged>';
      final record = sampleProvenance().copyWith(description: tricky);
      final readBack = parseXmpXml(
        updateXmpXml(_attributeStylePackage, record),
      )!;
      expect(readBack.description, tricky);
    });

    test('a new attribute value with a double quote is escaped', () {
      final package = XmpPackage.empty();
      package.setField(XmpField.platform, 'a "b" c');
      expect(package.text, contains('&quot;b&quot;'));
      expect(parseXmpFields(package.text).string(XmpField.platform), 'a "b" c');
    });

    test('a list value is written as an element, not as an attribute', () {
      final package = XmpPackage.empty();
      package.setField(XmpField.creator, ['A', 'B']);
      expect(package.text, contains('<dc:creator><rdf:Seq>'));
      expect(parseXmpFields(package.text).list(XmpField.creator), ['A', 'B']);
    });
  });

  group('characters that are illegal in XML are escaped', () {
    test('CR in text becomes a numeric reference', () {
      expect(escapeText('a\rb'), 'a&#13;b');
    });

    test('tab and newline in an attribute become numeric references', () {
      expect(escapeAttributeValue('a\tb\nc', '"'), 'a&#9;b&#10;c');
    });
  });
}
