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
  /// Parameters:
  ///   url: The URL for which data is to be cached.
  ///   data: The data to be cached.
  /// Returns:
  ///   A future that completes with a boolean value indicating the success of the caching operation.
  ///   Returns true if the data is successfully cached, otherwise false.
  Future<bool> setCacheData(String url, String data);

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

  @override
  Future<bool> setCacheData(String url, String data) {
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
    final previous = _pendingWrites[cacheKey];
    final write = previous == null
        ? _write(cacheKey, data)
        : previous.then((_) => _write(cacheKey, data),
            onError: (_) => _write(cacheKey, data));

    _pendingWrites[cacheKey] = write;
    return write.whenComplete(() {
      // Only clear if no later write has taken the slot.
      if (identical(_pendingWrites[cacheKey], write)) {
        _pendingWrites.remove(cacheKey);
      }
    });
  }

  Future<bool> _write(String cacheKey, String data) {
    return _apiCacheManager
        .addCacheData(APICacheDBModel(key: cacheKey, syncData: data));
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
    return await _apiCacheManager.deleteCache(cacheKey);
  }

  @override
  Future clearAllCache() async {
    // Empties the cache maintained by the API Cache Manager asynchronously.
    return await _apiCacheManager.emptyCache();
  }
}
