import 'dart:convert';

import 'package:api_cache_manager/api_cache_manager.dart';
import 'package:api_cache_manager/models/cache_db_model.dart';

/// A class responsible for managing caching of API data.
abstract interface class ApiCacheHelper {
  /// It starts as null and will be initialized when first accessed.
  static ApiCacheHelper? _instance;

  /// Define a static getter for accessing the singleton instance of ApiCacheHelper.
  /// If the instance is not already initialized, create a new one using the factory constructor.
  /// Return the existing or newly created instance.
  //coverage:ignore-start
  static ApiCacheHelper get instance {
    _instance ??= ApiCacheHelperImplementation.instanceFor(
        apiCacheManager: APICacheManager());
    return _instance!;
  }

  /// Retrieves cached data corresponding to the provided URL asynchronously.
  ///
  /// Returns `null` on a miss, and never throws — see the implementation note
  /// about the underlying package's behaviour on an unknown key.
  ///
  /// Parameters:
  ///   url: The URL for which cached data is requested.
  ///   maxAge: optional freshness window. If the cached entry is older than
  ///     [maxAge], it is treated as a miss — the stale entry is cleared and
  ///     `null` is returned instead of stale data. Omit to return cached data
  ///     regardless of age (previous behaviour).
  Future<APICacheDBModel?> getCacheData(String url, {Duration? maxAge});

  /// Sets cached data for the provided URL with the given data asynchronously.
  ///
  /// Parameters:
  ///   url: The URL for which data is to be cached.
  ///   data: The data to be cached.
  ///   maxEntries: caps how many entries the cache keeps. When this write
  ///     pushes it past the cap, the oldest entries are deleted until it fits.
  ///     `null` leaves the cache unbounded.
  ///   maxBytes: caps the combined size of cached bodies, evicting oldest-first
  ///     the same way. `null` leaves it unbounded.
  ///
  /// Returns:
  ///   A future that completes with a boolean value indicating the success of the caching operation.
  ///   Returns true if the data is successfully cached, otherwise false.
  ///
  /// Eviction is best-effort: a failure to prune never fails the write, since
  /// the response itself is already safely stored.
  Future<bool> setCacheData(
    String url,
    String data, {
    int? maxEntries,
    int? maxBytes,
  });

  /// Checks whether cached data exists for the provided URL asynchronously.
  /// Parameters:
  ///   url: The URL for which cached data existence is to be checked.
  /// Returns:
  ///   A future that completes with a boolean value indicating whether cached data exists for the URL.
  ///   Returns true if cached data exists for the URL, otherwise false.
  Future<bool> isCacheExist(String url);

  /// Clears cached data associated with the provided URL asynchronously.
  /// Parameters:
  ///   url: The URL for which cached data is to be cleared.
  /// Returns:
  ///   A future that completes with a boolean value indicating the success of the cache clearing operation.
  ///   Returns true if cached data is successfully cleared for the URL, otherwise false.
  Future<bool> clearCache(String url);

  /// Clears all cached data stored by the API Cache Manager asynchronously.
  /// Returns:
  ///   A future that completes when all cached data is successfully cleared.
  Future<void> clearAllCache();
}

class ApiCacheHelperImplementation implements ApiCacheHelper {
  /// This variable will be initialized once and remain unchanged afterwards.
  late final APICacheManager _apiCacheManager;

  /// It starts as null and will be initialized when first accessed.
  static ApiCacheHelperImplementation? _instance;

  /// Define a static getter for accessing the singleton instance of ApiCacheHelper.
  /// If the instance is not already initialized, create a new one using the factory constructor.
  /// Return the existing or newly created instance.
  //coverage:ignore-start
  static ApiCacheHelperImplementation get instance {
    _instance ??= ApiCacheHelperImplementation.instanceFor(
        apiCacheManager: APICacheManager());
    return _instance!;
  }
  //coverage:ignore-end

  /// Private constructor for creating an instance of ApiCacheHelper with a given API Cache Manager.
  /// The provided apiCacheManager is stored in the _apiCacheManager field.
  ApiCacheHelperImplementation._({required APICacheManager apiCacheManager})
      : _apiCacheManager = apiCacheManager;

