/// Host matching shared by `PinningConfig` and `ProxyConfig`.
library;

/// Whether [host] matches [pattern]: exactly, or — for a pattern written
/// `*.example.com` — as any subdomain of `example.com`, at any depth.
///
/// A wildcard does not match the bare domain: `*.example.com` covers
/// `api.example.com` and `a.b.example.com`, not `example.com`. List both when
/// you mean both. Comparison ignores case, as DNS does, and a trailing dot
/// (`api.example.com.`, the fully-qualified form TLS also accepts) — so it
/// cannot be used to step around a pin. An IPv6 key may be written with or
/// without brackets (`[::1]`, `::1`).
bool hostMatches(String pattern, String host) {
  final p = _normalize(pattern);
  final h = _normalize(host);
  if (p.startsWith('*.')) {
    final suffix = p.substring(1); // ".example.com"
    return h.length > suffix.length && h.endsWith(suffix);
  }
  return p == h;
}

/// The value in [byPattern] whose key best matches [host]: an exact key
/// first, then the longest matching `*.` suffix — so `*.api.example.com`
/// beats `*.example.com` for `v2.api.example.com`. `null` when none match.
V? lookupHost<V>(Map<String, V> byPattern, String host) {
  final h = _normalize(host);
  String? best;
  var bestLength = -1;
  for (final pattern in byPattern.keys) {
    final p = _normalize(pattern);
    if (!p.startsWith('*.')) {
      if (p == h) return byPattern[pattern];
      continue;
    }
    if (hostMatches(p, h) && p.length > bestLength) {
      best = pattern;
      bestLength = p.length;
    }
  }
  return best == null ? null : byPattern[best];
}

String _normalize(String host) {
  var h = host.toLowerCase();
  if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
  if (h.endsWith('.')) h = h.substring(0, h.length - 1);
  return h;
}
