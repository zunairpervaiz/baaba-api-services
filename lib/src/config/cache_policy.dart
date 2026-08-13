/// How a `GET` request should interact with the local response cache.
///
/// Only `get` and `getAs` accept a policy — a cache policy on a `POST` has no
/// meaning, so it is deliberately not expressible.
///
/// Nothing is cached unless you ask for it: the default is [networkOnly],
/// which behaves exactly as the package did before caching existed.
///
/// **Example — show something instantly, refresh in the background:**
///
/// ```dart
/// final result = await api.get(
///   endpoint: '/products',
///   cachePolicy: CachePolicy.cacheFirst,
///   cacheMaxAge: const Duration(minutes: 10),
/// );
/// ```
///
/// **Example — always prefer live data, survive going offline:**
///
/// ```dart
/// final result = await api.get(
///   endpoint: '/products',
///   cachePolicy: CachePolicy.networkFirst,
/// );
///
/// result.fold(
///   (failure) => showError(failure.message),
///   (response) {
///     if (response.isFromCache) showBanner('Showing offline data');
///     render(response.data);
///   },
/// );
/// ```
///
/// > Cached entries are **not** scoped per user. Call
/// > `ApiCacheHelper.instance.clearAllCache()` on logout, or the next user
/// > will read the previous user's responses.
enum CachePolicy {
  /// Never read or write the cache. The default, and the pre-2.0.0 behaviour.
  networkOnly,

  /// Return a fresh cached entry without touching the network. On a miss (or
  /// an entry older than `cacheMaxAge`), go to the network and store the
  /// result.
  ///
  /// Fastest, but can show data that is up to `cacheMaxAge` old.
  cacheFirst,

  /// Try the network first and store whatever comes back. If the request
  /// fails, fall back to the cached entry; if there is no cached entry, the
  /// original network failure is returned unchanged.
  ///
  /// The right default for offline tolerance — the user gets live data when
  /// online and the last-known data when not.
  networkFirst,

  /// Read only from the cache and never touch the network. A miss returns a
  /// `Failure` with `ErrorSource.cacheError`.
  ///
  /// Useful for rendering a screen in a known-offline state without emitting
  /// a request that is going to fail anyway.
  cacheOnly,
}
