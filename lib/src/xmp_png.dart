// PNG XMP reading and writing (SPEC §4.1, §4.7).
//
// XMP lives in an iTXt chunk with the keyword `XML:com.adobe.xmp`, stored
// uncompressed.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'file_rewriter.dart';
import 'xmp_core.dart';
import 'xmp_model.dart';

/// The iTXt keyword that marks the XMP chunk.
const String pngXmpKeyword = 'XML:com.adobe.xmp';

const List<int> _pngSignature = [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
];

/// A PNG chunk, with the offsets needed to rewrite it.
class PngChunk {
  /// Creates a chunk record.
  const PngChunk({
    required this.type,
    required this.start,
    required this.stop,
    required this.dataStart,
    required this.dataStop,
  });

  /// The four-character chunk type, for example `iTXt`.
  final String type;

  /// Offset of the length field.
  final int start;

  /// Offset just past the CRC.
  final int stop;

  /// Offset of the first data byte.
  final int dataStart;

  /// Offset just past the last data byte.
  final int dataStop;
}

/// Scans the chunks of [bytes] up to and including IEND.
///
/// A final chunk whose declared length runs past the end of [bytes] is still
/// reported, with [PngChunk.stop] clamped to the end of the buffer. Its
/// [PngChunk.dataStop] is the end of the declared data, or the end of the
/// buffer when the data itself is truncated: a truncated file normally has no
/// CRC at all, so no bytes are deducted for one.
List<PngChunk> scanPngChunks(Uint8List bytes) {
  if (bytes.length < 8 || !_hasPngSignature(bytes, 0)) {
    throw const FormatException('Not a PNG file');
  }

  final chunks = <PngChunk>[];
  var offset = 8;
  while (offset + 12 <= bytes.length) {
    final length = _readU32(bytes, offset);
    final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
    final stop = offset + 12 + length;
    if (stop > bytes.length) {
      chunks.add(
        PngChunk(
          type: type,
          start: offset,
          stop: bytes.length,
          dataStart: offset + 8,
          dataStop: _min(offset + 8 + length, bytes.length),
        ),
      );
      break;
    }
    chunks.add(
      PngChunk(
        type: type,
        start: offset,
        stop: stop,
        dataStart: offset + 8,
        dataStop: offset + 8 + length,
      ),
    );
    offset = stop;
    if (type == 'IEND') break;
  }
  return chunks;
}

/// Scans the chunks of an open file, reading only the 8-byte chunk headers.
///
/// Chunk payloads are skipped with a seek, so neither pixel data nor large
/// ancillary chunks are ever read into memory. A final truncated chunk is
/// reported the same way as in [scanPngChunks].
Future<List<PngChunk>> scanPngChunksFromFile(RandomAccessFile file) async {
  final length = await file.length();
  await file.setPosition(0);
  final signature = await file.read(8);
  if (signature.length < 8 || !_hasPngSignature(signature, 0)) {
    throw const FormatException('Not a PNG file');
  }

  final chunks = <PngChunk>[];
  var offset = 8;
  while (offset + 12 <= length) {
    await file.setPosition(offset);
    final head = await file.read(8);
    if (head.length < 8) break;
    final dataLength = _readU32(head, 0);
    final type = String.fromCharCodes(head.sublist(4, 8));
    final stop = offset + 12 + dataLength;
    if (stop > length) {
      chunks.add(
        PngChunk(
          type: type,
          start: offset,
          stop: length,
          dataStart: offset + 8,
          dataStop: _min(offset + 8 + dataLength, length),
        ),
      );
      break;
    }
    chunks.add(
      PngChunk(
        type: type,
        start: offset,
        stop: stop,
        dataStart: offset + 8,
        dataStop: offset + 8 + dataLength,
      ),
    );
    offset = stop;
    if (type == 'IEND') break;
  }
  return chunks;
}

/// Reads the provenance record from the XMP iTXt chunk of [bytes].
///
/// Returns `null` when there is no XMP chunk, when the package carries no
/// provenance fields, or when a truncated file leaves the XML unparsable.
XmpProvenance? readPngXmp(Uint8List bytes) {
  final text = readPngXmpText(bytes);
  return text == null ? null : _tryParseXmp(text);
}

/// Reads the provenance record from an open file.
///
/// Only chunk headers and the XMP chunk payload are read. Returns `null` when
/// the chunk is missing or truncated past the point where the XML can be
/// parsed.
Future<XmpProvenance?> readPngXmpFromFile(RandomAccessFile file) async {
  final text = await readPngXmpTextFromFile(file);
  return text == null ? null : _tryParseXmp(text);
}

