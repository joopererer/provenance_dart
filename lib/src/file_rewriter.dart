// Streaming file rewriting.
//
// Replacing an XMP segment changes the length of the container header, so the
// rest of the file has to move. Copying through a fixed-size buffer keeps
// memory independent of the file size, which matters for multi-gigabyte
// videos and images.

import 'dart:io';
import 'dart:typed_data';

/// A byte range of the source file to replace with [replacement].
///
/// An empty range (`start == stop`) inserts [replacement] at [start].
class FileRegion {
  /// Creates a region.
  const FileRegion(this.start, this.stop, this.replacement);

  /// Offset of the first byte to replace.
  final int start;

  /// Offset just past the last byte to replace.
  final int stop;

  /// Bytes written in place of `[start, stop)`.
  final List<int> replacement;
}

/// Test hook: when set, every write throws a simulated [FileSystemException]
/// once this many bytes have reached the temporary file.
///
/// It exists so the "a failed write leaves the original file intact" guarantee
/// can be tested without filling a disk. It is not exported from
/// `package:provenance_dart`; production code never sets it.
int? debugFailAfterBytes;

const int _copyBufferSize = 64 * 1024;

/// Thrown when a write fails before the original file was replaced.
///
/// The original file is guaranteed to be untouched when this is thrown, and
/// the temporary file has already been deleted.
class FileRewriteException implements Exception {
  /// Creates an exception.
  const FileRewriteException(this.message, this.path, [this.cause]);

  /// What went wrong.
  final String message;

  /// The path that was being written.
  final String path;

  /// The underlying error, if any.
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'FileRewriteException: $message ($path)'
      : 'FileRewriteException: $message ($path): $cause';
}

/// Rewrites [path], replacing [regions] and copying everything else verbatim.
///
/// The result is streamed into a temporary file **in the same directory**,
/// flushed to disk, and then atomically renamed over [path]. Every step is
/// guarded:
///
/// * if reading the source or writing the temporary file fails, the temporary
///   file is deleted and [path] keeps its original bytes;
/// * if the rename fails, the temporary file is deleted and [path] keeps its
///   original bytes.
///
/// A failure therefore never touches the original file (SPEC §4.6: a failed
/// metadata write must not affect the file itself); it surfaces as a
/// [FileRewriteException].
///
/// Set [preserveModificationTime] to copy the original file's last-modified
/// timestamp onto the rewritten file. The default is `false`, so the file looks
/// freshly modified, which is what a metadata edit normally should do.
Future<void> rewriteFile(
  String path,
  List<FileRegion> regions, {
  bool preserveModificationTime = false,
}) async {
  final sorted = [...regions]..sort((a, b) => a.start.compareTo(b.start));
  final source = File(path);

  final stat = await source.stat();
  if (stat.type == FileSystemEntityType.notFound) {
    throw FileRewriteException('Source file does not exist', path);
  }

  final temp = _tempFor(source);

  RandomAccessFile? input;
  RandomAccessFile? output;
  var replaced = false;
  try {
    if (await temp.exists()) await temp.delete();

    input = await source.open();
    output = await temp.open(mode: FileMode.writeOnly);
    var written = 0;

    void count(int bytes) {
      written += bytes;
      final limit = debugFailAfterBytes;
      if (limit != null && written >= limit) {
        throw const FileSystemException('Simulated write failure');
      }
    }

    try {
      final length = await input.length();
      var position = 0;
      final buffer = Uint8List(_copyBufferSize);

      for (final region in sorted) {
        if (region.start > position) {
          position = await _copy(
            input,
            output,
            position,
            region.start,
            buffer,
            onWritten: count,
          );
        }
        if (region.replacement.isNotEmpty) {
          await output.writeFrom(region.replacement);
          count(region.replacement.length);
        }
        if (region.stop > position) position = region.stop;
      }

      if (position < length) {
        await _copy(input, output, position, length, buffer, onWritten: count);
      }

      // Push the bytes out of the OS cache before the rename, so a crash or a
      // later failure cannot leave a half-written result in place.
      await output.flush();
    } finally {
      await output.close();
      output = null;
      await input.close();
      input = null;
    }

    await temp.rename(path);
    replaced = true;
  } on FileSystemException catch (error) {
    throw FileRewriteException('Could not rewrite file', path, error);
  } finally {
    await _closeQuietly(input);
    await _closeQuietly(output);
    if (!replaced) await _deleteQuietly(temp);
  }

  // After the rename the new file is in place; a failure here only loses a
  // timestamp, so it must not turn a successful write into an error.
  if (preserveModificationTime) {
    try {
      await source.setLastModified(stat.modified);
    } on FileSystemException {
      // Best effort.
    }
  }
}

