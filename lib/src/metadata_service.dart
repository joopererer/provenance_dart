// Orchestration of format detection, C2PA checks and XMP read/write.

import 'dart:io';

import 'c2pa_detector.dart';
import 'media_format.dart';
import 'xmp_core.dart';
import 'xmp_jpeg.dart';
import 'xmp_model.dart';
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
  const EmbedResult({required this.success, this.errorCode, this.errorMessage});

  /// Whether the operation completed without an error.
  final bool success;

  /// The failure or skip reason; `null` on success.
  final EmbedErrorCode? errorCode;

  /// A human readable message, for logging.
  final String? errorMessage;

  /// A successful embed.
  factory EmbedResult.embedded() => const EmbedResult(success: true);

  /// A skip because the file is C2PA signed.
  factory EmbedResult.skippedC2pa() => const EmbedResult(
    success: true,
    errorCode: EmbedErrorCode.c2paDetected,
    errorMessage: 'C2PA content credentials detected; use a sidecar',
  );

  /// A failure.
  factory EmbedResult.failure(EmbedErrorCode code, String message) =>
      EmbedResult(success: false, errorCode: code, errorMessage: message);

  /// Whether the file was left untouched because of C2PA.
  bool get skippedC2pa => errorCode == EmbedErrorCode.c2paDetected;

  /// Whether the failure was about the container format.
  bool get isFormatError =>
      errorCode == EmbedErrorCode.formatNotRecognized ||
      errorCode == EmbedErrorCode.formatUnsupported;
}

/// Reads and writes provenance metadata of media files.
///
/// Every method is asynchronous and reads only the container header, so files
/// of any size can be handled without loading them into memory.
class MetadataService {
  const MetadataService._();

  /// Reads the provenance record of [filePath], merging the embedded metadata
  /// with the sidecar file (SPEC §4.4).
  ///
  /// Returns `null` when neither source holds provenance metadata.
  static Future<XmpProvenance?> readProvenance(String filePath) async {
    final embedded = await readEmbedded(filePath);
    final sidecar = await readSidecar(filePath);
    return mergeProvenance(embedded, sidecar);
  }

  /// Reads only the metadata embedded in [filePath].
  static Future<XmpProvenance?> readEmbedded(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return null;

    final handle = await file.open();
    try {
      final format = await detectFormatFromFile(handle);
      return await _readEmbedded(handle, format);
    } on FormatException {
      return null;
    } finally {
      await handle.close();
    }
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
  static Future<EmbedResult> embedProvenance({
    required String filePath,
    required XmpProvenance provenance,
    bool checkC2pa = true,
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
          await writeJpegXmpToFile(filePath, provenance);
        case MediaFormat.png:
          await writePngXmpToFile(filePath, provenance);
        case MediaFormat.webp:
          await writeWebpXmpToFile(filePath, provenance);
        case MediaFormat.other:
          return EmbedResult.failure(
            EmbedErrorCode.formatUnsupported,
            'Format does not support embedded XMP: $filePath',
          );
      }
      return EmbedResult.embedded();
    } on ArgumentError catch (error) {
      return EmbedResult.failure(
        EmbedErrorCode.formatUnsupported,
        'Write failed: ${error.message}',
      );
    } catch (error) {
      return EmbedResult.failure(
        EmbedErrorCode.writeFailed,
        'Write failed: $error',
      );
    }
  }

  /// Writes [provenance] to the sidecar of [filePath], creating it if needed.
  static Future<void> writeSidecar(String filePath, XmpProvenance provenance) =>
      writeSidecarFor(filePath, provenance);

  static Future<XmpProvenance?> _readEmbedded(
    RandomAccessFile handle,
    MediaFormat format,
  ) async {
    switch (format) {
      case MediaFormat.jpeg:
        return readJpegXmpFromFile(handle);
      case MediaFormat.png:
        return readPngXmpFromFile(handle);
      case MediaFormat.webp:
        return readWebpXmpFromFile(handle);
      case MediaFormat.other:
        return null;
    }
  }
}
