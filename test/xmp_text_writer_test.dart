// The `writeXmpTextToFile` API: a caller that edited the XMP package itself
// hands the finished XML back, and the same atomic / in-place rules that
// `MetadataService.embedProvenance` uses store it.

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:provenance_dart/provenance_dart.dart';
import 'package:test/test.dart';

import 'support/vectors.dart';

const String _assetId = 'a1b2c3d4-e5f6-4a7b-8c9d-1e2f3a4b5c6d';

XmpProvenance _provenance({
  String? headline,
  List<String> creators = const ['Ada Lovelace'],
  List<String> subject = const ['engraving'],
}) => XmpProvenance(
  schema: '0.1',
  assetId: _assetId,
  metadataDate: DateTime.utc(2026, 3, 1, 12),
  capturedAt: DateTime.utc(2026, 3, 1, 12),
  capturedBy: 'TextWriter/1.0.0',
  title: headline,
  creators: creators,
  subject: subject,
);

/// An edited package: [headline] changed and, when [dropCreator] is set, the
/// whole `dc:creator` field removed by handing `setField` an empty list.
String _editedXml({required String headline, bool dropCreator = false}) {
  final package = XmpPackage.parse(buildXmpXml(_provenance()));
  package.setField(XmpField.title, headline);
  if (dropCreator) package.setField(XmpField.creator, <String>[]);
  return package.text;
}

/// The bytes from the start of the entropy-coded image data, which no XMP
/// write may touch (JPEG).
int _jpegImageStart(Uint8List bytes) {
  for (var i = 2; i + 1 < bytes.length; i++) {
    if (bytes[i] == 0xFF && bytes[i + 1] == 0xDA) return i;
  }
  fail('no SOS marker');
}

/// The payload of every `IDAT` chunk, which no XMP write may touch (PNG).
List<int> _pngImageData(Uint8List bytes) {
  final out = <int>[];
  var offset = 8;
  while (offset + 8 <= bytes.length) {
    final length = _u32(bytes, offset);
    final type = String.fromCharCodes(bytes, offset + 4, offset + 8);
    if (type == 'IDAT') {
      out.addAll(bytes.sublist(offset + 8, offset + 8 + length));
    }
    offset += 12 + length;
  }
  return out;
}

/// The payload of the `VP8 `/`VP8L` chunk, which no XMP write may touch (WebP).
List<int> _webpImageData(Uint8List bytes) {
  final out = <int>[];
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final type = String.fromCharCodes(bytes, offset, offset + 4);
    final length = _u32(bytes, offset + 4);
    if (type == 'VP8 ' || type == 'VP8L') {
      out.addAll(bytes.sublist(offset + 8, offset + 8 + length));
    }
    offset += 8 + length + (length.isOdd ? 1 : 0);
  }
  return out;
}

int _u32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

/// A top-level MP4 box.
class _Box {
  _Box(this.type, this.start, this.size);

  final String type;
  final int start;
  final int size;

  int get stop => start + size;
}

/// The top-level boxes of [bytes], honouring 32-bit, 64-bit and size-zero
/// lengths (SPEC §4.7).
List<_Box> _boxes(Uint8List bytes) {
  final boxes = <_Box>[];
  var offset = 0;
  while (offset + 8 <= bytes.length) {
    final size = _u32(bytes, offset);
    final type = String.fromCharCodes(bytes, offset + 4, offset + 8);
    if (size == 0) {
      boxes.add(_Box(type, offset, bytes.length - offset));
      break;
    }
    final length = size == 1
        ? _u32(bytes, offset + 8) * 0x100000000 + _u32(bytes, offset + 12)
        : size;
    if (length < 8 || offset + length > bytes.length) break;
    boxes.add(_Box(type, offset, length));
    offset += length;
  }
  return boxes;
}

bool _isXmpBox(Uint8List bytes, _Box box) {
  if (box.type != 'uuid') return false;
  for (var i = 0; i < mp4XmpUuid.length; i++) {
    if (bytes[box.start + 8 + i] != mp4XmpUuid[i]) return false;
  }
  return true;
}

/// Asserts the MP4 structural guarantees of a finished write: exactly one XMP
/// box, and it is the last box in the file.
void _expectSingleTrailingXmpBox(Uint8List bytes) {
  final boxes = _boxes(bytes);
  final xmp = boxes.where((b) => _isXmpBox(bytes, b)).toList();
  expect(xmp, hasLength(1), reason: 'exactly one XMP box');
  expect(xmp.single.stop, bytes.length, reason: 'the XMP box ends the file');
  expect(boxes.last.type, 'uuid', reason: 'the XMP box is the last one');
}

