// MP4 / MOV XMP reading and writing (SPEC §4.1, §4.3, §4.7).
//
// XMP lives in a **top-level** `uuid` box whose 16-byte extended type is
// BE7ACFCB-97A9-42E8-9C71-999491E3AFAC, followed directly by the XMP packet
// with no extra header.
//
// Reading walks the top-level box chain only, jumping over each box by its
// declared size, so `mdat` is never read and the work does not depend on the
// size of the video. Writing appends one new XMP box at the end of the file
// and retires every old XMP box by changing only its 4-byte box type to
// `free`; the media data is never re-encoded.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'file_rewriter.dart';
import 'xmp_core.dart';
import 'xmp_model.dart';

/// The 16-byte extended type of an XMP box in MP4 / MOV (SPEC §4.1).
///
/// `BE7ACFCB-97A9-42E8-9C71-999491E3AFAC`.
final Uint8List mp4XmpUuid = Uint8List.fromList(const [
  0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8, //
  0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC,
]);

/// The 16-byte extended type of a C2PA provenance box in MP4 / MOV
/// (SPEC §4.3).
///
/// `D8FEC3D6-1B0E-483C-9297-5828877EC481`.
final Uint8List mp4C2paUuid = Uint8List.fromList(const [
  0xD8, 0xFE, 0xC3, 0xD6, 0x1B, 0x0E, 0x48, 0x3C, //
  0x92, 0x97, 0x58, 0x28, 0x87, 0x7E, 0xC4, 0x81,
]);

/// The box type that replaces the type of a retired XMP box (SPEC §4.7).
const String mp4FreeBoxType = 'free';

/// The largest XMP payload read from an MP4 / MOV box.
///
/// A box that claims a larger payload is skipped instead of being loaded into
/// memory, so a corrupt size field cannot exhaust memory.
const int maxMp4XmpBytes = 16 * 1024 * 1024;

/// Box types that may legally start an MP4 / MOV file.
///
/// Used to keep [detectFormat] from mistaking unrelated data for a container.
const Set<String> _knownTopLevelTypes = {
  'ftyp',
  'styp',
  'moov',
  'mdat',
  'free',
  'skip',
  'wide',
  'junk',
  'pnot',
  'sidx',
  'moof',
  'mfra',
  'meta',
  'uuid',
  'udta',
};

/// How [MetadataService.embedProvenance] writes XMP into an MP4 / MOV file.
enum Mp4WriteMode {
  /// Replace the file through a temporary file plus a rename.
  ///
  /// Atomic: a failure at any point leaves the original bytes untouched, and
  /// no temporary file remains. It copies the whole file, so it is meant for
  /// files in an application's private directory.
  rewrite,

  /// Append the new XMP box in place with a [RandomAccessFile].
  ///
  /// No temporary file is created and the file is never loaded into memory, so
  /// this is the mode for large videos in a shared gallery directory. A
  /// failure truncates the file back to its original length and restores every
  /// byte it changed; see [appendMp4XmpInPlace].
  inPlace,
}

/// Why an MP4 / MOV write was refused.
enum Mp4WriteErrorCode {
  /// The file does not exist.
  fileNotFound,

  /// The file does not start with a valid top-level box.
  notMp4,

  /// The last top-level box runs past the end of the file.
  ///
  /// Either the file was truncated during a download or copy, or it ends with
  /// bytes that are not a complete box. Writing would make the damage worse,
  /// so the caller should use a sidecar instead (SPEC §4.2).
  truncatedFile,

  /// The last box has `size == 0` and is larger than 4 GiB.
  ///
  /// A zero size means "this box extends to the end of the file". Making that
  /// explicit would require a 64-bit header, which needs 8 extra bytes in the
  /// middle of the file; in-place writing cannot do that. The file must be
  /// rewritten or handled with a sidecar.
  requiresLargeSize,
}

/// Thrown when an MP4 / MOV file cannot be written safely.
class Mp4WriteException implements Exception {
  /// Creates an exception.
  const Mp4WriteException(this.code, this.message, [this.path]);

  /// The machine-readable reason.
  final Mp4WriteErrorCode code;

  /// A human readable message.
  final String message;

  /// The file being written, if the failure came from a file API.
  final String? path;

  @override
  String toString() => path == null
      ? 'Mp4WriteException(${code.name}): $message'
      : 'Mp4WriteException(${code.name}): $message ($path)';
}

