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
    _instance ??= ApiCacheHelperImplementation.instanceFor(apiCacheManager: APICacheManager());
    return _instance!;
  }

  /// Retrieves cached data corresponding to the provided URL asynchronously.
  /// Parameters:
  ///   url: The URL for which cached data is requested.
  /// Returns:
  ///   A future that completes with the cached data associated with the URL, if available.
  ///   If no cached data is found for the URL, returns null.
  Future<APICacheDBModel?> getCacheData(String url);

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
    _instance ??= ApiCacheHelperImplementation.instanceFor(apiCacheManager: APICacheManager());
    return _instance!;
  }
  //coverage:ignore-end

  /// Private constructor for creating an instance of ApiCacheHelper with a given API Cache Manager.
  /// The provided apiCacheManager is stored in the _apiCacheManager field.
  ApiCacheHelperImplementation._({required APICacheManager apiCacheManager}) : _apiCacheManager = apiCacheManager;

  // Factory constructor for creating an instance of ApiCacheHelper with a given API Cache Manager.
  // This provides an easier way to create an instance using a custom API Cache Manager.
  // Returns a new instance of ApiCacheHelper with the provided apiCacheManager.
  factory ApiCacheHelperImplementation.instanceFor({required APICacheManager apiCacheManager}) {
    return ApiCacheHelperImplementation._(apiCacheManager: apiCacheManager);
  }

  // Prefix for cache keys
  final String _cacheKeyPrefix = "api_cache_";

  @override
  Future<APICacheDBModel?> getCacheData(String url) async {
    var cacheKey = _cacheKeyPrefix + url;
    // Retrieves cached data using the constructed cache key asynchronously.
    return _apiCacheManager.getCacheData(cacheKey);
  }

  @override
  Future<bool> setCacheData(String url, String data) async {
    var cacheKey = _cacheKeyPrefix + url;
    // Creates a new APICacheDBModel instance with the constructed cache key and the provided data.
    APICacheDBModel dbModel = APICacheDBModel(key: cacheKey, syncData: data);
    // Adds the newly created cache model to the cache asynchronously and returns the operation's success status.
    return await _apiCacheManager.addCacheData(dbModel);
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
