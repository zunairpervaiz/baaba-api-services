import 'dart:io';
import 'dart:typed_data';

import 'package:baaba_api_handler/testing.dart';
import 'package:dio/dio.dart' show Headers, ResponseBody;
import 'package:flutter_test/flutter_test.dart';

/// Answers each attempt from [plan]: an int is a status, `'timeout'` a
/// connection timeout. The last entry repeats.
class _Adapter implements HttpClientAdapter {
  final List<Object> plan;
  final List<RequestOptions> requests = [];
  final List<Map<String, dynamic>> sentExtra = [];

  _Adapter(this.plan);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final step = plan[requests.length.clamp(0, plan.length - 1)];
    requests.add(options);
    sentExtra.add(Map<String, dynamic>.of(options.extra));
    if (step == 'timeout') {
      throw DioException.connectionTimeout(
        requestOptions: options,
        timeout: const Duration(seconds: 1),
      );
    }
    return ResponseBody.fromString(
      '{}',
      step as int,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Observer extends ApiObserver {
  final List<Map<String, dynamic>> requestExtras = [];
  final List<Failure> failures = [];

  @override
  void onRequest(RequestOptions options) =>
      requestExtras.add(Map.of(options.extra));

  @override
  void onFailure(Failure failure, RequestOptions? options) =>
      failures.add(failure);
}

ApiServices _init(
  _Adapter adapter, {
  RetryPolicy retry = const RetryPolicy(
    maxRetries: 2,
    baseDelay: Duration.zero,
    useJitter: false,
  ),
  ApiObserver? observer,
  List<Interceptor> interceptors = const [],
}) {
  ApiServices.init(
    ApiConfig(
      baseUrl: 'https://api.test',
      bypassConnectivityCheck: true,
      httpClientAdapter: adapter,
      logging: const ApiLogOptions(enabled: false),
      retry: retry,
      observer: observer,
      interceptors: interceptors,
    ),
  );
  return ApiServices.instance();
}

void main() {
  tearDown(ApiServices.reset);

  group('retryable: true', () {
    test('a POST is retried on an ambiguous status', () async {
      final adapter = _Adapter([500, 200]);
      final api = _init(adapter);

      final result = await api.post(endpoint: '/graphql', retryable: true);

      expect(result.isRight(), isTrue);
      expect(adapter.requests, hasLength(2));
    });

    test('a POST is retried on a transport error', () async {
      final adapter = _Adapter(['timeout', 200]);
      final api = _init(adapter);

      expect(
        (await api.post(endpoint: '/graphql', retryable: true)).isRight(),
        isTrue,
      );
      expect(adapter.requests, hasLength(2));
    });

    test('without the flag the same POST is not retried', () async {
      final adapter = _Adapter([500, 200]);
      final api = _init(adapter);

      expect((await api.post(endpoint: '/graphql')).isLeft(), isTrue);
      expect(adapter.requests, hasLength(1));
    });

    test('still bounded by maxRetries and the status list', () async {
      final always500 = _Adapter([500]);
      final api = _init(always500);
      await api.post(endpoint: '/graphql', retryable: true);
      expect(always500.requests, hasLength(3)); // 1 + maxRetries

      ApiServices.reset();
      final notListed = _Adapter([418, 200]);
      await _init(notListed).post(endpoint: '/graphql', retryable: true);
      expect(notListed.requests, hasLength(1));
    });

    test('retryIf still vetoes, and can read the flag', () async {
      final seen = <Object?>[];
      final adapter = _Adapter([500, 200]);
      final api = _init(
        adapter,
        retry: RetryPolicy(
          maxRetries: 2,
          baseDelay: Duration.zero,
          retryIf: (err, _) {
            seen.add(err.requestOptions.extra[RetryPolicy.retryableKey]);
            return false;
          },
        ),
      );

      expect(
        (await api.post(endpoint: '/graphql', retryable: true)).isLeft(),
        isTrue,
      );
      expect(adapter.requests, hasLength(1));
      expect(seen, [true]);
    });

    test('the *As variants forward it', () async {
      final adapter = _Adapter([500, 200]);
      final api = _init(adapter);

      final result = await api.postAs<Map>(
        endpoint: '/graphql',
        parser: (d) => d as Map,
        retryable: true,
      );

      expect(result.isRight(), isTrue);
      expect(adapter.requests, hasLength(2));
    });
  });

  group('retryable: false', () {
    for (final step in <Object>[503, 429, 500, 'timeout']) {
      test('a GET is never retried ($step)', () async {
        final adapter = _Adapter([step, 200]);
        final api = _init(adapter);

        expect(
          (await api.get(endpoint: '/a', retryable: false)).isLeft(),
          isTrue,
        );
        expect(adapter.requests, hasLength(1));
      });
    }

    test('a POST is not retried even on a 503', () async {
      final adapter = _Adapter([503, 200]);
      final api = _init(adapter);

      await api.post(endpoint: '/a', retryable: false);

      expect(adapter.requests, hasLength(1));
    });
  });

  group('extra', () {
    test(
      'reaches RequestOptions.extra, interceptors and the observer',
      () async {
        Object? seenByInterceptor;
        final observer = _Observer();
        final adapter = _Adapter([200]);
        final api = _init(
          adapter,
          observer: observer,
          interceptors: [
            InterceptorsWrapper(
              onRequest: (options, handler) {
                seenByInterceptor = options.extra['operation'];
                handler.next(options);
              },
            ),
          ],
        );

        await api.post(
          endpoint: '/graphql',
          extra: {'operation': 'GetBalance'},
          retryable: true,
        );

        expect(seenByInterceptor, 'GetBalance');
        expect(adapter.sentExtra.single['operation'], 'GetBalance');
        expect(adapter.sentExtra.single[RetryPolicy.retryableKey], isTrue);
        expect(observer.requestExtras.single['operation'], 'GetBalance');
      },
    );

    test('a failure carries it on its requestOptions', () async {
      final observer = _Observer();
      final api = _init(_Adapter([404]), observer: observer);

      final result = await api.get(endpoint: '/a', extra: {'screen': 'home'});

      expect(
        result.getLeft().toNullable()?.requestOptions?.extra['screen'],
        'home',
      );
      expect(observer.failures.single.requestOptions?.extra['screen'], 'home');
    });

    test('the caller\'s map is not modified', () async {
      final extra = <String, dynamic>{'a': 1};
      await _init(_Adapter([503, 200])).get(endpoint: '/a', extra: extra);
      expect(extra, {'a': 1});
    });

    test('calls differing only in extra are not collapsed together', () async {
      final adapter = _Adapter([200]);
      final api = _init(adapter);

      await Future.wait([
        api.get(endpoint: '/a', extra: {'v': 1}),
        api.get(endpoint: '/a', extra: {'v': 2}),
        api.get(endpoint: '/a', retryable: false),
      ]);
      expect(adapter.requests, hasLength(3));

      adapter.requests.clear();
      await Future.wait([
        api.get(endpoint: '/a', extra: {'v': 1}),
        api.get(endpoint: '/a', extra: {'v': 1}),
      ]);
      expect(adapter.requests, hasLength(1));
    });

    test('download takes both', () async {
      final adapter = _Adapter([503, 200]);
      final api = _init(adapter);
      final dir = await Directory.systemTemp.createTemp('baaba_dl');
      addTearDown(() => dir.delete(recursive: true));

      final result = await api.download(
        endpoint: '/file',
        savePath: '${dir.path}/f.json',
        retryable: false,
        extra: {'kind': 'export'},
      );

      expect(result.isLeft(), isTrue);
      expect(adapter.requests, hasLength(1));
      expect(adapter.sentExtra.single['kind'], 'export');
    });
  });

  test('FakeApiServices records both', () async {
    final fake = FakeApiServices()
      ..stubJson(HttpMethod.post, '/graphql', {'ok': true});

    await fake.post(
      endpoint: '/graphql',
      retryable: true,
      extra: {'operation': 'GetBalance'},
    );

    final call = fake.recordedCalls.single;
    expect(call.retryable, isTrue);
    expect(call.extra, {'operation': 'GetBalance'});
  });
}
