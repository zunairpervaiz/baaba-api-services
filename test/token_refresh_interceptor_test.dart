import 'dart:async';
import 'dart:typed_data';

import 'package:baaba_api_handler/src/interceptors/token_refresh_interceptor.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _MockAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions) handler;

  _MockAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _ok() => ResponseBody.fromString('{}', 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });

ResponseBody _unauthorized() =>
    ResponseBody.fromString('{"error":"Unauthorized"}', 401, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });

void main() {
  group('TokenRefreshInterceptor', () {
    late Dio dio;

    setUp(() {
      dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
    });

    test('attaches bearer token to every request', () async {
      String? capturedAuthHeader;

      dio.httpClientAdapter = _MockAdapter((options) async {
        capturedAuthHeader = options.headers['authorization'] as String?;
        return _ok();
      });

      dio.interceptors.add(TokenRefreshInterceptor(
        dio: dio,
        getToken: () async => 'my-token',
        onTokenRefresh: () async => true,
      ));

      await dio.get('/test');

      expect(capturedAuthHeader, 'Bearer my-token');
    });

    test('holds the refresh guard until the replay finishes', () async {
      // The replay is awaited, not merely returned, so the `finally` that
      // clears _isRefreshing cannot run while it is still in flight. If it
      // did, a 401 arriving during that window would see no refresh in
      // progress and start a second one — the stampede this interceptor
      // exists to prevent, and a real hazard when the backend rotates the
      // refresh token.
      var refreshCount = 0;

      dio.httpClientAdapter = _MockAdapter((options) async {
        if (options.extra['_tokenRetried'] != true) return _unauthorized();
        // Only the first request's replay is slow; that delay *is* the
        // window under test.
        if (options.path == '/slow') {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        return _ok();
      });

      dio.interceptors.add(TokenRefreshInterceptor(
        dio: dio,
        getToken: () async => 'token',
        onTokenRefresh: () async {
          refreshCount++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return true;
        },
      ));

      final slow = dio.get<dynamic>('/slow');
      // Long enough for /slow to have 401'd, refreshed, and started replaying.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final second = dio.get<dynamic>('/second');

      final responses = await Future.wait([slow, second]);

      expect(refreshCount, 1,
          reason: 'the second 401 should reuse the in-flight refresh');
      expect(responses.map((r) => r.statusCode), everyElement(200));
    });

    test('retries on 401 and succeeds after token refresh', () async {
      int callCount = 0;
      int refreshCount = 0;

      dio.httpClientAdapter = _MockAdapter((options) async {
        callCount++;
        return callCount == 1 ? _unauthorized() : _ok();
      });

      dio.interceptors.add(TokenRefreshInterceptor(
        dio: dio,
        getToken: () async => 'new-token',
        onTokenRefresh: () async {
          refreshCount++;
          return true;
        },
      ));

      final response = await dio.get('/test');

      expect(response.statusCode, 200);
      expect(refreshCount, 1);
      expect(callCount, 2);
    });

    test('does not retry a second time when _tokenRetried flag is set',
        () async {
      int callCount = 0;
      int refreshCount = 0;

      // Always return 401 — so the retry also gets 401, which should not trigger a second refresh.
      dio.httpClientAdapter = _MockAdapter((options) async {
        callCount++;
        return _unauthorized();
      });

      dio.interceptors.add(TokenRefreshInterceptor(
        dio: dio,
        getToken: () async => 'token',
        onTokenRefresh: () async {
          refreshCount++;
          return true;
        },
      ));

      await expectLater(dio.get('/test'), throwsA(isA<DioException>()));

      expect(refreshCount, 1);
      expect(callCount, 2); // original + one retry
    });

    test('calls onRefreshFailed when onTokenRefresh returns false', () async {
      bool refreshFailedCalled = false;

      dio.httpClientAdapter = _MockAdapter((_) async => _unauthorized());

      dio.interceptors.add(TokenRefreshInterceptor(
        dio: dio,
        getToken: () async => 'stale-token',
        onTokenRefresh: () async => false,
        onRefreshFailed: () => refreshFailedCalled = true,
      ));

      await expectLater(dio.get('/test'), throwsA(isA<DioException>()));

      expect(refreshFailedCalled, isTrue);
    });

    test('calls onRefreshFailed when onTokenRefresh throws', () async {
      bool refreshFailedCalled = false;

      dio.httpClientAdapter = _MockAdapter((_) async => _unauthorized());

      dio.interceptors.add(TokenRefreshInterceptor(
        dio: dio,
        getToken: () async => 'token',
        onTokenRefresh: () async =>
            throw Exception('network error during refresh'),
        onRefreshFailed: () => refreshFailedCalled = true,
      ));

      await expectLater(dio.get('/test'), throwsA(isA<DioException>()));

      expect(refreshFailedCalled, isTrue);
    });

    test(
        'queues a concurrent 401 behind an in-flight refresh and retries both after success',
        () async {
      bool tokenRefreshed = false;
      int refreshCallCount = 0;

      dio.httpClientAdapter = _MockAdapter((options) async {
        return tokenRefreshed ? _ok() : _unauthorized();
      });

      dio.interceptors.add(TokenRefreshInterceptor(
        dio: dio,
        getToken: () async => 'token',
        onTokenRefresh: () async {
          refreshCallCount++;
          await Future.delayed(const Duration(milliseconds: 50));
          tokenRefreshed = true;
          return true;
        },
      ));

      final first = dio.get('/a');
      // Give the first request's onError a chance to start the refresh
      // (and flip _isRefreshing) before firing the second — mirrors several
      // requests 401ing in quick succession right as the token expires.
      await Future.delayed(const Duration(milliseconds: 10));
      final second = dio.get('/b');

      final responses = await Future.wait([first, second]);

      expect(responses[0].statusCode, 200);
      expect(responses[1].statusCode, 200);
      expect(refreshCallCount, 1); // only the first request triggered a refresh
    });

    test(
        'gives up waiting after refreshTimeout and surfaces the original error',
        () async {
      dio.httpClientAdapter = _MockAdapter((_) async => _unauthorized());

      dio.interceptors.add(TokenRefreshInterceptor(
        dio: dio,
        getToken: () async => 'token',
        onTokenRefresh: () async {
          await Future.delayed(const Duration(milliseconds: 200));
          return true;
        },
        refreshTimeout: const Duration(milliseconds: 20),
      ));

      final first = dio.get('/a');
      await Future.delayed(const Duration(milliseconds: 10));
      final second = dio.get('/b');

      // Second gives up after ~20ms instead of waiting the full 200ms refresh.
      await expectLater(second, throwsA(isA<DioException>()));
      // First still runs its own refresh to completion (adapter keeps 401ing
      // here, so it fails too, but only after the real refresh finished).
      await expectLater(first, throwsA(isA<DioException>()));
    });

    test('uses custom headerBuilder when provided', () async {
      String? capturedHeader;

      dio.httpClientAdapter = _MockAdapter((options) async {
        capturedHeader = options.headers['x-api-key'] as String?;
        return _ok();
      });

      dio.interceptors.add(TokenRefreshInterceptor(
        dio: dio,
        getToken: () async => 'secret',
        onTokenRefresh: () async => true,
        headerBuilder: (token) => {'x-api-key': token},
      ));

      await dio.get('/test');

      expect(capturedHeader, 'secret');
    });

    test('skips header injection when getToken returns null', () async {
      String? capturedAuthHeader = 'initial';

      dio.httpClientAdapter = _MockAdapter((options) async {
        capturedAuthHeader = options.headers['authorization'] as String?;
        return _ok();
      });

      dio.interceptors.add(TokenRefreshInterceptor(
        dio: dio,
        getToken: () async => null,
        onTokenRefresh: () async => true,
      ));

      await dio.get('/test');

      expect(capturedAuthHeader, isNull);
    });

    test('a replay that throws keeps the real error, not a completer one',
        () async {
      var refreshFailedCalls = 0;
      var tokenReads = 0;

      dio.httpClientAdapter = _MockAdapter((_) async => _unauthorized());

      dio.interceptors.add(TokenRefreshInterceptor(
        dio: dio,
        // Fine for the original request, broken for the replay — secure
        // storage failing between the two, say.
        getToken: () async {
          if (++tokenReads > 1) throw StateError('storage unavailable');
          return 'token';
        },
        onTokenRefresh: () async => true,
        onRefreshFailed: () => refreshFailedCalls++,
      ));

      // The replay's error used to fall into the refresh's catch, which
      // completed the already-completed completer and threw "Future already
      // completed" in place of what actually went wrong.
      await expectLater(
        dio.get('/test'),
        throwsA(isA<DioException>().having(
          (e) => '${e.error}',
          'error',
          contains('storage unavailable'),
        )),
      );

      // The refresh itself succeeded, so the session is intact.
      expect(refreshFailedCalls, 0);
    });

    test('a refresh callback that throws synchronously counts as a failure',
        () async {
      var refreshFailedCalls = 0;
      dio.httpClientAdapter = _MockAdapter((_) async => _unauthorized());

      dio.interceptors.add(TokenRefreshInterceptor(
        dio: dio,
        getToken: () async => 'token',
        onTokenRefresh: () => throw StateError('not even a future'),
        onRefreshFailed: () => refreshFailedCalls++,
      ));

      await expectLater(dio.get('/test'), throwsA(isA<DioException>()));
      expect(refreshFailedCalls, 1);
    });

    test(
        'a 401 for a token that was already replaced replays without '
        'refreshing again', () async {
      var token = 'old';
      var refreshes = 0;
      final lateRequestSent = Completer<void>();
      final releaseLate = Completer<void>();

      dio.httpClientAdapter = _MockAdapter((options) async {
        final sentWith = options.headers['authorization'];
        if (options.path == '/late' && sentWith == 'Bearer old') {
          // Sent with the old token, but its 401 arrives only after another
          // request's refresh has already finished.
          lateRequestSent.complete();
          await releaseLate.future;
          return _unauthorized();
        }
        return sentWith == 'Bearer new' ? _ok() : _unauthorized();
      });

      dio.interceptors.add(TokenRefreshInterceptor(
        dio: dio,
        getToken: () async => token,
        onTokenRefresh: () async {
          refreshes++;
          token = 'new';
          return true;
        },
      ));

      final late = dio.get('/late');
      await lateRequestSent.future;

      // The first request 401s, refreshes, replays, and is done.
      await dio.get('/early');
      expect(refreshes, 1);

      releaseLate.complete();
      final response = await late;

      expect(response.statusCode, 200);
      expect(refreshes, 1,
          reason: 'the token had already been refreshed; with a backend that '
              'rotates refresh tokens, a second refresh can fail and log the '
              'user out');
    });

    test('a throwing onRefreshFailed still surfaces the 401', () async {
      dio.httpClientAdapter = _MockAdapter((_) async => _unauthorized());

      dio.interceptors.add(TokenRefreshInterceptor(
        dio: dio,
        getToken: () async => 'token',
        onTokenRefresh: () async => false,
        // Logout navigation with no context available, say.
        onRefreshFailed: () => throw StateError('no navigator'),
      ));

      await expectLater(
        dio.get('/test'),
        throwsA(isA<DioException>().having(
          (e) => e.response?.statusCode,
          'statusCode',
          401,
        )),
      );
    });

    test('a late 401 replays even when the token string did not change',
        () async {
      // The token check alone cannot see this refresh: the value is the same
      // before and after (a session renewed server-side, or a getToken that
      // reads a stale copy while the refresh lands). The generation can.
      var refreshes = 0;
      var renewed = false;
      final lateRequestSent = Completer<void>();
      final releaseLate = Completer<void>();

      dio.httpClientAdapter = _MockAdapter((options) async {
        final sentAfterRenewal = options.extra['_tokenGeneration'] != 0;
        if (options.path == '/late' && !sentAfterRenewal) {
          lateRequestSent.complete();
          await releaseLate.future;
          return _unauthorized();
        }
        return renewed && sentAfterRenewal ? _ok() : _unauthorized();
      });

      dio.interceptors.add(TokenRefreshInterceptor(
        dio: dio,
        getToken: () async => 'same',
        onTokenRefresh: () async {
          refreshes++;
          renewed = true;
          return true;
        },
      ));

      final late = dio.get('/late');
      await lateRequestSent.future;
      await dio.get('/early');
      expect(refreshes, 1);

      releaseLate.complete();
      expect((await late).statusCode, 200);
      expect(refreshes, 1);
    });
  });
}
