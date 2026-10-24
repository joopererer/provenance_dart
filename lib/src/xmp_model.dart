// The provenance data model of provenance-spec 0.1 (SPEC §3 and §7).

import 'date_formatter.dart';
import 'xmp_fields.dart';

/// The AI disclosure came from the platform itself, for example a badge the
/// site shows on AI-generated content (SPEC §3.7).
const String aiLabelSourcePlatform = 'platform';

/// The author declared the AI use in the caption or a tag (SPEC §3.7).
const String aiLabelSourceAuthor = 'author';

/// The source of the disclosure is unknown or was not stated (SPEC §3.7).
const String aiLabelSourceUnknown = 'unknown';

/// The IPTC `DigitalSourceType` written when a file carries an AI label
/// (SPEC §3.4).
///
/// It says the media is a composite with trained algorithmic media, that is
/// partly or wholly produced by a generative model.
const String compositeWithTrainedAlgorithmicMedia =
    'http://cv.iptc.org/newscodes/digitalsourcetype/'
    'compositeWithTrainedAlgorithmicMedia';

/// Maps [value] to one of the three values SPEC §3.7 allows.
///
/// Anything else, including `null`, becomes [aiLabelSourceUnknown].
String normalizeAiLabelSource(String? value) => switch (value) {
  aiLabelSourcePlatform => aiLabelSourcePlatform,
  aiLabelSourceAuthor => aiLabelSourceAuthor,
  _ => aiLabelSourceUnknown,
};

/// The raw field values read from an XMP package.
///
/// This is the tolerant layer: it holds whatever the file contained, without
/// requiring any field to be present (SPEC §1 principle 5, "readers are
/// forgiving"). Use [XmpProvenance.fromFields] to get the typed model, which
/// returns `null` when the required fields are missing.
class XmpFields {
  /// Creates a field set.
  XmpFields({
    Map<XmpField, Object?>? values,
    Map<String, String>? otherFields,
    Map<XmpField, String>? rawText,
  }) : values = values ?? <XmpField, Object?>{},
       otherFields = otherFields ?? <String, String>{},
       rawText = rawText ?? <XmpField, String>{};

  /// Known fields, mapped to a `String`, an `int` or a `List<String>`.
  final Map<XmpField, Object?> values;

  /// Fields of the known namespaces that this model has no property for,
  /// keyed by qualified name, for example `photoshop:Headline`.
  final Map<String, String> otherFields;

  /// The text each field was read from, used to write dates back unchanged.
  final Map<XmpField, String> rawText;

  /// Whether no known field was found.
  bool get isEmpty => values.isEmpty;

  /// The text value of [field], or `null`.
  String? string(XmpField field) {
    final value = values[field];
    if (value == null) return null;
    if (value is List) return value.isEmpty ? null : value.first.toString();
    return value.toString();
  }

  /// The integer value of [field], or `null` when absent or not a number.
  int? integer(XmpField field) {
    final value = values[field];
    if (value == null) return null;
    if (value is int) return value;
    if (value is List) {
      return value.isEmpty ? null : int.tryParse(value.first.toString().trim());
    }
    return int.tryParse(value.toString().trim());
  }

  /// The list value of [field], or `null`.
  List<String>? list(XmpField field) {
    final value = values[field];
    if (value == null) return null;
    if (value is List) return value.map((e) => e.toString()).toList();
    return [value.toString()];
  }
}

