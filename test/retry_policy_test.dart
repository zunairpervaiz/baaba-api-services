import 'dart:math';
import 'dart:typed_data';

import 'package:baaba_api_handler/src/config/retry_policy.dart';
import 'package:baaba_api_handler/src/interceptors/network_retry_interceptor.dart';
import 'package:baaba_api_handler/src/utils/http_date.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers with [statuses] in order, then `200`. A status of `-1` throws a
/// transport error instead, for exercising the non-status retry path.
class _ScriptedAdapter implements HttpClientAdapter {
  final List<int> statuses;
  final Map<String, String> headers;
  int callCount = 0;

  _ScriptedAdapter(this.statuses, {this.headers = const {}});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final index = callCount;
    callCount++;

    final status = index < statuses.length ? statuses[index] : 200;
    if (status == -1) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      );
    }

    return ResponseBody.fromString(
      '{}',
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        for (final entry in headers.entries) entry.key: [entry.value],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(RetryPolicy policy, _ScriptedAdapter adapter, {Random? random}) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
  dio.interceptors
      .add(NetworkRetryInterceptor(dio: dio, policy: policy, random: random));
  dio.httpClientAdapter = adapter;
  return dio;
}

const _fast = RetryPolicy(
  baseDelay: Duration(milliseconds: 1),
  useJitter: false,
);

