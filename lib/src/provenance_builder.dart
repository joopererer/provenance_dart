// A generic builder for provenance records.
//
// Everything application specific — the software name in `prov:capturedBy`,
// the localized platform name in `photoshop:Credit`, and any rule about which
// author IDs are trustworthy — is supplied by the caller. This package only
// provides the generic construction interface.

import 'dart:math';

import 'url_normalizer.dart';
import 'xmp_model.dart';

/// The maximum length of `dc:description` (SPEC §3.4).
const int maxDescriptionLength = 2000;

/// Generates a lowercase UUID v4, the format required for `prov:assetId`.
String generateAssetId([Random? random]) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 10
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
}

/// Truncates [text] to [maxDescriptionLength] characters, ending with `…`.
String truncateDescription(String text) => text.length <= maxDescriptionLength
    ? text
    : '${text.substring(0, maxDescriptionLength - 1)}…';

/// Builds an [XmpProvenance] record from download or import context.
///
/// The builder applies only the rules of the spec: the source URL is
/// normalized (SPEC §5), `itemIndex` and `itemCount` are written only for
/// multi-item sources (SPEC §3.3), and the description is truncated to 2000
/// characters (SPEC §3.4).
class ProvenanceBuilder {
  /// Creates a builder.
  ProvenanceBuilder({
    required this.platform,
    required this.capturedBy,
    this.sourceId,
    this.sourceUrl,
    this.authorId,
    this.authorName,
    this.title,
    this.caption,
    this.publishedAt,
    this.itemIndex,
    this.itemCount,
    this.existingAssetId,
    this.capturedAt,
    this.creditPlatformName,
    this.aiLabel,
    this.aiLabelSource,
    this.schema = '0.1',
    this.assetIdGenerator,
  });

  /// `prov:platform`, one of the identifiers registered in SPEC §3.5.
  final String platform;

  /// `prov:capturedBy`, for example `EasySave/1.7.0`.
  final String capturedBy;

  /// `prov:sourceId`, the opaque native ID on the platform.
  final String? sourceId;

  /// The source page URL; it is normalized before being stored.
  final String? sourceUrl;

  /// `prov:authorId`, the stable author ID on the platform.
  final String? authorId;

  /// The author display name, used for `dc:creator` and `photoshop:Credit`.
  final String? authorName;

  /// `dc:title`.
  final String? title;

  /// The caption, stored as `dc:description` after truncation.
  final String? caption;

  /// `prov:publishedAt`.
  final DateTime? publishedAt;

  /// 1-based position in a multi-item source.
  final int? itemIndex;

  /// Number of items in the source.
  final int? itemCount;

  /// An `assetId` already assigned to this source, reused when known
  /// (SPEC §3.2, §6.1).
  final String? existingAssetId;

  /// `prov:capturedAt`; defaults to the current time.
  final DateTime? capturedAt;

  /// The platform name used in `photoshop:Credit`, for example `小红书`.
  ///
  /// Supplied by the caller because the display name is application and
  /// locale specific. When `null`, no credit line is written.
  final String? creditPlatformName;

  /// `prov:schema`, the spec version.
  final String schema;

  /// `prov:aiLabel`, the AI disclosure text exactly as the platform or author
  /// stated it (SPEC §3.7). Stored verbatim: it is never translated or
  /// reworded.
  final String? aiLabel;

  /// `prov:aiLabelSource`: `platform`, `author` or `unknown` (SPEC §3.7).
  ///
  /// Any other value becomes `unknown`.
  final String? aiLabelSource;

  /// Overrides how a new `assetId` is generated, for tests.
  final String Function()? assetIdGenerator;

  /// Builds the record.
  ///
  /// [now] overrides the current time, for tests.
  XmpProvenance build({DateTime? now}) {
    final timestamp = now ?? DateTime.now();
    final multiItem = itemCount != null && itemCount! > 1;

    return XmpProvenance(
      schema: schema,
      assetId: existingAssetId ?? (assetIdGenerator ?? generateAssetId).call(),
      capturedAt: capturedAt ?? timestamp,
      capturedBy: capturedBy,
      metadataDate: timestamp,
      sourceUrl: sourceUrl == null ? null : normalizeUrl(sourceUrl!),
      platform: platform,
      sourceId: sourceId,
      itemIndex: multiItem ? itemIndex : null,
      itemCount: multiItem ? itemCount : null,
      authorId: authorId,
      publishedAt: publishedAt,
      title: title,
      creators: authorName == null ? null : [authorName!],
      description: caption == null ? null : truncateDescription(caption!),
      credit: authorName == null || creditPlatformName == null
          ? null
          : '$authorName / $creditPlatformName',
      aiLabel: aiLabel,
      aiLabelSource: aiLabelSource,
      // An AI label implies the IPTC source type, but the write path only
      // adds it when the file has no value of its own (SPEC §3.4, §4.6).
      digitalSourceType: aiLabel == null
          ? null
          : compositeWithTrainedAlgorithmicMedia,
    );
  }
}
