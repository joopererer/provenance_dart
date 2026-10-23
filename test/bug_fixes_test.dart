// Regression tests for the bugs fixed while extracting this package.
//
// Ported from EasySave's `bug_fixes_test.dart`. The application specific
// parts — the `xhs` → `xiaohongshu` platform map, the localized platform
// display names and the "X authorId must be numeric" rule — stay in EasySave
// and are not part of this package, so those cases are dropped. The timezone
// formatting cases are kept, with the UTC expectation adapted: a UTC
// `DateTime` is now written with `Z` instead of being converted to local time.

import 'package:provenance_dart/provenance_dart.dart';
import 'package:test/test.dart';

void main() {
  group('date formatting (SPEC §8)', () {
    test('a local DateTime is written with its offset', () {
      final formatted = formatDateTimeWithTimezone(
        DateTime(2026, 10, 21, 2, 12, 48),
      );
      expect(
        formatted,
        matches(RegExp(r'^2026-10-21T02:12:48[+-]\d{2}:\d{2}$')),
      );
    });

    test('a UTC DateTime is written with Z', () {
      expect(
        formatDateTimeWithTimezone(DateTime.utc(2026, 10, 21, 2, 12, 48)),
        '2026-10-21T02:12:48Z',
      );
    });

    test('formatDateTimeUtc always uses Z', () {
      expect(
        formatDateTimeUtc(DateTime.utc(2026, 10, 21)),
        '2026-10-21T00:00:00Z',
      );
    });

    test('formatDateTimeUtc converts a local DateTime to UTC', () {
      final local = DateTime(2026, 10, 21, 2, 12, 48);
      expect(formatDateTimeUtc(local), formatDateTimeUtc(local.toUtc()));
      expect(formatDateTimeUtc(local), endsWith('Z'));
    });

    test('toJson writes every date with a timezone', () {
      final record = XmpProvenance(
        schema: '0.1',
        assetId: 'test',
        capturedAt: DateTime(2026, 10, 21, 2, 12, 48),
        capturedBy: 'EasySave/1.7.0',
        metadataDate: DateTime(2026, 10, 21, 2, 12, 49),
        publishedAt: DateTime(2026, 10, 20, 10, 30, 45),
      );

      final json = record.toJson();
      expect(
        json['capturedAt'],
        matches(RegExp(r'^2026-10-21T02:12:48[+-]\d{2}:\d{2}$')),
      );
      expect(
        json['metadataDate'],
        matches(RegExp(r'^2026-10-21T02:12:49[+-]\d{2}:\d{2}$')),
      );
      final source = json['source'] as Map<String, dynamic>;
      expect(
        source['publishedAt'],
        matches(RegExp(r'^2026-10-20T10:30:45[+-]\d{2}:\d{2}$')),
      );
    });

    test('toXmpJson writes every date with a timezone', () {
      final record = XmpProvenance(
        schema: '0.1',
        assetId: 'test',
        capturedAt: DateTime(2026, 10, 21, 2, 12, 48),
        capturedBy: 'EasySave/1.7.0',
        metadataDate: DateTime(2026, 10, 21, 2, 12, 49),
      );

      final json = record.toXmpJson();
      expect(
        json['prov:capturedAt'],
        matches(RegExp(r'^2026-10-21T02:12:48[+-]\d{2}:\d{2}$')),
      );
      expect(
        json['xmp:MetadataDate'],
        matches(RegExp(r'^2026-10-21T02:12:49[+-]\d{2}:\d{2}$')),
      );
    });

    test('a UTC date is written with Z, not converted to local time', () {
      final record = XmpProvenance(
        schema: '0.1',
        assetId: 'test',
        capturedAt: DateTime.utc(2026, 10, 20, 10, 30, 45),
        capturedBy: 'EasySave/1.7.0',
        metadataDate: DateTime.utc(2026, 10, 20, 10, 30, 45),
        publishedAt: DateTime.utc(2026, 10, 20, 10, 30, 45),
      );

      expect(record.toXmpJson()['prov:publishedAt'], '2026-10-20T10:30:45Z');
      expect(record.toJson()['capturedAt'], '2026-10-20T10:30:45Z');
    });
  });

  group('ProvenanceBuilder passes authorId and publishedAt through', () {
    test('authorId is written unchanged', () {
      final record = ProvenanceBuilder(
        platform: 'xiaohongshu',
        capturedBy: 'EasySave/1.7.0',
        authorId: 'author123',
      ).build();
      expect(record.authorId, 'author123');
    });

    test('publishedAt is written unchanged', () {
      final publishedAt = DateTime(2026, 10, 20, 10, 30, 45);
      final record = ProvenanceBuilder(
        platform: 'xiaohongshu',
        capturedBy: 'EasySave/1.7.0',
        publishedAt: publishedAt,
      ).build();
      expect(record.publishedAt, publishedAt);
    });

    test('publishedAt in the XMP output has a timezone', () {
      final record = ProvenanceBuilder(
        platform: 'xiaohongshu',
        capturedBy: 'EasySave/1.7.0',
        publishedAt: DateTime(2026, 10, 20, 10, 30, 45),
      ).build();

      expect(
        record.toXmpJson()['prov:publishedAt'],
        matches(RegExp(r'^2026-10-20T10:30:45[+-]\d{2}:\d{2}$')),
      );
    });
  });

  group('URL normalization through the builder', () {
    test('a xiaohongshu /discovery/item URL is normalized', () {
      final record = ProvenanceBuilder(
        platform: 'xiaohongshu',
        capturedBy: 'EasySave/1.7.0',
        sourceUrl:
            'https://www.xiaohongshu.com/discovery/item/abc123?type=normal',
      ).build();
      expect(record.sourceUrl, 'https://www.xiaohongshu.com/explore/abc123');
    });

    test('an X username/status URL is normalized', () {
      final record = ProvenanceBuilder(
        platform: 'x',
        capturedBy: 'EasySave/1.7.0',
        sourceUrl: 'https://x.com/username/status/1234567890',
      ).build();
      expect(record.sourceUrl, 'https://x.com/i/status/1234567890');
    });

    test('tracking parameters are stripped', () {
      final record = ProvenanceBuilder(
        platform: 'xiaohongshu',
        capturedBy: 'EasySave/1.7.0',
        sourceUrl:
            'https://www.xiaohongshu.com/explore/abc123'
            '?utm_source=test&fbclid=abc&igsh=xyz',
      ).build();

      expect(record.sourceUrl, isNot(contains('utm_source')));
      expect(record.sourceUrl, isNot(contains('fbclid')));
      expect(record.sourceUrl, isNot(contains('igsh')));
    });
  });

  group('a sourceId is treated as an opaque string (SPEC §3.5)', () {
    test('a OneDrive {driveId}!{id} value is not split', () {
      final record = ProvenanceBuilder(
        platform: 'onedrive',
        capturedBy: 'EasySave/1.7.0',
        sourceId: 'b!aBcD1234!5678',
      ).build();

      expect(record.sourceId, 'b!aBcD1234!5678');
      expect(record.sourceUrl, isNull);
    });

    test('a baidupan fs_id is kept as a string', () {
      final record = ProvenanceBuilder(
        platform: 'baidupan',
        capturedBy: 'EasySave/1.7.0',
        sourceId: '1092837465019283',
      ).build();

      expect(record.sourceId, '1092837465019283');
      expect(record.sourceUrl, isNull);
    });
  });
}
