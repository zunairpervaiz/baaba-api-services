import 'package:api_cache_manager/api_cache_manager.dart';
import 'package:api_cache_manager/models/cache_db_model.dart';
import 'package:baaba_api_handler/src/api_cache_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
// import 'package:sqflite_common_ffi/sqflite_ffi.dart';
// import 'package:ts_essentials/src/features/api_handler/lib/api_cache_helper.dart';

class MockApiCacheManager extends Mock implements APICacheManager {}

void main() {
  runApiCacheTests();
}

void runApiCacheTests() {
  group('API Cache Tests', () {
    late MockApiCacheManager mockApiCacheManager;
    late ApiCacheHelper cacheHelper;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      mockApiCacheManager = MockApiCacheManager();
      registerFallbackValue(APICacheDBModel(key: 'key', syncData: 'syncData'));
    });

    setUp(() {
      cacheHelper = ApiCacheHelperImplementation.instanceFor(apiCacheManager: mockApiCacheManager);
    });
    String url = "test_url";
    String data = "Test data";
    String cacheKey = "api_cache_$url";

    test("setCacheData - Set cache data and return true on success", () async {
      when(() => mockApiCacheManager.addCacheData(any())).thenAnswer((invocation) async => true);
      final result = await cacheHelper.setCacheData(url, data);
      expect(result, true);
    });

    test("getCacheData -  Test caching and retriving data", () async {
      final expectedData = APICacheDBModel(key: url, syncData: data);
      when(() => mockApiCacheManager.addCacheData(expectedData)).thenAnswer((invocation) async => true);
      when(() => mockApiCacheManager.getCacheData(cacheKey)).thenAnswer((invocation) async => expectedData);
      final result = await cacheHelper.getCacheData(url);
      expect(result, expectedData);
    });

    test("isCacheExist - Test cache existence", () async {
      when(() => mockApiCacheManager.isAPICacheKeyExist(cacheKey)).thenAnswer((invocation) async => true);

      bool cacheExistsAfter = await cacheHelper.isCacheExist(url);
      expect(cacheExistsAfter, true);
    });

    test("clearCache - Test cache clearing", () async {
      when(() => mockApiCacheManager.deleteCache(cacheKey)).thenAnswer((invocation) async => true);

      var result = await cacheHelper.clearCache(url);

      expect(result, true);
    });

    test('clearAllCache - Test clearing all cache', () async {
      when(() => mockApiCacheManager.emptyCache()).thenAnswer((invocation) async {});

      // Clear all cache
      await cacheHelper.clearAllCache();

      verify(() => mockApiCacheManager.emptyCache()).called(1);
    });
  });
}