  // Factory constructor for creating an instance of ApiCacheHelper with a given API Cache Manager.
  // This provides an easier way to create an instance using a custom API Cache Manager.
  // Returns a new instance of ApiCacheHelper with the provided apiCacheManager.
  factory ApiCacheHelperImplementation.instanceFor(
      {required APICacheManager apiCacheManager}) {
    return ApiCacheHelperImplementation._(apiCacheManager: apiCacheManager);
  }

  // Prefix for cache keys
  final String _cacheKeyPrefix = "api_cache_";

  @override
  Future<APICacheDBModel?> getCacheData(String url, {Duration? maxAge}) async {
    var cacheKey = _cacheKeyPrefix + url;

    // APICacheManager.getCacheData does `.first` on the query result, so a key
    // that was never cached throws StateError. Catching that is the miss
    // check.
    //
    // Deliberately *not* guarded with isAPICacheKeyExist first. That returns
    // `rows.length == 1`, so it answers false for a key with duplicate rows
    // just as it does for a missing one — turning a recoverable state into a
    // permanent miss. `.first` copes with duplicates perfectly well, and this
    // is one query instead of two.
    final APICacheDBModel cached;
    try {
      cached = await _apiCacheManager.getCacheData(cacheKey);
    } catch (_) {
      return null;
    }

    if (cached.syncData.isEmpty) return null;

    if (maxAge != null && cached.syncTime != null) {
      final cachedAt = DateTime.fromMillisecondsSinceEpoch(cached.syncTime!);
      if (DateTime.now().difference(cachedAt) > maxAge) {
        await _apiCacheManager.deleteCache(cacheKey);
        return null;
      }
    }

    return cached;
  }

  /// Writes in flight, keyed by cache key, so same-key writes run in sequence.
  final Map<String, Future<bool>> _pendingWrites = {};

  /// Tracks what is in the cache so entries can be evicted oldest-first.
  ///
  /// `APICacheManager` exposes no way to list keys — only get, add, delete and
  /// empty — so there is nothing to sort by age without keeping this
  /// alongside. Maps cache key to `[writtenAtMillis, byteLength]`, and is
  /// itself stored as a cache row under [_indexKey].
  ///
  /// Only touched when a caller actually asks for a bound, so an unbounded
  /// cache pays nothing for it.
  Map<String, List<int>>? _index;

  /// Serialises index mutations. Per-key write chaining does not cover this:
  /// writes for *different* keys run concurrently and all touch this one row.
  Future<void> _indexLock = Future<void>.value();

  /// Deliberately without [_cacheKeyPrefix], so no real cache key can collide
  /// with it and the index can never be mistaken for a cached response.
  static const String _indexKey = '__baaba_cache_index__';

  @override
  Future<bool> setCacheData(
    String url,
    String data, {
    int? maxEntries,
    int? maxBytes,
  }) {
    var cacheKey = _cacheKeyPrefix + url;

    // APICacheManager.addCacheData is check-then-act — it asks
    // isAPICacheKeyExist and then inserts or updates — with no transaction
    // around the pair. Two concurrent writes for one key therefore both see
    // "absent" and both insert, leaving duplicate rows. That state is not
    // self-correcting: isAPICacheKeyExist answers `rows.length == 1`, so it
    // then reports the key as missing forever while every further write adds
    // another row.
    //
    // Request de-duplication makes this the ordinary path rather than a rare
    // race: two callers collapsed onto one network call each write the
    // response afterwards. Chaining writes per key keeps the check and the act
    // together.
    Future<bool> run() => _write(cacheKey, data, maxEntries, maxBytes);

    final previous = _pendingWrites[cacheKey];
    final write = previous == null
        ? run()
        : previous.then((_) => run(), onError: (_) => run());

    _pendingWrites[cacheKey] = write;
    return write.whenComplete(() {
      // Only clear if no later write has taken the slot.
      if (identical(_pendingWrites[cacheKey], write)) {
        _pendingWrites.remove(cacheKey);
      }
    });
  }

