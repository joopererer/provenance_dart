// Namespace URIs and the field registry of provenance-spec 0.1 (SPEC §2, §3).
//
// Fields are always identified by namespace URI plus local name, never by
// prefix (SPEC §4.7 read requirement 4).

/// Namespace URI of the `prov` fields (SPEC §2).
const String provNsUri = 'https://joopererer.github.io/provenance-spec/ns/';

/// Namespace URI of Dublin Core (SPEC §2).
const String dcNsUri = 'http://purl.org/dc/elements/1.1/';

/// Namespace URI of the XMP basic schema (SPEC §2).
const String xmpNsUri = 'http://ns.adobe.com/xap/1.0/';

/// Namespace URI of the Photoshop schema, used for `photoshop:Credit`.
const String photoshopNsUri = 'http://ns.adobe.com/photoshop/1.0/';

/// Namespace URI of the IPTC extension schema (SPEC §2), used for
/// `Iptc4xmpExt:DigitalSourceType`.
const String iptcExtNsUri = 'http://iptc.org/std/Iptc4xmpExt/2008-02-29/';

/// Namespace URI of RDF, used for `rdf:RDF`, `rdf:Description` and containers.
const String rdfNsUri = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#';

/// Namespace URI of the XML namespace, used for `xml:lang`.
const String xmlNsUri = 'http://www.w3.org/XML/1998/namespace';

/// Namespace URI of the XMP meta wrapper, used for `x:xmpmeta`.
const String adobeMetaNsUri = 'adobe:ns:meta/';

/// How a field is represented inside an `rdf:Description`.
enum XmpValueKind {
  /// A single text value, written as an attribute or as a text-only element.
  scalar,

  /// Localized text, written as `<rdf:Alt><rdf:li xml:lang="x-default">`.
  altText,

  /// An ordered list, written as `<rdf:Seq><rdf:li>`.
  sequence,

  /// An unordered list, written as `<rdf:Bag><rdf:li>`.
  bag,
}

/// Whether a field is fixed at capture time or may be edited by the user.
enum XmpFieldClass {
  /// Set when the file is first captured; never modified afterwards.
  capture,

  /// Editable by the user at any time.
  user,

  /// Updated by the software on every write.
  system,
}

/// A field of provenance-spec 0.1, identified by namespace URI and local name.
enum XmpField {
  /// `prov:schema` — spec version, currently `"0.1"`.
  schema(provNsUri, 'schema', XmpValueKind.scalar, XmpFieldClass.system),

  /// `prov:assetId` — permanent identity of the file.
  assetId(provNsUri, 'assetId', XmpValueKind.scalar, XmpFieldClass.capture),

  /// `prov:capturedAt` — when the file was first captured.
  capturedAt(
    provNsUri,
    'capturedAt',
    XmpValueKind.scalar,
    XmpFieldClass.capture,
  ),

  /// `prov:capturedBy` — software and version that first wrote the metadata.
  capturedBy(
    provNsUri,
    'capturedBy',
    XmpValueKind.scalar,
    XmpFieldClass.capture,
  ),

  /// `xmp:MetadataDate` — when this metadata was last modified.
  metadataDate(
    xmpNsUri,
    'MetadataDate',
    XmpValueKind.scalar,
    XmpFieldClass.system,
  ),

  /// `prov:sourceUrl` — normalized source page URL (SPEC §5).
  sourceUrl(provNsUri, 'sourceUrl', XmpValueKind.scalar, XmpFieldClass.capture),

  /// `prov:platform` — platform identifier (SPEC §3.5).
  platform(provNsUri, 'platform', XmpValueKind.scalar, XmpFieldClass.capture),

  /// `prov:sourceId` — opaque native ID on the platform (SPEC §3.5).
  sourceId(provNsUri, 'sourceId', XmpValueKind.scalar, XmpFieldClass.capture),

  /// `prov:itemIndex` — 1-based position in a multi-item source.
  itemIndex(provNsUri, 'itemIndex', XmpValueKind.scalar, XmpFieldClass.capture),

