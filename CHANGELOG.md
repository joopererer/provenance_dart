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