/// Provenance metadata of a single media file.
///
/// Field names follow the JSON representation of SPEC §7. [toXmpJson] maps
/// them to the namespace-qualified XMP names of SPEC §3.
///
/// Dates read from a file keep their original text: [toJson] and [toXmpJson]
/// write `2026-10-20T13:30:00Z` back as read instead of converting it to the
/// local timezone, as long as the date value itself is unchanged. Dates set in
/// code are written with `Z` when the [DateTime] is UTC and with the local
/// offset otherwise (see [formatDateTimeWithTimezone]).
class XmpProvenance {
  /// Creates a provenance record.
  XmpProvenance({
    required this.schema,
    required this.assetId,
    required this.capturedAt,
    required this.capturedBy,
    required this.metadataDate,
    this.sourceUrl,
    this.platform,
    this.sourceId,
    this.itemIndex,
    this.itemCount,
    this.authorId,
    this.publishedAt,
    this.pairId,
    this.title,
    this.creators,
    this.description,
    this.subject,
    this.rating,
    this.credit,
    this.aiLabel,
    String? aiLabelSource,
    this.digitalSourceType,
    this.otherFields = const {},
  }) : aiLabelSource = aiLabelSource == null
           ? null
           : normalizeAiLabelSource(aiLabelSource),
       _dateLiterals = const {};

  XmpProvenance._withLiterals({
    required this.schema,
    required this.assetId,
    required this.capturedAt,
    required this.capturedBy,
    required this.metadataDate,
    required this.sourceUrl,
    required this.platform,
    required this.sourceId,
    required this.itemIndex,
    required this.itemCount,
    required this.authorId,
    required this.publishedAt,
    required this.pairId,
    required this.title,
    required this.creators,
    required this.description,
    required this.subject,
    required this.rating,
    required this.credit,
    required this.aiLabel,
    required this.aiLabelSource,
    required this.digitalSourceType,
    required this.otherFields,
    required Map<String, String> dateLiterals,
  }) : _dateLiterals = dateLiterals;

  /// `prov:schema`, the spec version. Currently `"0.1"`.
  final String schema;

  /// `prov:assetId`, the permanent identity of the file (lowercase UUID v4).
  final String assetId;

  /// `prov:capturedAt`, when the file was first captured.
  final DateTime capturedAt;

  /// `prov:capturedBy`, the software and version that captured the file,
  /// for example `EasySave/1.7.0`.
  final String capturedBy;

  /// `xmp:MetadataDate`, when this metadata was last modified.
  final DateTime metadataDate;

  /// `prov:sourceUrl`, the normalized source page URL (SPEC §5).
  ///
  /// Optional since spec 0.1.2: platforms without a stable public page, such
  /// as private cloud drives, omit it.
  final String? sourceUrl;

  /// `prov:platform`, the platform identifier (SPEC §3.5).
  final String? platform;

  /// `prov:sourceId`, the opaque native ID of the source on the platform.
  ///
  /// Never parse its internal structure (SPEC §3.5).
  final String? sourceId;

  /// `prov:itemIndex`, 1-based position in a multi-item source.
  final int? itemIndex;

  /// `prov:itemCount`, number of items in the source.
  final int? itemCount;

  /// `prov:authorId`, the stable author ID on the platform.
  final String? authorId;

  /// `prov:publishedAt`, when the source content was published.
  final DateTime? publishedAt;

  /// `prov:pairId`, shared by the image and video of a Live Photo.
  final String? pairId;

  /// `dc:title`.
  final String? title;

  /// `dc:creator`, an ordered list of author display names.
  final List<String>? creators;

  /// `dc:description`, at most 2000 characters (SPEC §3.4).
  final String? description;

  /// `dc:subject`, an unordered list of tags.
  final List<String>? subject;

  /// `xmp:Rating`, 0 to 5.
  final int? rating;

  /// `photoshop:Credit`, the credit line `author / platform`.
  final String? credit;

  /// `prov:aiLabel`, the AI disclosure text exactly as the platform or the
  /// author stated it (SPEC §3.7).
  ///
  /// Stored verbatim: it is never translated or reworded, because the exact
  /// wording is what the platform or author declared.
  final String? aiLabel;

  /// `prov:aiLabelSource`, one of [aiLabelSourcePlatform],
  /// [aiLabelSourceAuthor] or [aiLabelSourceUnknown].
  ///
  /// Any other value read from a file becomes [aiLabelSourceUnknown]
  /// (SPEC §3.7).
  final String? aiLabelSource;

