// AI disclosure fields of provenance-spec 0.1.6 (SPEC §2, §3.4, §3.7, §7).

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:provenance_dart/provenance_dart.dart';
import 'package:test/test.dart';

import 'support/vectors.dart';

const String _composite = compositeWithTrainedAlgorithmicMedia;
const String _trained =
    'http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia';

XmpProvenance _labelled({String? aiLabel, String? aiLabelSource}) =>
    ProvenanceBuilder(
      platform: 'test',
      capturedBy: 'ProvenanceTest/1.0.0',
      sourceId: 'abc123',
      aiLabel: aiLabel,
      aiLabelSource: aiLabelSource,
    ).build(now: DateTime.utc(2026, 10, 24, 12));

void main() {
  group('§10 read: AI label vectors', () {
    test('jpeg-ai-label.jpg maps the platform badge to DigitalSourceType', () {
      final record = readJpegXmp(await0('jpeg-ai-label.jpg'));
      expect(record, isNotNull);
      expectJsonMatches(
        record!.toJson(),
        loadExpected('jpeg-ai-label.jpg'),
        'jpeg-ai-label',
      );
      expect(record.aiLabel, '内容疑似包含 AI 创作信息');
      expect(record.aiLabelSource, aiLabelSourcePlatform);
      expect(record.digitalSourceType, _composite);
    });

    test('mp4-ai-label.mp4 reads the author declaration', () {
      final record = readMp4Xmp(await0('mp4-ai-label.mp4'));
      expect(record, isNotNull);
      expectJsonMatches(
        record!.toJson(),
        loadExpected('mp4-ai-label.mp4'),
        'mp4-ai-label',
      );
      expect(record.aiLabelSource, aiLabelSourceAuthor);
      expect(record.digitalSourceType, _composite);
    });

    test('jpeg-existing-digitalsourcetype.jpg keeps its own source type', () {
      final record = readJpegXmp(await0('jpeg-existing-digitalsourcetype.jpg'));
      expect(record, isNotNull);
      expectJsonMatches(
        record!.toJson(),
        loadExpected('jpeg-existing-digitalsourcetype.jpg'),
        'existing-digitalsourcetype',
      );
      expect(record.digitalSourceType, _trained);
    });
  });

  group('model', () {
    test('the label is stored verbatim, never translated', () {
      const label = '  Content may include AI-generated 信息 🎨  ';
      final record = _labelled(aiLabel: label, aiLabelSource: 'platform');
      expect(record.aiLabel, label);
      expect(record.toXmpJson()['prov:aiLabel'], label);

      // A round trip through the XMP text keeps the exact code units.
      final text = buildXmpXml(record);
      expect(parseXmpXml(text)!.aiLabel, label);
    });

    test('only the three spec values are accepted as a source', () {
      for (final value in ['platform', 'author', 'unknown']) {
        expect(normalizeAiLabelSource(value), value);
      }
      for (final value in ['Platform', 'AUTHOR', 'platform ', 'bot', '', '0']) {
        expect(
          normalizeAiLabelSource(value),
          aiLabelSourceUnknown,
          reason: 'value "$value"',
        );
      }
      expect(normalizeAiLabelSource(null), aiLabelSourceUnknown);
    });

    test('an unknown source read from a file becomes unknown', () {
      final record = _labelled(aiLabel: 'x', aiLabelSource: 'author');
      final xml = buildXmpXml(record).replaceFirst(
        'prov:aiLabelSource="author"',
        'prov:aiLabelSource="vendor-specific"',
      );
      expect(parseXmpXml(xml)!.aiLabelSource, aiLabelSourceUnknown);
    });

    test('JSON uses the flat names of SPEC §7', () {
      final record = _labelled(aiLabel: '由 AI 生成', aiLabelSource: 'author');
      final json = record.toJson();
      expect(json['aiLabel'], '由 AI 生成');
      expect(json['aiLabelSource'], 'author');
      expect(json['digitalSourceType'], _composite);
      expect(json.containsKey('prov:aiLabel'), isFalse);

      final xmp = record.toXmpJson();
      expect(xmp['prov:aiLabel'], '由 AI 生成');
      expect(xmp['prov:aiLabelSource'], 'author');
      expect(xmp['Iptc4xmpExt:DigitalSourceType'], _composite);
    });

    test('fromJson accepts both spellings and normalizes the source', () {
      final flat = XmpProvenance.fromJson({
        'assetId': 'a1b2c3d4-e5f6-4a7b-8c9d-1e2f3a4b5c6d',
        'capturedAt': '2026-10-24T09:00:00+08:00',
        'capturedBy': 'EasySave/1.9.0',
        'aiLabel': '由 AI 生成',
        'aiLabelSource': 'nonsense',
      });
      expect(flat.aiLabel, '由 AI 生成');
      expect(flat.aiLabelSource, aiLabelSourceUnknown);
      expect(flat.toJson()['aiLabelSource'], aiLabelSourceUnknown);

      final qualified = XmpProvenance.fromJson({
        'prov:assetId': 'a1b2c3d4-e5f6-4a7b-8c9d-1e2f3a4b5c6d',
        'prov:capturedAt': '2026-10-24T09:00:00+08:00',
        'prov:capturedBy': 'EasySave/1.9.0',
        'prov:aiLabel': '作者声明',
        'prov:aiLabelSource': 'author',
        'Iptc4xmpExt:DigitalSourceType': _trained,
      });
      expect(qualified.aiLabel, '作者声明');
      expect(qualified.aiLabelSource, aiLabelSourceAuthor);
      expect(qualified.digitalSourceType, _trained);
      expect(qualified.toJson().containsKey('digitalSourceType'), isTrue);
    });
  });

  group('builder', () {
    test('an AI label implies the composite source type', () {
      final record = _labelled(aiLabel: '由 AI 生成', aiLabelSource: 'platform');
      expect(record.digitalSourceType, _composite);
      expect(record.aiLabelSource, aiLabelSourcePlatform);
    });

    test('no AI label means no source type is invented', () {
      final record = _labelled();
      expect(record.aiLabel, isNull);
      expect(record.aiLabelSource, isNull);
      expect(record.digitalSourceType, isNull);
      expect(record.toJson().containsKey('digitalSourceType'), isFalse);
    });

    test('an unknown source is normalized by the builder', () {
      final record = _labelled(aiLabel: 'x', aiLabelSource: 'machine');
      expect(record.aiLabelSource, aiLabelSourceUnknown);
    });
  });

  group('write: an existing DigitalSourceType is never overwritten', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('provenance_ai_label');
    });
    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test('JPEG keeps trainedAlgorithmicMedia', () async {
      final file = File(p.join(dir.path, 'existing.jpg'));
      await file.writeAsBytes(
        await readVector('jpeg-existing-digitalsourcetype.jpg'),
        flush: true,
      );

      final result = await MetadataService.embedProvenance(
        filePath: file.path,
        provenance: _labelled(aiLabel: '由 AI 生成', aiLabelSource: 'platform'),
      );
      expect(result.success, isTrue, reason: result.errorMessage);

      final record = readJpegXmp(await file.readAsBytes());
      expect(record, isNotNull);
      expect(
        record!.digitalSourceType,
        _trained,
        reason: 'the original source type must survive',
      );
      expect(
        record.aiLabel,
        '由 AI 生成',
        reason: 'aiLabel is a capture field, so the existing one wins',
      );
      expect(record.aiLabelSource, aiLabelSourceAuthor);
    });

    test('JPEG gains the composite type when it has none', () async {
      final file = File(p.join(dir.path, 'plain.jpg'));
      await file.writeAsBytes(await readVector('xhs-item3.jpg'), flush: true);

      final result = await MetadataService.embedProvenance(
        filePath: file.path,
        provenance: _labelled(aiLabel: '由 AI 生成', aiLabelSource: 'author'),
      );
      expect(result.success, isTrue, reason: result.errorMessage);

      final record = readJpegXmp(await file.readAsBytes())!;
      expect(record.digitalSourceType, _composite);
      expect(record.aiLabel, '由 AI 生成');
      expect(record.aiLabelSource, aiLabelSourceAuthor);
    });

    for (final mode in Mp4WriteMode.values) {
      test('MP4 keeps trainedAlgorithmicMedia via ${mode.name}', () async {
        final file = File(p.join(dir.path, 'existing.mp4'));
        await file.writeAsBytes(
          await readVector('mp4-no-xmp.mp4'),
          flush: true,
        );

        // Give the file a source type of its own, as a camera or generator
        // would.
        await MetadataService.embedProvenance(
          filePath: file.path,
          provenance: _labelled().copyWith(digitalSourceType: _trained),
          mp4WriteMode: mode,
        );
        expect(
          readMp4Xmp(await file.readAsBytes())!.digitalSourceType,
          _trained,
        );

        final result = await MetadataService.embedProvenance(
          filePath: file.path,
          provenance: _labelled(aiLabel: '由 AI 生成'),
          mp4WriteMode: mode,
        );
        expect(result.success, isTrue, reason: result.errorMessage);

        final record = readMp4Xmp(await file.readAsBytes());
        expect(record, isNotNull);
        expect(record!.digitalSourceType, _trained);
        expect(record.aiLabel, '由 AI 生成');
        expect(readMp4XmpText(await file.readAsBytes()), isNotNull);
      });
    }
  });

  group('merge: the three fields are capture fields', () {
    test('"missing only" applies to both sides', () {
      final embedded = XmpProvenance.fromJson({
        'assetId': 'a1b2c3d4-e5f6-4a7b-8c9d-1e2f3a4b5c6d',
        'capturedAt': '2026-10-24T09:00:00+08:00',
        'capturedBy': 'Embedded/1.0.0',
        'metadataDate': '2026-10-24T09:00:00+08:00',
      });
      final sidecar = embedded.copyWith(
        capturedBy: 'Sidecar/9.9.9',
        metadataDate: DateTime.utc(2027),
        aiLabel: '来自边车',
        aiLabelSource: 'platform',
        digitalSourceType: _composite,
      );

      final merged = mergeProvenance(embedded, sidecar)!;
      // The sidecar is newer, but the capture fields only fill gaps.
      expect(merged.aiLabel, '来自边车');
      expect(merged.aiLabelSource, aiLabelSourcePlatform);
      expect(merged.digitalSourceType, _composite);
      expect(merged.capturedBy, 'Embedded/1.0.0');

      final reverse = mergeProvenance(sidecar, embedded)!;
      expect(reverse.aiLabel, '来自边车', reason: 'the embedded value wins');
      expect(reverse.digitalSourceType, _composite);
    });

    test('a differing embedded source type wins over the sidecar', () {
      final embedded = XmpProvenance.fromJson({
        'assetId': 'a1b2c3d4-e5f6-4a7b-8c9d-1e2f3a4b5c6d',
        'capturedAt': '2026-10-24T09:00:00+08:00',
        'capturedBy': 'Embedded/1.0.0',
        'digitalSourceType': _trained,
      });
      final sidecar = embedded.copyWith(
        metadataDate: DateTime.utc(2027),
        digitalSourceType: _composite,
      );
      expect(mergeProvenance(embedded, sidecar)!.digitalSourceType, _trained);
    });
  });

  group('plugin fixtures unaffected', () {
    test('a provenance without an AI label emits no AI fields', () async {
      final record = readJpegXmp(await0('no-metadata.jpg'));
      expect(record, isNull);
      expect(parseXmpXml(buildXmpXml(_labelled()))?.aiLabel, isNull);
    });
  });
}

/// Reads a vector synchronously so the tests can stay free of `async` noise.
Uint8List await0(String name) => vectorFile(name).readAsBytesSync();
