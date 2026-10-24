## 0.2.2

Implements provenance-spec **0.1.6**, which adds the AI annotation fields.

### Added

- **`writeXmpTextToFile(path, xml)`**: stores an already-edited XMP package.
  The container is detected from the file header and the existing rules apply
  unchanged — JPEG / PNG / WebP and MP4 / MOV (rewrite mode) go through a
  temporary file plus a rename, MP4 / MOV can be appended in place
  (`mp4WriteMode: Mp4WriteMode.inPlace`), and a `.xmp` path is written as a
  sidecar. The package is parsed first, so malformed XML throws a
  `FormatException` and leaves the file untouched; an unsupported container
  throws `UnsupportedError`. This does **not** apply the write policy of SPEC
  §4.6 — it stores exactly the package it is given.
- **Per-format text writers** behind it: `writeJpegXmpText`,
  `writePngXmpText`, `writeWebpXmpText`, `writeMp4XmpText` (bytes) and
  `writeJpegXmpTextToFile`, `writePngXmpTextToFile`, `writeWebpXmpTextToFile`,
  `writeMp4XmpTextToFile`, `appendMp4XmpTextInPlace` (files), plus
  `isSidecarPath`.
- **AI annotation fields** (SPEC §3.7): `XmpProvenance` gains `aiLabel`,
  `aiLabelSource` (`platform` | `author` | `unknown`) and
  `digitalSourceType`, read and written for JPEG, PNG, WebP and MP4 / MOV, with
  the JSON names of SPEC §7.
- `ProvenanceBuilder` gains `aiLabel` and `aiLabelSource`. A provenance with an
  `aiLabel` implies
  `Iptc4xmpExt:DigitalSourceType` =
  `http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia`,
  but an existing `DigitalSourceType` in the file is never overwritten: all
  three fields are capture fields, so "missing only" applies on both sides of
  a merge.
- Exported `aiLabelSourcePlatform`, `aiLabelSourceAuthor`,
  `aiLabelSourceUnknown`, `normalizeAiLabelSource`,
  `compositeWithTrainedAlgorithmicMedia` and `iptcExtNsUri`.

### Changed

- **`XmpPackage.setField` removes the whole field when given an empty list.**
  An editor that cleared every value of a bag used to leave the empty field
  behind; the field (element and attributes) is now removed.
- `provenanceSpecVersion` is now `'0.1.6'`.
- The spec submodule is pinned to `v0.1.6`.

### Behaviour

- `aiLabel` is stored verbatim — never translated, never rewritten.
- `aiLabelSource` accepts only the three spec values; anything else, including
  a missing value, is read as `unknown`.

### Tests

- The three new vectors pass against their `expected.json`:
  `jpeg-ai-label.jpg`, `jpeg-existing-digitalsourcetype.jpg` and
  `mp4-ai-label.mp4`.
- Writing a provenance with an `aiLabel` to `jpeg-existing-digitalsourcetype.jpg`
  keeps that file's `trainedAlgorithmicMedia`, for JPEG and MP4, in both write
  modes.
- `writeXmpTextToFile` is covered for JPEG, PNG, WebP, MP4 (rewrite and
  in-place), MOV and `.xmp` sidecars: the image / media bytes are unchanged,
  exactly one XMP box ends an MP4, an empty list removes the field, malformed
  XML throws with the file untouched, an unsupported container throws.

## 0.2.1

Implements provenance-spec **0.1.5**, which revises the MP4 / MOV truncation
and recovery rules.

### Fixed

- **A permission error is no longer reported as a format problem.**
  `MetadataService.embedProvenance` now classifies failures explicitly:
  - a structural refusal (`Mp4WriteException` with `notMp4`, `truncatedFile` or
    `requiresLargeSize`, an oversized payload, a malformed container) returns
    `EmbedErrorCode.formatUnsupported`;
  - an I/O or permission failure while opening, reading, writing or truncating
    returns `EmbedErrorCode.writeFailed`.

  The same rule now applies to JPEG, PNG and WebP: a read-only file or a
  read-only directory returns `writeFailed`, never `formatUnsupported`.
