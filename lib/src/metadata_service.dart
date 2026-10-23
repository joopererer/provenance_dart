// Orchestration of format detection, C2PA checks and XMP read/write.

import 'dart:convert';
import 'dart:io';

import 'c2pa_detector.dart';
import 'file_rewriter.dart';
import 'media_format.dart';
import 'xmp_core.dart';
import 'xmp_jpeg.dart';
import 'xmp_model.dart';
import 'xmp_mp4.dart';
import 'xmp_png.dart';
import 'xmp_sidecar.dart';
import 'xmp_webp.dart';

/// Why a metadata embed did not happen.
enum EmbedErrorCode {
  /// The file does not exist.
  fileNotFound,

  /// The magic bytes match no supported container.
  formatNotRecognized,

  /// The container is supported but the write failed.
  formatUnsupported,

  /// The file carries C2PA content credentials, so a sidecar must be used
  /// (SPEC §4.3).
  c2paDetected,

  /// Any other write failure.
  writeFailed,
}

/// The outcome of an embed operation.
///
/// On success the file has been modified. On a C2PA skip the file is
/// untouched and the caller should write a sidecar instead.
class EmbedResult {
  /// Creates a result.
  const EmbedResult({
    required this.success,
    this.errorCode,
    this.errorMessage,
    this.cause,
  });

  /// Whether the operation completed without an error.
  final bool success;

  /// The failure or skip reason; `null` on success.
  final EmbedErrorCode? errorCode;

  /// A human readable message, for logging.
  final String? errorMessage;

  /// The original exception, when the failure came from the file system.
  ///
  /// A caller can inspect it to tell "Permission denied" from a full disk:
  ///
  /// ```dart
  /// if (result.errorCode == EmbedErrorCode.writeFailed) {
  ///   final cause = result.cause;
  ///   if (cause is FileSystemException) print(cause.osError?.message);
  /// }
  /// ```
  ///
  /// It is `null` for a C2PA skip and for a structural refusal, where
  /// [errorMessage] already says everything.
  final Object? cause;

  /// A successful embed.
  factory EmbedResult.embedded() => const EmbedResult(success: true);

  /// A skip because the file is C2PA signed.
  factory EmbedResult.skippedC2pa() => const EmbedResult(
    success: true,
    errorCode: EmbedErrorCode.c2paDetected,
    errorMessage: 'C2PA content credentials detected; use a sidecar',
  );

  /// A failure.
  factory EmbedResult.failure(
    EmbedErrorCode code,
    String message, {
    Object? cause,
  }) => EmbedResult(
    success: false,
    errorCode: code,
    errorMessage: message,
    cause: cause,
  );

  /// Whether the file was left untouched because of C2PA.
  bool get skippedC2pa => errorCode == EmbedErrorCode.c2paDetected;

  /// Whether the failure was about the container format.
  bool get isFormatError =>
      errorCode == EmbedErrorCode.formatNotRecognized ||
      errorCode == EmbedErrorCode.formatUnsupported;

  /// Whether the failure came from the file system rather than the format.
  bool get isWriteError => errorCode == EmbedErrorCode.writeFailed;
}

/// Reads and writes provenance metadata of media files.
///
/// Every method is asynchronous and reads only the container header, so files
/// of any size can be handled without loading them into memory.
class MetadataService {
  const MetadataService._();

  /// Reads the provenance record of [filePath], merging the embedded metadata
  /// with the sidecar file per field (SPEC §4.4).
  ///
  /// A field present on only one side is taken from that side, so a file whose
  /// embedded XMP has no `prov` fields still returns the `assetId` and source
  /// fields of its sidecar. Only a field present on both sides with different
  /// values is resolved by the conflict rule: capture fields keep the embedded
  /// value, user fields take the newer `xmp:MetadataDate`.
  ///
  /// Returns `null` when neither source holds provenance metadata.
  static Future<XmpProvenance?> readProvenance(String filePath) async {
    final embeddedXml = await readEmbeddedXmp(filePath);
    final sidecarXml = await readSidecarXmpText(filePath);
    return mergeProvenanceXml(embeddedXml, sidecarXml);
  }

  /// Reads the raw XMP text embedded in [filePath], or `null`.
  ///
  /// Only the header of the container is read, so this is safe on large files.
  static Future<String?> readEmbeddedXmp(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return null;

    final handle = await file.open();
    try {
      final format = await detectFormatFromFile(handle);
      return switch (format) {
        MediaFormat.jpeg => await readJpegXmpTextFromFile(handle),
        MediaFormat.png => await readPngXmpTextFromFile(handle),
        MediaFormat.webp => await readWebpXmpTextFromFile(handle),
        MediaFormat.mp4 => await readMp4XmpTextFromFile(handle),
        MediaFormat.other => null,
      };
    } on FormatException {
      return null;
    } finally {
      await handle.close();
    }
  }

  /// Reads the raw XMP text of the sidecar of [filePath], or `null`.
  static Future<String?> readSidecarXmpText(String filePath) async {
    final file = File(sidecarPathFor(filePath));
    if (!await file.exists()) return null;
    try {
      return await file.readAsString(encoding: utf8);
    } on FileSystemException {
      return null;
    }
  }

  /// Reads only the metadata embedded in [filePath].
  static Future<XmpProvenance?> readEmbedded(String filePath) async {
    final xml = await readEmbeddedXmp(filePath);
    return xml == null ? null : parseXmpXml(xml);
  }

