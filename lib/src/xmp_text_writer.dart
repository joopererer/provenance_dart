// Writing a ready-made XMP package back to a media file or a sidecar.
//
// The format-specific writers all plan the write from a `XmpProvenance` and
// update the package that is already in the file. This module is the other
// half: a caller that has edited the package itself (with `XmpPackage`, or by
// hand) can hand the final XML over and have it stored, using exactly the same
// atomic and in-place rules.

import 'dart:convert';
import 'dart:io';

import 'file_rewriter.dart';
import 'media_format.dart';
import 'xmp_jpeg.dart';
import 'xmp_mp4.dart';
import 'xmp_package.dart';
import 'xmp_png.dart';
import 'xmp_sidecar.dart';
import 'xmp_webp.dart';

/// Writes the XMP package [xml] into [path], replacing the package already
/// there.
///
/// The container is detected from the file header, so the same call works for
/// every format this package supports:
///
/// * **JPEG** — the XMP APP1 segment is replaced, or inserted after the last
///   APPn segment when there is none. EXIF and every other segment are copied
///   unchanged.
/// * **PNG** — the XMP `iTXt` chunk is replaced, or inserted before `IEND`.
/// * **WebP** — the `XMP ` chunk is replaced, or appended with the `VP8X` XMP
///   flag set. The image bitstream is copied unchanged.
/// * **MP4 / MOV** — an XMP `uuid` box is appended at the end of the file and
///   every old one is retired by changing only its type to `free`
///   (SPEC §4.7). [mp4WriteMode] picks between replacing the file and
///   appending in place; both rules, including recovery from an interrupted
///   append, are the same as for `MetadataService.embedProvenance`.
/// * **A `.xmp` path** — the package is written as a sidecar file. Unlike the
///   media writers this replaces the whole sidecar, because a sidecar contains
///   nothing but the package.
///
/// The package is validated first: a string that is not well-formed XML throws
/// a [FormatException] and leaves the file untouched. Writes to a media file go
/// through a temporary file plus a rename, so a failure leaves the original
/// bytes intact; the in-place MP4 mode rolls back instead.
///
/// Unlike `MetadataService.embedProvenance` this does **not** apply the write
/// policy of SPEC §4.6 — it does not merge fields, refuse to overwrite a
/// capture field, or check C2PA. It stores exactly the package it is given,
/// which is what a caller that edited [XmpPackage] wants. Apply your own
/// policy before calling it; use `MetadataService.embedProvenance` when the
/// policy of the spec should be enforced.
///
/// Set [preserveModificationTime] to keep the file's timestamp.
///
/// Throws [UnsupportedError] when the file is neither a supported container nor
/// a `.xmp` path.
Future<void> writeXmpTextToFile(
  String path,
  String xml, {
  Mp4WriteMode mp4WriteMode = Mp4WriteMode.rewrite,
  bool preserveModificationTime = false,
}) async {
  // Parse before touching anything: a package that cannot be read back is a
  // caller bug, and the file must stay untouched in that case.
  XmpPackage.parse(xml);

  final file = File(path);

  if (isSidecarPath(path)) {
    await writeFileAtomically(
      path,
      utf8.encode(xml),
      preserveModificationTime: preserveModificationTime,
    );
    return;
  }

  if (!await file.exists()) {
    throw FileSystemException('File does not exist', path);
  }

  final handle = await file.open();
  final MediaFormat format;
  try {
    format = await detectFormatFromFile(handle);
  } finally {
    await handle.close();
  }

  switch (format) {
    case MediaFormat.jpeg:
      await writeJpegXmpTextToFile(
        path,
        xml,
        preserveModificationTime: preserveModificationTime,
      );
    case MediaFormat.png:
      await writePngXmpTextToFile(
        path,
        xml,
        preserveModificationTime: preserveModificationTime,
      );
    case MediaFormat.webp:
      await writeWebpXmpTextToFile(
        path,
        xml,
        preserveModificationTime: preserveModificationTime,
      );
    case MediaFormat.mp4:
      if (mp4WriteMode == Mp4WriteMode.inPlace) {
        await appendMp4XmpTextInPlace(
          path,
          xml,
          preserveModificationTime: preserveModificationTime,
        );
      } else {
        await writeMp4XmpTextToFile(
          path,
          xml,
          preserveModificationTime: preserveModificationTime,
        );
      }
    case MediaFormat.other:
      throw UnsupportedError(
        'Cannot embed XMP in this container: $path. '
        'Write a sidecar file (${sidecarPathFor(path)}) instead.',
      );
  }
}

/// Whether [path] names a sidecar file, that is whether it ends in `.xmp`
/// (SPEC §4.2).
///
/// The check is case-insensitive so `.XMP` on a case-preserving file system is
/// recognised too.
bool isSidecarPath(String path) => path.toLowerCase().endsWith('.xmp');