/// Test hook: when set, the in-place writer fails at this step.
///
/// It exists so the rollback guarantee can be tested without a real I/O
/// failure. It is not re-exported from `package:provenance_dart`, so production
/// code cannot reach it by accident; tests import this library directly.
Mp4WriteFailurePoint? debugFailInPlaceAt;

/// A point at which [debugFailInPlaceAt] can force the in-place writer to fail.
enum Mp4WriteFailurePoint {
  /// Half of the new XMP box has been written.
  duringAppend,

  /// The new box is complete, but no old box has been retired yet.
  beforeTypePatch,

  /// Every old XMP box has been marked `free`.
  afterTypePatch,
}

/// A top-level box of an MP4 / MOV file.
class Mp4Box {
  /// Creates a box record.
  const Mp4Box({
    required this.type,
    required this.typeBytes,
    required this.start,
    required this.stop,
    required this.headerSize,
    required this.dataStart,
    required this.dataStop,
    required this.declaredSize,
    required this.largeSize,
    required this.extendsToEnd,
    required this.isTruncated,
    this.uuid,
  });

  /// The four-character box type, for example `moov`.
  final String type;

  /// The four type bytes exactly as they appear in the file.
  ///
  /// Keeping them lets the writer restore a box type byte for byte if a write
  /// has to be rolled back.
  final Uint8List typeBytes;

  /// Offset of the size field.
  final int start;

  /// Offset just past the box, clamped to the end of the available data.
  final int stop;

  /// Length of the box header: 8 bytes, or 16 when `size == 1`.
  final int headerSize;

  /// Offset of the first payload byte.
  final int dataStart;

  /// Offset just past the last payload byte, clamped to the available data.
  final int dataStop;

  /// The size the box declares: its 32-bit size, its `largesize`, or the
  /// distance to the end of the file when `size == 0`.
  final int declaredSize;

  /// The 64-bit `largesize`, when `size == 1`; otherwise `null`.
  final int? largeSize;

  /// Whether the box uses `size == 0`, which means it extends to the end.
  final bool extendsToEnd;

  /// Whether the box runs past the end of the available data.
  final bool isTruncated;

  /// For a `uuid` box, its 16-byte extended type, when it is present.
  final Uint8List? uuid;

  /// Offset of the four type bytes.
  int get typeOffset => start + 4;

  /// Whether this is a `uuid` box.
  bool get isUuid => type == 'uuid';

  /// Whether this is the XMP `uuid` box.
  bool get isXmp => isUuid && uuid != null && _bytesEqual(uuid!, mp4XmpUuid);

  /// Whether this box carries C2PA content credentials (SPEC §4.3).
  bool get isC2pa =>
      type == 'c2pa' ||
      (isUuid && uuid != null && _bytesEqual(uuid!, mp4C2paUuid));

  /// The number of payload bytes actually available.
  int get payloadLength => dataStop - dataStart;
}

/// Whether [bytes] starts with a plausible MP4 / MOV top-level box.
///
/// The check is deliberately shallow: a valid size field and a known
/// four-character box type. It is used by [detectFormat] to recognise the
/// container without reading the whole file.
bool isMp4Header(Uint8List bytes) {
  if (bytes.length < 8) return false;
  final size = _readU32(bytes, 0);
  if (size != 0 && size != 1 && size < 8) return false;
  for (var i = 4; i < 8; i++) {
    final byte = bytes[i];
    if (byte < 0x20 || byte > 0x7E) return false;
  }
  final type = String.fromCharCodes(bytes.sublist(4, 8));
  return _knownTopLevelTypes.contains(type);
}

/// Reads the top-level boxes of [bytes] in order.
///
/// The walk jumps over each box by its declared size, so the payload of a
/// large `mdat` is never touched. A truncated last box, a box with an invalid
/// size, or a box header that is itself cut short ends the walk; a truncated
/// box is reported with [Mp4Box.isTruncated] set so a writer can refuse it.
List<Mp4Box> scanMp4Boxes(Uint8List bytes) {
  final boxes = <Mp4Box>[];
  var offset = 0;
  while (offset + 8 <= bytes.length) {
    final box = _parseBox(bytes, offset);
    if (box == null) break;
    boxes.add(box);
    if (box.isTruncated) break;
    offset = box.stop;
  }
  return boxes;
}

