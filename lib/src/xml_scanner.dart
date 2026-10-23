// An offset-aware XML tree built on top of `package:xml`'s event parser.
//
// SPEC §4.7 write requirement 1 forbids regenerating the XMP package from a
// data model: only the fields of this spec may change, every other byte must
// survive. `XmlDocument.parse(...).toXmlString()` cannot do that (it reflows
// attributes and re-encodes non-ASCII text), so this scanner keeps the exact
// source offsets of every start tag, end tag, attribute value and text run and
// lets callers splice the original string.

import 'package:xml/xml_events.dart';

/// An attribute of an element, with the source range of its value.
class XmlAttr {
  /// Creates an attribute record.
  const XmlAttr({
    required this.qualifiedName,
    required this.prefix,
    required this.localName,
    required this.namespaceUri,
    required this.value,
    required this.nameStart,
    required this.valueStart,
    required this.valueStop,
    required this.quote,
  });

  /// The name as written, for example `prov:schema`.
  final String qualifiedName;

  /// The namespace prefix, or `null` when the name has none.
  final String? prefix;

  /// The local name, for example `schema`.
  final String localName;

  /// The resolved namespace URI, or `null` when the name has none.
  final String? namespaceUri;

  /// The entity-decoded value.
  final String value;

  /// Offset of the first character of the attribute name.
  final int nameStart;

  /// Offset of the first character inside the quotes.
  final int valueStart;

  /// Offset of the closing quote.
  final int valueStop;

  /// The quote character used in the source, `"` or `'`.
  final String quote;

  /// Whether this attribute is a namespace declaration.
  bool get isNamespaceDeclaration =>
      qualifiedName == 'xmlns' || prefix == 'xmlns';
}

/// A run of character data, with its source range.
class XmlTextNode {
  /// Creates a text record.
  const XmlTextNode({
    required this.start,
    required this.stop,
    required this.raw,
    required this.decoded,
  });

  /// Offset of the first character.
  final int start;

  /// Offset just past the last character.
  final int stop;

  /// The source text, still containing entity references.
  final String raw;

  /// The text with entity references restored (SPEC §4.7 read requirement 5).
  final String decoded;
}

/// An element, with the source ranges needed to edit it in place.
class XmlElementNode {
  /// Creates an element record.
  XmlElementNode({
    required this.qualifiedName,
    required this.prefix,
    required this.localName,
    required this.namespaceUri,
    required this.startTagStart,
    required this.startTagStop,
    required this.isSelfClosing,
    required this.attributes,
  });

  /// The name as written, for example `rdf:Description`.
  final String qualifiedName;

  /// The namespace prefix, or `null` when the name has none.
  final String? prefix;

  /// The local name, for example `Description`.
  final String localName;

  /// The resolved namespace URI, or `null` when the name has none.
  final String? namespaceUri;

  /// Offset of the `<` that opens the start tag.
  final int startTagStart;

  /// Offset just past the `>` that closes the start tag.
  final int startTagStop;

  /// Whether the element is written as `<name/>`.
  final bool isSelfClosing;

  /// Attributes in source order.
  final List<XmlAttr> attributes;

  /// Child elements in source order.
  final List<XmlElementNode> children = [];

  /// Direct text runs in source order.
  final List<XmlTextNode> texts = [];

  /// The parent element, or `null` for the root.
  XmlElementNode? parent;

  /// Offset of the `<` that opens the end tag, or `null` when self-closing.
  int? endTagStart;

  /// Offset just past the `>` that closes the end tag, or `null`.
  int? endTagStop;

  /// The concatenated decoded text of the direct text children.
  String get text => texts.map((t) => t.decoded).join();

  /// All descendant elements, depth first, excluding this one.
  Iterable<XmlElementNode> get descendants sync* {
    for (final child in children) {
      yield child;
      yield* child.descendants;
    }
  }

  /// The first descendant with the given namespace URI and local name.
  XmlElementNode? find(String? namespaceUri, String localName) {
    for (final node in descendants) {
      if (node.namespaceUri == namespaceUri && node.localName == localName) {
        return node;
      }
    }
    return null;
  }

  /// The attribute with the given namespace URI and local name, if any.
  XmlAttr? attribute(String? namespaceUri, String localName) {
    for (final attr in attributes) {
      if (attr.namespaceUri == namespaceUri && attr.localName == localName) {
        return attr;
      }
    }
    return null;
  }

  /// The namespace prefixes declared on this element, mapped to their URIs.
  Map<String, String> get namespaceDeclarations {
    final result = <String, String>{};
    for (final attr in attributes) {
      if (!attr.isNamespaceDeclaration) continue;
      final prefix = attr.qualifiedName == 'xmlns' ? '' : attr.localName;
      result[prefix] = attr.value;
    }
    return result;
  }

