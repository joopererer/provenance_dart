// MP4 / MOV XMP support against provenance-spec 0.1.5 (SPEC §4.1, §4.3, §4.7).
//
// Reading walks the top-level box chain only; writing appends one new XMP
// `uuid` box at the end of the file and retires the old ones by renaming their
// box type to `free`. Nothing is re-encoded.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:provenance_dart/provenance_dart.dart';
// The in-place rollback hook is deliberately not part of the public surface.
import 'package:provenance_dart/src/xmp_mp4.dart' as internal;
import 'package:test/test.dart';

import 'support/fixtures.dart';
import 'support/vectors.dart';

/// The MP4 / MOV read cases of `spec/test-vectors/`.
///
/// `local-video.mp4` carries its provenance in the `local-video.mp4.xmp`
/// sidecar, so it has no embedded XMP and is checked separately.
const List<String> _videoVectors = [
  'local-video.mp4',
  'mov-no-xmp.mov',
  'mov-xmp-uuid.mov',
  'mp4-64bit-box.mp4',
  'mp4-interrupted-append.mp4',
  'mp4-mdat-uuid-noise.mp4',
  'mp4-multiple-xmp.mp4',
  'mp4-no-xmp.mp4',
  'mp4-size-zero-mdat.mp4',
  'mp4-truncated-mdat.mp4',
  'mp4-truncated-xmp.mp4',
  'mp4-xmp-uuid.mp4',
];

/// The vectors whose provenance is embedded in the container.
final List<String> _embeddedVectors = _videoVectors
    .where((name) => name != 'local-video.mp4')
    .toList(growable: false);

/// Vectors whose last top-level box runs past the end of the file and is not a
/// recoverable XMP box, so a writer must refuse them.
const List<String> _truncatedVectors = ['mp4-truncated-mdat.mp4'];

/// The writable vectors: every read case a writer accepts.
///
/// `mp4-interrupted-append.mp4` and `mp4-truncated-xmp.mp4` end with a
/// half-written XMP box; SPEC §4.7 allows truncating it away and writing
/// normally.
final List<String> _writableVectors = _videoVectors
    .where((name) => !_truncatedVectors.contains(name))
    .toList(growable: false);

/// A foreign field that a write must keep (SPEC §4.7).
const String _foreignValue = 'Foreign field that must be preserved';

const String _writer = 'ProvenanceTest/1.0.0';

XmpProvenance _provenance() => ProvenanceBuilder(
  platform: 'test',
  capturedBy: _writer,
  sourceId: 'abc123',
  sourceUrl: 'https://example.com/p/abc123',
  authorName: 'Tester',
  title: 'MP4 写入测试',
).build();

