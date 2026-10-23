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