- **The original exception is preserved.** `EmbedResult` gains a `cause` field
  holding the exception that failed the write, so a caller can tell
  "Permission denied" from "No space left on device". `EmbedResult.isWriteError`
  was added as a shorthand.

### Added

- **Recovery from an interrupted append** (SPEC §4.7). When the last top-level
  box is an incomplete XMP `uuid` box (at least 24 bytes, type `uuid`, matching
  UUID), both writers truncate it away and write normally instead of refusing
  the file. The incomplete bytes are kept in memory, so a failure during the
  recovery write restores them and leaves the file byte-identical. Any other
  truncation is still refused with `Mp4WriteErrorCode.truncatedFile`.
- **Truncation-tolerant reading** (SPEC §4.7): a complete XMP box before the
  truncation point is still returned, even when a later box is cut short.

### Changed

- `provenanceSpecVersion` is now `'0.1.5'`.
- The spec submodule is pinned to `v0.1.5`.
- `mp4-mdat-uuid-noise.mp4` is now a valid file with a real top-level XMP box,
  so both write interfaces accept it. `mp4-truncated-xmp.mp4` and the new
  `mp4-interrupted-append.mp4` are writable through the recovery rule.

### Tests

- `mp4-interrupted-append.mp4` reads the complete old block and writes cleanly
  through both interfaces, with the media bytes unchanged.
- A simulated kill mid-append (half a box written directly, no rollback) is
  repaired by the next in-place write.
- Rollback is byte-identical for the interrupted-append file at all three
  failure points.
- Read-only MP4 (both modes), JPEG, PNG and WebP return `writeFailed` with the
  original `FileSystemException` / `FileRewriteException` in `cause`.

## 0.2.0

Implements provenance-spec **0.1.4**, which adds MP4 / MOV support.

### Added

- **MP4 and MOV embedded XMP** (SPEC §4.1, §4.7). XMP lives in a top-level
  `uuid` box with the extended type `BE7ACFCB-97A9-42E8-9C71-999491E3AFAC`,
  followed directly by the XMP packet with no extra header. `MediaFormat` gains
  `mp4`, covering both MP4 and QuickTime MOV, and `MetadataService` reads and
  writes it like the image formats.
- `lib/src/xmp_mp4.dart`, exported from `package:provenance_dart`:
  - `scanMp4Boxes` / `scanMp4BoxesFromFile` and `Mp4Box` — the top-level box
    chain, including 64-bit `largesize` headers and `size == 0` boxes that run
    to the end of the file. Payloads are never read.
  - `Mp4BoxReader` — the step-by-step, one-header-per-call primitive that the
    Kotlin and Rust implementations should mirror.
  - `isMp4Header` — shallow container sniffing used by `detectFormat`.
  - `readMp4Xmp`, `readMp4XmpFromFile`, `readMp4XmpText`,
    `readMp4XmpTextFromFile` — the last well-formed XMP box wins; a truncated
    or malformed package returns `null` instead of throwing.
  - `writeMp4Xmp` (bytes in, bytes out), `writeMp4XmpToFile` (file replacement
    through a temporary file plus a rename) and `appendMp4XmpInPlace`
    (`RandomAccessFile` append, no temporary file, no full-file read).
  - `Mp4WriteMode`, used as the new `mp4WriteMode` argument of
    `MetadataService.embedProvenance`.
  - `Mp4WriteException` and `Mp4WriteErrorCode` (`fileNotFound`, `notMp4`,
    `truncatedFile`, `requiresLargeSize`).
  - `mp4XmpUuid`, `mp4C2paUuid`, `mp4FreeBoxType`, `maxMp4XmpBytes`.
