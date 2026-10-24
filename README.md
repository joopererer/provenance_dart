# provenance_dart

A pure Dart implementation of
[provenance-spec](https://github.com/joopererer/provenance-spec) 0.1.6 — read
and write provenance metadata (where a file came from, who made it, when it was
captured) as XMP inside JPEG, PNG, WebP, MP4 and MOV files, and in `.xmp`
sidecar files.

No Flutter, no platform channels, no native code: it runs on the Dart VM, in
Flutter apps, in command-line tools and inside isolates.

## Features

- **Read** provenance from JPEG (APP1), PNG (`iTXt`), WebP (`XMP ` chunk) and
  MP4 / MOV (top-level `uuid` box) files, and from `.xmp` sidecar files.
- **Write** provenance in place: only the fields of the spec change, every
  other byte of the XMP package — foreign namespaces, attribute layout,
  comments, the xpacket header — is preserved (SPEC §4.7).
- **Merge** embedded metadata with a sidecar file field by field (SPEC §4.4).
- **Header-only reads**: a JPEG is scanned up to the start of scan, a PNG or
  WebP is walked chunk header by chunk header, and an MP4 / MOV is walked box
  header by box header without ever entering `mdat`. Memory use does not grow
  with the file size, so multi-gigabyte videos are fine.
- **Two ways to write a video** (SPEC §4.7): replace the file through a
  temporary file plus a rename, or append in place with a `RandomAccessFile`
  so a large video is never copied. The in-place writer rolls back to the
  original bytes if any step fails.
- **C2PA aware**: files carrying content credentials are detected and left
  alone, so their signature stays valid (SPEC §4.3).
- **URL normalization** for `prov:sourceUrl` (SPEC §5).
- **AI annotations** (SPEC §3.7): `prov:aiLabel`, `prov:aiLabelSource` and
  `Iptc4xmpExt:DigitalSourceType` are read and written like every other
  field, and an existing `DigitalSourceType` is never overwritten.
- **Tolerant reading**: unknown fields are ignored and preserved, missing
  fields do not fail a read (SPEC §1).
- **Truncated files are safe**: a PNG chunk, JPEG segment or WebP chunk cut
  short is reported as unreadable (`null`) instead of throwing; a PNG chunk
  that only lacks its trailing CRC is still read.

## Getting started

Add the dependency:

```yaml
dependencies:
  provenance_dart: ^0.2.2
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

`readProvenance` merges the embedded metadata with the sidecar file field by
field (SPEC §4.4):

- a field present on only one side is taken from that side, whether it is a
  capture field or a user field;
- only when both sides disagree does the rule apply — capture fields keep the
  embedded value, user fields take the value of the newer `xmp:MetadataDate`.

So a photo whose embedded XMP has no `prov` fields at all still reports the
`assetId` and the source fields of its sidecar, while keeping the title and
rating written by an external editor. Use `readEmbedded` or `readSidecar` to
read one side only, or `readEmbeddedXmp` / `readSidecarXmpText` for the raw XML.

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

The same pattern exists for PNG (`readPngXmp` / `writePngXmp`), WebP
(`readWebpXmp` / `writeWebpXmp`) and MP4 / MOV (`readMp4Xmp` / `writeMp4Xmp`).
`writeMp4Xmp` copies the whole file into memory, so for a video use the file
APIs below instead.

### Writing an MP4 / MOV

Two writers exist, for two different situations:

```dart
// App private directory: replace the file atomically.
await writeMp4XmpToFile('clip.mp4', provenance);

// Shared gallery, large video: append in place, no copy, no temp file.
await appendMp4XmpInPlace('clip.mp4', provenance);

// Or let MetadataService pick one.
await MetadataService.embedProvenance(
  filePath: 'clip.mp4',
  provenance: provenance,
  mp4WriteMode: Mp4WriteMode.inPlace, // default: Mp4WriteMode.rewrite
);
```

Both append one new XMP `uuid` box at the end of the file and retire every old
XMP box by changing only its 4-byte type to `free`. The media data is never
re-encoded, never moved and never read.

The in-place writer works in an order that survives interruption: a last box
with `size == 0` gets its real size first, then the new box is appended and
flushed, and only then are the old boxes retired. Any failure truncates the
file back to its original length and restores every byte it changed. It refuses
a truncated file whose last box is not a recoverable XMP box
(`Mp4WriteErrorCode.truncatedFile`) and a `size == 0` last box larger than
4 GiB (`Mp4WriteErrorCode.requiresLargeSize`, which would need a 64-bit header
in the middle of the file).

**Recovering from an interrupted append.** If a previous write was killed
before it finished, the file ends with a half-written XMP `uuid` box. SPEC
§4.7 allows a writer to truncate that box away and write normally, and both
writers do: the incomplete box is dropped, the new box takes its place, and the
complete XMP box before it is retired as usual. Any other truncation is still
refused, because a box appended after unreachable bytes could never be found by
a conformant reader. If the recovery write itself fails, the incomplete bytes
are put back, so the file is byte-identical to what it was before the attempt.

### Error handling

`MetadataService.embedProvenance` never throws for a write failure; it returns
an `EmbedResult` whose `errorCode` says what kind of problem it was:

| `errorCode` | Meaning |
|---|---|
| `formatUnsupported` | The container cannot hold the XMP: not an MP4 / MOV, a truncated non-XMP box, a `size == 0` box over 4 GiB, or a payload the format cannot hold. Use a sidecar. |
| `writeFailed` | The file system refused the write: permission denied, a locked file, a full disk, a failed rename. The file is unchanged. |
| `c2paDetected` | The file is C2PA signed; use a sidecar. |
| `fileNotFound` | The file does not exist. |

A permission error is never reported as a format problem. The original
exception is kept in `EmbedResult.cause`, so a caller can tell "Permission
denied" from "No space left on device":

```dart
final result = await MetadataService.embedProvenance(
  filePath: 'clip.mp4',
  provenance: provenance,
);

if (result.isWriteError) {
  final cause = result.cause;
  if (cause is FileSystemException) {
    print(cause.osError?.message); // e.g. "Permission denied"
  }
  // The file is untouched; retry later or fall back to a sidecar.
}
```

### MP4 / MOV read algorithm (for native implementations)

The same walk should be used by the Kotlin and Rust layers, so readers agree on
every file:

1. Record `position = 0` and the file `length`.
2. While `position + 8 <= length`:
   1. Read 8 bytes at `position`: `size` (big-endian `uint32`) and `type`
      (4 bytes).
   2. If `size == 1`, read 8 more bytes at `position + 8` as `largesize`
      (big-endian `uint64`) and set `headerSize = 16`, `boxSize = largesize`.
      If `largesize < 16`, stop.
   3. Else if `size == 0`, the box runs to the end of the file:
      `headerSize = 8`, `boxSize = length - position`.
   4. Else if `size < 8`, stop. Otherwise `headerSize = 8`, `boxSize = size`.
   5. If `position + boxSize > length` the box is truncated: report it and
      stop. Boxes already visited stay valid — a truncated file still yields
      the last complete XMP box before the truncation point.
   6. If `type == 'uuid'`, read the 16 bytes at `position + headerSize`. If they
      equal `BE7ACFCB-97A9-42E8-9C71-999491E3AFAC` this is the XMP box, whose
      packet starts at `position + headerSize + 16` and ends at
      `position + boxSize` with no extra header. If they equal
      `D8FEC3D6-1B0E-483C-9297-5828877EC481` the file is C2PA signed.
   7. `position += boxSize` — by seeking, not by reading. Never enter `mdat`.
3. Remember the last XMP box whose UTF-8 payload parses as XML. A box that is
   truncated or whose XML is incomplete is ignored, not an error.
4. If no box was remembered, the file has no readable provenance.

Because the loop seeks instead of reading, the number of reads is one per
top-level box (typically four to six) and the bytes read are around 24 per box,
whatever the size of the video.

### Editing an XMP package directly

```dart
final package = XmpPackage.parse(xml);
package.setField(XmpField.rating, 5);
print(package.text); // only the rating changed
```

`setField` writes a scalar, a list or `null`/`undefined` (remove). Passing an
**empty list** also removes the whole field, which is what an editor that
cleared every value of a bag should do:

```dart
package.setField(XmpField.creator, <String>[]); // dc:creator disappears
```

### Writing an edited package back to the file

`writeXmpTextToFile` stores a package the caller already edited. The container
is detected from the file header, and the atomic / in-place rules are the ones
described above — a media file is replaced through a temporary file plus a
rename, an MP4 / MOV can be appended to in place, and a `.xmp` path is written
as a sidecar:

```dart
final package = XmpPackage.parse(readJpegXmpText(bytes)!);
package.setField(XmpField.rating, 5);
await writeXmpTextToFile('photo.jpg', package.text);

// A large shared video: append in place, no temporary file, no full read.
await writeXmpTextToFile(
  'clip.mp4',
  package.text,
  mp4WriteMode: Mp4WriteMode.inPlace,
);
```

The package is parsed before anything is written, so malformed XML throws a
`FormatException` and leaves the file untouched. An unsupported container
throws `UnsupportedError` (write a sidecar instead).

Unlike `MetadataService.embedProvenance` this does **not** apply the write
policy of SPEC §4.6: it does not merge fields, does not refuse to overwrite a
capture field, and does not check C2PA. It stores exactly the package it is
given. Use `MetadataService.embedProvenance` when the spec's policy should be
enforced, and this function when the caller decided the final content.

### AI annotation fields (SPEC §3.7)

`XmpProvenance` carries the three AI fields of spec v0.1.6:

| JSON (SPEC §7) | XMP | Notes |
|---|---|---|
| `aiLabel` | `prov:aiLabel` | Stored verbatim: never translated, never rewritten |
| `aiLabelSource` | `prov:aiLabelSource` | `platform`, `author` or `unknown` |
| `digitalSourceType` | `Iptc4xmpExt:DigitalSourceType` | IPTC newscodes URI |

```dart
final provenance = ProvenanceBuilder(
  assetId: assetId,
  capturedAt: DateTime.now(),
  capturedBy: 'MyApp/1.0.0',
  aiLabel: '内容疑似包含 AI 创作信息', // kept exactly as given
  aiLabelSource: aiLabelSourcePlatform,
).build();
```

When an `aiLabel` is present the builder fills in
`Iptc4xmpExt:DigitalSourceType =
http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia`
— but only when the file has no `DigitalSourceType` yet. All three fields are
capture fields, so an existing value in the file wins over the one being
written (SPEC §4.6). A source value outside the three spec values is read as
`unknown`.

## Public API

| Area | Members |
|---|---|
| Orchestration | `MetadataService.readProvenance`, `readEmbeddedXmp`, `readSidecarXmpText`, `readEmbedded`, `readSidecar`, `detectFormat`, `hasC2pa`, `embedProvenance`, `writeSidecar`; `EmbedResult`, `EmbedErrorCode` |
| Spec | `provenanceSpecVersion` (the implemented spec release, currently `0.1.6`) |
| Model | `XmpProvenance`, `XmpFields` |
| Building | `ProvenanceBuilder`, `generateAssetId`, `truncateDescription`, `maxDescriptionLength` |
| XMP core | `parseXmpFields`, `parseXmpXml`, `mergeProvenance`, `mergeProvenanceXml`, `mergeXmpFields`, `buildXmpXml`, `writeProvenanceIntoPackage`, `updateXmpXml` |
| In-place editing | `XmpPackage`, `escapeAttributeValue`, `escapeText` |
| Edited packages | `writeXmpTextToFile`, `isSidecarPath`, `writeJpegXmpText`, `writePngXmpText`, `writeWebpXmpText`, `writeMp4XmpText`, `writeJpegXmpTextToFile`, `writePngXmpTextToFile`, `writeWebpXmpTextToFile`, `writeMp4XmpTextToFile`, `appendMp4XmpTextInPlace` |
| AI annotation | `XmpProvenance.aiLabel`/`aiLabelSource`/`digitalSourceType`, `aiLabelSourcePlatform`, `aiLabelSourceAuthor`, `aiLabelSourceUnknown`, `normalizeAiLabelSource`, `compositeWithTrainedAlgorithmicMedia`, `iptcExtNsUri` |
| Fields | `XmpField`, `XmpFieldClass`, `XmpValueKind`, namespace URI constants |
| JPEG | `readJpegXmp`, `writeJpegXmp`, `readJpegXmpText`, `scanJpegSegments`, `readJpegXmpFromFile`, `readJpegXmpTextFromFile`, `scanJpegSegmentsFromFile`, `writeJpegXmpToFile`, `JpegSegment`, `xmpApp1Header`, `exifApp1Header`, `maxJpegXmpBytes` |
| PNG | `readPngXmp`, `writePngXmp`, `readPngXmpText`, `readPngXmpTextFromFile`, `scanPngChunks`, `scanPngChunksFromFile`, `readPngXmpFromFile`, `writePngXmpToFile`, `PngChunk`, `pngXmpKeyword`, `crc32` |
| WebP | `readWebpXmp`, `writeWebpXmp`, `readWebpXmpText`, `readWebpXmpTextFromFile`, `scanWebpChunks`, `scanWebpChunksFromFile`, `readWebpXmpFromFile`, `writeWebpXmpToFile`, `WebpChunk`, `webpXmpFourCc`, `webpXmpFlag` |
| MP4 / MOV | `readMp4Xmp`, `writeMp4Xmp`, `readMp4XmpText`, `readMp4XmpTextFromFile`, `readMp4XmpFromFile`, `writeMp4XmpToFile`, `appendMp4XmpInPlace`, `scanMp4Boxes`, `scanMp4BoxesFromFile`, `Mp4BoxReader`, `Mp4Box`, `isMp4Header`, `Mp4WriteMode`, `Mp4WriteException`, `Mp4WriteErrorCode`, `mp4XmpUuid`, `mp4C2paUuid`, `mp4FreeBoxType`, `maxMp4XmpBytes` |
| Sidecar | `sidecarPathFor`, `readSidecarFor`, `readSidecarXmp`, `writeSidecarFor`, `writeSidecarXmp` |
| C2PA | `detectC2pa`, `detectC2paFromFile`, `C2paStatus` |
| Format | `detectFormat`, `detectFormatFromFile`, `MediaFormat` |
| URLs | `normalizeUrl` |
| Dates | `formatDateTimeWithTimezone`, `formatDateTimeUtc` |
| Files | `rewriteFile`, `writeFileAtomically`, `FileRegion`, `FileRewriteException` |
| XML | `parseXmlTree`, `XmlElementNode`, `XmlAttr`, `XmlTextNode` |

## Memory use

Reading looks only at the container header: a JPEG is scanned up to the start
of scan, a PNG or WebP is walked chunk header by chunk header, an MP4 / MOV is
walked top-level box header by top-level box header (seeking over `mdat`), and
nothing but the XMP payload is ever loaded. Writing copies the rest of the file
through a fixed 64 KiB buffer into a temporary file next to the target, flushes
it, and renames it over the original, so the replacement is atomic and a failed
write leaves the original bytes untouched and no temporary file behind. The
MP4 / MOV in-place writer skips even that copy: it appends with a positioned
write and touches only the type bytes of the retired boxes.

Memory use is therefore independent of the file size. The test suite verifies
this with 1 GiB sparse JPEG and PNG files and a 5 GiB sparse MP4 file.

## Modification time

Every writer takes an optional `preserveModificationTime` flag, defaulting to
`false`, so a metadata edit normally looks like a fresh modification:

```dart
await MetadataService.embedProvenance(
  filePath: 'photo.jpg',
  provenance: provenance,
  preserveModificationTime: true, // keep the photo's original timestamp
);
```

The same flag exists on `MetadataService.writeSidecar`, `writeSidecarFor`,
`writeSidecarXmp`, `writeJpegXmpToFile`, `writePngXmpToFile`,
`writeWebpXmpToFile`, `writeMp4XmpToFile`, `appendMp4XmpInPlace`, `rewriteFile`
and `writeFileAtomically`.

## Known behaviour

- **Only `stat` timestamps and bytes survive a write.** Because a write replaces
  the file through a same-directory temporary file plus a rename, everything
  that lives beside the file data is dropped: NTFS alternate data streams
  (including `Zone.Identifier`), macOS extended attributes (including
  `com.apple.metadata:kMDItemWhereFroms`), the file creation time, and any
  hard-link identity. Callers that need those source hints (SPEC §4.5) must
  read them **before** writing.
- **A file locked by another process on Windows.** Windows refuses the rename
  while another process holds the file open without sharing, so the write
  throws `FileRewriteException`. The original file is untouched and no
  temporary file is left behind; the caller should retry later.
- **A crash can leave `.<file name>.provenance-tmp` behind.** The file only ever
  holds a partially written copy and is never the original. Callers that scan a
  directory should ignore that suffix; the next write to the same target
  replaces it. `appendMp4XmpInPlace` never creates a temporary file.
- **An MP4 / MOV whose box chain ends before EOF is refused, unless the last
  box is a half-written XMP box.** If the last top-level box does not end
  exactly at the end of the file — a truncated download, or trailing bytes
  outside any box — a new box appended at EOF could never be reached by a
  conformant reader, so the write fails with
  `Mp4WriteErrorCode.truncatedFile` and the file is left untouched. The one
  exception is an incomplete XMP `uuid` box left by an interrupted append: it
  is truncated away and the write proceeds (SPEC §4.7).
- **An MP4 / MOV with a `size == 0` last box over 4 GiB is refused in place.**
  Making the size explicit needs a 64-bit header, which would shift the media
  data; `appendMp4XmpInPlace` reports
  `Mp4WriteErrorCode.requiresLargeSize`. `writeMp4XmpToFile` can still handle
  it, because it rewrites the file.

## Isolates

Everything in this library is pure Dart with no platform channels, so it can
run inside `Isolate.run` or a worker pool:

- **Safe in any isolate**: `normalizeUrl`, `generateAssetId`,
  `truncateDescription`, all `XmpProvenance` and `XmpFields` methods,
  `ProvenanceBuilder`, `mergeProvenance`, `mergeProvenanceXml`,
  `mergeXmpFields`, and the byte-level `readJpegXmp`, `writeJpegXmp`,
  `readPngXmp`, `writePngXmp`, `readWebpXmp`, `writeWebpXmp`, `readMp4Xmp`,
  `writeMp4Xmp`, `scanMp4Boxes`, `detectC2pa`, `detectFormat`, `parseXmpXml`
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

Implemented for 0.2.2:

- JPEG, PNG, WebP and MP4 / MOV embedded XMP, plus `.xmp` sidecar files.
- Reading and writing a ready-made package (`writeXmpTextToFile`), for callers
  that edited `XmpPackage` themselves.
- SPEC §3.7 AI annotation fields: `prov:aiLabel`, `prov:aiLabelSource` and
  `Iptc4xmpExt:DigitalSourceType`.
- SPEC §4.4 field-by-field merge, §4.6 write policy, §4.7 read and write
  requirements.
- Atomic writes: temporary file in the same directory, flushed, then renamed;
  a failure leaves the original bytes untouched and cleans up. MP4 / MOV also
  supports in-place append with rollback.
- SPEC §10 conformance, including all `spec/test-vectors/` cases.

Not implemented:

- QuickTime `moov/udta/XMP_` (the spec requires the top-level `uuid` box; use a
  sidecar when only the legacy location is available).
- `Zone.Identifier` / xattr source hints (SPEC §4.5).
- `prov:mediaUrl` (reserved by the spec, not implemented).

## License

See the repository for the license.
