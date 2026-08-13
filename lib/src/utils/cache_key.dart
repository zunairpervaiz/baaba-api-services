/// Builds the keys used for response caching and in-flight de-duplication.
///
/// Both need the same property: two calls that would hit the same URL with the
/// same inputs must produce the same string, and two calls that would not must
/// not.
///
/// The pre-2.0.0 cache key was just the raw url, so `/users?page=1` and
/// `/users?page=2` **collided** whenever the query lived in `params` rather
/// than the path — the second page would overwrite the first in the cache.
/// Query parameters are part of the key here, sorted so that argument order
/// never changes the result.
///
/// Keys are not hashed. A digest would need to be stable across app restarts
/// (`String.hashCode` is not, and a cryptographic hash would mean a new
/// dependency), and SQLite handles long `TEXT` keys without complaint.
library;

/// Joins [baseUrl] and [endpoint], leaving an already-absolute [endpoint]
/// alone so a call to a CDN or third-party host keys correctly.
String canonicalUrl(String? baseUrl, String endpoint) {
  final isAbsolute =
      endpoint.startsWith('http://') || endpoint.startsWith('https://');
  if (isAbsolute || baseUrl == null || baseUrl.isEmpty) return endpoint;

  final left = baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;
  final right = endpoint.startsWith('/') ? endpoint : '/$endpoint';
  return '$left$right';
}

/// Encodes [params] deterministically: keys sorted, values in the order given
/// (list order can be meaningful to a server, so it is preserved).
String canonicalQuery(Map<String, dynamic>? params) {
  if (params == null || params.isEmpty) return '';

  final keys = params.keys.toList()..sort();
  final pairs = <String>[];

  for (final key in keys) {
    final value = params[key];
    final encodedKey = Uri.encodeQueryComponent(key);
    if (value is Iterable) {
      for (final item in value) {
        pairs.add(_pair(encodedKey, item));
      }
    } else {
      pairs.add(_pair(encodedKey, value));
    }
  }

  return pairs.join('&');
}

/// Encodes one pair the way Dio does.
///
/// A null value becomes a bare key, matching `Transformer.urlEncodeQueryMap`.
/// Writing it as `key=null` instead would give `{'a': null}` and
/// `{'a': 'null'}` — two genuinely different URLs — the same cache key.
String _pair(String encodedKey, Object? value) => value == null
    ? encodedKey
    : '$encodedKey=${Uri.encodeQueryComponent('$value')}';

/// Key for a cached `GET` response.
String buildCacheKey({
  String? baseUrl,
  required String endpoint,
  Map<String, dynamic>? params,
}) {
  final query = canonicalQuery(params);
  final url = canonicalUrl(baseUrl, endpoint);
  return query.isEmpty ? url : '$url?$query';
}

/// Key identifying an in-flight request, for de-duplication.
///
/// Includes the method and body so that two calls differing only in payload
/// are never collapsed into one.
String buildRequestKey({
  required String method,
  String? baseUrl,
  required String endpoint,
  Map<String, dynamic>? params,
  Object? data,
}) {
  final base = buildCacheKey(
    baseUrl: baseUrl,
    endpoint: endpoint,
    params: params,
  );
  final body = data == null ? '' : '|$data';
  return '$method $base$body';
}