/// Whether the bytes of [a] and [b] are equal over `[from, to)`.
///
/// Comparing bytes is stronger than comparing their SHA-256, so the write
/// checks below use it directly.
bool _sameRange(Uint8List a, Uint8List b, int from, int to) {
  if (to > b.length) return false;
  for (var i = from; i < to; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

List<int> _u32(int value) => [
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
];

List<int> _u64(int value) => [
  (value >> 56) & 0xFF,
  (value >> 48) & 0xFF,
  (value >> 40) & 0xFF,
  (value >> 32) & 0xFF,
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
];

/// The four-byte type of a `uuid` box.
const List<int> _uuidType = [0x75, 0x75, 0x69, 0x64];

/// Asserts every structural guarantee of a finished MP4 / MOV write.
void _expectWriteResult({
  required Uint8List original,
  required Uint8List written,
  required String label,
}) {
  final before = scanMp4Boxes(original);
  final after = scanMp4Boxes(written);

  // An interrupted append leaves an incomplete XMP box at the end; the writer
  // is allowed to drop it, so it is not part of the comparison.
  final recoverable = before.last.isTruncated && before.last.isXmp;
  final stable = recoverable ? before.sublist(0, before.length - 1) : before;

  expect(
    after.length,
    stable.length + 1,
    reason: '$label: exactly one box was added',
  );

  for (var i = 0; i < stable.length; i++) {
    final a = stable[i];
    final b = after[i];
    if (a.isXmp) {
      expect(b.type, mp4FreeBoxType, reason: '$label: box $i retired');
      expect(
        b.stop - b.start,
        a.stop - a.start,
        reason: '$label: box $i keeps its size',
      );
      expect(
        _sameRange(original, written, a.start + 8, a.stop),
        isTrue,
        reason: '$label: box $i unchanged apart from its type',
      );
    } else if (a.extendsToEnd) {
      expect(b.extendsToEnd, isFalse, reason: '$label: box $i materialized');
      expect(
        b.declaredSize,
        original.length - a.start,
        reason: '$label: box $i gets its real size',
      );
      expect(
        _sameRange(original, written, a.start + 4, a.stop),
        isTrue,
        reason: '$label: box $i payload unchanged',
      );
    } else {
      expect(
        _sameRange(original, written, a.start, a.stop),
        isTrue,
        reason: '$label: box ${a.type} unchanged',
      );
    }
  }

  final xmpBoxes = after.where((box) => box.isXmp).toList();
  expect(xmpBoxes.length, 1, reason: '$label: exactly one XMP box');
  expect(after.last.isXmp, isTrue, reason: '$label: XMP box is last');
  expect(after.last.stop, written.length, reason: '$label: XMP box at EOF');
}

Future<File> _copyVector(Directory dir, String name) async {
  final target = File(p.join(dir.path, name));
  await target.writeAsBytes(await readVector(name), flush: true);
  return target;
}

/// A complete XMP `uuid` box for [provenance], built the way the writer does.
List<int> _encodeXmpBoxForTest(XmpProvenance provenance) {
  final payload = utf8.encode(buildXmpXml(provenance));
  final size = 8 + mp4XmpUuid.length + payload.length;
  return <int>[..._u32(size), ..._uuidType, ...mp4XmpUuid, ...payload];
}

/// Marks [file] read-only for the current user.
Future<void> _makeReadOnly(File file) async {
  if (Platform.isWindows) {
    await Process.run('attrib', ['+R', file.path]);
  } else {
    await Process.run('chmod', ['444', file.path]);
  }
}

/// Makes [dir] non-writable, so creating a temporary file inside it fails.
///
/// On Windows the read-only attribute of a directory does not prevent file
/// creation, so the read-only file itself is what blocks the rename there.
Future<void> _makeDirReadOnly(Directory dir) async {
  if (Platform.isWindows) return;
  await Process.run('chmod', ['555', dir.path]);
}

/// Restores write permission on [dir] and everything inside it.
Future<void> _restorePermissions(Directory dir) async {
  if (Platform.isWindows) {
    await Process.run('attrib', ['-R', '${dir.path}\\*', '/S']);
    return;
  }
  await Process.run('chmod', ['-R', 'u+rwX', dir.path]);
}

Future<void> _write(File file, XmpProvenance provenance, Mp4WriteMode mode) {
  switch (mode) {
    case Mp4WriteMode.rewrite:
      return writeMp4XmpToFile(file.path, provenance);
    case Mp4WriteMode.inPlace:
      return appendMp4XmpInPlace(file.path, provenance);
  }
}

/// Grows [path] to [length] bytes without occupying disk blocks where the
/// platform allows it.
Future<void> _extendSparsely(String path, int length) async {
  if (Platform.isWindows) {
    // Marking the file sparse first makes the extension below allocate no
    // clusters; without the flag NTFS would reserve the whole range.
    final flag = await Process.run('fsutil', ['sparse', 'setflag', path]);
    if (flag.exitCode != 0) {
      throw FileSystemException(
        'fsutil sparse setflag failed: ${flag.stderr}',
        path,
      );
    }
  }
  final handle = await File(path).open(mode: FileMode.append);
  try {
    await handle.setPosition(length - 1);
    await handle.writeFrom(const [0]);
    await handle.flush();
  } finally {
    await handle.close();
  }
}

/// Builds an `ftyp` + `mdat` file of exactly [totalBytes] bytes.
///
/// When [sizeZeroMdat] is set the `mdat` header declares `size == 0`, which
/// means "extends to the end of the file".
Future<File> _createSparseMp4(
  Directory dir, {
  required int totalBytes,
  bool sizeZeroMdat = false,
}) async {
  const ftypSize = 24;
  final path = p.join(
    dir.path,
    sizeZeroMdat ? 'sparse-size-zero.mp4' : 'sparse-64bit.mp4',
  );

  final header = BytesBuilder(copy: false)
    ..add(_u32(ftypSize))
    ..add(ascii.encode('ftyp'))
    ..add(ascii.encode('mp42'))
    ..add(_u32(0x200))
    ..add(ascii.encode('mp42'))
    ..add(ascii.encode('isom'));
  if (sizeZeroMdat) {
    header
      ..add(_u32(0))
      ..add(ascii.encode('mdat'));
  } else {
    header
      ..add(_u32(1))
      ..add(ascii.encode('mdat'))
      ..add(_u64(totalBytes - ftypSize));
  }

  final headerBytes = header.toBytes();

  final handle = await File(path).open(mode: FileMode.write);
  try {
    await handle.writeFrom(headerBytes);
    await handle.flush();
  } finally {
    await handle.close();
  }
  await _extendSparsely(path, totalBytes);
  return File(path);
}

void main() {
  group('conformance (SPEC §10)', () {
    for (final name in _embeddedVectors) {
      test('reads $name', () async {
        final expected = loadExpected(name);
        final bytes = await readVector(name);

        final file = vectorFile(name);
        final handle = await file.open();
        final String? textFromFile;
        try {
          textFromFile = await readMp4XmpTextFromFile(handle);
        } finally {
          await handle.close();
        }

        expect(
          textFromFile,
          readMp4XmpText(bytes),
          reason: '$name: bytes and file readers agree',
        );
        expect(
          detectFormat(bytes),
          MediaFormat.mp4,
          reason: '$name: detected as MP4 / MOV',
        );

        if (expected['_none'] == true) {
          expect(textFromFile, isNull, reason: '$name: no provenance metadata');
          expect(readMp4Xmp(bytes), isNull, reason: '$name: no provenance');
        } else {
          expect(textFromFile, isNotNull, reason: '$name: has XMP');
          final provenance = readMp4Xmp(bytes);
          expect(provenance, isNotNull);
          expectJsonMatches(provenance!.toJson(), expected, name);
        }
      });
    }

    test('MetadataService reads every video vector', () async {
      for (final name in _embeddedVectors) {
        final expected = loadExpected(name);
        expect(
          await MetadataService.detectFormat(vectorFile(name).path),
          MediaFormat.mp4,
          reason: name,
        );
        final embedded = await MetadataService.readEmbedded(
          vectorFile(name).path,
        );
        if (expected['_none'] == true) {
          expect(embedded, isNull, reason: name);
        } else {
          expect(embedded, isNotNull, reason: name);
          expectJsonMatches(embedded!.toJson(), expected, name);
        }
      }
    });

    test('local-video.mp4 reads its provenance from the sidecar', () async {
      final expected = loadExpected('local-video.mp4');
      final path = vectorFile('local-video.mp4').path;

      expect(await MetadataService.detectFormat(path), MediaFormat.mp4);
      expect(await MetadataService.readEmbeddedXmp(path), isNull);

      final merged = await MetadataService.readProvenance(path);
      expect(merged, isNotNull);
      expectJsonMatches(merged!.toJson(), expected, 'local-video.mp4');
    });
  });

  group('box scanning', () {
    test('skips boxes by their declared size', () async {
      final boxes = scanMp4Boxes(await readVector('mp4-64bit-box.mp4'));
      expect(boxes.map((box) => box.type).toList(), [
        'ftyp',
        'moov',
        'free',
        'mdat',
        'free',
        'uuid',
      ]);
      final largeFree = boxes[4];
      expect(largeFree.headerSize, 16, reason: '64-bit header');
      expect(largeFree.largeSize, largeFree.declaredSize);
      expect(boxes.last.isXmp, isTrue);
    });

    test('the step-by-step reader visits the same boxes', () async {
      final file = vectorFile('mp4-64bit-box.mp4');
      final handle = await file.open();
      try {
        final reader = Mp4BoxReader(handle);
        final types = <String>[];
        while (!reader.isDone) {
          final box = await reader.next();
          if (box == null) break;
          types.add(box.type);
          expect(reader.offset, box.stop, reason: 'reader advanced by size');
        }
        expect(
          types,
          scanMp4Boxes(
            await readVector('mp4-64bit-box.mp4'),
          ).map((box) => box.type).toList(),
        );
      } finally {
        await handle.close();
      }
    });

    test('a size == 0 box extends to the end of the file', () async {
      final bytes = await readVector('mp4-size-zero-mdat.mp4');
      final boxes = scanMp4Boxes(bytes);
      final last = boxes.last;
      expect(last.extendsToEnd, isTrue);
      expect(last.isTruncated, isFalse);
      expect(last.stop, bytes.length);
    });

    test('a truncated last box is reported, not thrown', () async {
      final bytes = await readVector('mp4-truncated-mdat.mp4');
      final boxes = scanMp4Boxes(bytes);
      expect(boxes.last.type, 'mdat');
      expect(boxes.last.isTruncated, isTrue);
      expect(boxes.last.stop, bytes.length);
      expect(readMp4XmpText(bytes), isNull);
    });

    test('UUID bytes inside mdat are not a top-level box', () async {
      final bytes = await readVector('mp4-mdat-uuid-noise.mp4');
      final boxes = scanMp4Boxes(bytes);

      // The vector carries a fake XMP packet inside mdat and a real top-level
      // XMP box at the end. Only the top-level one may be read.
      expect(boxes.map((box) => box.type).toList(), [
        'ftyp',
        'moov',
        'free',
        'mdat',
        'uuid',
      ]);
      expect(boxes.where((box) => box.isXmp).length, 1);

      final expected = loadExpected('mp4-mdat-uuid-noise.mp4');
      final provenance = readMp4Xmp(bytes);
      expect(provenance, isNotNull);
      expectJsonMatches(provenance!.toJson(), expected, 'noise');
      expect(
        provenance.platform,
        'web',
        reason: 'the top-level block wins, not the fake one in mdat',
      );
    });

    test('the last well-formed XMP box wins', () async {
      final bytes = await readVector('mp4-multiple-xmp.mp4');
      final xmpBoxes = scanMp4Boxes(bytes).where((box) => box.isXmp);
      expect(xmpBoxes.length, 2);
      final expected = loadExpected('mp4-multiple-xmp.mp4');
      expectJsonMatches(readMp4Xmp(bytes)!.toJson(), expected, 'multiple');
    });

    test('isMp4Header rejects non-containers', () {
      expect(isMp4Header(Uint8List(0)), isFalse);
      expect(isMp4Header(Uint8List.fromList(List.filled(16, 0x41))), isFalse);
      expect(
        isMp4Header(Uint8List.fromList([..._u32(24), ...ascii.encode('ftyp')])),
        isTrue,
      );
    });
  });

  group('C2PA (SPEC §4.3)', () {
    test('detects a top-level C2PA uuid box', () async {
      final base = await readVector('mp4-no-xmp.mp4');
      final box = <int>[
        ..._u32(8 + 16 + 4),
        ..._uuidType,
        ...mp4C2paUuid,
        ...ascii.encode('jumb'),
      ];
      final signed = Uint8List.fromList([...base, ...box]);

      expect(detectC2pa(signed, MediaFormat.mp4), C2paStatus.detected);
      expect(detectC2pa(base, MediaFormat.mp4), C2paStatus.none);
    });

    test(
      'MetadataService skips a signed MP4 and leaves it untouched',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'provenance_mp4_c2pa',
        );
        try {
          final base = await readVector('mp4-no-xmp.mp4');
          final signed = Uint8List.fromList([
            ...base,
            ..._u32(8 + 16 + 4),
            ..._uuidType,
            ...mp4C2paUuid,
            ...ascii.encode('jumb'),
          ]);
          final file = File(p.join(dir.path, 'signed.mp4'));
          await file.writeAsBytes(signed, flush: true);

          expect(await MetadataService.hasC2pa(file.path), isTrue);
          final result = await MetadataService.embedProvenance(
            filePath: file.path,
            provenance: _provenance(),
          );
          expect(result.success, isTrue);
          expect(result.skippedC2pa, isTrue);
          expect(await file.readAsBytes(), signed);
        } finally {
          await dir.delete(recursive: true);
        }
      },
    );
  });

  group('writing', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('provenance_mp4_write');
    });
    tearDown(() async {
      internal.debugFailInPlaceAt = null;
      await dir.delete(recursive: true);
    });

    for (final name in _writableVectors) {
      for (final mode in Mp4WriteMode.values) {
        test('$name via ${mode.name}', () async {
          final original = await readVector(name);
          final file = await _copyVector(dir, name);
          final provenance = _provenance();
          final label = '$name/${mode.name}';

          await _write(file, provenance, mode);
          var written = await file.readAsBytes();
          _expectWriteResult(
            original: original,
            written: written,
            label: label,
          );

          final xml = readMp4XmpText(written);
          expect(xml, isNotNull, reason: '$label: readable back');
          if (name == 'mp4-xmp-uuid.mp4') {
            expect(
              xml,
              contains(_foreignValue),
              reason: '$label: foreign field',
            );
            expect(xml, contains('photoshop:Headline'), reason: label);
          }

          final back = readMp4Xmp(written)!;
          final originalProvenance = readMp4Xmp(original);
          if (originalProvenance == null) {
            expect(back.capturedBy, _writer, reason: '$label: written field');
          } else {
            // Capture fields are never overwritten (SPEC §4.6).
            expect(
              back.capturedBy,
              originalProvenance.capturedBy,
              reason: '$label: capture field preserved',
            );
            expect(
              back.assetId,
              originalProvenance.assetId,
              reason: '$label: assetId kept',
            );
          }

          // A second write must retire the previous box, leaving one XMP box.
          await _write(file, provenance, mode);
          written = await file.readAsBytes();
          final boxes = scanMp4Boxes(written);
          expect(
            boxes.where((box) => box.isXmp).length,
            1,
            reason: '$label: still one XMP box after a second write',
          );
          expect(boxes.last.isXmp, isTrue, reason: label);
          expect(boxes.last.stop, written.length, reason: label);
          expect(readMp4Xmp(written), isNotNull, reason: label);
        });
      }
    }

    test('MetadataService.embedProvenance writes MP4 in both modes', () async {
      for (final mode in Mp4WriteMode.values) {
        final file = await _copyVector(dir, 'mp4-no-xmp.mp4');
        final result = await MetadataService.embedProvenance(
          filePath: file.path,
          provenance: _provenance(),
          mp4WriteMode: mode,
        );
        expect(
          result.success,
          isTrue,
          reason: '${mode.name}: ${result.errorMessage}',
        );
        final back = await MetadataService.readProvenance(file.path);
        expect(back?.capturedBy, _writer, reason: mode.name);
      }
    });

    test('an unsupported write leaves the file untouched', () async {
      final notMp4 = File(p.join(dir.path, 'notes.mp4'));
      await notMp4.writeAsBytes(List.filled(64, 0x41), flush: true);
      final before = await notMp4.readAsBytes();

      final result = await MetadataService.embedProvenance(
        filePath: notMp4.path,
        provenance: _provenance(),
      );
      expect(result.success, isFalse);
      expect(result.errorCode, EmbedErrorCode.formatUnsupported);
      expect(await notMp4.readAsBytes(), before);
    });
  });

  group('interrupted append (SPEC §4.7)', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('provenance_mp4_interrupted');
    });
    tearDown(() async {
      internal.debugFailInPlaceAt = null;
      await dir.delete(recursive: true);
    });

    test('the complete old block is still readable', () async {
      final bytes = await readVector('mp4-interrupted-append.mp4');
      final boxes = scanMp4Boxes(bytes);

      expect(boxes.last.isTruncated, isTrue, reason: 'half-written new block');
      expect(boxes.last.isXmp, isTrue, reason: 'it is recognisable as XMP');
      expect(boxes[boxes.length - 2].isXmp, isTrue, reason: 'old block');

      final expected = loadExpected('mp4-interrupted-append.mp4');
      final provenance = readMp4Xmp(bytes);
      expect(provenance, isNotNull, reason: 'the old block is still valid');
      expectJsonMatches(provenance!.toJson(), expected, 'interrupted');

      final path = vectorFile('mp4-interrupted-append.mp4').path;
      expect(
        await MetadataService.readEmbeddedXmp(path),
        isNotNull,
        reason: 'the file reader agrees',
      );
    });

    for (final mode in Mp4WriteMode.values) {
      test('writing over it succeeds via ${mode.name}', () async {
        final original = await readVector('mp4-interrupted-append.mp4');
        final file = await _copyVector(dir, 'mp4-interrupted-append.mp4');

        await _write(file, _provenance(), mode);
        final written = await file.readAsBytes();

        _expectWriteResult(
          original: original,
          written: written,
          label: 'interrupted/${mode.name}',
        );

        // The media data is untouched.
        final before = scanMp4Boxes(original);
        final after = scanMp4Boxes(written);
        final mdatBefore = before.firstWhere((box) => box.type == 'mdat');
        final mdatAfter = after.firstWhere((box) => box.type == 'mdat');
        expect(
          _sameRange(original, written, mdatBefore.start, mdatBefore.stop),
          isTrue,
          reason: '${mode.name}: mdat unchanged',
        );
        expect(
          mdatAfter.stop - mdatAfter.start,
          mdatBefore.stop - mdatBefore.start,
        );

        // The old complete block was retired, not deleted.
        expect(
          after.where((box) => box.type == mp4FreeBoxType).length,
          greaterThanOrEqualTo(1),
          reason: '${mode.name}: old XMP box became free',
        );
        expect(readMp4Xmp(written), isNotNull, reason: mode.name);
      });
    }

    test('a half-written block from a killed process is recovered', () async {
      final original = await readVector('mp4-no-xmp.mp4');
      final file = await _copyVector(dir, 'mp4-no-xmp.mp4');

      // Simulate a process killed mid-append: write half a box and stop, with
      // no rollback and no type patch.
      final half = _encodeXmpBoxForTest(_provenance());
      final handle = await file.open(mode: FileMode.append);
      try {
        await handle.setPosition(original.length);
        await handle.writeFrom(half.sublist(0, half.length ~/ 2));
        await handle.flush();
      } finally {
        await handle.close();
      }

      final damaged = await file.readAsBytes();
      expect(damaged.length, greaterThan(original.length));
      expect(scanMp4Boxes(damaged).last.isTruncated, isTrue);
      expect(readMp4Xmp(damaged), isNull, reason: 'nothing readable yet');

      await appendMp4XmpInPlace(file.path, _provenance());
      final repaired = await file.readAsBytes();

      final boxes = scanMp4Boxes(repaired);
      expect(boxes.where((box) => box.isXmp).length, 1);
      expect(boxes.last.isXmp, isTrue);
      expect(boxes.last.stop, repaired.length);
      expect(readMp4Xmp(repaired), isNotNull);

      // The media data is byte-identical.
      final mdat = scanMp4Boxes(original).firstWhere((b) => b.type == 'mdat');
      expect(_sameRange(original, repaired, mdat.start, mdat.stop), isTrue);
    });

    test('a truncated non-XMP box is still refused', () async {
      final file = await _copyVector(dir, 'mp4-truncated-mdat.mp4');
      final before = await file.readAsBytes();
      await expectLater(
        appendMp4XmpInPlace(file.path, _provenance()),
        throwsA(
          isA<Mp4WriteException>().having(
            (error) => error.code,
            'code',
            Mp4WriteErrorCode.truncatedFile,
          ),
        ),
      );
      expect(await file.readAsBytes(), before);
    });
  });

  group('permission errors', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('provenance_mp4_perm');
    });
    tearDown(() async {
      await _restorePermissions(dir);
      await dir.delete(recursive: true);
    });

    for (final mode in Mp4WriteMode.values) {
      test('a read-only MP4 reports writeFailed via ${mode.name}', () async {
        final file = await _copyVector(dir, 'mp4-no-xmp.mp4');
        final before = await file.readAsBytes();
        await _makeReadOnly(file);
        if (mode == Mp4WriteMode.rewrite) {
          // On POSIX a read-only file can still be replaced by a rename, so
          // the directory has to be read-only too.
          await _makeDirReadOnly(dir);
        }

        final result = await MetadataService.embedProvenance(
          filePath: file.path,
          provenance: _provenance(),
          mp4WriteMode: mode,
        );

        expect(result.success, isFalse, reason: mode.name);
        expect(
          result.errorCode,
          EmbedErrorCode.writeFailed,
          reason: '${mode.name}: a permission error is not a format problem',
        );
        expect(result.isFormatError, isFalse, reason: mode.name);
        expect(result.cause, isNotNull, reason: 'the original error is kept');
        expect(
          result.cause,
          anyOf(isA<FileSystemException>(), isA<FileRewriteException>()),
          reason: '${mode.name}: ${result.cause}',
        );
        expect(
          result.errorMessage,
          contains('Write failed'),
          reason: mode.name,
        );

        await _restorePermissions(dir);
        expect(await file.readAsBytes(), before, reason: 'file untouched');
      });
    }

    test('a read-only JPEG reports writeFailed', () async {
      final file = File(p.join(dir.path, 'photo.jpg'));
      await file.writeAsBytes(minimalJpeg(), flush: true);
      await _makeReadOnly(file);
      await _makeDirReadOnly(dir);

      final result = await MetadataService.embedProvenance(
        filePath: file.path,
        provenance: _provenance(),
      );
      expect(result.errorCode, EmbedErrorCode.writeFailed);
      expect(
        result.cause,
        anyOf(isA<FileSystemException>(), isA<FileRewriteException>()),
      );
    });

    test('a read-only PNG reports writeFailed', () async {
      final file = File(p.join(dir.path, 'image.png'));
      await file.writeAsBytes(minimalPng(), flush: true);
      await _makeReadOnly(file);
      await _makeDirReadOnly(dir);

      final result = await MetadataService.embedProvenance(
        filePath: file.path,
        provenance: _provenance(),
      );
      expect(result.errorCode, EmbedErrorCode.writeFailed);
      expect(
        result.cause,
        anyOf(isA<FileSystemException>(), isA<FileRewriteException>()),
      );
    });

    test('a read-only WebP reports writeFailed', () async {
      final file = File(p.join(dir.path, 'image.webp'));
      await file.writeAsBytes(minimalWebpVp8(), flush: true);
      await _makeReadOnly(file);
      await _makeDirReadOnly(dir);

      final result = await MetadataService.embedProvenance(
        filePath: file.path,
        provenance: _provenance(),
      );
      expect(result.errorCode, EmbedErrorCode.writeFailed);
      expect(
        result.cause,
        anyOf(isA<FileSystemException>(), isA<FileRewriteException>()),
      );
    });
  });

  group('write refusals', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('provenance_mp4_refuse');
    });
    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test('a non-container is refused', () {
      final bytes = Uint8List.fromList(List.filled(64, 0x41));
      expect(
        () => writeMp4Xmp(bytes, _provenance()),
        throwsA(
          isA<Mp4WriteException>().having(
            (error) => error.code,
            'code',
            Mp4WriteErrorCode.notMp4,
          ),
        ),
      );
    });

    for (final name in _truncatedVectors) {
      for (final mode in Mp4WriteMode.values) {
        test('$name is refused via ${mode.name}', () async {
          final file = await _copyVector(dir, name);
          final before = await file.readAsBytes();
          await expectLater(
            _write(file, _provenance(), mode),
            throwsA(
              isA<Mp4WriteException>().having(
                (error) => error.code,
                'code',
                Mp4WriteErrorCode.truncatedFile,
              ),
            ),
          );
          expect(await file.readAsBytes(), before, reason: 'file untouched');
        });
      }
    }

    test('a missing file is refused', () async {
      final path = p.join(dir.path, 'missing.mp4');
      expect(
        () => writeMp4XmpToFile(path, _provenance()),
        throwsA(
          isA<Mp4WriteException>().having(
            (error) => error.code,
            'code',
            Mp4WriteErrorCode.fileNotFound,
          ),
        ),
      );
      expect(
        () => appendMp4XmpInPlace(path, _provenance()),
        throwsA(
          isA<Mp4WriteException>().having(
            (error) => error.code,
            'code',
            Mp4WriteErrorCode.fileNotFound,
          ),
        ),
      );
    });
  });

  group('in-place rollback', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('provenance_mp4_rollback');
    });
    tearDown(() async {
      internal.debugFailInPlaceAt = null;
      await dir.delete(recursive: true);
    });

    for (final point in internal.Mp4WriteFailurePoint.values) {
      for (final name in [
        'mp4-xmp-uuid.mp4',
        'mp4-size-zero-mdat.mp4',
        'mp4-interrupted-append.mp4',
      ]) {
        test('$name rolls back when failing ${point.name}', () async {
          final file = await _copyVector(dir, name);
          final before = await file.readAsBytes();

          internal.debugFailInPlaceAt = point;
          await expectLater(
            appendMp4XmpInPlace(file.path, _provenance()),
            throwsA(isA<FileSystemException>()),
          );
          internal.debugFailInPlaceAt = null;

          expect(
            await file.readAsBytes(),
            before,
            reason: 'the file must be byte-identical after a failed write',
          );
        });
      }
    }

    test('a successful in-place write leaves no rollback residue', () async {
      final file = await _copyVector(dir, 'mp4-xmp-uuid.mp4');
      final original = await file.readAsBytes();
      await appendMp4XmpInPlace(file.path, _provenance());
      final written = await file.readAsBytes();
      expect(written.length, greaterThan(original.length));
      _expectWriteResult(
        original: original,
        written: written,
        label: 'inplace',
      );
    });
  });

  group('large files', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('provenance_mp4_large');
    });
    tearDown(() async {
      await dir.delete(recursive: true);
    });

    /// 5 GiB: above the 32-bit box size limit, so a 64-bit header is required.
    const bigSize = 5 * 1024 * 1024 * 1024;

    test(
      'reads, seeks and appends in a 5 GiB file',
      () async {
        final File file;
        try {
          file = await _createSparseMp4(dir, totalBytes: bigSize);
        } on FileSystemException catch (error) {
          markTestSkipped('cannot create a sparse file here: $error');
          return;
        }

        expect(await file.length(), bigSize);

        final rssBefore = ProcessInfo.currentRss;

        final handle = await file.open();
        final List<Mp4Box> boxes;
        final String? xml;
        try {
          boxes = await scanMp4BoxesFromFile(handle);
          xml = await readMp4XmpTextFromFile(handle);
        } finally {
          await handle.close();
        }

        final rssAfterRead = ProcessInfo.currentRss;

        expect(boxes.map((box) => box.type).toList(), ['ftyp', 'mdat']);
        final mdat = boxes.last;
        expect(mdat.headerSize, 16, reason: '64-bit header');
        expect(mdat.largeSize, bigSize - 24);
        expect(mdat.declaredSize, bigSize - 24);
        expect(mdat.stop, bigSize, reason: 'the walk lands on the file end');
        expect(mdat.isTruncated, isFalse);
        expect(xml, isNull, reason: 'no XMP yet');

        expect(
          rssAfterRead - rssBefore,
          lessThan(128 * 1024 * 1024),
          reason: 'reading must not load the media data',
        );

        await appendMp4XmpInPlace(file.path, _provenance());
        expect(
          ProcessInfo.currentRss - rssBefore,
          lessThan(128 * 1024 * 1024),
          reason: 'writing must not load the media data',
        );

        final afterHandle = await file.open();
        final List<Mp4Box> after;
        final String? afterXml;
        try {
          after = await scanMp4BoxesFromFile(afterHandle);
          afterXml = await readMp4XmpTextFromFile(afterHandle);
        } finally {
          await afterHandle.close();
        }

        expect(after.map((box) => box.type).toList(), ['ftyp', 'mdat', 'uuid']);
        expect(after.last.isXmp, isTrue);
        expect(after.last.stop, await file.length());
        expect(
          after[1].largeSize,
          bigSize - 24,
          reason: 'the 64-bit mdat is untouched',
        );
        expect(afterXml, isNotNull);
        expect(parseXmpXml(afterXml!)!.capturedBy, _writer);
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'refuses a 5 GiB size == 0 box it cannot describe',
      () async {
        final File file;
        try {
          file = await _createSparseMp4(
            dir,
            totalBytes: bigSize,
            sizeZeroMdat: true,
          );
        } on FileSystemException catch (error) {
          markTestSkipped('cannot create a sparse file here: $error');
          return;
        }

        final before = await file.length();
        await expectLater(
          appendMp4XmpInPlace(file.path, _provenance()),
          throwsA(
            isA<Mp4WriteException>().having(
              (error) => error.code,
              'code',
              Mp4WriteErrorCode.requiresLargeSize,
            ),
          ),
        );
        expect(await file.length(), before, reason: 'nothing was written');
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });
}
