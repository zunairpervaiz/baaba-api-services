import 'dart:convert';

/// Whether the JWT [token] has expired, or will within [skew].
///
/// Reads the `exp` claim from the payload — base64url, with any missing
/// padding restored — and compares it with the current time plus [skew], so
/// a token about to die is treated as dead and refreshed before a request
/// carries it, not after the server rejects it.
///
/// ```dart
/// jwtExpired(token);                                   // 30s of margin
/// jwtExpired(token, skew: const Duration(minutes: 2)); // more, for slow links
/// ```
///
/// **The signature is not checked.** This decides when to refresh, which is
/// a client-side convenience — the server still verifies the token. Never use
/// it to decide whether to *trust* one.
///
/// - A **malformed** token — not three dot-separated parts, a payload that
///   is not base64url JSON, an `exp` that is not a number — counts as
///   expired. Refreshing is the safe answer to a token you cannot read.
/// - A token with **no `exp`** claim never expires, per RFC 7519, and returns
///   `false`. Treating it as expired would refresh before every request.
///
/// [now] is for tests; it defaults to the current time.
///
/// To plug it into `AuthConfig.isTokenExpired`, see [jwtExpiryCheck].
bool jwtExpired(
  String token, {
  Duration skew = const Duration(seconds: 30),
  DateTime? now,
}) {
  final parts = token.split('.');
  if (parts.length != 3 || parts[1].isEmpty) return true;
  try {
    final payload = utf8.decode(
      base64Url.decode(base64Url.normalize(parts[1])),
    );
    final claims = jsonDecode(payload);
    if (claims is! Map) return true;
    if (!claims.containsKey('exp')) return false;
    final exp = claims['exp'];
    if (exp is! num) return true;
    // Compared in seconds, as numbers: building a DateTime from a far-future
    // `exp` would overflow and read as expired.
    final threshold =
        (now ?? DateTime.now()).add(skew).millisecondsSinceEpoch / 1000;
    return threshold >= exp;
  } catch (_) {
    return true;
  }
}

/// [jwtExpired], shaped for `AuthConfig.isTokenExpired`: reads the token with
/// [getToken] — usually the same function given to `AuthConfig.getToken` —
/// and checks it.
///
/// ```dart
/// AuthConfig(
///   getToken: storage.readAccessToken,
///   isTokenExpired: jwtExpiryCheck(storage.readAccessToken),
///   onTokenRefresh: authRepository.refresh,
/// )
/// ```
///
/// No token at all (`null` or empty) is not "expired": there is no session
/// to refresh, and the request goes out without auth as it would anyway.
Future<bool> Function() jwtExpiryCheck(
  Future<String?> Function() getToken, {
  Duration skew = const Duration(seconds: 30),
}) {
  return () async {
    final token = await getToken();
    if (token == null || token.isEmpty) return false;
    return jwtExpired(token, skew: skew);
  };
}