/// Returns the raw XMP text of the XMP iTXt chunk, or `null`.
String? readPngXmpText(Uint8List bytes) {
  for (final chunk in scanPngChunks(bytes)) {
    if (chunk.type != 'iTXt') continue;
    final text = _decodeItxtData(
      bytes.sublist(chunk.dataStart, chunk.dataStop),
    );
    if (text != null) return text;
  }
  return null;
}

/// Returns the raw XMP text of the XMP iTXt chunk of an open file, or `null`.
Future<String?> readPngXmpTextFromFile(RandomAccessFile file) async {
  for (final chunk in await scanPngChunksFromFile(file)) {
    if (chunk.type != 'iTXt') continue;
    await file.setPosition(chunk.dataStart);
    final data = await file.read(chunk.dataStop - chunk.dataStart);
    final text = _decodeItxtData(data);
    if (text != null) return text;
  }
  return null;
}

/// Writes [provenance] into the XMP iTXt chunk of [bytes].
///
/// An existing XMP chunk is replaced in place; otherwise a new chunk is
/// inserted before IEND. All other chunks are copied unchanged.
Uint8List writePngXmp(Uint8List bytes, XmpProvenance provenance) {
  final chunks = scanPngChunks(bytes);
  final existing = _findXmpChunk(bytes, chunks);
  final currentXml = existing == null
      ? null
      : _decodeItxtData(bytes.sublist(existing.dataStart, existing.dataStop));
  final plan = _planWrite(chunks, existing, currentXml, provenance);

  return (BytesBuilder(copy: false)
        ..add(bytes.sublist(0, plan.start))
        ..add(plan.chunk)
        ..add(bytes.sublist(plan.stop)))
      .toBytes();
}

/// Writes [provenance] into the XMP iTXt chunk of the file at [path].
///
/// The file is rewritten through a temporary file, so a failure leaves the
/// original untouched. Set [preserveModificationTime] to keep the original
/// timestamp.
Future<void> writePngXmpToFile(
  String path,
  XmpProvenance provenance, {
  bool preserveModificationTime = false,
}) async {
  final file = await File(path).open();
  late final _WritePlan plan;
  try {
    final chunks = await scanPngChunksFromFile(file);
    PngChunk? existing;
    String? currentXml;
    for (final chunk in chunks) {
      if (chunk.type != 'iTXt') continue;
      await file.setPosition(chunk.dataStart);
      final data = await file.read(chunk.dataStop - chunk.dataStart);
      final text = _decodeItxtData(data);
      if (text != null) {
        existing = chunk;
        currentXml = text;
        break;
      }
    }
    plan = _planWrite(chunks, existing, currentXml, provenance);
  } finally {
    await file.close();
  }

  await rewriteFile(path, [
    FileRegion(plan.start, plan.stop, plan.chunk),
  ], preserveModificationTime: preserveModificationTime);
}

class _WritePlan {
  const _WritePlan(this.start, this.stop, this.chunk);

  final int start;
  final int stop;
  final List<int> chunk;
}

_WritePlan _planWrite(
  List<PngChunk> chunks,
  PngChunk? existing,
  String? currentXml,
  XmpProvenance provenance,
) {
  final xml = currentXml == null
      ? buildXmpXml(provenance)
      : updateXmpXml(currentXml, provenance);

  final data = <int>[
    ...utf8.encode(pngXmpKeyword),
    0, // keyword terminator
    0, // compression flag: uncompressed
    0, // compression method
    0, // language tag terminator
    0, // translated keyword terminator
    ...utf8.encode(xml),
  ];
  final chunk = _encodeChunk('iTXt', data);

  if (existing != null) return _WritePlan(existing.start, existing.stop, chunk);

  var insertAt = chunks.isEmpty ? 8 : chunks.last.stop;
  for (final candidate in chunks) {
    if (candidate.type == 'IEND') {
      insertAt = candidate.start;
      break;
    }
  }
  return _WritePlan(insertAt, insertAt, chunk);
}

PngChunk? _findXmpChunk(Uint8List bytes, List<PngChunk> chunks) {
  for (final chunk in chunks) {
    if (chunk.type != 'iTXt') continue;
    final text = _decodeItxtData(
      bytes.sublist(chunk.dataStart, chunk.dataStop),
    );
    if (text != null) return chunk;
  }
  return null;
}