/// Reads the top-level boxes of an open file, one box header at a time.
///
/// Only box headers and the 16-byte extended type of a `uuid` box are read;
/// payloads are skipped with a seek. The number of reads and the bytes read
/// therefore depend on the number of top-level boxes, not on the size of the
/// video, and `mdat` is never read.
Future<List<Mp4Box>> scanMp4BoxesFromFile(RandomAccessFile file) async {
  final boxes = <Mp4Box>[];
  final reader = Mp4BoxReader(file);
  while (true) {
    final box = await reader.next();
    if (box == null) break;
    boxes.add(box);
    if (box.isTruncated) break;
  }
  return boxes;
}

/// Walks the top-level boxes of an open file, one box at a time.
///
/// Each call reads a single header (at most 32 bytes, to cover a 64-bit header
/// plus a `uuid` extended type) and leaves the file position at the end of
/// that header. Payloads are never read, so a caller can decide per box
/// whether to read it or skip it. This is the primitive to mirror in a native
/// (Kotlin / Rust) implementation.
class Mp4BoxReader {
  /// Creates a reader positioned at the start of [file].
  Mp4BoxReader(this._file);

  final RandomAccessFile _file;
  int _offset = 0;
  bool _done = false;

  /// The offset of the next box header.
  int get offset => _offset;

  /// Whether the end of the file or a malformed header has been reached.
  bool get isDone => _done;

  /// Reads the next top-level box, or `null` at the end of the file.
  Future<Mp4Box?> next() async {
    if (_done) return null;
    final box = await _parseBoxFromFile(_file, _offset);
    if (box == null) {
      _done = true;
      return null;
    }
    if (box.isTruncated) {
      _done = true;
    } else {
      _offset = box.stop;
    }
    return box;
  }
}

/// Reads the provenance record from the XMP boxes of [bytes].
///
/// When several XMP boxes exist the last one whose XML is well-formed wins
/// (SPEC §4.7). A truncated or malformed package is reported as `null`, never
/// thrown.
XmpProvenance? readMp4Xmp(Uint8List bytes) {
  final text = readMp4XmpText(bytes);
  return text == null ? null : parseXmpXml(text);
}

/// Reads the provenance record from an open file.
///
/// Only box headers and XMP payloads are read.
Future<XmpProvenance?> readMp4XmpFromFile(RandomAccessFile file) async {
  final text = await readMp4XmpTextFromFile(file);
  return text == null ? null : parseXmpXml(text);
}

/// Returns the raw XMP text of the last well-formed XMP box, or `null`.
String? readMp4XmpText(Uint8List bytes) {
  String? last;
  for (final box in scanMp4Boxes(bytes)) {
    if (!box.isXmp) continue;
    final length = box.payloadLength;
    if (length <= 0 || length > maxMp4XmpBytes) continue;
    final text = utf8.decode(
      bytes.sublist(box.dataStart, box.dataStop),
      allowMalformed: true,
    );
    if (_isWellFormed(text)) last = text;
  }
  return last;
}

/// Returns the raw XMP text of the last well-formed XMP box of an open file.
Future<String?> readMp4XmpTextFromFile(RandomAccessFile file) async {
  final boxes = await scanMp4BoxesFromFile(file);
  String? last;
  for (final box in boxes) {
    if (!box.isXmp) continue;
    final length = box.payloadLength;
    if (length <= 0 || length > maxMp4XmpBytes) continue;
    await file.setPosition(box.dataStart);
    final data = await file.read(length);
    final text = utf8.decode(data, allowMalformed: true);
    if (_isWellFormed(text)) last = text;
  }
  return last;
}

/// Writes [provenance] into [bytes] and returns the new file bytes.
///
/// An existing XMP package is edited in place, so foreign fields survive
/// (SPEC §4.7). The new XMP box is appended at the end and every old XMP box
/// becomes `free`. The media data is copied byte for byte.
///
/// This copies the whole file into memory; for a video use
/// [writeMp4XmpToFile] or [appendMp4XmpInPlace] instead.
Uint8List writeMp4Xmp(Uint8List bytes, XmpProvenance provenance) {
  final boxes = scanMp4Boxes(bytes);
  final currentXml = _currentXml(bytes, boxes);
  final xml = currentXml == null
      ? buildXmpXml(provenance)
      : updateXmpXml(currentXml, provenance);
  final plan = _planWrite(boxes, bytes.length, xml);

  final output = Uint8List(plan.appendAt + plan.newBox.length);
  output.setRange(0, plan.appendAt, bytes);
  output.setRange(plan.appendAt, output.length, plan.newBox);

  if (plan.sizeZeroBox != null) {
    _writeU32(output, plan.sizeZeroBox!.start, plan.materializedSize!);
  }
  for (final box in plan.oldXmpBoxes) {
    output.setRange(box.typeOffset, box.typeOffset + 4, _freeBytes);
  }
  return output;
}

