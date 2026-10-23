// In-place editing of an XMP package (SPEC §4.7 write requirement 1).
//
// The package keeps the original XML text and splices only the ranges that
// belong to the fields of this spec. Every other byte — foreign namespaces,
// namespace declarations, attribute order, whitespace, comments, the xpacket
// header — is preserved verbatim.

import 'xmp_fields.dart';
import 'xml_scanner.dart';

/// An XMP package that can be edited in place.
///
/// Construct one with [XmpPackage.parse] to edit an existing package, or with
/// [XmpPackage.empty] to start a new one. [setField] changes only the field it
/// is given; [text] returns the resulting XML.
class XmpPackage {
  XmpPackage._(this._text) : _root = parseXmlTree(_text);

  /// Parses [text] as an XMP package.
  ///
  /// Throws [FormatException] when [text] is not well-formed XML.
  factory XmpPackage.parse(String text) => XmpPackage._(text);

  /// Creates an empty package with the usual namespace declarations.
  factory XmpPackage.empty() => XmpPackage._(_skeleton);

  /// Creates a package that contains exactly the fields of [provenance].
  ///
  /// This regenerates the whole package, so it must only be used when no
  /// existing package is available (SPEC §4.7 write requirement 1).
  factory XmpPackage.fromFields(Map<XmpField, Object?> fields) {
    final package = XmpPackage.empty();
    fields.forEach(package.setField);
    return package;
  }

  String _text;
  XmlElementNode _root;

  /// The current XML text of the package.
  String get text => _text;

  /// The root element of the package, for inspection.
  XmlElementNode get root => _root;

  /// All `rdf:Description` blocks, in document order (SPEC §4.7 read
  /// requirement 3).
  List<XmlElementNode> get descriptions => _root.descendants
      .where((n) => n.namespaceUri == rdfNsUri && n.localName == 'Description')
      .toList();

  /// Sets [field] to [value], editing the existing node in place.
  ///
  /// A `null` value leaves the package untouched, so callers can pass optional
  /// fields without special-casing them. When the field is absent it is added
  /// to the first `rdf:Description`; when it is present only its value is
  /// replaced, so surrounding markup survives.
  ///
  /// Only the first occurrence is updated. A second occurrence of the same
  /// field in a later `rdf:Description` block is left alone, which keeps
  /// language variants of `dc:title` intact.
  void setField(XmpField field, Object? value) {
    if (value == null) return;
    final text = _scalarText(value);
    if (text == null) return;

    final attribute = _findAttribute(field);
    if (attribute != null) {
      if (field.kind == XmpValueKind.scalar) {
        _apply(
          attribute.valueStart,
          attribute.valueStop,
          escapeAttributeValue(text, attribute.quote),
        );
      } else {
        // A list stored as an attribute cannot hold several values; replace it
        // with the element form.
        _apply(attribute.nameStart, attribute.valueStop + 1, '');
        _insertField(field, value, text);
      }
      return;
    }

    final element = _findElement(field);
    if (element != null) {
      _updateElement(element, field, value, text);
      return;
    }

    _insertField(field, value, text);
  }

  /// Updates an existing field element, touching as little as possible.
  void _updateElement(
    XmlElementNode element,
    XmpField field,
    Object value,
    String text,
  ) {
    if (field.kind == XmpValueKind.scalar) {
      _replaceContent(element, escapeText(text));
      return;
    }

    if (field.kind == XmpValueKind.altText) {
      final alt = element.find(rdfNsUri, 'Alt');
      if (alt == null) {
        _replaceContent(element, _containerInner(element, field, value));
        return;
      }
      final items = alt.children
          .where((c) => c.namespaceUri == rdfNsUri && c.localName == 'li')
          .toList();
      if (items.isEmpty) {
        _insertContent(alt, _itemMarkup(element, text, language: 'x-default'));
        return;
      }
      // Only the default language variant is ours to update; other languages
      // written by other software stay untouched.
      final target = items.firstWhere(
        (li) => li.attribute(xmlNsUri, 'lang')?.value == 'x-default',
        orElse: () => items.first,
      );
      _replaceContent(target, escapeText(text));
      return;
    }

    final containerName = field.kind == XmpValueKind.sequence ? 'Seq' : 'Bag';
    final container = element.find(rdfNsUri, containerName);
    if (container == null) {
      _replaceContent(element, _containerInner(element, field, value));
      return;
    }
    final items = (value is List ? value : [value])
        .map((item) => _itemMarkup(element, _scalarText(item) ?? ''))
        .join();
    _replaceContent(container, items);
  }