List<int> _encodeChunk(String type, List<int> data) {
  final typeBytes = utf8.encode(type);
  final crc = crc32([...typeBytes, ...data]);
  return [
    (data.length >> 24) & 0xFF,
    (data.length >> 16) & 0xFF,
    (data.length >> 8) & 0xFF,
    data.length & 0xFF,
    ...typeBytes,
    ...data,
    (crc >> 24) & 0xFF,
    (crc >> 16) & 0xFF,
    (crc >> 8) & 0xFF,
    crc & 0xFF,
  ];
}

/// Extracts the text of an iTXt chunk when it holds XMP, or `null`.
String? _decodeItxtData(Uint8List data) {
  final keywordEnd = data.indexOf(0);
  if (keywordEnd <= 0) return null;
  final keyword = utf8.decode(
    data.sublist(0, keywordEnd),
    allowMalformed: true,
  );
  if (keyword != pngXmpKeyword) return null;

  var pos = keywordEnd + 1;
  if (pos + 1 >= data.length) return null;
  final compressionFlag = data[pos];
  pos += 2; // compression flag and compression method

  // The language tag and the translated keyword are both null terminated.
  for (var i = 0; i < 2; i++) {
    while (pos < data.length && data[pos] != 0) {
      pos++;
    }
    pos++;
  }
  if (pos > data.length) return null;

  // XMP must be uncompressed (SPEC §4.1).
  if (compressionFlag != 0) return null;
  return utf8.decode(data.sublist(pos), allowMalformed: true);
}

/// Parses an embedded package, treating truncated or otherwise malformed XML
/// as "no readable provenance" instead of throwing.
XmpProvenance? _tryParseXmp(String text) {
  try {
    return parseXmpXml(text);
  } on FormatException {
    return null;
  }
}

int _min(int a, int b) => a < b ? a : b;

bool _hasPngSignature(Uint8List bytes, int offset) {
  for (var i = 0; i < _pngSignature.length; i++) {
    if (bytes[offset + i] != _pngSignature[i]) return false;
  }
  return true;
}

int _readU32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

/// CRC-32 as used by PNG chunks.
int crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc = _crc32Table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFF;
}