- **C2PA detection for MP4** (SPEC §4.3): a top-level `uuid` box with the C2PA
  type `D8FEC3D6-1B0E-483C-9297-5828877EC481` (or a `c2pa` box) makes
  `hasC2pa` return `true`, so `embedProvenance` skips the write and the caller
  uses a sidecar.

### Writing an MP4 / MOV

- The new XMP box is appended at the end of the file; every old XMP box keeps
  its bytes and only its 4-byte type changes to `free`. `mdat` and the rest of
  the media data are never re-encoded or moved.
- `appendMp4XmpInPlace` orders the work so an interruption cannot lose data:
  first a `size == 0` last box gets its real size, then the new box is appended
  and flushed, and only then are the old boxes retired. Any failure truncates
  the file back to its original length and restores every byte it changed.
- A truncated file, or one whose box chain ends before EOF, is refused with
  `Mp4WriteErrorCode.truncatedFile`: a box appended after unreachable bytes
  could never be found by a conformant reader. A `size == 0` last box larger
  than 4 GiB is refused with `requiresLargeSize`, because making it explicit
  would need a 64-bit header in the middle of the file.

### Changed

- `provenanceSpecVersion` is now `'0.1.4'`.
- `detectFormatFromFile` reads 16 header bytes instead of 12, so a 64-bit box
  header can be recognised.
- The spec submodule is pinned to `v0.1.4`.

### Tests

- All 11 `spec/test-vectors/` video cases match their `expected.json`
  (`_none: true` means an empty result, not an exception).
- For every writable vector and both write interfaces: the original boxes are
  byte-identical, exactly one XMP box sits at EOF, old XMP boxes became `free`
  with their other bytes unchanged, `photoshop:Headline` survives, the file
  reads back, and a second write still leaves one XMP box.
- In-place rollback is forced at three points (during the append, before the
  type patch, after the type patch) and the file is byte-identical afterwards.
- A 5 GiB sparse file checks 64-bit lengths, skipping and bounded memory.

## 0.1.1

### Fixed

- **PNG truncated chunk (`scanPngChunks`).** A final chunk whose declared
  length runs past the end of the data is now reported with
  `dataStop = min(dataStart + length, bytes.length)`. The previous code always
  subtracted four bytes for a CRC, but a truncated file usually has no trailing
  CRC, so the last four bytes of the XML were deleted and `readPngXmp` threw
  `FormatException` (reported by EasySave 0.1.0). `scanPngChunksFromFile` now
  reports the same truncated chunk instead of silently dropping it.
- **Truncated XMP is reported as "no readable provenance".** `readPngXmp` and
  `readPngXmpFromFile` return `null` when a truncated package cannot be parsed,
  instead of throwing an uncaught `FormatException`. JPEG and WebP were checked:
  neither has a CRC-based length assumption, and their scanners already skip an
  incomplete final segment or chunk, so their readers return `null`.

### Added

- `provenanceSpecVersion` (`'0.1.3'`), the spec release this package
  implements, so other projects can reference it instead of hard-coding the
  string. It is distinct from `prov:schema`, which stays `0.1`.
- Tests for complete, CRC-less and half-written PNG chunks, plus truncated
  JPEG and WebP segments.

## 0.1.0

First release: a pure Dart implementation of provenance-spec 0.1.3, extracted
from EasySave's `feature/v1.7` metadata modules.

### Added

- Reading and writing provenance XMP in JPEG (APP1), PNG (`iTXt`) and WebP
  (`XMP ` chunk) files, and in `.xmp` sidecar files.
- `MetadataService` for format detection, C2PA checks, reading, merging and
  embedding.
- `ProvenanceBuilder` for building a record from download or import context.
- In-place XMP editing (`XmpPackage`) that changes only the fields of the spec
  and preserves every other byte of the package (SPEC §4.7 write requirement 1).
- Field-by-field merge of embedded metadata and sidecar files (SPEC §4.4).
- In-place editing of an existing sidecar; a new one is created only when there
  is none (SPEC §4.7).
