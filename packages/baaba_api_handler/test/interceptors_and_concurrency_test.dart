import 'dart:async';
import 'dart:typed_data';

import 'package:baaba_api_handler/ts_api_handler.dart';
import 'package:dio/dio.dart' show Headers, ResponseBody;
import 'package:flutter_test/flutter_test.dart';

class _Adapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  /// Headers as they were at the moment of each fetch.
  ///
  /// A retry replays the *same* `RequestOptions` instance, so reading headers
  /// off [requests] afterwards shows every entry with the final attempt's
  /// values. Snapshotting is the only way to see what each attempt actually
  /// sent.
  final List<Map<String, dynamic>> sentHeaders = [];
  final int Function(RequestOptions options)? status;

  /// Completers the test resolves by hand, so requests can be held in flight.
  final List<Completer<void>> gates = [];
  final bool manual;

  int active = 0;
  int peakActive = 0;

  _Adapter({this.status, this.manual = false});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    sentHeaders.add(Map<String, dynamic>.of(options.headers));
    active++;
    peakActive = active > peakActive ? active : peakActive;
    try {
      if (manual) {
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
      }
      return ResponseBody.fromString(
        '{}',
        status?.call(options) ?? 200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    } finally {
      active--;
    }
  }

  /// Lets one held request complete.
  void releaseOne() => gates.removeAt(0).complete();

  @override
  void close({bool force = false}) {}
}

