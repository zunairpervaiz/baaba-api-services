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

class _InMemoryCache implements ApiCacheHelper {
  final Map<String, String> entries = {};
  var opened = false;

  @override
  Future<APICacheDBModel?> getCacheData(String url, {Duration? maxAge}) async {
    opened = true;
    final data = entries[url];
    return data == null ? null : APICacheDBModel(key: url, syncData: data);
  }

  @override
  Future<bool> setCacheData(String url, String data) async {
    opened = true;
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
  late int networkCalls;

  ApiServices buildApi() => ApiServicesImplementation.instanceFor(
        dio: mockDio,
        networkInfo: mockNetworkInfo,
        cacheHelper: cache,
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
    when(() => mockDio.request<dynamic>(
          any(),
          data: any(named: 'data'),
          queryParameters: any(named: 'queryParameters'),
          options: any(named: 'options'),
          cancelToken: any(named: 'cancelToken'),
          onSendProgress: any(named: 'onSendProgress'),
          onReceiveProgress: any(named: 'onReceiveProgress'),
        )).thenAnswer((_) async {
      networkCalls++;
      return Response(
        requestOptions: RequestOptions(path: '/products'),
        statusCode: 200,
        data: {'items': 1},
      );
    });
  });

  tearDown(ApiServices.reset);

  group('cacheEnabled: false', () {
    setUp(() => ApiServices.init(const ApiConfig(cacheEnabled: false)));

    test('overrides an explicit cachePolicy on a call site', () async {
      final api = buildApi();

      await api.get(
        endpoint: '/products',
        cachePolicy: CachePolicy.cacheFirst,
      );
      await api.get(
        endpoint: '/products',
        cachePolicy: CachePolicy.cacheFirst,
      );

      // Both went to the network and nothing was written to disk.
      expect(networkCalls, 2);
      expect(cache.entries, isEmpty);
      expect(cache.opened, isFalse);
    });

    test('a cacheOnly request goes to the network instead of failing',
        () async {
      final result = await buildApi().get(
        endpoint: '/products',
        cachePolicy: CachePolicy.cacheOnly,
      );

      expect(result.isRight(), isTrue);
      expect(networkCalls, 1);
    });

    test('an already-populated cache is never read', () async {
      cache.entries[buildCacheKey(endpoint: '/products')] =
          jsonEncode({'items': 'stale'});

      final result = await buildApi().get(
        endpoint: '/products',
        cachePolicy: CachePolicy.networkFirst,
      );

      result.fold((f) => fail('$f'), (r) => expect(r.isFromCache, isFalse));
    });

    test('overrides defaultCachePolicy too', () async {
      ApiServices.init(const ApiConfig(
        cacheEnabled: false,
        defaultCachePolicy: CachePolicy.cacheFirst,
      ));

      await buildApi().get(endpoint: '/products');
      await buildApi().get(endpoint: '/products');

      expect(networkCalls, 2);
      expect(cache.entries, isEmpty);
    });
  });

  group('defaultCachePolicy', () {
    test('applies when the call site does not name a policy', () async {
      ApiServices.init(const ApiConfig(
        defaultCachePolicy: CachePolicy.cacheFirst,
      ));
      final api = buildApi();

      await api.get(endpoint: '/products');
      final second = await api.get(endpoint: '/products');

      expect(networkCalls, 1);
      second.fold((f) => fail('$f'), (r) => expect(r.isFromCache, isTrue));
    });

    test('a call site can still opt out explicitly', () async {
      ApiServices.init(const ApiConfig(
        defaultCachePolicy: CachePolicy.cacheFirst,
      ));
      final api = buildApi();

      await api.get(endpoint: '/products');
      await api.get(
        endpoint: '/products',
        cachePolicy: CachePolicy.networkOnly,
      );

      expect(networkCalls, 2);
    });

    test('defaults to networkOnly, so nothing caches unasked', () async {
      ApiServices.init(const ApiConfig());
      final api = buildApi();

      await api.get(endpoint: '/products');
      await api.get(endpoint: '/products');

      expect(networkCalls, 2);
      expect(cache.entries, isEmpty);
      expect(cache.opened, isFalse);
    });
  });
}
