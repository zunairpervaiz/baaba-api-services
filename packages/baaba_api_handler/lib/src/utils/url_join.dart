/// Slash handling between `ApiConfig.baseUrl` and a relative endpoint.
///
/// Dio joins the two by plain concatenation and then collapses `//` — but
/// only when the url contains `:/` exactly once. So `https://x/api` +
/// `users` became `https://x/apiusers`, and `https://x/` +
/// `/cb?next=https://y` kept its double slash. These two functions remove
/// both cases: the base never ends in `/`, and a relative endpoint always
/// starts with one.
library;

/// Whether [endpoint] is absolute, and so bypasses `baseUrl` — the same test
/// Dio applies.
bool isAbsoluteEndpoint(String endpoint) =>
    endpoint.startsWith('http://') || endpoint.startsWith('https://');

/// [baseUrl] without trailing slashes, for the Dio client's `BaseOptions`.
String normalizeBaseUrl(String? baseUrl) {
  var base = baseUrl ?? '';
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  return base;
}

/// The path to hand Dio for [endpoint], joined to a client whose base was
/// [baseUrl] before [normalizeBaseUrl] trimmed it.
///
/// Only a relative endpoint missing its leading slash changes — `users`
/// becomes `/users` — and only when there is a base to join it to. An
/// endpoint written `/auth/login` reaches interceptors, `skipRefresh` and the
/// observer exactly as written.
String resolveEndpointPath(String? baseUrl, String endpoint) {
  final base = baseUrl ?? '';
  if (base.isEmpty || isAbsoluteEndpoint(endpoint)) return endpoint;
  // The base is the resource itself; keep the slash the caller wrote on it,
  // which trimming the base for Dio would otherwise drop.
  if (endpoint.isEmpty) return base.endsWith('/') ? '/' : '';
  // A bare query (`?page=2`) belongs to the base itself.
  if (endpoint.startsWith('/') || endpoint.startsWith('?')) return endpoint;
  return '/$endpoint';
}