void main() {
  tearDown(ApiServices.reset);

  // `retry` is applied by the caller's config when it sets one, so a test
  // exercising retries is not silently overridden by the shared default.
  void init(_Adapter adapter, {ApiConfig? config}) {
    final base = config ?? const ApiConfig();
    ApiServices.init(
      base.copyWith(
        baseUrl: 'https://api.test',
        bypassConnectivityCheck: true,
        httpClientAdapter: adapter,
        retry: identical(base.retry, const ApiConfig().retry)
            ? const RetryPolicy.disabled()
            : base.retry,
        logging: const ApiLogOptions(enabled: false),
      ),
    );
  }

  group('ApiConfig.interceptors', () {
    test('a caller interceptor can modify the outgoing request', () async {
      final adapter = _Adapter();
      init(
        adapter,
        config: ApiConfig(
          interceptors: [
            InterceptorsWrapper(
              onRequest: (options, handler) {
                options.headers['X-Correlation-Id'] = 'abc-123';
                handler.next(options);
              },
            ),
          ],
        ),
      );

      await ApiServices.instance().get(endpoint: '/users');

      expect(adapter.requests.single.headers['X-Correlation-Id'], 'abc-123');
    });

    test('runs after auth, so it can see and sign the token header', () async {
      String? authSeenByInterceptor;
      final adapter = _Adapter();
      ApiServices.init(
        ApiConfig(
          baseUrl: 'https://api.test',
          bypassConnectivityCheck: true,
          httpClientAdapter: adapter,
          retry: const RetryPolicy.disabled(),
          logging: const ApiLogOptions(enabled: false),
          auth: AuthConfig(
            getToken: () async => 'TOKEN',
            onTokenRefresh: () async => true,
          ),
          interceptors: [
            InterceptorsWrapper(
              onRequest: (options, handler) {
                authSeenByInterceptor =
                    options.headers['authorization'] as String?;
                options.headers['X-Signature'] =
                    'signed($authSeenByInterceptor)';
                handler.next(options);
              },
            ),
          ],
        ),
      );

      await ApiServices.instance().get(endpoint: '/users');

      expect(authSeenByInterceptor, 'Bearer TOKEN');
      expect(
        adapter.requests.single.headers['X-Signature'],
        'signed(Bearer TOKEN)',
      );
    });

    test(
      'runs again for each retry, so a stale signature is not replayed',
      () async {
        var stamps = 0;
        final adapter = _Adapter(
          status: (options) =>
              options.extra['networkRetryCount'] == null ? 503 : 200,
        );
        init(
          adapter,
          config: ApiConfig(
            retry: const RetryPolicy(
              maxRetries: 2,
              baseDelay: Duration(milliseconds: 1),
            ),
            interceptors: [
              InterceptorsWrapper(
                onRequest: (options, handler) {
                  options.headers['X-Stamp'] = '${stamps++}';
                  handler.next(options);
                },
              ),
            ],
          ),
        );

        await ApiServices.instance().get(endpoint: '/flaky');

        expect(adapter.requests, hasLength(2));
        expect(adapter.sentHeaders.first['X-Stamp'], '0');
        expect(
          adapter.sentHeaders.last['X-Stamp'],
          '1',
          reason:
              'the retry re-ran the interceptor rather than replaying '
              'the first attempt\'s value',
        );
      },
    );

    test('several run in the order given', () async {
      final order = <String>[];
      final adapter = _Adapter();
      init(
        adapter,
        config: ApiConfig(
          interceptors: [
            InterceptorsWrapper(
              onRequest: (o, h) {
                order.add('first');
                h.next(o);
              },
            ),
            InterceptorsWrapper(
              onRequest: (o, h) {
                order.add('second');
                h.next(o);
              },
            ),
          ],
        ),
      );

      await ApiServices.instance().get(endpoint: '/users');

      expect(order, ['first', 'second']);
    });

    test(
      'one can short-circuit to a fixture without touching the network',
      () async {
        final adapter = _Adapter();
        init(
          adapter,
          config: ApiConfig(
            interceptors: [
              InterceptorsWrapper(
                onRequest: (options, handler) {
                  handler.resolve(
                    Response<dynamic>(
                      requestOptions: options,
                      statusCode: 200,
                      data: {'stubbed': true},
                    ),
                  );
                },
              ),
            ],
          ),
        );

        final result = await ApiServices.instance().get(endpoint: '/users');

        expect(adapter.requests, isEmpty);
        expect(result.getRight().toNullable()!.data, {'stubbed': true});
      },
    );

    test('none by default', () async {
      final adapter = _Adapter();
      init(adapter);

      expect(
        (await ApiServices.instance().get(endpoint: '/a')).isRight(),
        isTrue,
      );
    });
  });

  group('maxConcurrentRequests', () {
    test('never exceeds the cap', () async {
      final adapter = _Adapter(manual: true);
      init(adapter, config: const ApiConfig(maxConcurrentRequests: 2));
      final api = ApiServices.instance();

      final calls = [for (var i = 0; i < 6; i++) api.get(endpoint: '/item/$i')];

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(adapter.active, 2, reason: 'only the cap may be in flight');
      expect(adapter.requests, hasLength(2), reason: 'the rest are queued');

      while (adapter.gates.isNotEmpty) {
        adapter.releaseOne();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      await Future.wait(calls);
      expect(adapter.peakActive, 2);
      expect(adapter.requests, hasLength(6), reason: 'all of them still run');
    });

    test('queued requests start in the order they were made', () async {
      final adapter = _Adapter(manual: true);
      init(adapter, config: const ApiConfig(maxConcurrentRequests: 1));
      final api = ApiServices.instance();

      final calls = [for (var i = 0; i < 4; i++) api.get(endpoint: '/item/$i')];

      await Future<void>.delayed(const Duration(milliseconds: 10));
      while (adapter.gates.isNotEmpty) {
        adapter.releaseOne();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future.wait(calls);

      expect(adapter.requests.map((r) => r.path), [
        '/item/0',
        '/item/1',
        '/item/2',
        '/item/3',
      ]);
    });

    test('unlimited by default', () async {
      final adapter = _Adapter(manual: true);
      init(adapter);
      final api = ApiServices.instance();

      final calls = [for (var i = 0; i < 5; i++) api.get(endpoint: '/item/$i')];

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(adapter.active, 5);

      while (adapter.gates.isNotEmpty) {
        adapter.releaseOne();
      }
      await Future.wait(calls);
    });

    test('de-duplicated callers share one slot', () async {
      final adapter = _Adapter(manual: true);
      init(adapter, config: const ApiConfig(maxConcurrentRequests: 1));
      final api = ApiServices.instance();

      // Both collapse onto one network call, so a cap of 1 must not deadlock.
      final pair = Future.wait([
        api.get(endpoint: '/feed'),
        api.get(endpoint: '/feed'),
      ]);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(adapter.requests, hasLength(1));
      adapter.releaseOne();

      final results = await pair;
      expect(results.every((r) => r.isRight()), isTrue);
    });

    test('a slot is released even when the request fails', () async {
      final adapter = _Adapter(status: (_) => 500);
      init(adapter, config: const ApiConfig(maxConcurrentRequests: 1));
      final api = ApiServices.instance();

      // If a failure leaked its slot, the second call would hang forever.
      expect((await api.get(endpoint: '/a')).isLeft(), isTrue);
      expect((await api.get(endpoint: '/b')).isLeft(), isTrue);
      expect(adapter.requests, hasLength(2));
    });

    test('a queued request is still cancellable', () async {
      final adapter = _Adapter(manual: true);
      init(adapter, config: const ApiConfig(maxConcurrentRequests: 1));
      final api = ApiServices.instance();

      final running = api.get(endpoint: '/running', tag: 'a');
      final queued = api.get(endpoint: '/queued', tag: 'b');

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(adapter.requests, hasLength(1), reason: '/queued has not started');

      api.cancelRequest(tag: 'b');
      adapter.releaseOne();

      expect((await running).isRight(), isTrue);
      expect(
        (await queued).getLeft().toNullable()!.errorType,
        ErrorSource.cancel,
      );
    });

    test('one shared token cancels every request it queued', () async {
      final adapter = _Adapter(manual: true);
      init(adapter, config: const ApiConfig(maxConcurrentRequests: 1));
      final api = ApiServices.instance();
      final shared = CancelToken();

      // /first is admitted on the shared token and finishes; the gate keeps
      // listening to the token for the ones queued after it.
      final first = api.get(endpoint: '/first', cancelToken: shared);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      adapter.releaseOne();
      expect((await first).isRight(), isTrue);

      final running = api.get(endpoint: '/running');
      final a = api.get(endpoint: '/a', cancelToken: shared);
      final b = api.get(endpoint: '/b', cancelToken: shared);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      shared.cancel();

      for (final queued in [a, b]) {
        final result = await queued.timeout(const Duration(seconds: 1));
        expect(result.getLeft().toNullable()!.errorType, ErrorSource.cancel);
      }
      adapter.releaseOne();
      expect((await running).isRight(), isTrue);
      expect(adapter.requests.map((r) => r.path), ['/first', '/running']);
    });

    test(
      'a queued request cancels at once, not when a slot frees up',
      () async {
        final adapter = _Adapter(manual: true);
        init(adapter, config: const ApiConfig(maxConcurrentRequests: 1));
        final api = ApiServices.instance();

        final running = api.get(endpoint: '/running', tag: 'a');
        final queued = api.get(endpoint: '/queued', tag: 'b');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        api.cancelRequest(tag: 'b');

        // /running is still held. Before the fix, /queued sat in the gate until
        // it was released — behind a long upload, that is the whole upload.
        final result = await queued.timeout(const Duration(seconds: 1));
        expect(result.getLeft().toNullable()!.errorType, ErrorSource.cancel);
        expect(
          adapter.requests.map((r) => r.path),
          ['/running'],
          reason: 'a request cancelled in the queue never reaches the network',
        );

        adapter.releaseOne();
        expect((await running).isRight(), isTrue);
      },
    );

    test(
      'a request cancelled in the queue gives up its place, not a slot',
      () async {
        final adapter = _Adapter(manual: true);
        init(adapter, config: const ApiConfig(maxConcurrentRequests: 1));
        final api = ApiServices.instance();

        final running = api.get(endpoint: '/running', tag: 'a');
        final cancelled = api.get(endpoint: '/cancelled', tag: 'b');
        final next = api.get(endpoint: '/next', tag: 'c');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        api.cancelRequest(tag: 'b');
        await cancelled;

        // The slot /running releases must go to /next, and only one may run.
        adapter.releaseOne();
        await running;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(adapter.requests.map((r) => r.path), ['/running', '/next']);
        expect(adapter.active, 1);

        adapter.releaseOne();
        expect((await next).isRight(), isTrue);
        expect(adapter.peakActive, 1);
      },
    );
  });

  group('ApiServices.reset', () {
    test('cancels requests still in flight on the discarded client', () async {
      final adapter = _Adapter(manual: true);
      init(adapter);

      final inFlight = ApiServices.instance().get(endpoint: '/me');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // A logout: the previous user's request must not complete afterwards,
      // still carrying their token.
      ApiServices.reset();

      final result = await inFlight.timeout(const Duration(seconds: 1));
      expect(result.getLeft().toNullable()!.errorType, ErrorSource.cancel);
      adapter.releaseOne();
    });

    test('hides a loader that is still showing', () async {
      final adapter = _Adapter(manual: true);
      init(adapter);
      final events = <String>[];
      ApiServices.configureLoader(
        onShow: () => events.add('show'),
        onHide: () => events.add('hide'),
      );

      final inFlight = ApiServices.instance().get(endpoint: '/me');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events, ['show']);

      // The request's own release is stale after reset() and is ignored, so
      // reset() has to close the dialog itself or nothing ever will.
      ApiServices.reset();
      await inFlight.timeout(const Duration(seconds: 1));
      adapter.releaseOne();

      expect(events, ['show', 'hide']);
    });

    test('does not call onHide when no loader is showing', () async {
      final events = <String>[];
      ApiServices.configureLoader(
        onShow: () => events.add('show'),
        onHide: () => events.add('hide'),
      );

      ApiServices.reset();

      expect(events, isEmpty);
    });
  });

  group('maxConcurrentRequests with token refresh', () {
    test(
      'a refresh made through the client is not queued behind its waiters',
      () async {
        var refreshed = false;
        final adapter = _Adapter(
          status: (options) {
            if (options.path == '/refresh') return 200;
            return refreshed ? 200 : 401;
          },
        );
        ApiServices.init(
          ApiConfig(
            baseUrl: 'https://api.test',
            bypassConnectivityCheck: true,
            httpClientAdapter: adapter,
            retry: const RetryPolicy.disabled(),
            logging: const ApiLogOptions(enabled: false),
            maxConcurrentRequests: 1,
            auth: AuthConfig(
              getToken: () async => refreshed ? 'new' : 'old',
              // The README's shape: the refresh goes through the same client.
              onTokenRefresh: () async {
                final result = await ApiServices.instance().post(
                  endpoint: '/refresh',
                  showLoader: false,
                );
                refreshed = result.isRight();
                return refreshed;
              },
              refreshTimeout: const Duration(seconds: 5),
            ),
          ),
        );

        // The /me request holds the only slot while it waits on the refresh,
        // so a gated /refresh could never start.
        final result = await ApiServices.instance()
            .get(endpoint: '/me')
            .timeout(const Duration(seconds: 2));

        expect(result.isRight(), isTrue);
        expect(adapter.requests.map((r) => r.path), ['/me', '/refresh', '/me']);
      },
    );

    test('a refresh GET is not collapsed onto a queued twin', () async {
      var refreshed = false;
      final adapter = _Adapter(
        status: (options) {
          if (options.path == '/session') return 200;
          return refreshed ? 200 : 401;
        },
      );
      ApiServices.init(
        ApiConfig(
          baseUrl: 'https://api.test',
          bypassConnectivityCheck: true,
          httpClientAdapter: adapter,
          retry: const RetryPolicy.disabled(),
          logging: const ApiLogOptions(enabled: false),
          maxConcurrentRequests: 1,
          auth: AuthConfig(
            getToken: () async => refreshed ? 'new' : 'old',
            onTokenRefresh: () async {
              final result = await ApiServices.instance().get(
                endpoint: '/session',
                showLoader: false,
              );
              refreshed = result.isRight();
              return refreshed;
            },
            refreshTimeout: const Duration(seconds: 5),
          ),
        ),
      );
      final api = ApiServices.instance();

      // /me takes the only slot and 401s; the outer /session queues behind
      // it. Collapsed onto that queued call, the refresh's own /session would
      // wait for a slot /me holds until the refresh finishes.
      final results = await Future.wait([
        api.get(endpoint: '/me'),
        api.get(endpoint: '/session'),
      ]).timeout(const Duration(seconds: 2));

      expect(results.every((r) => r.isRight()), isTrue);
    });
  });

  group('token refresh through the client', () {
    test('a 401 from the refresh call itself fails at once', () async {
      var refreshFailed = false;
      final adapter = _Adapter(status: (_) => 401);
      ApiServices.init(
        ApiConfig(
          baseUrl: 'https://api.test',
          bypassConnectivityCheck: true,
          httpClientAdapter: adapter,
          retry: const RetryPolicy.disabled(),
          logging: const ApiLogOptions(enabled: false),
          auth: AuthConfig(
            getToken: () async => 'expired',
            // An expired refresh token: the refresh endpoint 401s too.
            onTokenRefresh: () async {
              final result = await ApiServices.instance().post(
                endpoint: '/refresh',
                showLoader: false,
              );
              return result.isRight();
            },
            onRefreshFailed: () => refreshFailed = true,
            refreshTimeout: const Duration(seconds: 5),
          ),
        ),
      );

      // It used to wait on its own refresh for the whole refreshTimeout.
      final stopwatch = Stopwatch()..start();
      final result = await ApiServices.instance()
          .get(endpoint: '/me')
          .timeout(const Duration(seconds: 2));
      stopwatch.stop();

      expect(
        result.getLeft().toNullable()!.errorType,
        ErrorSource.unauthorized,
      );
      expect(refreshFailed, isTrue);
      expect(stopwatch.elapsedMilliseconds, lessThan(1000));
      expect(adapter.requests.map((r) => r.path), ['/me', '/refresh']);
    });
  });

  group('cancellation reaches every stage of a request', () {
    late Completer<bool> probe;
    late _Adapter adapter;

    setUp(() {
      probe = Completer<bool>();
      adapter = _Adapter();
      ApiServices.init(
        ApiConfig(
          baseUrl: 'https://api.test',
          httpClientAdapter: adapter,
          retry: const RetryPolicy.disabled(),
          logging: const ApiLogOptions(enabled: false),
          connectivityProbe: () => probe.future,
        ),
      );
    });

    test('cancelRequest() during the connectivity probe', () async {
      final pending = ApiServices.instance().get(endpoint: '/feed', tag: 'f');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      ApiServices.instance().cancelRequest(tag: 'f');
      probe.complete(true);

      final result = await pending;
      expect(result.getLeft().toNullable()!.errorType, ErrorSource.cancel);
      expect(adapter.requests, isEmpty, reason: 'nothing may be sent');
    });

    test('reset() during the connectivity probe', () async {
      // The logout case: the previous user's request was still probing.
      final pending = ApiServices.instance().get(endpoint: '/me');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      ApiServices.reset();
      probe.complete(true);

      final result = await pending;
      expect(result.getLeft().toNullable()!.errorType, ErrorSource.cancel);
      expect(adapter.requests, isEmpty);
    });
  });

  test(
    'one CancelToken shared by several requests stays cancellable',
    () async {
      final adapter = _Adapter(manual: true);
      init(adapter);
      final api = ApiServices.instance();
      final token = CancelToken();

      final slow = api.get(endpoint: '/slow', cancelToken: token);
      final fast = api.get(endpoint: '/fast', cancelToken: token);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // /fast finishing used to unregister the token for /slow as well.
      adapter.gates.removeAt(1).complete();
      expect((await fast).isRight(), isTrue);

      api.cancelRequest();
      final result = await slow.timeout(const Duration(seconds: 1));
      expect(result.getLeft().toNullable()!.errorType, ErrorSource.cancel);
      adapter.releaseOne();
    },
  );
}
