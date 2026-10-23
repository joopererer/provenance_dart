// WebP XMP reading and writing (SPEC §4.1, §4.7).
//
// XMP lives in a RIFF chunk with the four-character code `XMP `. Writing it
// requires the extended (`VP8X`) header with the XMP flag set, so a simple
// `VP8 `/`VP8L` file is upgraded on first write.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'file_rewriter.dart';
import 'xmp_core.dart';
import 'xmp_model.dart';

/// The RIFF chunk code that holds XMP.
const String webpXmpFourCc = 'XMP ';

/// The bit in the `VP8X` flags byte that announces an XMP chunk.
const int webpXmpFlag = 0x04;

/// A RIFF chunk, with the offsets needed to rewrite it.
class WebpChunk {
  /// Creates a chunk record.
  const WebpChunk({
    required this.fourCc,
    required this.start,
    required this.stop,
    required this.dataStart,
    required this.dataStop,
  });

  /// The four-character code, for example `XMP `.
  final String fourCc;

  /// Offset of the four-character code.
  final int start;

  /// Offset just past the chunk, including the pad byte.
  final int stop;

  /// Offset of the first data byte.
  final int dataStart;

  /// Offset just past the last data byte, excluding the pad byte.
  final int dataStop;
}

/// Scans the RIFF chunks of [bytes].
List<WebpChunk> scanWebpChunks(Uint8List bytes) {
  if (!_hasWebpHeader(bytes, bytes.length)) {
    throw const FormatException('Not a WebP file');
  }

  final chunks = <WebpChunk>[];
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final fourCc = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = _readU32(bytes, offset + 4);
    final dataStart = offset + 8;
    final dataStop = dataStart + size;
    if (dataStop > bytes.length) break;
    final stop = dataStop + (size.isOdd ? 1 : 0);
    chunks.add(
      WebpChunk(
        fourCc: fourCc,
        start: offset,
        stop: stop > bytes.length ? bytes.length : stop,
        dataStart: dataStart,
        dataStop: dataStop,
      ),
    );
    offset = stop;
  }
  return chunks;
}

/// Scans the RIFF chunks of an open file, reading only the 8-byte headers.
Future<List<WebpChunk>> scanWebpChunksFromFile(RandomAccessFile file) async {
  final length = await file.length();
  await file.setPosition(0);
  final header = await file.read(12);
  if (!_hasWebpHeader(header, length)) {
    throw const FormatException('Not a WebP file');
  }

  final chunks = <WebpChunk>[];
  var offset = 12;
  while (offset + 8 <= length) {
    await file.setPosition(offset);
    final head = await file.read(8);
    if (head.length < 8) break;
    final fourCc = String.fromCharCodes(head.sublist(0, 4));
    final size = _readU32(head, 4);
    final dataStart = offset + 8;
    final dataStop = dataStart + size;
    if (dataStop > length) break;
    final stop = dataStop + (size.isOdd ? 1 : 0);
    chunks.add(
      WebpChunk(
        fourCc: fourCc,
        start: offset,
        stop: stop > length ? length : stop,
        dataStart: dataStart,
        dataStop: dataStop,
      ),
    );
    offset = stop;
  }
  return chunks;
}

/// Reads the provenance record from the XMP chunk of [bytes].
XmpProvenance? readWebpXmp(Uint8List bytes) {
  final text = readWebpXmpText(bytes);
  return text == null ? null : parseXmpXml(text);
}

/// Reads the provenance record from an open file.
Future<XmpProvenance?> readWebpXmpFromFile(RandomAccessFile file) async {
  final text = await readWebpXmpTextFromFile(file);
  return text == null ? null : parseXmpXml(text);
}

/// Returns the raw XMP text of the XMP chunk, or `null`.
String? readWebpXmpText(Uint8List bytes) {
  for (final chunk in scanWebpChunks(bytes)) {
    if (chunk.fourCc != webpXmpFourCc) continue;
    return utf8.decode(
      bytes.sublist(chunk.dataStart, chunk.dataStop),
      allowMalformed: true,
    );
  }
  return null;
}