  Future<bool> _write(
    String cacheKey,
    String data,
    int? maxEntries,
    int? maxBytes,
  ) async {
    final saved = await _apiCacheManager
        .addCacheData(APICacheDBModel(key: cacheKey, syncData: data));

    if (saved && (maxEntries != null || maxBytes != null)) {
      await _guardIndex(
          () => _record(cacheKey, data.length, maxEntries, maxBytes));
    }
    return saved;
  }

  /// Runs [action] after any index work already queued, and keeps the chain
  /// usable whatever it does.
  Future<void> _guardIndex(Future<void> Function() action) {
    final next = _indexLock.then((_) => action(), onError: (_) => action());
    _indexLock = next;
    return next;
  }

  /// Notes the write in the index and prunes until the cache fits its bounds.
  ///
  /// Never throws: a cache that cannot be pruned is a cache that is too big,
  /// which is not worth failing a request over.
  Future<void> _record(
    String key,
    int bytes,
    int? maxEntries,
    int? maxBytes,
  ) async {
    try {
      final index = await _loadIndex();
      index[key] = [DateTime.now().millisecondsSinceEpoch, bytes];

      final oldestFirst = index.keys.toList()
        ..sort((a, b) => index[a]![0].compareTo(index[b]![0]));

      var count = index.length;
      var total = index.values.fold<int>(0, (sum, e) => sum + e[1]);

      for (final candidate in oldestFirst) {
        final overCount = maxEntries != null && count > maxEntries;
        final overBytes = maxBytes != null && total > maxBytes;
        if (!overCount && !overBytes) break;

        // Never evict the entry this write just stored — a cap of zero or one
        // would otherwise throw away the response we were asked to cache.
        if (candidate == key) continue;

        final entry = index.remove(candidate);
        if (entry == null) continue;
        count--;
        total -= entry[1];
        await _apiCacheManager.deleteCache(candidate);
      }

      await _saveIndex(index);
    } catch (_) {}
  }

  Future<Map<String, List<int>>> _loadIndex() async {
    final cached = _index;
    if (cached != null) return cached;

    final loaded = <String, List<int>>{};
    try {
      // Same `.first`-on-empty behaviour as any other key: a missing index is
      // a StateError, and an empty index is the right answer for it.
      final raw = await _apiCacheManager.getCacheData(_indexKey);
      final decoded = jsonDecode(raw.syncData);
      if (decoded is Map) {
        decoded.forEach((k, v) {
          if (v is List && v.length == 2 && v[0] is int && v[1] is int) {
            loaded[k.toString()] = [v[0] as int, v[1] as int];
          }
        });
      }
    } catch (_) {}

    return _index = loaded;
  }

  Future<void> _saveIndex(Map<String, List<int>> index) async {
    _index = index;
    await _apiCacheManager.addCacheData(
      APICacheDBModel(key: _indexKey, syncData: jsonEncode(index)),
    );
  }

  @override
  Future<bool> isCacheExist(String url) async {
    var cacheKey = _cacheKeyPrefix + url;
    // Checks whether the cache key exists in the API Cache Manager asynchronously and returns the result.
    return await _apiCacheManager.isAPICacheKeyExist(cacheKey);
  }

  @override
  Future<bool> clearCache(String url) async {
    var cacheKey = _cacheKeyPrefix + url;
    // Deletes cached data corresponding to the constructed cache key asynchronously and returns the operation's success status.
    final deleted = await _apiCacheManager.deleteCache(cacheKey);

    // Drop it from the index too, or its bytes keep counting against the cap
    // and eviction starts discarding live entries to make room for a row that
    // no longer exists.
    if (_index != null) {
      await _guardIndex(() async {
        final index = await _loadIndex();
        if (index.remove(cacheKey) != null) await _saveIndex(index);
      });
    }
    return deleted;
  }

  @override
  Future clearAllCache() async {
    // Empties the cache maintained by the API Cache Manager asynchronously.
    // That drops the index row along with everything else, so the in-memory
    // copy has to go as well or eviction would price entries that are gone.
    return _guardIndex(() async {
      await _apiCacheManager.emptyCache();
      _index = <String, List<int>>{};
    });
  }
}
