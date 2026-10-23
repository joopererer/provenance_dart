// URL normalization for `prov:sourceUrl` (SPEC §5).

/// Normalizes [url] for storage in `prov:sourceUrl`.
///
/// Applies the rules of SPEC §5: tracking and share parameters are removed,
/// the fragment is dropped, the scheme and host are lowercased, and known
/// platforms are rewritten to their canonical form.
///
/// Short links (`xhslink.com`, `t.co`, `vm.tiktok.com`) have to be expanded
/// over the network before they can be normalized; this function is pure and
/// does not do that.
String normalizeUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return url;

  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();

  switch (host) {
    case 'www.xiaohongshu.com':
    case 'xiaohongshu.com':
      return _normalizeXiaohongshu(uri) ?? _normalizeGeneric(uri, scheme, host);
    case 'www.instagram.com':
    case 'instagram.com':
      return _normalizeInstagram(uri) ?? _normalizeGeneric(uri, scheme, host);
    case 'x.com':
    case 'www.x.com':
    case 'twitter.com':
    case 'www.twitter.com':
      return _normalizeX(uri) ?? _normalizeGeneric(uri, scheme, host);
    case 'drive.google.com':
      return _normalizeGoogleDrive(uri) ?? _normalizeGeneric(uri, scheme, host);
    default:
      return _normalizeGeneric(uri, scheme, host);
  }
}

String? _normalizeXiaohongshu(Uri uri) {
  final segments = uri.pathSegments;
  String? noteId;
  if (segments.length >= 3 &&
      segments[0] == 'discovery' &&
      segments[1] == 'item') {
    noteId = segments[2];
  } else if (segments.length >= 2 && segments[0] == 'explore') {
    noteId = segments[1];
  }
  if (noteId == null || noteId.isEmpty) return null;
  return 'https://www.xiaohongshu.com/explore/$noteId';
}

String? _normalizeInstagram(Uri uri) {
  final segments = uri.pathSegments;
  if (segments.length < 2) return null;
  // Reels use the same canonical `/p/` form (SPEC §5).
  if (segments[0] != 'p' && segments[0] != 'reel' && segments[0] != 'reels') {
    return null;
  }
  final shortcode = segments[1];
  if (shortcode.isEmpty) return null;
  return 'https://www.instagram.com/p/$shortcode/';
}

String? _normalizeX(Uri uri) {
  final segments = uri.pathSegments;
  String? tweetId;
  if (segments.length >= 3 && segments[1] == 'status') {
    tweetId = segments[2];
  } else if (segments.length >= 3 &&
      segments[0] == 'i' &&
      segments[1] == 'status') {
    tweetId = segments[2];
  }
  if (tweetId == null || tweetId.isEmpty) return null;
  return 'https://x.com/i/status/$tweetId';
}

String? _normalizeGoogleDrive(Uri uri) {
  final segments = uri.pathSegments;
  String? fileId;
  if (segments.length >= 3 && segments[0] == 'file' && segments[1] == 'd') {
    fileId = segments[2];
  } else if (segments.isNotEmpty && segments[0] == 'open') {
    fileId = uri.queryParameters['id'];
  }
  if (fileId == null || fileId.isEmpty) return null;
  return 'https://drive.google.com/file/d/$fileId/view';
}

String _normalizeGeneric(Uri uri, String scheme, String host) {
  final query = <String, String>{};
  uri.queryParameters.forEach((key, value) {
    if (!_isTrackingParameter(key)) query[key] = value;
  });

  return Uri(
    scheme: scheme,
    userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
    host: host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
    queryParameters: query.isEmpty ? null : query,
  ).toString();
}

bool _isTrackingParameter(String key) {
  final lower = key.toLowerCase();
  if (lower.startsWith('utm_') || lower.startsWith('share_')) return true;
  return _trackingParameters.contains(lower);
}

const Set<String> _trackingParameters = {
  'fbclid',
  'gclid',
  'igsh',
  'igshid',
  'si',
  'spm',
  'shareredid',
  'xsec_token',
  'xsec_source',
  'apptime',
  'author_share',
  'xhsshare',
  'track_code',
  'app_platform',
  'app_version',
  'ignoreengage',
  'dlrf',
  'xtok',
  'img_index',
  'usp',
};