/// Returns the raw XMP text of the XMP chunk of an open file, or `null`.
Future<String?> readWebpXmpTextFromFile(RandomAccessFile file) async {
  for (final chunk in await scanWebpChunksFromFile(file)) {
    if (chunk.fourCc != webpXmpFourCc) continue;
    await file.setPosition(chunk.dataStart);
    final data = await file.read(chunk.dataStop - chunk.dataStart);
    return utf8.decode(data, allowMalformed: true);
  }
  return null;
}

/// Writes [provenance] into the XMP chunk of [bytes].
///
/// An existing XMP chunk is replaced in place; otherwise one is appended and
/// the `VP8X` header is added or its XMP flag set. The image bitstream is
/// copied unchanged.
Uint8List writeWebpXmp(Uint8List bytes, XmpProvenance provenance) {
  final chunks = scanWebpChunks(bytes);
  final existing = _findXmpChunk(chunks);
  final currentXml = existing == null
      ? null
      : utf8.decode(
          bytes.sublist(existing.dataStart, existing.dataStop),
          allowMalformed: true,
        );
  final regions = _planWrite(
    chunks,
    bytes.length,
    existing,
    currentXml,
    provenance,
    vp8xFlags: _findChunk(chunks, 'VP8X') == null
        ? null
        : bytes[_findChunk(chunks, 'VP8X')!.dataStart],
    dimensions: _findChunk(chunks, 'VP8X') == null
        ? _readDimensions(
            chunks,
            (offset, length) => bytes.sublist(offset, offset + length),
          )
        : null,
  );
  return _applyRegions(bytes, regions);
}

/// Writes [provenance] into the XMP chunk of the file at [path].
///
/// The file is rewritten through a temporary file, so a failure leaves the
/// original untouched. Set [preserveModificationTime] to keep the original
/// timestamp.
Future<void> writeWebpXmpToFile(
  String path,
  XmpProvenance provenance, {
  bool preserveModificationTime = false,
}) async {
  final file = await File(path).open();
  late final List<FileRegion> regions;
  try {
    final length = await file.length();
    final chunks = await scanWebpChunksFromFile(file);
    final existing = _findXmpChunk(chunks);
    String? currentXml;
    if (existing != null) {
      await file.setPosition(existing.dataStart);
      final data = await file.read(existing.dataStop - existing.dataStart);
      currentXml = utf8.decode(data, allowMalformed: true);
    }

    final vp8x = _findChunk(chunks, 'VP8X');
    int? vp8xFlags;
    (int, int)? dimensions;
    if (vp8x != null) {
      await file.setPosition(vp8x.dataStart);
      vp8xFlags = (await file.read(1))[0];
    } else {
      dimensions = await _readDimensionsFromFile(file, chunks);
    }

    regions = _planWrite(
      chunks,
      length,
      existing,
      currentXml,
      provenance,
      vp8xFlags: vp8xFlags,
      dimensions: dimensions,
    );
  } finally {
    await file.close();
  }

  await rewriteFile(
    path,
    regions,
    preserveModificationTime: preserveModificationTime,
  );
}

