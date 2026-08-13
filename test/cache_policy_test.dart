import 'dart:convert';

import 'package:baaba_api_handler/src/api_service.dart';
import 'package:baaba_api_handler/src/utils/cache_key.dart';
import 'package:baaba_api_handler/src/utils/network_info.dart';
import 'package:baaba_api_handler/ts_api_handler.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockDio extends Mock implements Dio {}

class MockNetworkInfo extends Mock implements NetworkInfo {}

/// In-memory stand-in for the SQLite-backed helper, so these tests exercise
/// the policy logic rather than the database.
class _InMemoryCache implements ApiCacheHelper {
  final Map<String, String> entries = {};
  final List<String> reads = [];

  @override
  Future<APICacheDBModel?> getCacheData(String url, {Duration? maxAge}) async {
    reads.add(url);
    final data = entries[url];
    if (data == null) return null;
    return APICacheDBModel(key: url, syncData: data);
  }

  @override
  Future<bool> setCacheData(String url, String data) async {
    entries[url] = data;
    return true;
  }

  @override
  Future<bool> isCacheExist(String url) async => entries.containsKey(url);

  @override
  Future<bool> clearCache(String url) async => entries.remove(url) != null;

  @override
  Future<void> clearAllCache() async => entries.clear();
}

void main() {
  late MockDio mockDio;
  late MockNetworkInfo mockNetworkInfo;
  late _InMemoryCache cache;
  late ApiServices api;
  late int networkCalls;

  void stubNetwork({Object? body, DioException? error, int statusCode = 200}) {
    final call = when(() => mockDio.request<dynamic>(
          any(),
          data: any(named: 'data'),
          queryParameters: any(named: 'queryParameters'),
          options: any(named: 'options'),
          cancelToken: any(named: 'cancelToken'),
          onSendProgress: any(named: 'onSendProgress'),
          onReceiveProgress: any(named: 'onReceiveProgress'),
        ));

    call.thenAnswer((_) async {
      networkCalls++;
      if (error != null) throw error;
      return Response(
        requestOptions: RequestOptions(path: '/products'),
        statusCode: statusCode,
        data: body,
      );
    });
  }

  DioException serverError() => DioException(
        type: DioExceptionType.connectionError,
        requestOptions: RequestOptions(path: '/products'),
      );

  setUp(() {
    ApiServices.reset();
    networkCalls = 0;
    mockDio = MockDio();
    mockNetworkInfo = MockNetworkInfo();
    cache = _InMemoryCache();

    registerFallbackValue(RequestOptions(path: ''));
    registerFallbackValue(Options());
    when(() => mockNetworkInfo.isConnected).thenAnswer((_) async => true);

    api = ApiServicesImplementation.instanceFor(
      dio: mockDio,
      networkInfo: mockNetworkInfo,
      cacheHelper: cache,
    );
  });

  tearDown(ApiServices.reset);

  group('networkOnly (default)', () {
    test('never reads or writes the cache', () async {
      stubNetwork(body: {'items': []});

      await api.get(endpoint: '/products');

      expect(cache.reads, isEmpty);
      expect(cache.entries, isEmpty);
      expect(networkCalls, 1);
    });
  });

  group('cacheFirst', () {
    test('stores the response on a miss, then serves it without a call',
        () async {
      stubNetwork(body: {'items': 1});

      final first = await api.get(
        endpoint: '/products',
        cachePolicy: CachePolicy.cacheFirst,
      );
      final second = await api.get(
        endpoint: '/products',
        cachePolicy: CachePolicy.cacheFirst,
      );

      expect(networkCalls, 1);
      first.fold((f) => fail('$f'), (r) => expect(r.isFromCache, isFalse));
      second.fold((f) => fail('$f'), (r) {
        expect(r.isFromCache, isTrue);
        expect(r.data, {'items': 1});
      });
    });

    test('does not touch the network even when offline on a hit', () async {
      cache.entries[buildCacheKey(endpoint: '/products')] =
          jsonEncode({'items': 1});
      when(() => mockNetworkInfo.isConnected).thenAnswer((_) async => false);

      final result = await api.get(
        endpoint: '/products',
        cachePolicy: CachePolicy.cacheFirst,
      );

      expect(result.isRight(), isTrue);
      expect(networkCalls, 0);
    });
  });

  group('networkFirst', () {
    test('prefers live data and refreshes the stored copy', () async {
      cache.entries[buildCacheKey(endpoint: '/products')] =
          jsonEncode({'items': 'stale'});
      stubNetwork(body: {'items': 'fresh'});

      final result = await api.get(
        endpoint: '/products',
        cachePolicy: CachePolicy.networkFirst,
      );

      result.fold((f) => fail('$f'), (r) {
        expect(r.isFromCache, isFalse);
        expect(r.data, {'items': 'fresh'});
      });
      expect(
        jsonDecode(cache.entries[buildCacheKey(endpoint: '/products')]!),
        {'items': 'fresh'},
      );
    });

    test('falls back to the cached copy when the request fails', () async {
      cache.entries[buildCacheKey(endpoint: '/products')] =
          jsonEncode({'items': 'stale'});
      stubNetwork(error: serverError());

      final result = await api.get(
        endpoint: '/products',
        cachePolicy: CachePolicy.networkFirst,
      );

      result.fold((f) => fail('Expected the cached fallback, got $f'), (r) {
        expect(r.isFromCache, isTrue);
        expect(r.data, {'items': 'stale'});
      });
    });

    test('returns the original failure when there is nothing cached', () async {
      stubNetwork(error: serverError());

      final result = await api.get(
        endpoint: '/products',
        cachePolicy: CachePolicy.networkFirst,
      );

      result.fold(
        (failure) => expect(failure.errorType, ErrorSource.connectionFailure),
        (_) => fail('Expected a failure'),
      );
    });
  });

  group('cacheOnly', () {
    test('serves a hit without any network call', () async {
      cache.entries[buildCacheKey(endpoint: '/products')] =
          jsonEncode({'items': 1});

      final result = await api.get(
        endpoint: '/products',
        cachePolicy: CachePolicy.cacheOnly,
      );

      expect(networkCalls, 0);
      result.fold((f) => fail('$f'), (r) => expect(r.isFromCache, isTrue));
    });

    test('a miss is a cacheError, not a network call', () async {
      final result = await api.get(
        endpoint: '/products',
        cachePolicy: CachePolicy.cacheOnly,
      );

      expect(networkCalls, 0);
      result.fold(
        (failure) => expect(failure.errorType, ErrorSource.cacheError),
        (_) => fail('Expected a cache miss failure'),
      );
    });
  });

  group('what gets cached', () {
    test('a non-2xx response is not stored', () async {
      stubNetwork(body: {'error': 'nope'}, statusCode: 204);
      // 204 is 2xx and does get stored; use a redirect to prove the guard.
      stubNetwork(body: {'error': 'nope'}, statusCode: 302);

      await api.get(
        endpoint: '/products',
        cachePolicy: CachePolicy.cacheFirst,
      );

      expect(cache.entries, isEmpty);
    });

    test('a body that will not encode does not fail the request', () async {
      stubNetwork(body: Object());

      final result = await api.get(
        endpoint: '/products',
        cachePolicy: CachePolicy.cacheFirst,
      );

      expect(result.isRight(), isTrue);
      expect(cache.entries, isEmpty);
    });
  });

  group('cache keys', () {
    test('query parameters produce distinct entries', () async {
      stubNetwork(body: {'page': 1});

      await api.get(
        endpoint: '/products',
        params: {'page': 1},
        cachePolicy: CachePolicy.cacheFirst,
      );
      await api.get(
        endpoint: '/products',
        params: {'page': 2},
        cachePolicy: CachePolicy.cacheFirst,
      );

      // Two separate calls, two separate entries — before 2.0.0 the second
      // page overwrote the first.
      expect(networkCalls, 2);
      expect(cache.entries, hasLength(2));
    });

    test('argument order does not change the key', () {
      expect(
        buildCacheKey(endpoint: '/p', params: {'a': 1, 'b': 2}),
        buildCacheKey(endpoint: '/p', params: {'b': 2, 'a': 1}),
      );
    });

    test('baseUrl is joined without doubling the slash', () {
      expect(
        buildCacheKey(baseUrl: 'https://api.test/', endpoint: '/users'),
        'https://api.test/users',
      );
      expect(
        buildCacheKey(baseUrl: 'https://api.test', endpoint: 'users'),
        'https://api.test/users',
      );
    });

    test('an absolute endpoint ignores baseUrl', () {
      expect(
        buildCacheKey(
          baseUrl: 'https://api.test',
          endpoint: 'https://cdn.other/thing',
        ),
        'https://cdn.other/thing',
      );
    });

    test('request keys separate methods and bodies', () {
      final get = buildRequestKey(method: 'GET', endpoint: '/a');
      final post = buildRequestKey(method: 'POST', endpoint: '/a');
      final postB = buildRequestKey(
        method: 'POST',
        endpoint: '/a',
        data: {'x': 1},
      );

      expect(get, isNot(post));
      expect(post, isNot(postB));
    });
  });
}