const List<int> _crc32Table = [
  0x00000000,
  0x77073096,
  0xEE0E612C,
  0x990951BA,
  0x076DC419,
  0x706AF48F,
  0xE963A535,
  0x9E6495A3,
  0x0EDB8832,
  0x79DCB8A4,
  0xE0D5E91E,
  0x97D2D988,
  0x09B64C2B,
  0x7EB17CBD,
  0xE7B82D07,
  0x90BF1D91,
  0x1DB71064,
  0x6AB020F2,
  0xF3B97148,
  0x84BE41DE,
  0x1ADAD47D,
  0x6DDDE4EB,
  0xF4D4B551,
  0x83D385C7,
  0x136C9856,
  0x646BA8C0,
  0xFD62F97A,
  0x8A65C9EC,
  0x14015C4F,
  0x63066CD9,
  0xFA0F3D63,
  0x8D080DF5,
  0x3B6E20C8,
  0x4C69105E,
  0xD56041E4,
  0xA2677172,
  0x3C03E4D1,
  0x4B04D447,
  0xD20D85FD,
  0xA50AB56B,
  0x35B5A8FA,
  0x42B2986C,
  0xDBBBC9D6,
  0xACBCF940,
  0x32D86CE3,
  0x45DF5C75,
  0xDCD60DCF,
  0xABD13D59,
  0x26D930AC,
  0x51DE003A,
  0xC8D75180,
  0xBFD06116,
  0x21B4F4B5,
  0x56B3C423,
  0xCFBA9599,
  0xB8BDA50F,
  0x2802B89E,
  0x5F058808,
  0xC60CD9B2,
  0xB10BE924,
  0x2F6F7C87,
  0x58684C11,
  0xC1611DAB,
  0xB6662D3D,
  0x76DC4190,
  0x01DB7106,
  0x98D220BC,
  0xEFD5102A,
  0x71B18589,
  0x06B6B51F,
  0x9FBFE4A5,
  0xE8B8D433,
  0x7807C9A2,
  0x0F00F934,
  0x9609A88E,
  0xE10E9818,
  0x7F6A0DBB,
  0x086D3D2D,
  0x91646C97,
  0xE6635C01,
  0x6B6B51F4,
  0x1C6C6162,
  0x856530D8,
  0xF262004E,
  0x6C0695ED,
  0x1B01A57B,
  0x8208F4C1,
  0xF50FC457,
  0x65B0D9C6,
  0x12B7E950,
  0x8BBEB8EA,
  0xFCB9887C,
  0x62DD1DDF,
  0x15DA2D49,
  0x8CD37CF3,
  0xFBD44C65,
  0x4DB26158,
  0x3AB551CE,
  0xA3BC0074,
  0xD4BB30E2,
  0x4ADFA541,
  0x3DD895D7,
  0xA4D1C46D,
  0xD3D6F4FB,
  0x4369E96A,
  0x346ED9FC,
  0xAD678846,
  0xDA60B8D0,
  0x44042D73,
  0x33031DE5,
  0xAA0A4C5F,
  0xDD0D7CC9,
  0x5005713C,
  0x270241AA,
  0xBE0B1010,
  0xC90C2086,
  0x5768B525,
  0x206F85B3,
  0xB966D409,
  0xCE61E49F,
  0x5EDEF90E,
  0x29D9C998,
  0xB0D09822,
  0xC7D7A8B4,
  0x59B33D17,
  0x2EB40D81,
  0xB7BD5C3B,
  0xC0BA6CAD,
  0xEDB88320,
  0x9ABFB3B6,
  0x03B6E20C,
  0x74B1D29A,
  0xEAD54739,
  0x9DD277AF,
  0x04DB2615,
  0x73DC1683,
  0xE3630B12,
  0x94643B84,
  0x0D6D6A3E,
  0x7A6A5AA8,
  0xE40ECF0B,
  0x9309FF9D,
  0x0A00AE27,
  0x7D079EB1,
  0xF00F9344,
  0x8708A3D2,
  0x1E01F268,
  0x6906C2FE,
  0xF762575D,
  0x806567CB,
  0x196C3671,
  0x6E6B06E7,
  0xFED41B76,
  0x89D32BE0,
  0x10DA7A5A,
  0x67DD4ACC,
  0xF9B9DF6F,
  0x8EBEEFF9,
  0x17B7BE43,
  0x60B08ED5,
  0xD6D6A3E8,
  0xA1D1937E,
  0x38D8C2C4,
  0x4FDFF252,
  0xD1BB67F1,
  0xA6BC5767,
  0x3FB506DD,
  0x48B2364B,
  0xD80D2BDA,
  0xAF0A1B4C,
  0x36034AF6,
  0x41047A60,
  0xDF60EFC3,
  0xA867DF55,
  0x316E8EEF,
  0x4669BE79,
  0xCB61B38C,
  0xBC66831A,
  0x256FD2A0,
  0x5268E236,
  0xCC0C7795,
  0xBB0B4703,
  0x220216B9,
  0x5505262F,
  0xC5BA3BBE,
  0xB2BD0B28,
  0x2BB45A92,
  0x5CB36A04,
  0xC2D7FFA7,
  0xB5D0CF31,
  0x2CD99E8B,
  0x5BDEAE1D,
  0x9B64C2B0,
  0xEC63F226,
  0x756AA39C,
  0x026D930A,
  0x9C0906A9,
  0xEB0E363F,
  0x72076785,
  0x05005713,
  0x95BF4A82,
  0xE2B87A14,
  0x7BB12BAE,
  0x0CB61B38,
  0x92D28E9B,
  0xE5D5BE0D,
  0x7CDCEFB7,
  0x0BDBDF21,
  0x86D3D2D4,
  0xF1D4E242,
  0x68DDB3F8,
  0x1FDA836E,
  0x81BE16CD,
  0xF6B9265B,
  0x6FB077E1,
  0x18B74777,
  0x88085AE6,
  0xFF0F6A70,
  0x66063BCA,
  0x11010B5C,
  0x8F659EFF,
  0xF862AE69,
  0x616BFFD3,
  0x166CCF45,
  0xA00AE278,
  0xD70DD2EE,
  0x4E048354,
  0x3903B3C2,
  0xA7672661,
  0xD06016F7,
  0x4969474D,
  0x3E6E77DB,
  0xAED16A4A,
  0xD9D65ADC,
  0x40DF0B66,
  0x37D83BF0,
  0xA9BCAE53,
  0xDEBB9EC5,
  0x47B2CF7F,
  0x30B5FFE9,
  0xBDBDF21C,
  0xCABAC28A,
  0x53B39330,
  0x24B4A3A6,
  0xBAD03605,
  0xCDD70693,
  0x54DE5729,
  0x23D967BF,
  0xB3667A2E,
  0xC4614AB8,
  0x5D681B02,
  0x2A6F2B94,
  0xB40BBE37,
  0xC30C8EA1,
  0x5A05DF1B,
  0x2D02EF8D,
];
