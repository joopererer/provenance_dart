// Atomic file rewriting (SPEC §4.6: a failed metadata write must not affect
// the file itself).
//
// The writer must go through a temporary file in the same directory, flush it,
// and rename it over the original. Every failure short of the rename must leave
// the original bytes and the directory unchanged.

import 'dart:io';
import 'dart:typed_data';

import 'package:provenance_dart/provenance_dart.dart';
import 'package:provenance_dart/src/file_rewriter.dart'
    show debugFailAfterBytes, debugTempPathFor;
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// A byte payload large enough to be copied in several 64 KiB chunks.
Uint8List _payload(int length) =>
    Uint8List.fromList(List.generate(length, (i) => i & 0xFF));

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('provenance_atomic_');
  });

  tearDown(() async {
    debugFailAfterBytes = null;
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  /// Every entry in [dir], so a test can assert that nothing was left behind.
  Future<List<String>> entries() async {
    final names = await dir
        .list()
        .map((e) => e.path.split(Platform.pathSeparator).last)
        .toList();
    names.sort();
    return names;
  }

  group('rewriteFile', () {
    test('replaces a region and copies the rest verbatim', () async {
      final path = '${dir.path}/data.bin';
      final original = _payload(300);
      await File(path).writeAsBytes(original);

      await rewriteFile(path, [
        FileRegion(10, 20, [1, 2, 3]),
      ]);

      final result = await File(path).readAsBytes();
      expect(result.length, 293);
      expect(result.sublist(0, 10), original.sublist(0, 10));
      expect(result.sublist(10, 13), [1, 2, 3]);
      expect(result.sublist(13), original.sublist(20));
    });

    test('an empty region inserts its bytes', () async {
      final path = '${dir.path}/data.bin';
      await File(path).writeAsBytes([1, 2, 3, 4]);

      await rewriteFile(path, [
        FileRegion(2, 2, [9, 9]),
      ]);

      expect(await File(path).readAsBytes(), [1, 2, 9, 9, 3, 4]);
    });

    test('several regions are applied in offset order', () async {
      final path = '${dir.path}/data.bin';
      await File(path).writeAsBytes(_payload(100));

      await rewriteFile(path, [
        FileRegion(50, 60, [0xAA]),
        FileRegion(10, 20, [0xBB]),
      ]);

      final result = await File(path).readAsBytes();
      expect(result.length, 82);
      expect(result[10], 0xBB);
      // Everything from 11 on is the original data, shifted by the shrinkage.
      expect(result[11], 0x14);
      expect(result[41], 0xAA);
      expect(result[42], 0x3C);
    });

    test('the temporary file is created next to the target, not in the '
        'current directory', () async {
      final path = '${dir.path}/data.bin';
      await File(path).writeAsBytes(_payload(10));

      // The temp path must be inside the same directory, so the rename stays
      // inside one file system and is atomic.
      final temp = debugTempPathFor(path);
      expect(File(temp).parent.path, dir.path);

      await rewriteFile(path, [
        FileRegion(0, 1, [0xFF]),
      ]);
      expect(await File(temp).exists(), isFalse);
    });

    test('leaves no temporary file behind on success', () async {
      final path = '${dir.path}/data.bin';
      await File(path).writeAsBytes(_payload(10));

      await rewriteFile(path, [
        FileRegion(0, 1, [0xFF]),
      ]);

      expect(await entries(), ['data.bin']);
    });

    test('a failure mid-copy leaves the original untouched and removes the '
        'temporary file', () async {
      final path = '${dir.path}/data.bin';
      final original = _payload(400 * 1024);
      await File(path).writeAsBytes(original);

      // Fail after roughly 1.5 copy buffers, that is in the middle of the file.
      debugFailAfterBytes = 96 * 1024;

      await expectLater(
        rewriteFile(path, [
          FileRegion(10, 20, [1, 2, 3]),
        ]),
        throwsA(isA<FileRewriteException>()),
      );

      expect(
        await File(path).readAsBytes(),
        original,
        reason: 'the original file must keep its exact bytes',
      );
      expect(await entries(), ['data.bin']);
    });

    test('a failure while writing the replacement itself also leaves the '
        'original untouched', () async {
      final path = '${dir.path}/data.bin';
      final original = _payload(1000);
      await File(path).writeAsBytes(original);

      debugFailAfterBytes = 1;

      await expectLater(
        rewriteFile(path, [FileRegion(0, 0, _payload(200))]),
        throwsA(isA<FileRewriteException>()),
      );

      expect(await File(path).readAsBytes(), original);
      expect(await entries(), ['data.bin']);
    });

    test(
      'a missing source file throws without creating a temporary file',
      () async {
        final path = '${dir.path}/absent.bin';

        await expectLater(
          rewriteFile(path, [
            FileRegion(0, 1, [0]),
          ]),
          throwsA(isA<FileRewriteException>()),
        );

        expect(await entries(), isEmpty);
      },
    );

    test('a stale temporary file from an earlier crash is replaced', () async {
      final path = '${dir.path}/data.bin';
      await File(path).writeAsBytes(_payload(10));
      await File(debugTempPathFor(path)).writeAsBytes([0xDE, 0xAD]);

      await rewriteFile(path, [
        FileRegion(0, 1, [0xFF]),
      ]);

      expect(await entries(), ['data.bin']);
      expect((await File(path).readAsBytes())[0], 0xFF);
    });

    test('a failed write keeps the original modification time', () async {
      final path = '${dir.path}/data.bin';
      await File(path).writeAsBytes(_payload(400 * 1024));
      final before = (await File(path).stat()).modified;
      await File(
        path,
      ).setLastModified(DateTime.now().subtract(const Duration(hours: 2)));
      final original = (await File(path).stat()).modified;
      expect(original.isBefore(before), isTrue);

      debugFailAfterBytes = 96 * 1024;
      await expectLater(
        rewriteFile(path, [
          FileRegion(0, 1, [0xFF]),
        ]),
        throwsA(isA<FileRewriteException>()),
      );

      expect((await File(path).stat()).modified, original);
    });
  });

  group('preserveModificationTime', () {
    test('is off by default, so the file looks freshly modified', () async {
      final path = '${dir.path}/data.bin';
      await File(path).writeAsBytes(_payload(10));
      final old = DateTime.now().subtract(const Duration(days: 3));
      await File(path).setLastModified(old);

      await rewriteFile(path, [
        FileRegion(0, 1, [0xFF]),
      ]);

      final modified = (await File(path).stat()).modified;
      expect(modified.isAfter(old.add(const Duration(days: 1))), isTrue);
    });

    test('keeps the original timestamp when requested', () async {
      final path = '${dir.path}/data.bin';
      await File(path).writeAsBytes(_payload(10));
      final old = DateTime.now().subtract(const Duration(days: 3));
      await File(path).setLastModified(old);

      await rewriteFile(path, [
        FileRegion(0, 1, [0xFF]),
      ], preserveModificationTime: true);

      final modified = (await File(path).stat()).modified;
      expect(modified.difference(old).inSeconds.abs(), lessThan(2));
    });

    test('an embedded write can keep the file timestamp', () async {
      final path = '${dir.path}/image.jpg';
      await File(path).writeAsBytes(minimalJpeg());
      final old = DateTime.now().subtract(const Duration(days: 5));
      await File(path).setLastModified(old);

      final result = await MetadataService.embedProvenance(
        filePath: path,
        provenance: sampleProvenance(),
        preserveModificationTime: true,
      );

      expect(result.success, isTrue);
      final modified = (await File(path).stat()).modified;
      expect(modified.difference(old).inSeconds.abs(), lessThan(2));
      // The metadata was really written.
      expect(readJpegXmp(await File(path).readAsBytes()), isNotNull);
    });

    test('a sidecar write can keep the file timestamp', () async {
      final sidecar = File('${dir.path}/video.mp4.xmp');
      await sidecar.writeAsString('placeholder');
      final old = DateTime.now().subtract(const Duration(days: 5));
      await sidecar.setLastModified(old);

      await MetadataService.writeSidecar(
        '${dir.path}/video.mp4',
        sampleProvenance(),
        preserveModificationTime: true,
      );

      expect(
        (await sidecar.stat()).modified.difference(old).inSeconds.abs(),
        lessThan(2),
      );
      expect(await sidecar.readAsString(), contains('prov:assetId'));
    });
  });

  group('writeFileAtomically', () {
    test('creates the file when it does not exist', () async {
      final path = '${dir.path}/new.txt';
      await writeFileAtomically(path, [104, 105]);
      expect(await File(path).readAsBytes(), [104, 105]);
      expect(await entries(), ['new.txt']);
    });

    test('replaces an existing file', () async {
      final path = '${dir.path}/new.txt';
      await File(path).writeAsString('old');
      await writeFileAtomically(path, [110, 101, 119]);
      expect(await File(path).readAsString(), 'new');
      expect(await entries(), ['new.txt']);
    });

    test('a failure leaves an existing file untouched', () async {
      final path = '${dir.path}/new.txt';
      await File(path).writeAsString('original');

      debugFailAfterBytes = 1;
      await expectLater(
        writeFileAtomically(path, List.filled(64, 120)),
        throwsA(isA<FileRewriteException>()),
      );

      expect(await File(path).readAsString(), 'original');
      expect(await entries(), ['new.txt']);
    });

    test('a failure does not create the file when there was none', () async {
      final path = '${dir.path}/new.txt';

      debugFailAfterBytes = 1;
      await expectLater(
        writeFileAtomically(path, List.filled(64, 120)),
        throwsA(isA<FileRewriteException>()),
      );

      expect(await entries(), isEmpty);
    });
  });

  group('sidecar writes', () {
    test('a failed sidecar write leaves the existing sidecar intact', () async {
      final path = '${dir.path}/photo.jpg';
      await File(path).writeAsBytes(minimalJpeg());
      await MetadataService.writeSidecar(
        path,
        XmpProvenance.fromJson(sampleProvenance().toJson()),
      );
      final sidecar = File('$path.xmp');
      final original = await sidecar.readAsString();

      debugFailAfterBytes = 1;
      await expectLater(
        MetadataService.writeSidecar(path, _titledProvenance('new')),
        throwsA(isA<FileRewriteException>()),
      );

      expect(await sidecar.readAsString(), original);
      expect(await entries(), ['photo.jpg', 'photo.jpg.xmp']);
    });

    test(
      'a failed embedded write leaves the image intact and readable',
      () async {
        final path = '${dir.path}/image.jpg';
        final original = minimalJpeg();
        await File(path).writeAsBytes(original);

        debugFailAfterBytes = 1;
        final result = await MetadataService.embedProvenance(
          filePath: path,
          provenance: sampleProvenance(),
        );

        expect(result.success, isFalse);
        expect(result.errorCode, EmbedErrorCode.writeFailed);
        expect(await File(path).readAsBytes(), original);
        expect(await entries(), ['image.jpg']);
      },
    );
  });
}

/// `sampleProvenance` with a different title, for the sidecar-failure test.
XmpProvenance _titledProvenance(String? title) => XmpProvenance(
  schema: '0.1',
  assetId: '3f0c6a2e-8d4b-4c1a-9a3e-2b7f5d9e1c40',
  capturedAt: DateTime.utc(2026, 10, 20, 13, 30),
  capturedBy: 'TestApp/1.0.0',
  metadataDate: DateTime.utc(2026, 10, 20, 13, 30),
  title: title ?? 'wow～ 好干净的奶白色',
);