  /// `Iptc4xmpExt:DigitalSourceType`, the IPTC digital source type URI.
  ///
  /// Written as [compositeWithTrainedAlgorithmicMedia] when an AI label is
  /// present, but only when the file has no value of its own: a camera or
  /// generator that already recorded a source type keeps it (SPEC §3.4, §4.6).
  final String? digitalSourceType;

  /// Other fields of the known namespaces (prov, dc, xmp, photoshop) that this
  /// model has no property for, keyed by qualified name, for example
  /// `photoshop:Headline`.
  ///
  /// Writing never overwrites a field that already exists in the file, and
  /// fields of other namespaces are always kept by the in-place XMP update,
  /// whether or not they appear here.
  final Map<String, String> otherFields;

  /// Original date text read from a file, keyed by JSON field name.
  final Map<String, String> _dateLiterals;

  /// Returns a copy with the given fields replaced.
  ///
  /// Nullable fields cannot be cleared with [copyWith]; construct a new
  /// instance for that.
  XmpProvenance copyWith({
    String? schema,
    String? assetId,
    DateTime? capturedAt,
    String? capturedBy,
    DateTime? metadataDate,
    String? sourceUrl,
    String? platform,
    String? sourceId,
    int? itemIndex,
    int? itemCount,
    String? authorId,
    DateTime? publishedAt,
    String? pairId,
    String? title,
    List<String>? creators,
    String? description,
    List<String>? subject,
    int? rating,
    String? credit,
    String? aiLabel,
    String? aiLabelSource,
    String? digitalSourceType,
    Map<String, String>? otherFields,
  }) => XmpProvenance._withLiterals(
    schema: schema ?? this.schema,
    assetId: assetId ?? this.assetId,
    capturedAt: capturedAt ?? this.capturedAt,
    capturedBy: capturedBy ?? this.capturedBy,
    metadataDate: metadataDate ?? this.metadataDate,
    sourceUrl: sourceUrl ?? this.sourceUrl,
    platform: platform ?? this.platform,
    sourceId: sourceId ?? this.sourceId,
    itemIndex: itemIndex ?? this.itemIndex,
    itemCount: itemCount ?? this.itemCount,
    authorId: authorId ?? this.authorId,
    publishedAt: publishedAt ?? this.publishedAt,
    pairId: pairId ?? this.pairId,
    title: title ?? this.title,
    creators: creators ?? this.creators,
    description: description ?? this.description,
    subject: subject ?? this.subject,
    rating: rating ?? this.rating,
    credit: credit ?? this.credit,
    aiLabel: aiLabel ?? this.aiLabel,
    aiLabelSource: aiLabelSource == null
        ? this.aiLabelSource
        : normalizeAiLabelSource(aiLabelSource),
    digitalSourceType: digitalSourceType ?? this.digitalSourceType,
    otherFields: otherFields ?? this.otherFields,
    // Stale literals are ignored by _formatDate, so they can be carried.
    dateLiterals: _dateLiterals,
  );

  /// Formats a date, reusing the text it was read from if unchanged.
  String _formatDate(String jsonKey, DateTime value) {
    final literal = _dateLiterals[jsonKey];
    if (literal != null) {
      final parsed = DateTime.tryParse(literal);
      if (parsed != null && parsed.isAtSameMomentAs(value)) return literal;
    }
    return formatDateTimeWithTimezone(value);
  }