Future<(int, int)> _readDimensionsFromFile(
  RandomAccessFile file,
  List<WebpChunk> chunks,
) async {
  final vp8 = _findChunk(chunks, 'VP8 ');
  if (vp8 != null) {
    await file.setPosition(vp8.dataStart);
    final data = await file.read(10);
    if (data.length < 10) {
      throw const FormatException('VP8 chunk too short');
    }
    return (
      data[6] | ((data[7] & 0x3F) << 8),
      data[8] | ((data[9] & 0x3F) << 8),
    );
  }

  final vp8l = _findChunk(chunks, 'VP8L');
  if (vp8l != null) {
    await file.setPosition(vp8l.dataStart);
    final data = await file.read(5);
    if (data.length < 5 || data[0] != 0x2F) {
      throw const FormatException('Invalid VP8L bitstream');
    }
    final bits = data[1] | (data[2] << 8) | (data[3] << 16) | (data[4] << 24);
    return ((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1);
  }

  throw const FormatException('WebP file has no VP8 or VP8L chunk');
}

List<FileRegion> _planWrite(
  List<WebpChunk> chunks,
  int fileLength,
  WebpChunk? existing,
  String? currentXml,
  XmpProvenance provenance, {
  required int? vp8xFlags,
  required (int, int)? dimensions,
}) {
  final xml = currentXml == null
      ? buildXmpXml(provenance)
      : updateXmpXml(currentXml, provenance);
  final xmpChunk = _encodeChunk(webpXmpFourCc, utf8.encode(xml));

  final regions = <FileRegion>[];
  if (existing != null) {
    regions.add(FileRegion(existing.start, existing.stop, xmpChunk));
  } else {
    regions.add(FileRegion(fileLength, fileLength, xmpChunk));
  }

  final vp8x = _findChunk(chunks, 'VP8X');
  if (vp8x != null) {
    regions.add(
      FileRegion(vp8x.dataStart, vp8x.dataStart + 1, [
        vp8xFlags! | webpXmpFlag,
      ]),
    );
  } else {
    regions.add(FileRegion(12, 12, _encodeVp8x(dimensions!.$1, dimensions.$2)));
  }

  var newLength = fileLength;
  for (final region in regions) {
    newLength += region.replacement.length - (region.stop - region.start);
  }
  regions.add(FileRegion(4, 8, _u32(newLength - 8)));

  return regions;
}

Uint8List _applyRegions(Uint8List bytes, List<FileRegion> regions) {
  final sorted = [...regions]..sort((a, b) => a.start.compareTo(b.start));
  final builder = BytesBuilder(copy: false);
  var position = 0;
  for (final region in sorted) {
    if (region.start > position) {
      builder.add(bytes.sublist(position, region.start));
    }
    builder.add(region.replacement);
    position = region.stop;
  }
  if (position < bytes.length) builder.add(bytes.sublist(position));
  return builder.toBytes();
}

WebpChunk? _findXmpChunk(List<WebpChunk> chunks) =>
    _findChunk(chunks, webpXmpFourCc);

WebpChunk? _findChunk(List<WebpChunk> chunks, String fourCc) {
  for (final chunk in chunks) {
    if (chunk.fourCc == fourCc) return chunk;
  }
  return null;
}

(int, int) _readDimensions(
  List<WebpChunk> chunks,
  Uint8List Function(int offset, int length) read,
) {
  final vp8 = _findChunk(chunks, 'VP8 ');
  if (vp8 != null) {
    final data = read(vp8.dataStart, 10);
    if (data.length < 10) {
      throw const FormatException('VP8 chunk too short');
    }
    final width = data[6] | ((data[7] & 0x3F) << 8);
    final height = data[8] | ((data[9] & 0x3F) << 8);
    return (width, height);
  }

  final vp8l = _findChunk(chunks, 'VP8L');
  if (vp8l != null) {
    final data = read(vp8l.dataStart, 5);
    if (data.length < 5 || data[0] != 0x2F) {
      throw const FormatException('Invalid VP8L bitstream');
    }
    final bits = data[1] | (data[2] << 8) | (data[3] << 16) | (data[4] << 24);
    return ((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1);
  }

  throw const FormatException('WebP file has no VP8 or VP8L chunk');
}

List<int> _encodeVp8x(int width, int height) {
  final data = <int>[
    webpXmpFlag,
    0, 0, 0, // reserved
    (width - 1) & 0xFF, ((width - 1) >> 8) & 0xFF, ((width - 1) >> 16) & 0xFF,
    (height - 1) & 0xFF,
    ((height - 1) >> 8) & 0xFF,
    ((height - 1) >> 16) & 0xFF,
  ];
  return _encodeChunk('VP8X', data);
}

List<int> _encodeChunk(String fourCc, List<int> data) {
  final result = <int>[...utf8.encode(fourCc), ..._u32(data.length), ...data];
  // RIFF chunks are padded to an even length; the pad byte is not counted in
  // the chunk size (SPEC §4.7 write requirement 3).
  if (data.length.isOdd) result.add(0);
  return result;
}

List<int> _u32(int value) => [
  value & 0xFF,
  (value >> 8) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 24) & 0xFF,
];

int _readU32(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

bool _hasWebpHeader(Uint8List bytes, int length) =>
    length >= 12 &&
    bytes.length >= 12 &&
    bytes[0] == 0x52 &&
    bytes[1] == 0x49 &&
    bytes[2] == 0x46 &&
    bytes[3] == 0x46 &&
    bytes[8] == 0x57 &&
    bytes[9] == 0x45 &&
    bytes[10] == 0x42 &&
    bytes[11] == 0x50;