  /// `prov:itemCount` — number of items in the source.
  itemCount(provNsUri, 'itemCount', XmpValueKind.scalar, XmpFieldClass.capture),

  /// `prov:authorId` — stable author ID on the platform.
  authorId(provNsUri, 'authorId', XmpValueKind.scalar, XmpFieldClass.capture),

  /// `prov:publishedAt` — when the source content was published.
  publishedAt(
    provNsUri,
    'publishedAt',
    XmpValueKind.scalar,
    XmpFieldClass.capture,
  ),

  /// `prov:pairId` — shared by the image and video of a Live Photo.
  pairId(provNsUri, 'pairId', XmpValueKind.scalar, XmpFieldClass.capture),

  /// `dc:title` — title.
  title(dcNsUri, 'title', XmpValueKind.altText, XmpFieldClass.user),

  /// `dc:creator` — ordered list of author display names.
  creator(dcNsUri, 'creator', XmpValueKind.sequence, XmpFieldClass.user),

  /// `dc:description` — caption, at most 2000 characters.
  description(dcNsUri, 'description', XmpValueKind.altText, XmpFieldClass.user),

  /// `dc:subject` — unordered list of tags.
  subject(dcNsUri, 'subject', XmpValueKind.bag, XmpFieldClass.user),

  /// `xmp:Rating` — rating from 0 to 5.
  rating(xmpNsUri, 'Rating', XmpValueKind.scalar, XmpFieldClass.user),

  /// `dc:source` — mirror of `prov:sourceUrl` for software that ignores `prov`.
  dcSource(dcNsUri, 'source', XmpValueKind.scalar, XmpFieldClass.capture),

  /// `photoshop:Credit` — credit line `author / platform`.
  credit(photoshopNsUri, 'Credit', XmpValueKind.scalar, XmpFieldClass.capture),

  /// `prov:aiLabel` — the AI disclosure text shown by the platform, verbatim
  /// (SPEC §3.7).
  aiLabel(provNsUri, 'aiLabel', XmpValueKind.scalar, XmpFieldClass.capture),

  /// `prov:aiLabelSource` — who made the disclosure: `platform`, `author` or
  /// `unknown` (SPEC §3.7).
  aiLabelSource(
    provNsUri,
    'aiLabelSource',
    XmpValueKind.scalar,
    XmpFieldClass.capture,
  ),

  /// `Iptc4xmpExt:DigitalSourceType` — the IPTC digital source type URI
  /// (SPEC §3.4). Added only when absent; an existing value is never
  /// overwritten.
  digitalSourceType(
    iptcExtNsUri,
    'DigitalSourceType',
    XmpValueKind.scalar,
    XmpFieldClass.capture,
  );

  const XmpField(this.namespaceUri, this.localName, this.kind, this.fieldClass);

  /// Namespace URI that identifies this field.
  final String namespaceUri;

  /// Local name inside [namespaceUri].
  final String localName;

  /// How the value is represented in the XML.
  final XmpValueKind kind;

  /// Whether the field is a capture, user or system field.
  final XmpFieldClass fieldClass;

  /// The conventional prefix, used only when a new declaration is needed.
  String get preferredPrefix => switch (namespaceUri) {
    provNsUri => 'prov',
    dcNsUri => 'dc',
    xmpNsUri => 'xmp',
    photoshopNsUri => 'photoshop',
    iptcExtNsUri => 'Iptc4xmpExt',
    _ => 'ns',
  };

  /// The qualified name with the conventional prefix, for example `prov:schema`.
  String get qualifiedName => '$preferredPrefix:$localName';

  /// Looks up a field by namespace URI and local name.
  ///
  /// Returns `null` for fields this implementation does not know, which the
  /// caller must preserve untouched (SPEC §1 principle 5).
  static XmpField? lookup(String? namespaceUri, String localName) {
    if (namespaceUri == null) return null;
    for (final field in values) {
      if (field.namespaceUri == namespaceUri && field.localName == localName) {
        return field;
      }
    }
    return null;
  }
}
