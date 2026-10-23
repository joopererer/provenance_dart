/// A pure Dart implementation of [provenance-spec](https://github.com/joopererer/provenance-spec) 0.1.
///
/// Reads and writes provenance metadata — where a file came from, who made it,
/// when it was captured — as XMP inside JPEG, PNG and WebP files, and in
/// `.xmp` sidecar files.
///
/// ## Reading
///
/// ```dart
/// final provenance = await MetadataService.readProvenance('photo.jpg');
/// print(provenance?.toJson());
/// ```
///
/// [MetadataService.readProvenance] merges the embedded metadata with the
/// sidecar file field by field (SPEC §4.4): a field present on only one side is
/// taken from that side; a field present on both sides with different values
/// keeps the embedded value when it is a capture field, and the value of the
/// newer `xmp:MetadataDate` when it is a user field.
///
/// ## Writing
///
/// ```dart
/// final provenance = ProvenanceBuilder(
///   platform: 'xiaohongshu',
///   capturedBy: 'MyApp/1.0.0',
///   sourceId: '6ad2f7050000000012034042',
///   sourceUrl: 'https://www.xiaohongshu.com/explore/6ad2f7050000000012034042',
///   authorName: '示例作者',
///   creditPlatformName: '小红书',
/// ).build();
///
/// final result = await MetadataService.embedProvenance(
///   filePath: 'photo.jpg',
///   provenance: provenance,
/// );
/// if (result.skippedC2pa || result.isFormatError) {
///   await MetadataService.writeSidecar('photo.jpg', provenance);
/// }
/// ```
///
/// ## Memory use
///
/// Reading looks only at the container header: a JPEG is scanned up to the
/// start of scan, a PNG or WebP is walked chunk header by chunk header, and
/// nothing but the XMP payload is ever loaded. Writing copies the rest of the
/// file through a fixed 64 KiB buffer into a temporary file next to the target,
/// flushes it, and renames it over the original, so the replacement is atomic
/// and a failed write leaves the original untouched
/// ([FileRewriteException]).
///
/// ## Modification time
///
/// Every writer takes an optional `preserveModificationTime` argument,
/// defaulting to `false`. Set it to keep the original timestamp instead of
/// making the file look freshly modified.
///
/// ## Isolates
///
/// Everything in this library is pure Dart with no platform channels, so it
/// can run inside [Isolate.run] or a worker pool:
///
/// * **Safe in any isolate**: [normalizeUrl], [generateAssetId],
///   [truncateDescription], all `XmpProvenance` methods, [mergeProvenance],
///   [mergeProvenanceXml], [mergeXmpFields], [ProvenanceBuilder], and the
///   byte-level `readJpegXmp`, `writeJpegXmp`, `readPngXmp`, `writePngXmp`,
///   `readWebpXmp`, `writeWebpXmp`, `detectC2pa`, [detectFormat],
///   [parseXmpXml] and [buildXmpXml]. They take and return plain values and
///   share no mutable state.
/// * **Safe in any isolate, but will perform file I/O there**:
///   [MetadataService] and the `...ToFile` / `...FromFile` functions,
///   `readSidecarXmp` and `writeSidecarXmp`. Each call opens and closes its own
///   handle; nothing is cached across calls. Handles cannot be passed between
///   isolates, so open the file in the isolate that uses it.
/// * **Time zone dependent**: [formatDateTimeWithTimezone] writes the local
///   offset of the current isolate for non-UTC values. Isolates share the
///   process time zone, but a UTC [DateTime] is preferred for reproducible
///   output.
library;

export 'src/c2pa_detector.dart' show C2paStatus, detectC2pa, detectC2paFromFile;
export 'src/date_formatter.dart'
    show formatDateTimeUtc, formatDateTimeWithTimezone;
export 'src/file_rewriter.dart'
    show FileRegion, FileRewriteException, rewriteFile, writeFileAtomically;
export 'src/media_format.dart'
    show MediaFormat, detectFormat, detectFormatFromFile;
export 'src/metadata_service.dart'
    show EmbedErrorCode, EmbedResult, MetadataService;
export 'src/provenance_builder.dart'
    show
        ProvenanceBuilder,
        generateAssetId,
        maxDescriptionLength,
        truncateDescription;
export 'src/spec_version.dart' show provenanceSpecVersion;
export 'src/url_normalizer.dart' show normalizeUrl;
export 'src/xmp_core.dart'
    show
        buildXmpXml,
        mergeProvenance,
        mergeProvenanceXml,
        mergeXmpFields,
        parseXmpFields,
        parseXmpXml,
        updateXmpXml,
        writeProvenanceIntoPackage;
export 'src/xmp_fields.dart'
    show
        XmpField,
        XmpFieldClass,
        XmpValueKind,
        adobeMetaNsUri,
        dcNsUri,
        photoshopNsUri,
        provNsUri,
        rdfNsUri,
        xmlNsUri,
        xmpNsUri;
export 'src/xmp_jpeg.dart'
    show
        JpegSegment,
        exifApp1Header,
        maxJpegXmpBytes,
        readJpegXmp,
        readJpegXmpFromFile,
        readJpegXmpText,
        scanJpegSegments,
        scanJpegSegmentsFromFile,
        writeJpegXmp,
        writeJpegXmpToFile,
        xmpApp1Header;
export 'src/xmp_model.dart' show XmpFields, XmpProvenance;
export 'src/xmp_package.dart' show XmpPackage, escapeAttributeValue, escapeText;
export 'src/xmp_png.dart'
    show
        PngChunk,
        crc32,
        pngXmpKeyword,
        readPngXmp,
        readPngXmpFromFile,
        readPngXmpText,
        scanPngChunks,
        scanPngChunksFromFile,
        writePngXmp,
        writePngXmpToFile;
export 'src/xmp_sidecar.dart'
    show
        readSidecarFor,
        readSidecarXmp,
        sidecarPathFor,
        writeSidecarFor,
        writeSidecarXmp;
export 'src/xmp_webp.dart'
    show
        WebpChunk,
        readWebpXmp,
        readWebpXmpFromFile,
        readWebpXmpText,
        scanWebpChunks,
        scanWebpChunksFromFile,
        webpXmpFlag,
        webpXmpFourCc,
        writeWebpXmp,
        writeWebpXmpToFile;
export 'src/xml_scanner.dart'
    show XmlAttr, XmlElementNode, XmlTextNode, parseXmlTree;
