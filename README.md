# provenance_dart

A pure Dart implementation of
[provenance-spec](https://github.com/joopererer/provenance-spec) 0.1.3 — read
and write provenance metadata (where a file came from, who made it, when it was
captured) as XMP inside JPEG, PNG and WebP files, and in `.xmp` sidecar files.

No Flutter, no platform channels, no native code: it runs on the Dart VM, in
Flutter apps, in command-line tools and inside isolates.

## Features

- **Read** provenance from JPEG (APP1), PNG (`iTXt`) and WebP (`XMP ` chunk)
  files, and from `.xmp` sidecar files.
- **Write** provenance in place: only the fields of the spec change, every
  other byte of the XMP package — foreign namespaces, attribute layout,
  comments, the xpacket header — is preserved (SPEC §4.7).
- **Merge** embedded metadata with a sidecar file field by field (SPEC §4.4).
- **Header-only reads**: a JPEG is scanned up to the start of scan, a PNG or
  WebP is walked chunk header by chunk header. Memory use does not grow with
  the file size, so multi-gigabyte files are fine.
- **C2PA aware**: files carrying content credentials are detected and left
  alone, so their signature stays valid (SPEC §4.3).
- **URL normalization** for `prov:sourceUrl` (SPEC §5).
- **Tolerant reading**: unknown fields are ignored and preserved, missing
  fields do not fail a read (SPEC §1).

## Getting started

Add the dependency:

```yaml
dependencies:
  provenance_dart: ^0.1.0
```

The spec is a git submodule at `spec/`, pinned to a release tag. The test
vectors are read from it in place, so initialise it before running the tests:

```sh
git submodule update --init
dart test
```

## Usage

### Reading

```dart
import 'package:provenance_dart/provenance_dart.dart';

final provenance = await MetadataService.readProvenance('photo.jpg');
if (provenance != null) {
  print(provenance.toJson());
  // {schema: 0.1, assetId: ..., capturedAt: ..., source: {...}, title: ...}
}
```

`readProvenance` merges the embedded metadata with the sidecar file. Use
`readEmbedded` or `readSidecar` to read one side only.

### Writing

```dart
final provenance = ProvenanceBuilder(
  platform: 'xiaohongshu',
  capturedBy: 'MyApp/1.0.0',
  sourceId: '6ad2f7050000000012034042',
  sourceUrl: 'https://www.xiaohongshu.com/explore/6ad2f7050000000012034042',
  authorName: '示例作者',
  creditPlatformName: '小红书',
  itemIndex: 3,
  itemCount: 9,
).build();

final result = await MetadataService.embedProvenance(
  filePath: 'photo.jpg',
  provenance: provenance,
);

if (result.skippedC2pa || result.isFormatError) {
  // The file must not be modified: use a sidecar instead (SPEC §4.3).
  await MetadataService.writeSidecar('photo.jpg', provenance);
}
```

`ProvenanceBuilder` applies only the rules of the spec: the source URL is
normalized, `itemIndex`/`itemCount` are written only for multi-item sources,
and the description is truncated to 2000 characters. Everything application
specific — the software name in `prov:capturedBy`, the localized platform name
in `photoshop:Credit`, and any rule about which author IDs are trustworthy — is
supplied by the caller.

### Byte-level API

Every format module also exposes a byte-based API, which is handy when the
bytes are already in memory or come from somewhere other than a file:

```dart
final bytes = await File('photo.jpg').readAsBytes();
final provenance = readJpegXmp(bytes);           // XmpProvenance?
final updated = writeJpegXmp(bytes, provenance); // Uint8List
```

The same pattern exists for PNG (`readPngXmp` / `writePngXmp`) and WebP
(`readWebpXmp` / `writeWebpXmp`).

### Editing an XMP package directly

```dart
final package = XmpPackage.parse(xml);
package.setField(XmpField.rating, 5);
print(package.text); // only the rating changed
```

## Public API

| Area | Members |
|---|---|
| Orchestration | `MetadataService.readProvenance`, `readEmbedded`, `readSidecar`, `detectFormat`, `hasC2pa`, `embedProvenance`, `writeSidecar`; `EmbedResult`, `EmbedErrorCode` |
| Model | `XmpProvenance`, `XmpFields` |
| Building | `ProvenanceBuilder`, `generateAssetId`, `truncateDescription`, `maxDescriptionLength` |
| XMP core | `parseXmpFields`, `parseXmpXml`, `mergeProvenance`, `buildXmpXml`, `writeProvenanceIntoPackage`, `updateXmpXml` |
| In-place editing | `XmpPackage`, `escapeAttributeValue`, `escapeText` |
| Fields | `XmpField`, `XmpFieldClass`, `XmpValueKind`, namespace URI constants |
| JPEG | `readJpegXmp`, `writeJpegXmp`, `readJpegXmpText`, `scanJpegSegments`, `readJpegXmpFromFile`, `scanJpegSegmentsFromFile`, `writeJpegXmpToFile`, `JpegSegment`, `xmpApp1Header`, `exifApp1Header`, `maxJpegXmpBytes` |
| PNG | `readPngXmp`, `writePngXmp`, `readPngXmpText`, `readPngXmpTextFromFile`, `scanPngChunks`, `scanPngChunksFromFile`, `readPngXmpFromFile`, `writePngXmpToFile`, `PngChunk`, `pngXmpKeyword`, `crc32` |
| WebP | `readWebpXmp`, `writeWebpXmp`, `readWebpXmpText`, `readWebpXmpTextFromFile`, `scanWebpChunks`, `scanWebpChunksFromFile`, `readWebpXmpFromFile`, `writeWebpXmpToFile`, `WebpChunk`, `webpXmpFourCc`, `webpXmpFlag` |
| Sidecar | `sidecarPathFor`, `readSidecarFor`, `readSidecarXmp`, `writeSidecarFor`, `writeSidecarXmp` |
| C2PA | `detectC2pa`, `detectC2paFromFile`, `C2paStatus` |
| Format | `detectFormat`, `detectFormatFromFile`, `MediaFormat` |
| URLs | `normalizeUrl` |
| Dates | `formatDateTimeWithTimezone`, `formatDateTimeUtc` |
| Files | `rewriteFile`, `FileRegion` |
| XML | `parseXmlTree`, `XmlElementNode`, `XmlAttr`, `XmlTextNode` |

## Memory use

Reading looks only at the container header: a JPEG is scanned up to the start
of scan, a PNG or WebP is walked chunk header by chunk header, and nothing but
the XMP payload is ever loaded. Writing copies the rest of the file through a
fixed 64 KiB buffer to a temporary file and then renames it over the original,
so a failed write leaves the file untouched.

Memory use is therefore independent of the file size. The test suite verifies
this with 1 GiB sparse files.

## Isolates

Everything in this library is pure Dart with no platform channels, so it can
run inside `Isolate.run` or a worker pool:

- **Safe in any isolate**: `normalizeUrl`, `generateAssetId`,
  `truncateDescription`, all `XmpProvenance` methods, `ProvenanceBuilder`, and
  the byte-level `readJpegXmp`, `writeJpegXmp`, `readPngXmp`, `writePngXmp`,
  `readWebpXmp`, `writeWebpXmp`, `detectC2pa`, `detectFormat`, `parseXmpXml`
  and `buildXmpXml`. They take and return plain values and share no mutable
  state.
- **Safe in any isolate, but will perform file I/O there**: `MetadataService`
  and the `...ToFile` / `...FromFile` functions, `readSidecarXmp` and
  `writeSidecarXmp`. Each call opens and closes its own handle; nothing is
  cached across calls. Handles cannot be passed between isolates, so open the
  file in the isolate that uses it.
- **Time zone dependent**: `formatDateTimeWithTimezone` writes the local offset
  of the current isolate for non-UTC values. Isolates share the process time
  zone, but a UTC `DateTime` is preferred for reproducible output.

## Scope

Implemented for 0.1.0:

- JPEG, PNG and WebP embedded XMP, plus `.xmp` sidecar files.
- SPEC §4.4 merge, §4.6 write policy, §4.7 read and write requirements.
- SPEC §10 conformance, including all `spec/test-vectors/` cases.

Not implemented (deferred to 0.2):

- MP4 / MOV `uuid` box.
- `Zone.Identifier` / xattr source hints (SPEC §4.5).
- `prov:mediaUrl` (reserved by the spec, not implemented).

## License

See the repository for the license.