/// Writes [bytes] to [path] atomically.
///
/// The bytes go to a temporary file in the same directory, which is flushed
/// and then atomically renamed over [path]. A failure leaves the original file
/// untouched and deletes the temporary file.
///
/// Set [preserveModificationTime] to keep the timestamp of an existing file.
Future<void> writeFileAtomically(
  String path,
  List<int> bytes, {
  bool preserveModificationTime = false,
}) async {
  final target = File(path);
  final stat = await target.stat();
  final hadFile = stat.type == FileSystemEntityType.file;
  final temp = _tempFor(target);

  RandomAccessFile? output;
  var replaced = false;
  try {
    if (await temp.exists()) await temp.delete();
    output = await temp.open(mode: FileMode.writeOnly);
    try {
      await output.writeFrom(bytes);
      final limit = debugFailAfterBytes;
      if (limit != null && bytes.length >= limit) {
        throw const FileSystemException('Simulated write failure');
      }
      await output.flush();
    } finally {
      await output.close();
      output = null;
    }
    await temp.rename(path);
    replaced = true;
  } on FileSystemException catch (error) {
    throw FileRewriteException('Could not write file', path, error);
  } finally {
    await _closeQuietly(output);
    if (!replaced) await _deleteQuietly(temp);
  }

  if (preserveModificationTime && hadFile) {
    try {
      await target.setLastModified(stat.modified);
    } on FileSystemException {
      // Best effort.
    }
  }
}

/// The temporary file used to replace [target].
///
/// It sits in the same directory as [target], so the rename stays inside one
/// file system and is therefore atomic. The dot prefix hides it on Unix-like
/// systems, which makes a leftover from a hard kill easy to spot and harmless.
File _tempFor(File target) => File(
  '${target.parent.path}${Platform.pathSeparator}'
  '.${_baseName(target)}.provenance-tmp',
);

/// The last path segment of [file], independent of the separator style.
String _baseName(File file) {
  final path = file.path;
  final parent = file.parent.path;
  var name = path;
  if (path.length > parent.length) {
    name = path.substring(parent.length);
  }
  while (name.startsWith('/') || name.startsWith(r'\')) {
    name = name.substring(1);
  }
  return name;
}

/// The path [rewriteFile] would use as its temporary file for [path].
///
/// Exposed for tests, which assert that the temporary file is created in the
/// same directory as the target. Not exported from `package:provenance_dart`.
String debugTempPathFor(String path) => _tempFor(File(path)).path;

Future<void> _closeQuietly(RandomAccessFile? handle) async {
  if (handle == null) return;
  try {
    await handle.close();
  } on FileSystemException {
    // The handle is unusable either way.
  }
}

Future<void> _deleteQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // Nothing left to clean up.
  }
}

/// Copies `[from, to)` of [input] to [output], returning the new position.
Future<int> _copy(
  RandomAccessFile input,
  RandomAccessFile output,
  int from,
  int to,
  Uint8List buffer, {
  void Function(int count)? onWritten,
}) async {
  var position = from;
  while (position < to) {
    final want = (to - position).clamp(1, buffer.length);
    await input.setPosition(position);
    final chunk = await input.read(want);
    if (chunk.isEmpty) break;
    await output.writeFrom(chunk);
    onWritten?.call(chunk.length);
    position += chunk.length;
  }
  return position;
}
