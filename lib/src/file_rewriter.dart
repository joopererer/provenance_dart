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

const int _copyBufferSize = 64 * 1024;

/// Rewrites [path], replacing [regions] and copying everything else verbatim.
///
/// The result is written to a temporary file next to [path] and then renamed
/// over it, so a failure leaves the original file untouched (SPEC §4.6: a
/// failed metadata write must not affect the file itself).
Future<void> rewriteFile(String path, List<FileRegion> regions) async {
  final sorted = [...regions]..sort((a, b) => a.start.compareTo(b.start));
  final source = File(path);
  final temp = File('$path.provenance-tmp');
  if (await temp.exists()) await temp.delete();

  final input = await source.open();
  final output = await temp.open(mode: FileMode.write);
  try {
    final length = await input.length();
    var position = 0;
    final buffer = Uint8List(_copyBufferSize);

    for (final region in sorted) {
      if (region.start > position) {
        position = await _copy(input, output, position, region.start, buffer);
      }
      if (region.replacement.isNotEmpty) {
        await output.writeFrom(region.replacement);
      }
      if (region.stop > position) position = region.stop;
    }

    if (position < length) {
      await _copy(input, output, position, length, buffer);
    }
  } finally {
    await input.close();
    await output.close();
  }

  await temp.rename(path);
}

Future<int> _copy(
  RandomAccessFile input,
  RandomAccessFile output,
  int from,
  int to,
  Uint8List buffer,
) async {
  var position = from;
  while (position < to) {
    final want = (to - position).clamp(1, buffer.length);
    await input.setPosition(position);
    final chunk = await input.read(want);
    if (chunk.isEmpty) break;
    await output.writeFrom(chunk);
    position += chunk.length;
  }
  return position;
}