  /// Resolves the prefix bound to [namespaceUri] at this element, if any.
  ///
  /// Walks outwards through the ancestors so that a declaration on `rdf:RDF`
  /// is found for a field inserted into `rdf:Description`.
  String? prefixFor(String namespaceUri) {
    XmlElementNode? node = this;
    while (node != null) {
      for (final entry in node.namespaceDeclarations.entries) {
        if (entry.value == namespaceUri && entry.key.isNotEmpty) {
          return entry.key;
        }
      }
      node = node.parent;
    }
    return null;
  }
}

/// Parses [source] into an offset-aware tree.
///
/// Throws [XmlParserException] or [XmlTagException] when the input is not
/// well-formed XML.
XmlElementNode parseXmlTree(String source) {
  final events = parseEvents(
    source,
    withLocation: true,
    withNamespace: true,
    validateNesting: true,
  );

  XmlElementNode? root;
  final stack = <XmlElementNode>[];

  for (final event in events) {
    final start = event.start;
    final stop = event.stop;
    if (start == null || stop == null) continue;

    if (event is XmlStartElementEvent) {
      final node = XmlElementNode(
        qualifiedName: event.name,
        prefix: event.namespacePrefix,
        localName: event.localName,
        namespaceUri: event.namespaceUri,
        startTagStart: start,
        startTagStop: stop,
        isSelfClosing: event.isSelfClosing,
        attributes: _readAttributes(source, start, stop, event.attributes),
      );
      if (stack.isEmpty) {
        root ??= node;
      } else {
        node.parent = stack.last;
        stack.last.children.add(node);
      }
      if (!event.isSelfClosing) stack.add(node);
    } else if (event is XmlEndElementEvent) {
      if (stack.isEmpty) continue;
      final node = stack.removeLast();
      node.endTagStart = start;
      node.endTagStop = stop;
    } else if (event is XmlTextEvent) {
      if (stack.isEmpty) continue;
      stack.last.texts.add(
        XmlTextNode(
          start: start,
          stop: stop,
          raw: source.substring(start, stop),
          decoded: event.value,
        ),
      );
    }
  }

  if (root == null) {
    throw const FormatException('XML document has no root element');
  }
  return root;
}

/// Recovers the source range of each attribute value.
///
/// `XmlEventAttribute` carries the decoded value but no offsets, so the start
/// tag is re-scanned. Attributes appear in the source in the same order as in
/// the event, which makes a single forward scan sufficient.
List<XmlAttr> _readAttributes(
  String source,
  int startTagStart,
  int startTagStop,
  List<XmlEventAttribute> attributes,
) {
  if (attributes.isEmpty) return const [];

  final result = <XmlAttr>[];
  var pos = startTagStart + 1;

  // Skip the element name.
  while (pos < startTagStop && !_isSpace(source.codeUnitAt(pos))) {
    pos++;
  }

  for (final attribute in attributes) {
    while (pos < startTagStop && _isSpace(source.codeUnitAt(pos))) {
      pos++;
    }
    final nameStart = pos;
    // Skip the attribute name.
    while (pos < startTagStop) {
      final c = source.codeUnitAt(pos);
      if (c == 0x3D || _isSpace(c)) break; // '='
      pos++;
    }
    while (pos < startTagStop && _isSpace(source.codeUnitAt(pos))) {
      pos++;
    }
    if (pos < startTagStop && source.codeUnitAt(pos) == 0x3D) pos++; // '='
    while (pos < startTagStop && _isSpace(source.codeUnitAt(pos))) {
      pos++;
    }

    var quote = '"';
    if (pos < startTagStop) {
      final c = source.codeUnitAt(pos);
      if (c == 0x22 || c == 0x27) {
        quote = String.fromCharCode(c);
        pos++;
      }
    }
    final valueStart = pos;
    while (pos < startTagStop && source[pos] != quote) {
      pos++;
    }
    final valueStop = pos;
    if (pos < startTagStop) pos++; // closing quote

    result.add(
      XmlAttr(
        qualifiedName: attribute.name,
        prefix: attribute.namespacePrefix,
        localName: attribute.localName,
        namespaceUri: attribute.namespaceUri,
        value: attribute.value,
        nameStart: nameStart,
        valueStart: valueStart,
        valueStop: valueStop,
        quote: quote,
      ),
    );
  }

  return result;
}

bool _isSpace(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x09 ||
    codeUnit == 0x0A ||
    codeUnit == 0x0D;