void main() {
  group('status-code retries', () {
    test('retries a 503 on POST — the server never processed it', () async {
      final adapter = _ScriptedAdapter([503]);
      final dio = _dioWith(_fast, adapter);

      final response = await dio.post('/orders');

      expect(response.statusCode, 200);
      expect(adapter.callCount, 2);
    });

    test('retries a 429 on POST', () async {
      final adapter = _ScriptedAdapter([429]);
      final dio = _dioWith(_fast, adapter);

      await dio.post('/orders');

      expect(adapter.callCount, 2);
    });

    test('does NOT retry a 500 on POST — it may already have been processed',
        () async {
      final adapter = _ScriptedAdapter([500]);
      final dio = _dioWith(_fast, adapter);

      await expectLater(dio.post('/orders'), throwsA(isA<DioException>()));
      expect(adapter.callCount, 1);
    });

    test('does retry a 500 on GET', () async {
      final adapter = _ScriptedAdapter([500]);
      final dio = _dioWith(_fast, adapter);

      final response = await dio.get('/users');

      expect(response.statusCode, 200);
      expect(adapter.callCount, 2);
    });

    test('does not retry a status outside the retryable set', () async {
      final adapter = _ScriptedAdapter([404]);
      final dio = _dioWith(_fast, adapter);

      await expectLater(dio.get('/users'), throwsA(isA<DioException>()));
      expect(adapter.callCount, 1);
    });
  });

  group('retryIf', () {
    test('can veto a retry the built-in rules would have allowed', () async {
      final adapter = _ScriptedAdapter([503]);
      final dio = _dioWith(
        RetryPolicy(
          baseDelay: const Duration(milliseconds: 1),
          useJitter: false,
          retryIf: (err, _) => !err.requestOptions.path.contains('/payments'),
        ),
        adapter,
      );

      await expectLater(dio.get('/payments/1'), throwsA(isA<DioException>()));
      expect(adapter.callCount, 1);
    });

    test('receives the 1-based attempt number', () async {
      final attempts = <int>[];
      final adapter = _ScriptedAdapter([503, 503, 503]);
      final dio = _dioWith(
        RetryPolicy(
          baseDelay: const Duration(milliseconds: 1),
          useJitter: false,
          retryIf: (_, attempt) {
            attempts.add(attempt);
            return true;
          },
        ),
        adapter,
      );

      await dio.get('/users');

      expect(attempts, [1, 2, 3]);
    });
  });

  group('RetryPolicy.disabled', () {
    test('surfaces the first failure without retrying', () async {
      final adapter = _ScriptedAdapter([-1]);
      final dio = _dioWith(const RetryPolicy.disabled(), adapter);

      await expectLater(dio.get('/users'), throwsA(isA<DioException>()));
      expect(adapter.callCount, 1);
    });
  });

  group('Retry-After', () {
    test('waits the delta-seconds the server asked for', () async {
      final adapter = _ScriptedAdapter([503], headers: {'retry-after': '1'});
      final dio = _dioWith(
        const RetryPolicy(baseDelay: Duration(milliseconds: 1)),
        adapter,
      );

      final stopwatch = Stopwatch()..start();
      await dio.get('/users');
      stopwatch.stop();

      // Would have been ~1ms of backoff without the header.
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(900));
      expect(adapter.callCount, 2);
    });

    test('clamps the requested wait to maxDelay', () async {
      final adapter = _ScriptedAdapter([503], headers: {'retry-after': '3600'});
      final dio = _dioWith(
        const RetryPolicy(maxDelay: Duration(milliseconds: 5)),
        adapter,
      );

      final stopwatch = Stopwatch()..start();
      await dio.get('/users');
      stopwatch.stop();

      expect(stopwatch.elapsedMilliseconds, lessThan(500));
      expect(adapter.callCount, 2);
    });

    test('ignores an unparseable header and falls back to backoff', () async {
      final adapter =
          _ScriptedAdapter([503], headers: {'retry-after': 'soon-ish'});
      final dio = _dioWith(_fast, adapter);

      final response = await dio.get('/users');

      expect(response.statusCode, 200);
      expect(adapter.callCount, 2);
    });

    test('is ignored entirely when respectRetryAfter is false', () async {
      final adapter = _ScriptedAdapter([503], headers: {'retry-after': '3600'});
      final dio = _dioWith(
        const RetryPolicy(
          baseDelay: Duration(milliseconds: 1),
          useJitter: false,
          respectRetryAfter: false,
        ),
        adapter,
      );

      final stopwatch = Stopwatch()..start();
      await dio.get('/users');
      stopwatch.stop();

      expect(stopwatch.elapsedMilliseconds, lessThan(500));
    });
  });

  group('jitter', () {
    test('spreads the wait across the backoff window', () async {
      // A seeded Random makes the choice deterministic; nextInt is called with
      // the full computed window, so 0 means "retry immediately".
      final adapter = _ScriptedAdapter([-1]);
      final dio = _dioWith(
        const RetryPolicy(baseDelay: Duration(seconds: 10)),
        adapter,
        random: _ZeroRandom(),
      );

      final stopwatch = Stopwatch()..start();
      await dio.get('/users');
      stopwatch.stop();

      // Without jitter this would have waited the full 10s.
      expect(stopwatch.elapsedMilliseconds, lessThan(1000));
      expect(adapter.callCount, 2);
    });

    test('never waits longer than maxDelay, even drawing the maximum', () {
      // _MaxRandom always returns the top of the range, so this measures the
      // widest wait the jitter window can produce.
      final adapter = _ScriptedAdapter([-1]);
      final dio = _dioWith(
        const RetryPolicy(
          baseDelay: Duration(seconds: 30),
          maxDelay: Duration(milliseconds: 60),
        ),
        adapter,
        random: _MaxRandom(),
      );

      final stopwatch = Stopwatch()..start();
      return dio.get('/users').then((_) {
        stopwatch.stop();
        // 30s base, clamped to 60ms before jitter is applied.
        expect(stopwatch.elapsedMilliseconds, lessThan(1000));
        expect(adapter.callCount, 2);
      });
    });
  });

  group('backoff arithmetic', () {
    test('a very large retry count still completes', () {
      // The exponential term reaches 2^49 here. Duration's operator* rounds a
      // double into its microsecond count, which saturates rather than
      // throwing, and _clamp brings it back to maxDelay — so no guard against
      // the magnitude is needed. Pinned because it is not obvious.
      final adapter = _ScriptedAdapter(List.filled(60, -1));
      final dio = _dioWith(
        const RetryPolicy(
          maxRetries: 50,
          baseDelay: Duration(milliseconds: 500),
          maxDelay: Duration(milliseconds: 1),
        ),
        adapter,
      );

      return expectLater(dio.get('/users'), throwsA(isA<DioException>()))
          .then((_) => expect(adapter.callCount, 51));
    });

    test('a zero baseDelay retries immediately', () {
      final adapter = _ScriptedAdapter([-1]);
      final dio = _dioWith(
        const RetryPolicy(
          baseDelay: Duration.zero,
          maxDelay: Duration(seconds: 30),
          useJitter: false,
        ),
        adapter,
      );

      final stopwatch = Stopwatch()..start();
      return dio.get('/users').then((_) {
        stopwatch.stop();
        expect(stopwatch.elapsedMilliseconds, lessThan(1000));
      });
    });
  });

  group('HttpDate', () {
    test('parses the RFC 1123 form servers actually send', () {
      expect(
        HttpDate.parse('Wed, 21 Oct 2015 07:28:00 GMT'),
        DateTime.utc(2015, 10, 21, 7, 28, 0),
      );
    });

    test('tolerates a missing day-of-week', () {
      expect(
        HttpDate.parse('21 Oct 2015 07:28:00 GMT'),
        DateTime.utc(2015, 10, 21, 7, 28, 0),
      );
    });

    test('throws on junk rather than returning a half-parsed value', () {
      expect(() => HttpDate.parse('tomorrow'), throwsFormatException);
      expect(() => HttpDate.parse('Wed, 21 Foo 2015 07:28:00 GMT'),
          throwsFormatException);
    });
  });

  group('idempotency helper', () {
    test('classifies methods correctly', () {
      const policy = RetryPolicy();

      expect(policy.isIdempotent('get'), isTrue);
      expect(policy.isIdempotent('PUT'), isTrue);
      expect(policy.isIdempotent('DELETE'), isTrue);
      expect(policy.isIdempotent('POST'), isFalse);
      expect(policy.isIdempotent('PATCH'), isFalse);
    });
  });
}

/// Always draws 0, so a jittered backoff resolves to "no wait".
class _ZeroRandom implements Random {
  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;

  @override
  int nextInt(int max) => 0;
}

/// Always draws the top of the range, giving the widest possible jitter wait.
class _MaxRandom implements Random {
  @override
  bool nextBool() => true;

  @override
  double nextDouble() => 1;

  @override
  int nextInt(int max) => max - 1;
}