/// Writes [provenance] into the MP4 / MOV file at [path] by replacing it.
///
/// The result is streamed into a temporary file in the same directory,
/// flushed, and renamed over the original, so a failure leaves the original
/// bytes untouched. Only box headers are read while planning; the media data
/// is copied through a fixed buffer.
///
/// Throws [Mp4WriteException] when the file must not be written (see
/// [Mp4WriteErrorCode]) and [FileRewriteException] when the replacement
/// itself fails.
///
/// Set [preserveModificationTime] to keep the original timestamp.
Future<void> writeMp4XmpToFile(
  String path,
  XmpProvenance provenance, {
  bool preserveModificationTime = false,
}) async {
  final file = File(path);
  if (!await file.exists()) {
    throw Mp4WriteException(
      Mp4WriteErrorCode.fileNotFound,
      'File does not exist',
      path,
    );
  }

  late final _Mp4WritePlan plan;
  late final int length;
  final handle = await file.open();
  try {
    length = await handle.length();
    final boxes = await scanMp4BoxesFromFile(handle);
    final currentXml = await _currentXmlFromFile(handle, boxes);
    final xml = currentXml == null
        ? buildXmpXml(provenance)
        : updateXmpXml(currentXml, provenance);
    plan = _planWrite(boxes, length, xml, path: path);
  } finally {
    await handle.close();
  }

  final regions = <FileRegion>[];
  if (plan.sizeZeroBox != null) {
    regions.add(
      FileRegion(
        plan.sizeZeroBox!.start,
        plan.sizeZeroBox!.start + 4,
        _u32(plan.materializedSize!),
      ),
    );
  }
  for (final box in plan.oldXmpBoxes) {
    regions.add(FileRegion(box.typeOffset, box.typeOffset + 4, _freeBytes));
  }
  // Replacing `[appendAt, length)` with the new box both appends it and drops
  // an incomplete XMP box left behind by an interrupted append.
  regions.add(FileRegion(plan.appendAt, length, plan.newBox));

  await rewriteFile(
    path,
    regions,
    preserveModificationTime: preserveModificationTime,
  );
}