  /// Converts to the JSON representation of SPEC §7.
  ///
  /// Source fields are nested under `source`, which is omitted when empty;
  /// [otherFields] are added at the top level with their qualified names.
  Map<String, dynamic> toJson() {
    final source = <String, dynamic>{
      if (sourceUrl != null) 'url': sourceUrl,
      if (platform != null) 'platform': platform,
      if (sourceId != null) 'id': sourceId,
      if (itemIndex != null) 'itemIndex': itemIndex,
      if (itemCount != null) 'itemCount': itemCount,
      if (authorId != null) 'authorId': authorId,
      if (publishedAt != null)
        'publishedAt': _formatDate('publishedAt', publishedAt!),
      if (pairId != null) 'pairId': pairId,
    };

    return {
      'schema': schema,
      'assetId': assetId,
      'capturedAt': _formatDate('capturedAt', capturedAt),
      'capturedBy': capturedBy,
      'metadataDate': _formatDate('metadataDate', metadataDate),
      if (source.isNotEmpty) 'source': source,
      if (title != null) 'title': title,
      if (creators != null) 'creator': creators,
      if (description != null) 'description': description,
      if (subject != null) 'subject': subject,
      if (rating != null) 'rating': rating,
      if (credit != null) 'credit': credit,
      if (aiLabel != null) 'aiLabel': aiLabel,
      if (aiLabelSource != null) 'aiLabelSource': aiLabelSource,
      if (digitalSourceType != null) 'digitalSourceType': digitalSourceType,
      ...otherFields,
    };
  }

  /// Converts to namespace-qualified XMP names, as used for writing.
  Map<String, dynamic> toXmpJson() => {
    'prov:schema': schema,
    'prov:assetId': assetId,
    'prov:capturedAt': _formatDate('capturedAt', capturedAt),
    'prov:capturedBy': capturedBy,
    'xmp:MetadataDate': _formatDate('metadataDate', metadataDate),
    if (sourceUrl != null) 'prov:sourceUrl': sourceUrl,
    if (platform != null) 'prov:platform': platform,
    if (sourceId != null) 'prov:sourceId': sourceId,
    if (itemIndex != null) 'prov:itemIndex': itemIndex,
    if (itemCount != null) 'prov:itemCount': itemCount,
    if (authorId != null) 'prov:authorId': authorId,
    if (publishedAt != null)
      'prov:publishedAt': _formatDate('publishedAt', publishedAt!),
    if (pairId != null) 'prov:pairId': pairId,
    if (title != null) 'dc:title': title,
    if (creators != null) 'dc:creator': creators,
    if (description != null) 'dc:description': description,
    if (subject != null) 'dc:subject': subject,
    if (rating != null) 'xmp:Rating': rating,
    if (credit != null) 'photoshop:Credit': credit,
    if (aiLabel != null) 'prov:aiLabel': aiLabel,
    if (aiLabelSource != null) 'prov:aiLabelSource': aiLabelSource,
    if (digitalSourceType != null)
      'Iptc4xmpExt:DigitalSourceType': digitalSourceType,
    ...otherFields,
  };

  /// The fields to write, keyed by [XmpField].
  ///
  /// `dc:source` mirrors `prov:sourceUrl` (SPEC §3.4) and is included only
  /// when a source URL is known.
  Map<XmpField, Object?> toFields() => {
    XmpField.schema: schema,
    XmpField.assetId: assetId,
    XmpField.capturedAt: _formatDate('capturedAt', capturedAt),
    XmpField.capturedBy: capturedBy,
    XmpField.metadataDate: _formatDate('metadataDate', metadataDate),
    XmpField.sourceUrl: sourceUrl,
    XmpField.platform: platform,
    XmpField.sourceId: sourceId,
    XmpField.itemIndex: itemIndex,
    XmpField.itemCount: itemCount,
    XmpField.authorId: authorId,
    XmpField.publishedAt: publishedAt == null
        ? null
        : _formatDate('publishedAt', publishedAt!),
    XmpField.pairId: pairId,
    XmpField.title: title,
    XmpField.creator: creators,
    XmpField.description: description,
    XmpField.subject: subject,
    XmpField.rating: rating,
    XmpField.credit: credit,
    XmpField.aiLabel: aiLabel,
    XmpField.aiLabelSource: aiLabelSource,
    XmpField.digitalSourceType: digitalSourceType,
    XmpField.dcSource: sourceUrl,
  };