- Header-only, asynchronous reads over `RandomAccessFile`: a JPEG is scanned up
  to the start of scan, a PNG or WebP is walked chunk header by chunk header.
  Memory use does not grow with the file size.
- Streaming file writes through a fixed 64 KiB buffer and a temporary file in
  the same directory, which is flushed and then renamed over the original, so
  a failed write leaves the original bytes untouched and no temporary file
  behind.
- Optional `preserveModificationTime` on `rewriteFile`, `writeFileAtomically`,
  the `...ToFile` writers, `writeSidecar`, `writeSidecarFor`,
  `writeSidecarXmp` and `MetadataService.embedProvenance`.
- C2PA content credential detection for JPEG, PNG and WebP (SPEC §4.3).
- URL normalization for `prov:sourceUrl` (SPEC §5).
- ISO 8601 date formatting that always carries a timezone (SPEC §8).

### Conformance

Passes all six requirements of SPEC §10, including every case of
`spec/test-vectors/` and `spec/test-vectors/urls.json`.

### Changes relative to the EasySave implementation

- **Streaming reads.** EasySave read whole files into memory; this package reads
  only the container header and the XMP payload.
- **In-place XMP editing.** EasySave regenerated the whole XMP package from its
  data model, which reflowed attributes and re-encoded non-ASCII text. This
  package splices only the fields of the spec into the original XML.
- **Strict JPEG APP1 identification.** The 29-byte
  `http://ns.adobe.com/xap/1.0/\0` marker is compared byte for byte, and EXIF
  and other APP1 segments are skipped without being decoded as text
  (SPEC §4.7 read requirement 6, added in spec 0.1.3).
- **EXIF preservation.** Writing XMP inserts or replaces only the XMP APP1
  segment; EXIF and every other segment are copied byte for byte
  (SPEC §4.7 write requirement 4, added in spec 0.1.3).
- **Field-by-field merge (SPEC §4.4).** A field present on only one side is
  taken from that side, whether it is a capture or a user field. Only a real
  conflict — both sides present with different values — uses the rule "capture
  fields from the embedded metadata, user fields from the newer
  `xmp:MetadataDate`". So a file whose embedded XMP carries no `prov` fields
  still gets every capture field, and its `assetId`, from the sidecar.
  `mergeProvenanceXml` / `mergeXmpFields` operate on the raw XML so this works
  even when the embedded package has no provenance metadata at all.
- **Fields are identified by namespace URI only.** EasySave also fell back to
  the local name, which could pick up a field from an unrelated namespace.
- **Write policy follows SPEC §4.6.** Capture fields are only added when
  absent, never overwritten; `prov:assetId` is never changed; user fields are
  written when the caller supplies a value.
- **Atomic writes.** EasySave overwrote the target file in place. Every write
  here goes to a temporary file next to the target, is flushed, and is then
  renamed over it; a failure at any point before the rename deletes the
  temporary file and leaves the original bytes exactly as they were.
- **UTC dates keep `Z`.** EasySave converted every date to local time; this
  package writes a UTC `DateTime` with `Z` and a local one with its offset.
- **No application-specific rules.** The `xhs` → `xiaohongshu` platform map,
  the localized platform display names and the "X authorId must be numeric"
  rule stay in EasySave. `ProvenanceBuilder` takes `capturedBy` and
  `creditPlatformName` from the caller.
- **`prov:sourceUrl` is optional** (spec 0.1.2). `dc:source` is omitted when
  there is no source URL, and `baidupan` / `onedrive` sources are supported
  without one.
- **`prov:sourceId` is opaque** (spec 0.1.3). It is never parsed, so a OneDrive
  `{driveId}!{id}` value is stored and returned unchanged.

### Not implemented

- MP4 / MOV `uuid` box.
- `Zone.Identifier` / xattr source hints (SPEC §4.5).
- `prov:mediaUrl` (reserved by the spec, not implemented).