/// Writes [provenance] into the MP4 / MOV file at [path] in place.
///
/// The order is chosen so that an interruption cannot lose data:
///
/// 1. a last box with `size == 0` has its real size written first, because
///    otherwise the appended box would fall inside it;
/// 2. the new XMP box is appended at the end of the file and flushed;
/// 3. only then is the type of every old XMP box changed to `free`.
///
/// If any step fails, the file is truncated back to its original length and
/// every byte that was changed is restored, so the file is left exactly as it
/// was. No temporary file is created and the file is never loaded into memory.
///
/// Throws [Mp4WriteException] when the file must not be written. In
/// particular, a truncated file is refused and a `size == 0` last box larger
/// than 4 GiB cannot be made explicit in place
/// ([Mp4WriteErrorCode.requiresLargeSize]).
///
/// The caller is responsible for the C2PA check (SPEC §4.3); use
/// [MetadataService.hasC2pa] first.
Future<void> appendMp4XmpInPlace(
  String path,
  XmpProvenance provenance, {
  bool preserveModificationTime = false,
}) async {
  final file = File(path);
  final stat = await file.stat();
  if (stat.type == FileSystemEntityType.notFound) {
    throw Mp4WriteException(
      Mp4WriteErrorCode.fileNotFound,
      'File does not exist',
      path,
    );
  }

  // FileMode.append is read/write without truncation; the initial position is
  // the end of the file, but positioned writes are still honoured.
  final handle = await file.open(mode: FileMode.append);
  final originalLength = await handle.length();
  _Mp4WritePlan? plan;
  var sizeZeroPatched = false;
  var tailTruncated = false;
  final patchedTypes = <Mp4Box>[];

  try {
    final boxes = await scanMp4BoxesFromFile(handle);
    final currentXml = await _currentXmlFromFile(handle, boxes);
    final xml = currentXml == null
        ? buildXmpXml(provenance)
        : updateXmpXml(currentXml, provenance);
    plan = _planWrite(boxes, originalLength, xml, path: path);

    // Keep the bytes of an incomplete trailing XMP box, so a failure can put
    // them back exactly.
    if (plan.truncateFrom != null) {
      await handle.setPosition(plan.truncateFrom!);
      plan = plan.withSavedTail(
        await handle.read(originalLength - plan.truncateFrom!),
      );
    }

    final failurePoint = debugFailInPlaceAt;

    // 1. Make an open-ended last box explicit before writing past it.
    if (plan.sizeZeroBox != null) {
      await handle.setPosition(plan.sizeZeroBox!.start);
      await handle.writeFrom(_u32(plan.materializedSize!));
      sizeZeroPatched = true;
    }

    // 2. Drop an incomplete XMP box left behind by an interrupted append.
    if (plan.truncateFrom != null) {
      await handle.truncate(plan.truncateFrom!);
      tailTruncated = true;
    }

    // 3. Append the new box.
    await handle.setPosition(plan.appendAt);
    if (failurePoint == Mp4WriteFailurePoint.duringAppend) {
      await handle.writeFrom(plan.newBox.sublist(0, plan.newBox.length ~/ 2));
      throw const FileSystemException('Simulated in-place write failure');
    }
    await handle.writeFrom(plan.newBox);
    await handle.flush();

    if (failurePoint == Mp4WriteFailurePoint.beforeTypePatch) {
      throw const FileSystemException('Simulated in-place write failure');
    }

    // 4. Retire the old boxes.
    for (final box in plan.oldXmpBoxes) {
      await handle.setPosition(box.typeOffset);
      await handle.writeFrom(_freeBytes);
      patchedTypes.add(box);
    }
    await handle.flush();

    if (failurePoint == Mp4WriteFailurePoint.afterTypePatch) {
      throw const FileSystemException('Simulated in-place write failure');
    }
  } catch (error) {
    await _rollBack(
      handle,
      originalLength: originalLength,
      plan: plan,
      sizeZeroPatched: sizeZeroPatched,
      tailTruncated: tailTruncated,
      patchedTypes: patchedTypes,
    );
    rethrow;
  } finally {
    await handle.close();
  }

  if (preserveModificationTime) {
    try {
      await file.setLastModified(stat.modified);
    } on FileSystemException {
      // Best effort: a lost timestamp must not fail the write.
    }
  }
}

Future<void> _rollBack(
  RandomAccessFile handle, {
  required int originalLength,
  required _Mp4WritePlan? plan,
  required bool sizeZeroPatched,
  required bool tailTruncated,
  required List<Mp4Box> patchedTypes,
}) async {
  try {
    await handle.truncate(originalLength);
    if (tailTruncated && plan?.savedTail != null) {
      await handle.setPosition(plan!.truncateFrom!);
      await handle.writeFrom(plan.savedTail!);
    }
    for (final box in patchedTypes) {
      await handle.setPosition(box.typeOffset);
      await handle.writeFrom(box.typeBytes);
    }
    if (sizeZeroPatched && plan?.sizeZeroBox != null) {
      await handle.setPosition(plan!.sizeZeroBox!.start);
      await handle.writeFrom(_u32(0));
    }
    await handle.flush();
  } on FileSystemException {
    // Best effort: the original error is more useful to the caller.
  }
}

class _Mp4WritePlan {
  const _Mp4WritePlan({
    required this.newBox,
    required this.appendAt,
    required this.oldXmpBoxes,
    required this.sizeZeroBox,
    required this.materializedSize,
    required this.truncateFrom,
    required this.savedTail,
  });

  final List<int> newBox;
  final int appendAt;
  final List<Mp4Box> oldXmpBoxes;
  final Mp4Box? sizeZeroBox;
  final int? materializedSize;

  /// Offset from which the file must be truncated before the new box is
  /// written, when an interrupted append left an incomplete XMP box behind.
  final int? truncateFrom;

  /// The bytes of `[truncateFrom, originalLength)`, kept so a failed write can
  /// restore them exactly.
  final Uint8List? savedTail;

  /// Returns a copy of this plan with [savedTail] filled in.
  _Mp4WritePlan withSavedTail(Uint8List tail) => _Mp4WritePlan(
    newBox: newBox,
    appendAt: appendAt,
    oldXmpBoxes: oldXmpBoxes,
    sizeZeroBox: sizeZeroBox,
    materializedSize: materializedSize,
    truncateFrom: truncateFrom,
    savedTail: tail,
  );
}