/// The payload bytes of every `mdat` box.
List<int> _mdatPayload(Uint8List bytes) {
  final out = <int>[];
  for (final box in _boxes(bytes).where((b) => b.type == 'mdat')) {
    final header = _u32(bytes, box.start) == 1 ? 16 : 8;
    out.addAll(bytes.sublist(box.start + header, box.stop));
  }
  return out;
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('provenance_xmp_text_');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  /// Copies [vector] into [dir] under [name] and returns the file.
  Future<File> copyVector(String vector, [String? name]) async {
    final file = File(p.join(dir.path, name ?? vector));
    await file.writeAsBytes(await readVector(vector), flush: true);
    return file;
  }

  group('media containers', () {
    test('JPEG stores the edited package and keeps the image', () async {
      final file = await copyVector('xhs-item3.jpg');
      final before = await file.readAsBytes();

      await writeXmpTextToFile(file.path, _editedXml(headline: 'Edited'));

      final after = await file.readAsBytes();
      final record = readJpegXmp(after)!;
      expect(record.title, 'Edited');
      expect(record.assetId, _assetId);
      expect(
        after.sublist(_jpegImageStart(after)),
        before.sublist(_jpegImageStart(before)),
        reason: 'the entropy-coded image data is untouched',
      );
    });

    test('PNG stores the edited package and keeps the image', () async {
      final file = await copyVector('ig-item2.png');
      final before = await file.readAsBytes();

      await writeXmpTextToFile(file.path, _editedXml(headline: 'Edited'));

      final after = await file.readAsBytes();
      expect(readPngXmp(after)!.title, 'Edited');
      expect(_pngImageData(after), _pngImageData(before));
    });

    test('WebP stores the edited package and keeps the image', () async {
      final file = await copyVector('x-single.webp');
      final before = await file.readAsBytes();

      await writeXmpTextToFile(file.path, _editedXml(headline: 'Edited'));

      final after = await file.readAsBytes();
      expect(readWebpXmp(after)!.title, 'Edited');
      expect(_webpImageData(after), _webpImageData(before));
    });

    test('MP4 rewrite appends one XMP box and keeps mdat', () async {
      final file = await copyVector('mp4-xmp-uuid.mp4');
      final before = await file.readAsBytes();

      await writeXmpTextToFile(file.path, _editedXml(headline: 'Edited'));

      final after = await file.readAsBytes();
      expect(readMp4Xmp(after)!.title, 'Edited');
      _expectSingleTrailingXmpBox(after);
      expect(_mdatPayload(after), _mdatPayload(before));
    });

    test('MP4 in-place append appends one XMP box and keeps mdat', () async {
      final file = await copyVector('mp4-xmp-uuid.mp4');
      final before = await file.readAsBytes();

      await writeXmpTextToFile(
        file.path,
        _editedXml(headline: 'Edited'),
        mp4WriteMode: Mp4WriteMode.inPlace,
      );

      final after = await file.readAsBytes();
      expect(readMp4Xmp(after)!.title, 'Edited');
      _expectSingleTrailingXmpBox(after);
      expect(_mdatPayload(after), _mdatPayload(before));
    });

    test('MOV is treated as MP4', () async {
      final file = await copyVector('mov-xmp-uuid.mov');

      await writeXmpTextToFile(file.path, _editedXml(headline: 'Edited'));

      final after = await file.readAsBytes();
      expect(readMp4Xmp(after)!.title, 'Edited');
      _expectSingleTrailingXmpBox(after);
    });
  });

  group('sidecar', () {
    test('a .xmp path receives the package itself', () async {
      final path = p.join(dir.path, 'asset.xmp');
      final xml = _editedXml(headline: 'Sidecar');

      await writeXmpTextToFile(path, xml);

      final text = await File(path).readAsString();
      expect(text, xml);
      expect(parseXmpXml(text)!.title, 'Sidecar');
    });

    test('an uppercase .XMP path is a sidecar too', () {
      expect(isSidecarPath('asset.XMP'), isTrue);
      expect(isSidecarPath('asset.jpg'), isFalse);
    });
  });

  group('field removal', () {
    test('an empty list removes the whole field', () async {
      final file = await copyVector('xhs-item3.jpg');
      final before = readJpegXmp(await file.readAsBytes())!;
      expect(before.creators, isNotNull);
      expect(before.creators, isNotEmpty);

      await writeXmpTextToFile(
        file.path,
        _editedXml(headline: 'Edited', dropCreator: true),
      );

      final after = readJpegXmp(await file.readAsBytes())!;
      expect(after.creators ?? const <String>[], isEmpty);
      expect(after.title, 'Edited');
      expect(
        readJpegXmpText(await file.readAsBytes())!.contains('dc:creator'),
        isFalse,
      );
    });

    test('setField with an empty list is the same as removeField', () {
      final xml = buildXmpXml(_provenance());
      final package = XmpPackage.parse(xml)
        ..setField(XmpField.creator, <String>[]);
      expect(package.hasField(XmpField.creator), isFalse);
      expect(parseXmpXml(package.text)!.creators ?? const <String>[], isEmpty);
    });
  });

  group('errors', () {
    test('malformed XML throws and leaves the file untouched', () async {
      final file = await copyVector('xhs-item3.jpg');
      final before = await file.readAsBytes();

      await expectLater(
        writeXmpTextToFile(file.path, '<x:xmpmeta>not closed'),
        throwsFormatException,
      );

      expect(await file.readAsBytes(), before);
    });

    test('an unsupported container throws UnsupportedError', () async {
      final file = File(p.join(dir.path, 'clip.bin'));
      await file.writeAsBytes(List<int>.filled(64, 0x2A), flush: true);

      await expectLater(
        writeXmpTextToFile(file.path, _editedXml(headline: 'nope')),
        throwsUnsupportedError,
      );
    });

    test('a missing file throws FileSystemException', () async {
      await expectLater(
        writeXmpTextToFile(
          p.join(dir.path, 'missing.jpg'),
          _editedXml(headline: 'nope'),
        ),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
