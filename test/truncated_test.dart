// Truncated-container handling (SPEC §1 principle 5, "readers are forgiving").
//
// A file can be cut short at any byte: a download was interrupted, a disk was
// full, or a tool wrote a chunk without its trailing CRC. Reading such a file
// must never throw an uncaught exception; it either returns the metadata that
// is still complete or reports "no readable provenance" (`null`).

import 'dart:io';
import 'dart:typed_data';

import 'package:provenance_dart/provenance_dart.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// A PNG whose last chunk is the XMP iTXt chunk, including its CRC.
///
/// `writePngXmp` inserts the chunk before IEND, so dropping the 12-byte IEND
/// chunk leaves the XMP chunk at the end of the file, where truncation is easy
/// to simulate.
Uint8List _pngEndingWithXmp() {
  final withIend = writePngXmp(minimalPng(), sampleProvenance());
  return Uint8List.fromList(withIend.sublist(0, withIend.length - 12));
}

void main() {
  group('PNG truncated chunks', () {
    test('a complete chunk is read normally', () {
      final bytes = _pngEndingWithXmp();
      final chunk = scanPngChunks(bytes).last;

      expect(chunk.type, 'iTXt');
      expect(chunk.stop, bytes.length);
      expect(chunk.dataStop, bytes.length - 4); // the CRC is present
      expect(readPngXmp(bytes)!.assetId, sampleProvenance().assetId);
    });

    test('a chunk without its CRC keeps every data byte', () {
      final complete = _pngEndingWithXmp();
      final bytes = Uint8List.fromList(
        complete.sublist(0, complete.length - 4),
      );
      final chunk = scanPngChunks(bytes).last;

      expect(chunk.type, 'iTXt');
      expect(chunk.stop, bytes.length);
      // Regression: this used to be bytes.length - 4, which deleted the last
      // four bytes of the XML and made the package unparsable.
      expect(chunk.dataStop, bytes.length);

      final record = readPngXmp(bytes);
      expect(record, isNotNull);
      expect(record!.assetId, sampleProvenance().assetId);
      expect(record.title, sampleProvenance().title);
    });

    test('a chunk cut in half reports no readable provenance', () {
      final complete = _pngEndingWithXmp();
      final full = scanPngChunks(complete).last;
      final dataLength = full.dataStop - full.dataStart;
      final bytes = Uint8List.fromList(
        complete.sublist(0, full.dataStart + dataLength ~/ 2),
      );
      final chunk = scanPngChunks(bytes).last;

      expect(chunk.type, 'iTXt');
      expect(chunk.dataStop, bytes.length);
      expect(chunk.dataStop, lessThan(full.dataStop));

      expect(() => readPngXmp(bytes), returnsNormally);
      expect(readPngXmp(bytes), isNull);
    });

    test('the file scanner treats a missing CRC the same way', () async {
      final dir = await Directory.systemTemp.createTemp('provenance_trunc_');
      try {
        final complete = _pngEndingWithXmp();
        final file = File('${dir.path}/no-crc.png');
        await file.writeAsBytes(
          complete.sublist(0, complete.length - 4),
          flush: true,
        );

        final handle = await file.open();
        try {
          final chunks = await scanPngChunksFromFile(handle);
          expect(chunks.last.type, 'iTXt');
          expect(chunks.last.dataStop, await file.length());
          expect(
            (await readPngXmpFromFile(handle))!.assetId,
            sampleProvenance().assetId,
          );
        } finally {
          await handle.close();
        }
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('the file scanner returns null for a half-written chunk', () async {
      final dir = await Directory.systemTemp.createTemp('provenance_trunc_');
      try {
        final complete = _pngEndingWithXmp();
        final full = scanPngChunks(complete).last;
        final dataLength = full.dataStop - full.dataStart;
        final file = File('${dir.path}/half.png');
        await file.writeAsBytes(
          complete.sublist(0, full.dataStart + dataLength ~/ 2),
          flush: true,
        );

        final handle = await file.open();
        try {
          expect(await readPngXmpFromFile(handle), isNull);
        } finally {
          await handle.close();
        }
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('JPEG truncated segments', () {
    test('a segment cut in half is skipped, not decoded', () {
      final complete = writeJpegXmp(minimalJpeg(), sampleProvenance());
      final xmp = scanJpegSegments(
        complete,
      ).firstWhere((segment) => segment.marker == 0xE1);
      final bytes = Uint8List.fromList(
        complete.sublist(0, xmp.payloadStart + 10),
      );

      // JPEG has no CRC, so there is no "deduct four bytes" assumption: the
      // incomplete segment is simply not reported.
      expect(
        scanJpegSegments(bytes).where((segment) => segment.marker == 0xE1),
        isEmpty,
      );
      expect(() => readJpegXmp(bytes), returnsNormally);
      expect(readJpegXmp(bytes), isNull);
    });
  });

  group('WebP truncated chunks', () {
    test('a chunk cut in half is skipped, not decoded', () {
      final complete = writeWebpXmp(minimalWebpExtended(), sampleProvenance());
      final xmp = scanWebpChunks(
        complete,
      ).firstWhere((chunk) => chunk.fourCc == webpXmpFourCc);
      final dataLength = xmp.dataStop - xmp.dataStart;
      final bytes = Uint8List.fromList(
        complete.sublist(0, xmp.dataStart + dataLength ~/ 2),
      );

      // WebP has no CRC either; the incomplete chunk is not reported.
      expect(
        scanWebpChunks(bytes).where((chunk) => chunk.fourCc == webpXmpFourCc),
        isEmpty,
      );
      expect(() => readWebpXmp(bytes), returnsNormally);
      expect(readWebpXmp(bytes), isNull);
    });
  });

  group('spec version', () {
    test('provenanceSpecVersion names the implemented spec release', () {
      expect(provenanceSpecVersion, '0.1.7');
    });
  });
}