_Mp4WritePlan _planWrite(
  List<Mp4Box> boxes,
  int length,
  String xml, {
  String? path,
}) {
  if (boxes.isEmpty || !_knownTopLevelTypes.contains(boxes.first.type)) {
    throw Mp4WriteException(
      Mp4WriteErrorCode.notMp4,
      'File does not start with an MP4 / MOV box',
      path,
    );
  }
  final last = boxes.last;

  // An interrupted append leaves an incomplete XMP box at the end. SPEC §4.7
  // allows truncating it away and writing normally; any other truncation is
  // still refused, because a box appended after unreachable bytes could never
  // be found by a conformant reader.
  int? truncateFrom;
  if (last.isTruncated) {
    final available = length - last.start;
    if (last.isXmp && available >= 24 && available <= maxMp4XmpBytes) {
      truncateFrom = last.start;
    } else {
      throw Mp4WriteException(
        Mp4WriteErrorCode.truncatedFile,
        'The last top-level box is incomplete and is not a recoverable '
        'XMP box',
        path,
      );
    }
  } else if (last.stop != length) {
    throw Mp4WriteException(
      Mp4WriteErrorCode.truncatedFile,
      'The last top-level box does not end at the end of the file',
      path,
    );
  }

  Mp4Box? sizeZero;
  int? materialized;
  if (truncateFrom == null && last.extendsToEnd) {
    final actual = length - last.start;
    if (actual > 0xFFFFFFFF) {
      throw Mp4WriteException(
        Mp4WriteErrorCode.requiresLargeSize,
        'The last box has size 0 and is larger than 4 GiB; '
        'its length cannot be written in place',
        path,
      );
    }
    sizeZero = last;
    materialized = actual;
  }

  return _Mp4WritePlan(
    newBox: _encodeXmpBox(xml),
    appendAt: truncateFrom ?? length,
    oldXmpBoxes: boxes
        .where((box) => box.isXmp && box.start != truncateFrom)
        .toList(growable: false),
    sizeZeroBox: sizeZero,
    materializedSize: materialized,
    truncateFrom: truncateFrom,
    savedTail: null,
  );
}

String? _currentXml(Uint8List bytes, List<Mp4Box> boxes) {
  String? last;
  for (final box in boxes) {
    if (!box.isXmp) continue;
    final length = box.payloadLength;
    if (length <= 0 || length > maxMp4XmpBytes) continue;
    final text = utf8.decode(
      bytes.sublist(box.dataStart, box.dataStop),
      allowMalformed: true,
    );
    if (_isWellFormed(text)) last = text;
  }
  return last;
}

Future<String?> _currentXmlFromFile(
  RandomAccessFile file,
  List<Mp4Box> boxes,
) async {
  String? last;
  for (final box in boxes) {
    if (!box.isXmp) continue;
    final length = box.payloadLength;
    if (length <= 0 || length > maxMp4XmpBytes) continue;
    await file.setPosition(box.dataStart);
    final data = await file.read(length);
    final text = utf8.decode(data, allowMalformed: true);
    if (_isWellFormed(text)) last = text;
  }
  return last;
}

/// Parses the box header at [offset], or `null` when it is unusable.
Mp4Box? _parseBox(Uint8List bytes, int offset) {
  final available = bytes.length;
  if (offset + 8 > available) return null;

  final size = _readU32(bytes, offset);
  final typeBytes = Uint8List.fromList(bytes.sublist(offset + 4, offset + 8));
  final type = String.fromCharCodes(typeBytes);

  var headerSize = 8;
  int? largeSize;
  var extendsToEnd = false;
  int declaredSize;

  if (size == 1) {
    if (offset + 16 > available) return null;
    largeSize = _readU64(bytes, offset + 8);
    if (largeSize < 16) return null;
    headerSize = 16;
    declaredSize = largeSize;
  } else if (size == 0) {
    extendsToEnd = true;
    declaredSize = available - offset;
  } else if (size < 8) {
    return null;
  } else {
    declaredSize = size;
  }

  final end = offset + declaredSize;
  final truncated = end > available;
  final stop = truncated ? available : end;
  final dataStart = offset + headerSize;
  final dataStop = truncated ? available : end;

  Uint8List? uuid;
  if (type == 'uuid' && dataStart + 16 <= stop) {
    uuid = Uint8List.fromList(bytes.sublist(dataStart, dataStart + 16));
  }

  return Mp4Box(
    type: type,
    typeBytes: typeBytes,
    start: offset,
    stop: stop,
    headerSize: headerSize,
    dataStart: dataStart,
    dataStop: dataStop,
    declaredSize: declaredSize,
    largeSize: largeSize,
    extendsToEnd: extendsToEnd,
    isTruncated: truncated,
    uuid: uuid,
  );
}