  String _itemMarkup(XmlElementNode context, String text, {String? language}) {
    final prefix = context.prefixFor(rdfNsUri) ?? 'rdf';
    final lang = language == null ? '' : ' xml:lang="$language"';
    return '<$prefix:li$lang>${escapeText(text)}</$prefix:li>';
  }

  /// Sets a field identified by its qualified name, for example
  /// `photoshop:Headline`.
  ///
  /// Used for the foreign fields of [XmpProvenance.otherFields] when a package
  /// is created from scratch. Only prefixes this package knows a namespace URI
  /// for can be written; anything else is ignored, because writing a name
  /// without a namespace would change its meaning.
  void setQualifiedField(String qualifiedName, String value) {
    final colon = qualifiedName.indexOf(':');
    if (colon <= 0) return;
    final prefix = qualifiedName.substring(0, colon);
    final localName = qualifiedName.substring(colon + 1);
    final namespaceUri = _namespaceUriForPrefix(prefix);
    if (namespaceUri == null) return;

    final description = _ensureDescription();
    final existing = description.attribute(namespaceUri, localName);
    if (existing != null) {
      _apply(
        existing.valueStart,
        existing.valueStop,
        escapeAttributeValue(value, existing.quote),
      );
      return;
    }

    final target = _ensureDescription();
    final declared = target.prefixFor(namespaceUri);
    final usePrefix = declared ?? prefix;
    if (declared == null) {
      _insertAttribute(
        target,
        ' xmlns:$usePrefix="${escapeAttributeValue(namespaceUri, '"')}"',
      );
    }
    _insertAttribute(
      _ensureDescription(),
      ' $usePrefix:$localName="${escapeAttributeValue(value, '"')}"',
    );
  }

  static String? _namespaceUriForPrefix(String prefix) => switch (prefix) {
    'prov' => provNsUri,
    'dc' => dcNsUri,
    'xmp' => xmpNsUri,
    'photoshop' => photoshopNsUri,
    _ => null,
  };

  /// Removes every occurrence of [field] from the package.
  ///
  /// Used only when a caller explicitly clears a user field; capture fields
  /// must never be removed (SPEC §4.6).
  void removeField(XmpField field) {
    while (true) {
      final attribute = _findAttribute(field);
      if (attribute != null) {
        var start = attribute.nameStart;
        while (start > 0 && _isSpace(_text.codeUnitAt(start - 1))) {
          start--;
        }
        _apply(start, attribute.valueStop + 1, '');
        continue;
      }
      final element = _findElement(field);
      if (element == null) return;
      final stop = element.endTagStop ?? element.startTagStop;
      _apply(element.startTagStart, stop, '');
    }
  }

  /// Whether [field] is present in any `rdf:Description` block.
  bool hasField(XmpField field) =>
      _findAttribute(field) != null || _findElement(field) != null;

  // --- lookup ---------------------------------------------------------------

  XmlAttr? _findAttribute(XmpField field) {
    for (final description in descriptions) {
      final attribute = description.attribute(
        field.namespaceUri,
        field.localName,
      );
      if (attribute != null) return attribute;
    }
    return null;
  }

  XmlElementNode? _findElement(XmpField field) {
    for (final description in descriptions) {
      for (final child in description.children) {
        if (child.namespaceUri == field.namespaceUri &&
            child.localName == field.localName) {
          return child;
        }
      }
    }
    return null;
  }

  // --- insertion ------------------------------------------------------------

  void _insertField(XmpField field, Object value, String text) {
    final description = _ensureDescription();
    final prefix = _ensurePrefix(description, field);
    final target = _ensureDescription();

    if (field.kind == XmpValueKind.scalar) {
      _insertAttribute(
        target,
        ' $prefix:${field.localName}="${escapeAttributeValue(text, '"')}"',
      );
    } else {
      final rdfPrefix = target.prefixFor(rdfNsUri) ?? 'rdf';
      _insertContent(
        target,
        '<$prefix:${field.localName}>'
        '${_containerInner(target, field, value, rdfPrefix: rdfPrefix)}'
        '</$prefix:${field.localName}>',
      );
    }
  }

  /// Returns a prefix bound to the field's namespace, declaring one if needed.
  String _ensurePrefix(XmlElementNode description, XmpField field) {
    final existing = description.prefixFor(field.namespaceUri);
    if (existing != null) return existing;

    final prefix = field.preferredPrefix;
    _insertAttribute(
      description,
      ' xmlns:$prefix="${escapeAttributeValue(field.namespaceUri, '"')}"',
    );
    return prefix;
  }

