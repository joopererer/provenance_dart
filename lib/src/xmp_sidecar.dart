// XMP sidecar files (SPEC §4.2, §4.7).

import 'dart:convert';
import 'dart:io';

import 'xmp_core.dart';
import 'xmp_model.dart';

/// Returns the sidecar path for [mediaPath].
///
/// The sidecar is the full original file name plus `.xmp`, in the same
/// directory, so `IMG_001.jpg` and `IMG_001.mp4` of a Live Photo do not
/// collide (SPEC §4.2).
String sidecarPathFor(String mediaPath) => '$mediaPath.xmp';

/// Reads the provenance record from the sidecar of [mediaPath].
///
/// Returns `null` when the sidecar does not exist or holds no provenance
/// metadata.
Future<XmpProvenance?> readSidecarFor(String mediaPath) =>
    readSidecarXmp(File(sidecarPathFor(mediaPath)));

/// Reads the provenance record from [file].
///
/// Returns `null` when [file] does not exist or holds no provenance metadata.
Future<XmpProvenance?> readSidecarXmp(File file) async {
  if (!await file.exists()) return null;
  final text = await file.readAsString(encoding: utf8);
  return parseXmpXml(text);
}

/// Writes [provenance] to the sidecar of [mediaPath].
Future<void> writeSidecarFor(String mediaPath, XmpProvenance provenance) =>
    writeSidecarXmp(File(sidecarPathFor(mediaPath)), provenance);

/// Writes [provenance] to [file].
///
/// When the sidecar already exists its XML is edited in place, so foreign
/// fields and formatting survive (SPEC §4.7 write requirement 1). A new file
/// is created only when there is none. The file is written as UTF-8 without a
/// byte order mark (SPEC §4.2).
Future<void> writeSidecarXmp(File file, XmpProvenance provenance) async {
  String xml;
  if (await file.exists()) {
    final existing = await file.readAsString(encoding: utf8);
    xml = updateXmpXml(existing, provenance);
  } else {
    xml = buildXmpXml(provenance);
  }
  await file.writeAsString(xml, encoding: utf8, flush: true);
}