  /// Builds the typed model from raw [fields].
  ///
  /// Returns `null` when `prov:assetId`, `prov:capturedAt` or
  /// `prov:capturedBy` is missing or a date cannot be parsed, which is how a
  /// file without provenance metadata is reported. A missing
  /// `xmp:MetadataDate` falls back to `capturedAt`.
  static XmpProvenance? fromFields(XmpFields fields) {
    final assetId = fields.string(XmpField.assetId);
    final capturedBy = fields.string(XmpField.capturedBy);
    final capturedAtText = fields.string(XmpField.capturedAt);
    if (assetId == null || capturedBy == null || capturedAtText == null) {
      return null;
    }
    final capturedAt = DateTime.tryParse(capturedAtText);
    if (capturedAt == null) return null;

    final literals = <String, String>{'capturedAt': capturedAtText};
    final metadataDateText = fields.string(XmpField.metadataDate);
    var metadataDate = metadataDateText == null
        ? null
        : DateTime.tryParse(metadataDateText);
    if (metadataDate == null) {
      metadataDate = capturedAt;
      literals['metadataDate'] = capturedAtText;
    } else {
      literals['metadataDate'] = metadataDateText!;
    }

    final publishedAtText = fields.string(XmpField.publishedAt);
    final publishedAt = publishedAtText == null
        ? null
        : DateTime.tryParse(publishedAtText);
    if (publishedAt != null) literals['publishedAt'] = publishedAtText!;

    return XmpProvenance._withLiterals(
      schema: fields.string(XmpField.schema) ?? '0.1',
      assetId: assetId,
      capturedAt: capturedAt,
      capturedBy: capturedBy,
      metadataDate: metadataDate,
      sourceUrl: fields.string(XmpField.sourceUrl),
      platform: fields.string(XmpField.platform),
      sourceId: fields.string(XmpField.sourceId),
      itemIndex: fields.integer(XmpField.itemIndex),
      itemCount: fields.integer(XmpField.itemCount),
      authorId: fields.string(XmpField.authorId),
      publishedAt: publishedAt,
      pairId: fields.string(XmpField.pairId),
      title: fields.string(XmpField.title),
      creators: fields.list(XmpField.creator),
      description: fields.string(XmpField.description),
      subject: fields.list(XmpField.subject),
      rating: fields.integer(XmpField.rating),
      credit: fields.string(XmpField.credit),
      aiLabel: fields.string(XmpField.aiLabel),
      aiLabelSource: fields.string(XmpField.aiLabelSource) == null
          ? null
          : normalizeAiLabelSource(fields.string(XmpField.aiLabelSource)),
      digitalSourceType: fields.string(XmpField.digitalSourceType),
      otherFields: fields.otherFields,
      dateLiterals: literals,
    );
  }

