// Reading, merging and writing XMP packages (SPEC §4.4, §4.6, §4.7).

import 'xmp_fields.dart';
import 'xmp_model.dart';
import 'xmp_package.dart';
import 'xml_scanner.dart';

/// Reads every field of this spec from [xml].
///
/// Supports attribute syntax, child-element syntax, several
/// `rdf:Description` blocks, any namespace prefix and XML entities
/// (SPEC §4.7 read requirements 1–5). Fields are identified by namespace URI,
/// never by prefix.
///
/// Never throws for missing fields: an XMP package without provenance data
/// yields an empty [XmpFields]. Throws [FormatException] only when [xml] is not
/// well-formed.
XmpFields parseXmpFields(String xml) {
  final root = parseXmlTree(xml);
  final values = <XmpField, Object?>{};
  final rawText = <XmpField, String>{};
  final otherFields = <String, String>{};

  final descriptions = root.descendants.where(
    (n) => n.namespaceUri == rdfNsUri && n.localName == 'Description',
  );

  for (final description in descriptions) {
    for (final attribute in description.attributes) {
      if (attribute.isNamespaceDeclaration) continue;
      if (attribute.namespaceUri == rdfNsUri &&
          attribute.localName == 'about') {
        continue;
      }
      final field = XmpField.lookup(
        attribute.namespaceUri,
        attribute.localName,
      );
      if (field == null) {
        _recordForeign(
          otherFields,
          attribute.namespaceUri,
          attribute.localName,
          attribute.value,
        );
        continue;
      }
      if (values.containsKey(field)) continue;
      values[field] = attribute.value;
      rawText[field] = attribute.value;
    }

    for (final child in description.children) {
      final field = XmpField.lookup(child.namespaceUri, child.localName);
      if (field == null) {
        _recordForeign(
          otherFields,
          child.namespaceUri,
          child.localName,
          _elementText(child),
        );
        continue;
      }
      if (values.containsKey(field)) continue;
      final value = _readElementValue(child, field.kind);
      if (value == null) continue;
      values[field] = value;
      if (value is String) rawText[field] = value;
    }
  }

  return XmpFields(values: values, otherFields: otherFields, rawText: rawText);
}

/// Reads the provenance record from [xml].
///
/// Returns `null` when the package carries no provenance metadata, that is
/// when `prov:assetId`, `prov:capturedAt` or `prov:capturedBy` is missing.
XmpProvenance? parseXmpXml(String xml) =>
    XmpProvenance.fromFields(parseXmpFields(xml));

/// Merges the embedded and sidecar records of one file (SPEC §4.4).
///
/// Capture fields come from [embedded]; user fields come from whichever side
/// has the newer `xmp:MetadataDate`. When only one side exists it is returned
/// unchanged, so the original date text survives.
XmpProvenance? mergeProvenance(
  XmpProvenance? embedded,
  XmpProvenance? sidecar,
) {
  if (embedded == null) return sidecar;
  if (sidecar == null) return embedded;

  final sidecarIsNewer = sidecar.metadataDate.isAfter(embedded.metadataDate);
  final mergedOtherFields = <String, String>{
    ...sidecar.otherFields,
    ...embedded.otherFields,
  };

  if (!sidecarIsNewer) {
    return embedded.copyWith(
      title: embedded.title ?? sidecar.title,
      creators: embedded.creators ?? sidecar.creators,
      description: embedded.description ?? sidecar.description,
      subject: embedded.subject ?? sidecar.subject,
      rating: embedded.rating ?? sidecar.rating,
      otherFields: mergedOtherFields,
    );
  }

  return embedded.copyWith(
    metadataDate: sidecar.metadataDate,
    title: sidecar.title ?? embedded.title,
    creators: sidecar.creators ?? embedded.creators,
    description: sidecar.description ?? embedded.description,
    subject: sidecar.subject ?? embedded.subject,
    rating: sidecar.rating ?? embedded.rating,
    otherFields: mergedOtherFields,
  );
}

/// Builds a complete XMP package from [provenance].
///
/// This regenerates the whole package, so it must only be used when no
/// existing package is available. To update a file that already has XMP, use
/// [writeProvenanceIntoPackage] instead (SPEC §4.7 write requirement 1).
String buildXmpXml(XmpProvenance provenance) {
  final package = XmpPackage.empty();
  writeProvenanceIntoPackage(package, provenance);
  return package.text;
}

/// Writes [provenance] into an existing package, editing it in place.
///
/// Follows SPEC §4.6:
/// * capture fields are only added when absent, never overwritten;
/// * user fields are written when [provenance] supplies a value, which is how
///   a caller signals that the user changed them;
/// * `xmp:MetadataDate` is always updated;
/// * every other node, attribute and namespace declaration is left untouched.
void writeProvenanceIntoPackage(XmpPackage package, XmpProvenance provenance) {
  provenance.toFields().forEach((field, value) {
    if (value == null) return;
    if (field.fieldClass == XmpFieldClass.capture && package.hasField(field)) {
      return;
    }
    package.setField(field, value);
  });
  provenance.otherFields.forEach(package.setQualifiedField);
}

/// Updates [xml] in place with [provenance] and returns the new XML.
///
/// Falls back to [buildXmpXml] when [xml] is not a well-formed package.
String updateXmpXml(String xml, XmpProvenance provenance) {
  try {
    final package = XmpPackage.parse(xml);
    writeProvenanceIntoPackage(package, provenance);
    return package.text;
  } on FormatException {
    return buildXmpXml(provenance);
  }
}

Object? _readElementValue(XmlElementNode element, XmpValueKind kind) {
  switch (kind) {
    case XmpValueKind.scalar:
      final text = element.text;
      return text.isEmpty ? null : text;
    case XmpValueKind.altText:
      final alt = element.find(rdfNsUri, 'Alt');
      if (alt != null) {
        final items = alt.children
            .where((c) => c.namespaceUri == rdfNsUri && c.localName == 'li')
            .toList();
        if (items.isNotEmpty) {
          final preferred = items.firstWhere(
            (li) => li.attribute(xmlNsUri, 'lang')?.value == 'x-default',
            orElse: () => items.first,
          );
          return preferred.text;
        }
      }
      final text = element.text;
      return text.isEmpty ? null : text;
    case XmpValueKind.sequence:
    case XmpValueKind.bag:
      final containerName = kind == XmpValueKind.sequence ? 'Seq' : 'Bag';
      final container = element.find(rdfNsUri, containerName);
      if (container != null) {
        return container.children
            .where((c) => c.namespaceUri == rdfNsUri && c.localName == 'li')
            .map((li) => li.text)
            .toList();
      }
      final text = element.text;
      return text.isEmpty ? null : [text];
  }
}

String _elementText(XmlElementNode element) {
  final direct = element.text;
  if (direct.isNotEmpty) return direct;
  final items = element.descendants
      .where((n) => n.namespaceUri == rdfNsUri && n.localName == 'li')
      .map((n) => n.text)
      .where((t) => t.isNotEmpty)
      .toList();
  return items.join(', ');
}

void _recordForeign(
  Map<String, String> target,
  String? namespaceUri,
  String localName,
  String value,
) {
  final prefix = _conventionalPrefix(namespaceUri);
  if (prefix == null) return;
  target.putIfAbsent('$prefix:$localName', () => value);
}

String? _conventionalPrefix(String? namespaceUri) => switch (namespaceUri) {
  provNsUri => 'prov',
  dcNsUri => 'dc',
  xmpNsUri => 'xmp',
  photoshopNsUri => 'photoshop',
  _ => null,
};
