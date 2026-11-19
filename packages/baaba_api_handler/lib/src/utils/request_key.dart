/// Builds the keys used for in-flight de-duplication.
///
/// Two calls that would hit the same URL with the same inputs must produce the
/// same string, and two calls that would not must not. Query parameters are
/// part of the key, sorted so that argument order never changes the result —
/// a raw url would make `/users?page=1` and `/users?page=2` collide whenever
/// the query lived in `params` rather than the path.
library;

import 'dart:convert';

import 'package:baaba_api_handler/src/utils/url_join.dart';

/// The url Dio will request for [endpoint]: built with the same functions
/// the service layer uses, so two endpoints Dio sends to different urls —
/// `''` and `'/'`, `'?p=2'` and `'/?p=2'` — never share a key.
String _canonicalUrl(String? baseUrl, String endpoint) {
  if (isAbsoluteEndpoint(endpoint) || baseUrl == null || baseUrl.isEmpty) {
    return endpoint;
  }
  return '${normalizeBaseUrl(baseUrl)}${resolveEndpointPath(baseUrl, endpoint)}';
}

/// Encodes [params] deterministically: keys sorted, values in the order given
/// (list order can be meaningful to a server, so it is preserved).
String _canonicalQuery(Map<String, dynamic>? params) {
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
/// `{'a': 'null'}` — two genuinely different URLs — the same key.
String _pair(String encodedKey, Object? value) => value == null
    ? encodedKey
    : '$encodedKey=${Uri.encodeQueryComponent('$value')}';

/// The canonical url, query included, that [buildRequestKey] builds on.
String buildUrlKey({
  String? baseUrl,
  required String endpoint,
  Map<String, dynamic>? params,
}) {
  final query = _canonicalQuery(params);
  final url = _canonicalUrl(baseUrl, endpoint);
  return query.isEmpty ? url : '$url?$query';
}

/// Key identifying an in-flight request, for de-duplication, or `null` when
/// the request cannot be keyed safely and so must not be collapsed.
///
/// Everything that changes what comes back is part of the key: the method and
/// body, so two calls differing only in payload stay apart; the [headers], so
/// an `Accept-Language: ur` caller is not handed the English response; and the
/// [responseType], so a caller asking for bytes is not handed a decoded map.
///
/// The body is JSON-encoded rather than `toString()`ed: a model without its
/// own `toString` prints as `Instance of 'User'`, which would make every user
/// the same request. A body that will not encode returns `null`.
String? buildRequestKey({
  required String method,
  String? baseUrl,
  required String endpoint,
  Map<String, dynamic>? params,
  Object? data,
  Map<String, String>? headers,
  String? responseType,
  Map<String, dynamic>? extra,
}) {
  final String body;
  final String extras;
  try {
    body = data == null ? '' : '|${jsonEncode(data)}';
    // An interceptor or retryIf may act on it, so two calls differing only
    // in `extra` are not the same request.
    extras = extra == null || extra.isEmpty ? '' : '|x:${jsonEncode(extra)}';
  } catch (_) {
    return null;
  }

  final base = buildUrlKey(
    baseUrl: baseUrl,
    endpoint: endpoint,
    params: params,
  );
  final type = responseType == null ? '' : '|as:$responseType';
  return '$method $base$type${_canonicalHeaders(headers)}$extras$body';
}

/// Header names are case-insensitive, so they are lowercased before sorting.
String _canonicalHeaders(Map<String, String>? headers) {
  if (headers == null || headers.isEmpty) return '';
  final pairs =
      [
        for (final MapEntry(:key, :value) in headers.entries)
          [key.toLowerCase(), value],
      ]..sort((a, b) {
        final byName = a[0].compareTo(b[0]);
        return byName != 0 ? byName : a[1].compareTo(b[1]);
      });
  // JSON-encoded so a value containing `,` or `:` — common in headers — can
  // never be read as a boundary between two pairs.
  return '|h:${jsonEncode(pairs)}';
}