  XmlElementNode _ensureDescription() {
    final existing = descriptions;
    if (existing.isNotEmpty) return existing.first;

    final rdf = _root.find(rdfNsUri, 'RDF');
    if (rdf == null) {
      throw const FormatException(
        'XMP package has no rdf:RDF element to add fields to',
      );
    }
    final rdfPrefix = rdf.prefixFor(rdfNsUri) ?? rdf.prefix ?? 'rdf';
    _insertContent(rdf, '<$rdfPrefix:Description $rdfPrefix:about=""/>');
    return descriptions.first;
  }

  // --- markup ---------------------------------------------------------------

  /// The `rdf:Alt` / `rdf:Seq` / `rdf:Bag` container for [field].
  String _containerInner(
    XmlElementNode context,
    XmpField field,
    Object value, {
    String? rdfPrefix,
  }) {
    final prefix = rdfPrefix ?? context.prefixFor(rdfNsUri) ?? 'rdf';

    if (field.kind == XmpValueKind.altText) {
      final text = _scalarText(value) ?? '';
      return '<$prefix:Alt>'
          '<$prefix:li xml:lang="x-default">${escapeText(text)}</$prefix:li>'
          '</$prefix:Alt>';
    }

    final container = field.kind == XmpValueKind.sequence ? 'Seq' : 'Bag';
    final items = (value is List ? value : [value])
        .map(
          (item) =>
              '<$prefix:li>${escapeText(_scalarText(item) ?? '')}</$prefix:li>',
        )
        .join();
    return '<$prefix:$container>$items</$prefix:$container>';
  }

  // --- splicing -------------------------------------------------------------

  void _insertAttribute(XmlElementNode node, String markup) {
    final at = node.isSelfClosing
        ? node.startTagStop - 2
        : node.startTagStop - 1;
    _apply(at, at, markup);
  }

  void _insertContent(XmlElementNode node, String markup) {
    if (node.isSelfClosing) {
      _apply(
        node.startTagStop - 2,
        node.startTagStop,
        '>$markup</${node.qualifiedName}>',
      );
    } else {
      _apply(node.endTagStart!, node.endTagStart!, markup);
    }
  }

  void _replaceContent(XmlElementNode node, String markup) {
    if (node.isSelfClosing) {
      _apply(
        node.startTagStop - 2,
        node.startTagStop,
        '>$markup</${node.qualifiedName}>',
      );
    } else {
      _apply(node.startTagStop, node.endTagStart!, markup);
    }
  }

  void _apply(int start, int stop, String replacement) {
    _text = _text.replaceRange(start, stop, replacement);
    _root = parseXmlTree(_text);
  }

  static String? _scalarText(Object? value) {
    if (value == null) return null;
    if (value is List) return value.isEmpty ? null : value.first.toString();
    return value.toString();
  }

  static bool _isSpace(int codeUnit) =>
      codeUnit == 0x20 ||
      codeUnit == 0x09 ||
      codeUnit == 0x0A ||
      codeUnit == 0x0D;

  static const String _skeleton =
      '<?xpacket begin="\uFEFF" '
      'id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
      '<x:xmpmeta xmlns:x="adobe:ns:meta/">\n'
      ' <rdf:RDF xmlns:rdf="$rdfNsUri">\n'
      '  <rdf:Description rdf:about=""'
      ' xmlns:prov="$provNsUri"'
      ' xmlns:dc="$dcNsUri"'
      ' xmlns:xmp="$xmpNsUri"'
      ' xmlns:photoshop="$photoshopNsUri"/>\n'
      ' </rdf:RDF>\n'
      '</x:xmpmeta>\n'
      '<?xpacket end="w"?>';
}

/// Escapes [value] for use inside an attribute delimited by [quote].
String escapeAttributeValue(String value, String quote) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    if (rune == 0x26) {
      buffer.write('&amp;');
    } else if (rune == 0x3C) {
      buffer.write('&lt;');
    } else if (rune == 0x22) {
      buffer.write(quote == '"' ? '&quot;' : '"');
    } else if (rune == 0x27) {
      buffer.write(quote == "'" ? '&apos;' : "'");
    } else if (rune == 0x0A) {
      buffer.write('&#10;');
    } else if (rune == 0x0D) {
      buffer.write('&#13;');
    } else if (rune == 0x09) {
      buffer.write('&#9;');
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

/// Escapes [value] for use as element content.
String escapeText(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    if (rune == 0x26) {
      buffer.write('&amp;');
    } else if (rune == 0x3C) {
      buffer.write('&lt;');
    } else if (rune == 0x3E) {
      buffer.write('&gt;');
    } else if (rune == 0x0D) {
      buffer.write('&#13;');
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}
