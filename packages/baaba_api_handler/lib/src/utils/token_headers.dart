/// Which request headers carry the session token, so the transport can keep
/// them from following a redirect to another origin.
///
/// `HttpClient` drops a fixed list of credential headers on a cross-origin
/// redirect ([redirectStrippedHeaders]). A token in any other header — an
/// `AuthConfig.headerBuilder` returning `{'X-Auth-Token': token}` — would be
/// sent to whatever host the server redirects to. `TokenRefreshInterceptor`
/// records the names it added; `PinnedRoutingAdapter` reads them.
library;

import 'package:dio/dio.dart';

/// Key in `RequestOptions.extra` under which the interceptor lists the
/// (lowercased) names of the headers it added. Names only, never values:
/// `extra` is printed by the logger and handed to observers.
const String tokenHeadersKey = '_tokenHeaders';

/// Headers `HttpClient` already drops on a cross-origin redirect.
const Set<String> redirectStrippedHeaders = {
  'authorization',
  'www-authenticate',
  'cookie',
  'cookie2',
  'proxy-authorization',
  'proxy-authenticate',
};

/// The token header names recorded on [options], lowercased.
Set<String> tokenHeaderNames(RequestOptions options) {
  final names = options.extra[tokenHeadersKey];
  if (names is! List) return const {};
  return {
    for (final name in names)
      if (name is String) name.toLowerCase(),
  };
}

/// Whether [options] carries the token in a header `HttpClient` would keep
/// on a cross-origin redirect.
bool carriesUnstrippedTokenHeader(RequestOptions options) => tokenHeaderNames(
  options,
).any((name) => !redirectStrippedHeaders.contains(name));