  /// Creates an instance from either the JSON representation of SPEC §7
  /// (`capturedAt`, `source.url`, ...) or namespace-qualified XMP names
  /// (`prov:capturedAt`, `prov:sourceUrl`, ...).
  ///
  /// Throws a [FormatException] if `assetId`, `capturedAt` or `capturedBy`
  /// is missing or a date cannot be parsed. A missing `metadataDate` falls
  /// back to `capturedAt`.
  factory XmpProvenance.fromJson(Map<String, dynamic> json) {
    final otherFields = <String, String>{};
    json.forEach((key, value) {
      if (!_knownFields.contains(key) && value != null) {
        otherFields[key] = value.toString();
      }
    });

    final source = json['source'] is Map
        ? Map<String, dynamic>.from(json['source'] as Map)
        : const <String, dynamic>{};
    final literals = <String, String>{};

    Object? pick(String xmpKey, String jsonKey, [String? sourceKey]) {
      if (json[xmpKey] != null) return json[xmpKey];
      if (json[jsonKey] != null) return json[jsonKey];
      if (sourceKey != null) return source[sourceKey];
      return null;
    }

    String? text(String xmpKey, String jsonKey, [String? sourceKey]) =>
        pick(xmpKey, jsonKey, sourceKey)?.toString();

    DateTime? date(String xmpKey, String jsonKey, [String? sourceKey]) {
      final raw = text(xmpKey, jsonKey, sourceKey);
      if (raw == null) return null;
      final parsed = DateTime.tryParse(raw);
      if (parsed == null) {
        throw FormatException('Invalid date in $xmpKey', raw);
      }
      literals[jsonKey] = raw;
      return parsed;
    }

    List<String>? list(String xmpKey, String jsonKey) {
      final raw = pick(xmpKey, jsonKey);
      if (raw == null) return null;
      if (raw is List) return raw.map((e) => e.toString()).toList();
      return [raw.toString()];
    }

    String requireText(String xmpKey, String jsonKey) {
      final value = text(xmpKey, jsonKey);
      if (value == null) {
        throw FormatException('Missing required field $xmpKey');
      }
      return value;
    }

    final assetId = requireText('prov:assetId', 'assetId');
    final capturedBy = requireText('prov:capturedBy', 'capturedBy');
    final capturedAt = date('prov:capturedAt', 'capturedAt');
    if (capturedAt == null) {
      throw const FormatException('Missing required field prov:capturedAt');
    }
    var metadataDate = date('xmp:MetadataDate', 'metadataDate');
    if (metadataDate == null) {
      metadataDate = capturedAt;
      final capturedLiteral = literals['capturedAt'];
      if (capturedLiteral != null) literals['metadataDate'] = capturedLiteral;
    }

    return XmpProvenance._withLiterals(
      schema: text('prov:schema', 'schema') ?? '0.1',
      assetId: assetId,
      capturedAt: capturedAt,
      capturedBy: capturedBy,
      metadataDate: metadataDate,
      sourceUrl: text('prov:sourceUrl', 'sourceUrl', 'url'),
      platform: text('prov:platform', 'platform', 'platform'),
      sourceId: text('prov:sourceId', 'sourceId', 'id'),
      itemIndex: _parseInt(pick('prov:itemIndex', 'itemIndex', 'itemIndex')),
      itemCount: _parseInt(pick('prov:itemCount', 'itemCount', 'itemCount')),
      authorId: text('prov:authorId', 'authorId', 'authorId'),
      publishedAt: date('prov:publishedAt', 'publishedAt', 'publishedAt'),
      pairId: text('prov:pairId', 'pairId', 'pairId'),
      title: text('dc:title', 'title'),
      creators: list('dc:creator', 'creator'),
      description: text('dc:description', 'description'),
      subject: list('dc:subject', 'subject'),
      rating: _parseInt(pick('xmp:Rating', 'rating')),
      credit: text('photoshop:Credit', 'credit'),
      aiLabel: text('prov:aiLabel', 'aiLabel'),
      aiLabelSource: text('prov:aiLabelSource', 'aiLabelSource') == null
          ? null
          : normalizeAiLabelSource(text('prov:aiLabelSource', 'aiLabelSource')),
      digitalSourceType: text(
        'Iptc4xmpExt:DigitalSourceType',
        'digitalSourceType',
      ),
      otherFields: otherFields,
      dateLiterals: literals,
    );
  }

  static int? _parseInt(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static const _knownFields = {
    'prov:schema',
    'prov:assetId',
    'prov:capturedAt',
    'prov:capturedBy',
    'xmp:MetadataDate',
    'prov:sourceUrl',
    'prov:platform',
    'prov:sourceId',
    'prov:itemIndex',
    'prov:itemCount',
    'prov:authorId',
    'prov:publishedAt',
    'prov:pairId',
    'dc:title',
    'dc:creator',
    'dc:description',
    'dc:subject',
    'xmp:Rating',
    'dc:source',
    'photoshop:Credit',
    'prov:aiLabel',
    'prov:aiLabelSource',
    'Iptc4xmpExt:DigitalSourceType',
    // Flat SPEC format keys
    'schema',
    'assetId',
    'capturedAt',
    'capturedBy',
    'metadataDate',
    'sourceUrl',
    'platform',
    'sourceId',
    'itemIndex',
    'itemCount',
    'authorId',
    'publishedAt',
    'pairId',
    'title',
    'creator',
    'description',
    'subject',
    'rating',
    'credit',
    'aiLabel',
    'aiLabelSource',
    'digitalSourceType',
    'source',
  };
}
