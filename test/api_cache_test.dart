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
      // The mock is shared across the group, so clear recorded interactions
      // and stubs between tests — otherwise a verifyNever here trips over a
      // call an earlier test made.
      reset(mockApiCacheManager);
      cacheHelper = ApiCacheHelperImplementation.instanceFor(
          apiCacheManager: mockApiCacheManager);
    });
    String url = "test_url";
    String data = "Test data";
    String cacheKey = "api_cache_$url";

    test("setCacheData - Set cache data and return true on success", () async {
      when(() => mockApiCacheManager.addCacheData(any()))
          .thenAnswer((invocation) async => true);
      final result = await cacheHelper.setCacheData(url, data);
      expect(result, true);
    });

    test("getCacheData -  Test caching and retriving data", () async {
      final expectedData = APICacheDBModel(key: url, syncData: data);
      when(() => mockApiCacheManager.addCacheData(expectedData))
          .thenAnswer((invocation) async => true);
      when(() => mockApiCacheManager.getCacheData(cacheKey))
          .thenAnswer((invocation) async => expectedData);
      final result = await cacheHelper.getCacheData(url);
      expect(result, expectedData);
    });

    test("getCacheData - returns null on a miss instead of throwing", () async {
      // APICacheManager.getCacheData does `.first` on an empty query result,
      // so an uncached key threw StateError before 2.0.0 despite the nullable
      // return type.
      when(() => mockApiCacheManager.getCacheData(cacheKey))
          .thenThrow(StateError('No element'));

      expect(await cacheHelper.getCacheData(url), isNull);
    });

    test("getCacheData - reads through duplicate rows rather than giving up",
        () async {
      // isAPICacheKeyExist answers `rows.length == 1`, so it reports a
      // duplicated key as missing. Guarding on it would turn a recoverable
      // state into a permanent miss; `.first` copes fine.
      final expectedData = APICacheDBModel(key: url, syncData: data);
      when(() => mockApiCacheManager.isAPICacheKeyExist(cacheKey))
          .thenAnswer((_) async => false);
      when(() => mockApiCacheManager.getCacheData(cacheKey))
          .thenAnswer((_) async => expectedData);

      expect(await cacheHelper.getCacheData(url), expectedData);
    });

    test("getCacheData - treats an empty entry as a miss", () async {
      when(() => mockApiCacheManager.getCacheData(cacheKey))
          .thenAnswer((_) async => APICacheDBModel(key: url, syncData: ''));

      expect(await cacheHelper.getCacheData(url), isNull);
    });

    test("setCacheData - serialises concurrent writes to the same key",
        () async {
      // addCacheData is check-then-act with no transaction, so overlapping
      // writes would both insert and leave duplicate rows. Request
      // de-duplication makes concurrent same-key writes routine.
      var inFlight = 0;
      var maxConcurrent = 0;
      when(() => mockApiCacheManager.addCacheData(any())).thenAnswer((_) async {
        inFlight++;
        maxConcurrent = inFlight > maxConcurrent ? inFlight : maxConcurrent;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        inFlight--;
        return true;
      });

      await Future.wait([
        cacheHelper.setCacheData(url, 'first'),
        cacheHelper.setCacheData(url, 'second'),
        cacheHelper.setCacheData(url, 'third'),
      ]);

      expect(maxConcurrent, 1);
      verify(() => mockApiCacheManager.addCacheData(any())).called(3);
    });

    test("setCacheData - different keys still write in parallel", () async {
      var inFlight = 0;
      var maxConcurrent = 0;
      when(() => mockApiCacheManager.addCacheData(any())).thenAnswer((_) async {
        inFlight++;
        maxConcurrent = inFlight > maxConcurrent ? inFlight : maxConcurrent;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        inFlight--;
        return true;
      });

      await Future.wait([
        cacheHelper.setCacheData('a', 'one'),
        cacheHelper.setCacheData('b', 'two'),
      ]);

      expect(maxConcurrent, 2);
    });

    test("setCacheData - a failed write does not block the next one", () async {
      var calls = 0;
      when(() => mockApiCacheManager.addCacheData(any())).thenAnswer((_) async {
        calls++;
        if (calls == 1) throw StateError('disk full');
        return true;
      });

      final first = cacheHelper.setCacheData(url, 'first');
      final second = cacheHelper.setCacheData(url, 'second');

      await expectLater(first, throwsStateError);
      expect(await second, isTrue);
    });

    test("isCacheExist - Test cache existence", () async {
      when(() => mockApiCacheManager.isAPICacheKeyExist(cacheKey))
          .thenAnswer((invocation) async => true);

      bool cacheExistsAfter = await cacheHelper.isCacheExist(url);
      expect(cacheExistsAfter, true);
    });

    test("getCacheData - returns fresh data when within maxAge", () async {
      final freshData = APICacheDBModel(
        key: url,
        syncData: data,
        syncTime: DateTime.now()
            .subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
      );
      when(() => mockApiCacheManager.getCacheData(cacheKey))
          .thenAnswer((invocation) async => freshData);

      final result = await cacheHelper.getCacheData(
        url,
        maxAge: const Duration(minutes: 5),
      );

      expect(result, freshData);
      verifyNever(() => mockApiCacheManager.deleteCache(cacheKey));
    });

    test(
        "getCacheData - returns null and clears the entry when older than maxAge",
        () async {
      final staleData = APICacheDBModel(
        key: url,
        syncData: data,
        syncTime: DateTime.now()
            .subtract(const Duration(minutes: 10))
            .millisecondsSinceEpoch,
      );
      when(() => mockApiCacheManager.getCacheData(cacheKey))
          .thenAnswer((invocation) async => staleData);
      when(() => mockApiCacheManager.deleteCache(cacheKey))
          .thenAnswer((invocation) async => true);

      final result = await cacheHelper.getCacheData(
        url,
        maxAge: const Duration(minutes: 5),
      );

      expect(result, isNull);
      verify(() => mockApiCacheManager.deleteCache(cacheKey)).called(1);
    });

    test("clearCache - Test cache clearing", () async {
      when(() => mockApiCacheManager.deleteCache(cacheKey))
          .thenAnswer((invocation) async => true);

      var result = await cacheHelper.clearCache(url);

      expect(result, true);
    });

    test('clearAllCache - Test clearing all cache', () async {
      when(() => mockApiCacheManager.emptyCache())
          .thenAnswer((invocation) async {});

      // Clear all cache
      await cacheHelper.clearAllCache();

      verify(() => mockApiCacheManager.emptyCache()).called(1);
    });
  });
}