  /// Reads only the sidecar of [filePath].
  static Future<XmpProvenance?> readSidecar(String filePath) async {
    try {
      return await readSidecarFor(filePath);
    } on FormatException {
      return null;
    }
  }

  /// Detects the container format of [filePath].
  static Future<MediaFormat> detectFormat(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return MediaFormat.other;
    final handle = await file.open();
    try {
      return await detectFormatFromFile(handle);
    } finally {
      await handle.close();
    }
  }

  /// Whether [filePath] carries C2PA content credentials (SPEC §4.3).
  static Future<bool> hasC2pa(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return false;
    final handle = await file.open();
    try {
      final format = await detectFormatFromFile(handle);
      if (format == MediaFormat.other) return false;
      return await detectC2paFromFile(handle, format) == C2paStatus.detected;
    } on FormatException {
      return false;
    } finally {
      await handle.close();
    }
  }

  /// Embeds [provenance] into [filePath].
  ///
  /// The existing XMP package is edited in place, so foreign fields survive
  /// (SPEC §4.7). Capture fields that are already present are never
  /// overwritten and `prov:assetId` is never changed (SPEC §4.6).
  ///
  /// When the file is C2PA signed the write is skipped and
  /// [EmbedResult.skippedC2pa] is returned; the caller must write a sidecar
  /// instead. When the container is not supported, [EmbedErrorCode
  /// .formatUnsupported] is returned and the caller should also use a sidecar.
  ///
  /// The file is replaced atomically: a failed write leaves the original bytes
  /// intact. Set [preserveModificationTime] to keep the file's timestamp.
  ///
  /// For MP4 / MOV files [mp4WriteMode] selects between replacing the file
  /// ([Mp4WriteMode.rewrite], the default) and appending in place
  /// ([Mp4WriteMode.inPlace]). The in-place mode avoids copying the file and is
  /// meant for large videos in shared directories; it rolls back on failure.
  static Future<EmbedResult> embedProvenance({
    required String filePath,
    required XmpProvenance provenance,
    bool checkC2pa = true,
    bool preserveModificationTime = false,
    Mp4WriteMode mp4WriteMode = Mp4WriteMode.rewrite,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      return EmbedResult.failure(
        EmbedErrorCode.fileNotFound,
        'File not found: $filePath',
      );
    }

    try {
      final format = await detectFormat(filePath);
      if (format == MediaFormat.other) {
        return EmbedResult.failure(
          EmbedErrorCode.formatUnsupported,
          'Format does not support embedded XMP: $filePath',
        );
      }

      if (checkC2pa && await hasC2pa(filePath)) {
        return EmbedResult.skippedC2pa();
      }

      switch (format) {
        case MediaFormat.jpeg:
          await writeJpegXmpToFile(
            filePath,
            provenance,
            preserveModificationTime: preserveModificationTime,
          );
        case MediaFormat.png:
          await writePngXmpToFile(
            filePath,
            provenance,
            preserveModificationTime: preserveModificationTime,
          );
        case MediaFormat.webp:
          await writeWebpXmpToFile(
            filePath,
            provenance,
            preserveModificationTime: preserveModificationTime,
          );
        case MediaFormat.mp4:
          if (mp4WriteMode == Mp4WriteMode.inPlace) {
            await appendMp4XmpInPlace(
              filePath,
              provenance,
              preserveModificationTime: preserveModificationTime,
            );
          } else {
            await writeMp4XmpToFile(
              filePath,
              provenance,
              preserveModificationTime: preserveModificationTime,
            );
          }
        case MediaFormat.other:
          return EmbedResult.failure(
            EmbedErrorCode.formatUnsupported,
            'Format does not support embedded XMP: $filePath',
          );
      }
      return EmbedResult.embedded();
    } on Mp4WriteException catch (error) {
      // A structural refusal is a format problem; an I/O failure is not.
      if (error.code == Mp4WriteErrorCode.fileNotFound) {
        return EmbedResult.failure(
          EmbedErrorCode.fileNotFound,
          error.message,
          cause: error,
        );
      }
      return EmbedResult.failure(
        EmbedErrorCode.formatUnsupported,
        'Write failed: ${error.message}',
        cause: error,
      );
    } on ArgumentError catch (error) {
      // Raised by the writers for a payload the container cannot hold.
      return EmbedResult.failure(
        EmbedErrorCode.formatUnsupported,
        'Write failed: ${error.message}',
        cause: error,
      );
    } on FormatException catch (error) {
      return EmbedResult.failure(
        EmbedErrorCode.formatUnsupported,
        'Write failed: ${error.message}',
        cause: error,
      );
    } on FileRewriteException catch (error) {
      return EmbedResult.failure(
        EmbedErrorCode.writeFailed,
        'Write failed: $error',
        cause: error,
      );
    } on FileSystemException catch (error) {
      return EmbedResult.failure(
        EmbedErrorCode.writeFailed,
        'Write failed: $error',
        cause: error,
      );
    } catch (error) {
      return EmbedResult.failure(
        EmbedErrorCode.writeFailed,
        'Write failed: $error',
        cause: error,
      );
    }
  }

  /// Writes [provenance] to the sidecar of [filePath], creating it if needed.
  ///
  /// Set [preserveModificationTime] to keep the sidecar's timestamp when it
  /// already exists.
  static Future<void> writeSidecar(
    String filePath,
    XmpProvenance provenance, {
    bool preserveModificationTime = false,
  }) => writeSidecarFor(
    filePath,
    provenance,
    preserveModificationTime: preserveModificationTime,
  );
}
