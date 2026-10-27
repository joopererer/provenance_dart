// URL normalization (SPEC §5).
//
// Ported from EasySave's `url_normalizer_test.dart`. The application platform
// maps (`xhs` → `xiaohongshu`, localized display names) stay in EasySave, so
// only the spec rules are tested here.

import 'dart:convert';

import 'package:provenance_dart/provenance_dart.dart';
import 'package:test/test.dart';

import 'support/vectors.dart';

void main() {
  group('test-vectors/urls.json', () {
    late List<dynamic> cases;

    setUpAll(() {
      cases =
          (jsonDecode(vectorFile('urls.json').readAsStringSync())
                  as Map<String, dynamic>)['cases']
              as List<dynamic>;
    });

    test('every case normalizes as expected', () {
      for (final testCase in cases) {
        expect(
          normalizeUrl(testCase['in'] as String),
          testCase['out'],
          reason:
              'platform ${testCase['platform']}\n'
              'input ${testCase['in']}',
        );
      }
    });

    test('normalizing twice yields the same result', () {
      for (final testCase in cases) {
        final once = normalizeUrl(testCase['in'] as String);
        expect(normalizeUrl(once), once, reason: 'input ${testCase['in']}');
      }
    });

    test('extracts IDs from all TikTok vectors', () {
      final tiktok = cases.where((c) => c['platform'] == 'tiktok');
      expect(tiktok, hasLength(5));
      for (final c in tiktok) {
        expect(extractTiktokPostId(c['in'] as String), c['id']);
        expect(extractTiktokPostId(c['out'] as String), c['id']);
      }
    });
  });

  group('tiktok', () {
    test('hosts, paths, trailing slash, query and fragment', () {
      for (final host in ['www.TikTok.COM', 'TikTok.com', 'M.TikTok.Com']) {
        for (final path in [
          '@user/video/7123456789012345678',
          '@user/photo/7123456789012345678',
          '@/video/7123456789012345678',
          'v/7123456789012345678.html',
          'share/video/7123456789012345678',
        ]) {
          for (final suffix in [
            '',
            '/',
            '?keep=1&utm_source=x#part',
            '/?x=1#part',
          ]) {
            final url = 'https://$host/$path$suffix';
            expect(extractTiktokPostId(url), '7123456789012345678');
            expect(
              normalizeUrl(url),
              'https://www.tiktok.com/@/video/7123456789012345678',
            );
          }
        }
      }
    });

    test('short and unrecognized links are returned verbatim', () {
      for (final url in [
        'https://VM.TikTok.com/abc/?utm_source=x#part',
        'https://vt.tiktok.com/abc?x=1#part',
        'https://www.TikTok.com/@user?utm_source=x#part',
        'https://m.tiktok.com/@user/video/abc?x=1#part',
        'https://tiktok.com/@user/video/123abc',
        'https://tiktok.com/@user/video/',
        'https://tiktok.com/@user/video/extra/123',
        'https://tiktok.com/@user/video/123/extra',
        'https://tiktok.com/extra/@user/video/123',
        'https://tiktok.com/share/video/extra/123',
        'https://tiktok.com/share/video/123/extra',
        'https://tiktok.com/v/extra/123.html',
        'https://tiktok.com/v/123.html/extra',
        'https://tiktok.com/v/123',
        'https://tiktok.com/@user/video/123.html',
        'https://tiktok.com/@user/video/%FF',
      ]) {
        expect(extractTiktokPostId(url), isNull, reason: url);
        expect(normalizeUrl(url), url);
      }
    });

    test('extractor rejects other hosts and invalid URLs', () {
      for (final url in [
        '',
        'not a url',
        'https://[invalid',
        'https://example.com/@user/video/123',
        'https://www.tiktok.com.example.com/@user/video/123',
        'https://vm.tiktok.com/@user/video/123',
      ]) {
        expect(extractTiktokPostId(url), isNull, reason: url);
      }
    });

    test('platform and Credit follow the existing builder contract', () {
      for (final platform in ['tiktok', 'instagram']) {
        final displayName = platform == 'tiktok' ? 'TikTok' : 'Instagram';
        for (final author in [null, 'Author']) {
          for (final display in [null, displayName]) {
            final record = ProvenanceBuilder(
              platform: platform,
              capturedBy: 'Test/1',
              authorName: author,
              creditPlatformName: display,
            ).build();
            expect(record.platform, platform);
            expect(
              record.credit,
              author == null || display == null ? null : '$author / $display',
            );
          }
        }
      }
    });
  });

  group('xiaohongshu', () {
    test('/discovery/item/ becomes /explore/', () {
      expect(
        normalizeUrl(
          'https://www.xiaohongshu.com/discovery/item/abc123?type=normal',
        ),
        'https://www.xiaohongshu.com/explore/abc123',
      );
    });

    test('tracking parameters are stripped', () {
      final result = normalizeUrl(
        'https://www.xiaohongshu.com/explore/abc123'
        '?utm_source=test&fbclid=abc&igsh=xyz&xsec_token=FAKE',
      );
      expect(result, 'https://www.xiaohongshu.com/explore/abc123');
    });
  });

  group('x', () {
    test('a username/status URL becomes /i/status/', () {
      expect(
        normalizeUrl('https://x.com/username/status/1234567890'),
        'https://x.com/i/status/1234567890',
      );
    });

    test('twitter.com is rewritten to x.com', () {
      expect(
        normalizeUrl('https://twitter.com/someone/status/1234567890/photo/1'),
        'https://x.com/i/status/1234567890',
      );
    });
  });

  group('instagram', () {
    test('a reel becomes /p/', () {
      expect(
        normalizeUrl('https://www.instagram.com/reel/ABC123/?igsh=FAKE'),
        'https://www.instagram.com/p/ABC123/',
      );
    });
  });

  group('gdrive', () {
    test('a file link is canonicalized', () {
      expect(
        normalizeUrl('https://drive.google.com/file/d/ABC123/view?usp=sharing'),
        'https://drive.google.com/file/d/ABC123/view',
      );
    });
  });

  group('generic web pages', () {
    test('the host is lowercased and the fragment dropped', () {
      expect(
        normalizeUrl('https://Example.COM/articles/42?utm_source=x#comments'),
        'https://example.com/articles/42',
      );
    });

    test('non-tracking query parameters are kept', () {
      expect(
        normalizeUrl('https://example.com/a?page=2&utm_medium=email'),
        'https://example.com/a?page=2',
      );
    });
  });

  group('robustness', () {
    test('a string that is not a URL is returned unchanged', () {
      expect(normalizeUrl('not a url'), 'not a url');
    });

    test('an empty string is returned unchanged', () {
      expect(normalizeUrl(''), '');
    });
  });
}