/// Parses the box header at [offset] of [file], or `null` when it is unusable.
Future<Mp4Box?> _parseBoxFromFile(RandomAccessFile file, int offset) async {
  final available = await file.length();
  if (offset + 8 > available) return null;

  await file.setPosition(offset);
  final head = await file.read(32);
  if (head.length < 8) return null;

  final size = _readU32(head, 0);
  final typeBytes = Uint8List.fromList(head.sublist(4, 8));
  final type = String.fromCharCodes(typeBytes);

  var headerSize = 8;
  int? largeSize;
  var extendsToEnd = false;
  int declaredSize;

  if (size == 1) {
    if (offset + 16 > available) return null;
    if (head.length < 16) {
      await file.setPosition(offset + 8);
      final extended = await file.read(8);
      if (extended.length < 8) return null;
      largeSize = _readU64(extended, 0);
    } else {
      largeSize = _readU64(head, 8);
    }
    if (largeSize < 16) return null;
    headerSize = 16;
    declaredSize = largeSize;
  } else if (size == 0) {
    extendsToEnd = true;
    declaredSize = available - offset;
  } else if (size < 8) {
    return null;
  } else {
    declaredSize = size;
  }

  final end = offset + declaredSize;
  final truncated = end > available;
  final stop = truncated ? available : end;
  final dataStart = offset + headerSize;
  final dataStop = truncated ? available : end;

  Uint8List? uuid;
  if (type == 'uuid' && dataStart + 16 <= stop) {
    if (head.length >= headerSize + 16) {
      uuid = Uint8List.fromList(head.sublist(headerSize, headerSize + 16));
    } else {
      await file.setPosition(dataStart);
      final extended = await file.read(16);
      if (extended.length == 16) uuid = Uint8List.fromList(extended);
    }
  }

  return Mp4Box(
    type: type,
    typeBytes: typeBytes,
    start: offset,
    stop: stop,
    headerSize: headerSize,
    dataStart: dataStart,
    dataStop: dataStop,
    declaredSize: declaredSize,
    largeSize: largeSize,
    extendsToEnd: extendsToEnd,
    isTruncated: truncated,
    uuid: uuid,
  );
}

List<int> _encodeXmpBox(String xml) {
  final payload = utf8.encode(xml);
  final total32 = 8 + mp4XmpUuid.length + payload.length;
  if (total32 <= 0xFFFFFFFF) {
    return <int>[
      ..._u32(total32),
      ..._uuidTypeBytes,
      ...mp4XmpUuid,
      ...payload,
    ];
  }
  final total64 = 16 + mp4XmpUuid.length + payload.length;
  return <int>[
    ..._u32(1),
    ..._uuidTypeBytes,
    ..._u64(total64),
    ...mp4XmpUuid,
    ...payload,
  ];
}

void _writeU32(Uint8List bytes, int offset, int value) {
  bytes[offset] = (value >> 24) & 0xFF;
  bytes[offset + 1] = (value >> 16) & 0xFF;
  bytes[offset + 2] = (value >> 8) & 0xFF;
  bytes[offset + 3] = value & 0xFF;
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

int _readU32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

int _readU64(Uint8List bytes, int offset) =>
    (bytes[offset] << 56) |
    (bytes[offset + 1] << 48) |
    (bytes[offset + 2] << 40) |
    (bytes[offset + 3] << 32) |
    (bytes[offset + 4] << 24) |
    (bytes[offset + 5] << 16) |
    (bytes[offset + 6] << 8) |
    bytes[offset + 7];

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _isWellFormed(String xml) {
  try {
    parseXmpFields(xml);
    return true;
  } on FormatException {
    return false;
  }
}

final Uint8List _freeBytes = Uint8List.fromList(mp4FreeBoxType.codeUnits);

const List<int> _uuidTypeBytes = [0x75, 0x75, 0x69, 0x64];
