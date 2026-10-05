import 'dart:math';

import 'package:baaba_api_handler/src/config/retry_policy.dart';
import 'package:baaba_api_handler/src/utils/http_date.dart';
import 'package:baaba_api_handler/src/utils/replayable_request.dart';
import 'package:dio/dio.dart';

/// Retries transient failures according to a [RetryPolicy].
///
/// Two distinct things get retried:
///
/// - **Transport errors** — connection/receive/send timeouts and connection
///   failures. Retried for idempotent methods only: if the server already
///   processed a `POST` before the timeout, repeating it could create the same
///   order twice.
/// - **Status codes** in [RetryPolicy.retryableStatusCodes]. `429` and `503`
///   mean the server explicitly refused the work, so those are safe for any
///   method; `408`/`500`/`502`/`504` are ambiguous and stay gated on
///   idempotency.
class NetworkRetryInterceptor extends Interceptor {
  static const String _attemptKey = 'networkRetryCount';

  final Dio dio;
  final RetryPolicy policy;
  final Random _random;

  NetworkRetryInterceptor({
    required this.dio,
    RetryPolicy? policy,
    Random? random,
  }) : policy = policy ?? const RetryPolicy(),
       _random = random ?? Random();

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final attempt = (err.requestOptions.extra[_attemptKey] as int? ?? 0) + 1;

    if (attempt > policy.maxRetries || !_shouldRetry(err, attempt)) {
      return handler.next(err);
    }

    err.requestOptions.extra[_attemptKey] = attempt;
    await Future<void>.delayed(_delayFor(err, attempt));

    // A multipart body has already been consumed by the failed attempt.
    prepareForReplay(err.requestOptions);

    try {
      final response = await dio.fetch(err.requestOptions);
      return handler.resolve(response);
    } catch (e) {
      return handler.next(
        e is DioException
            ? e
            : DioException(
                requestOptions: err.requestOptions,
                error: e,
                type: DioExceptionType.unknown,
              ),
      );
    }
  }

  bool _shouldRetry(DioException err, int attempt) {
    if (!_isRetryableFailure(err)) return false;
    // A stream body was consumed by the attempt that failed.
    if (!canReplay(err.requestOptions)) return false;
    // A throwing veto means "don't retry". Letting it escape would replace
    // the real 429/503 — status and body included — with an `unknown` error.
    try {
      return policy.retryIf?.call(err, attempt) ?? true;
    } catch (_) {
      return false;
    }
  }

  bool _isRetryableFailure(DioException err) {
    final method = err.requestOptions.method;

    final status = err.response?.statusCode;
    if (status != null) {
      if (!policy.retryableStatusCodes.contains(status)) return false;
      // The server told us it did not process the request, so repeating it
      // cannot duplicate a side effect — safe even for POST/PATCH.
      if (RetryPolicy.alwaysRetryableStatusCodes.contains(status)) return true;
      return policy.isIdempotent(method);
    }

    const transient = {
      DioExceptionType.connectionTimeout,
      DioExceptionType.receiveTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.connectionError,
    };
    if (!transient.contains(err.type)) return false;

    return policy.isIdempotent(method);
  }

  Duration _delayFor(DioException err, int attempt) {
    if (policy.respectRetryAfter) {
      final retryAfter = _parseRetryAfter(err.response?.headers);
      // An explicit instruction from the server beats our guess.
      if (retryAfter != null) return _clamp(retryAfter);
    }

    // Exponential: attempt 1 -> base, 2 -> 2x base, 3 -> 4x base. Computed
    // and compared in doubles before any Duration is built — `pow(2, n)` on
    // ints wraps negative at 2^63, which slipped under the clamp and made the
    // jitter below throw.
    final micros = policy.baseDelay.inMicroseconds * pow(2.0, attempt - 1);
    final capped = micros >= policy.maxDelay.inMicroseconds
        ? policy.maxDelay
        : Duration(microseconds: micros.round());
    if (!policy.useJitter) return capped;

    // Full jitter — without it, requests that failed together also retry
    // together and hit a recovering server in lockstep. Randomised in
    // milliseconds: nextInt caps at 2^32, which a long maxDelay would exceed
    // in microseconds.
    return Duration(milliseconds: _random.nextInt(capped.inMilliseconds + 1));
  }

  Duration _clamp(Duration value) =>
      value > policy.maxDelay ? policy.maxDelay : value;

  /// Parses `Retry-After` in either permitted form: delta-seconds
  /// (`Retry-After: 30`) or an HTTP date
  /// (`Retry-After: Wed, 21 Oct 2015 07:28:00 GMT`).
  Duration? _parseRetryAfter(Headers? headers) {
    // Not Headers.value(): it throws when a header appears more than once,
    // which would turn a real 429 into an `unknown` error.
    final values = headers?['retry-after'];
    if (values == null || values.isEmpty) return null;
    final raw = values.first.trim();
    if (raw.isEmpty) return null;

    // RFC 9110 delta-seconds is plain digits. int.tryParse alone would also
    // accept `-5` (invalid, so it falls back to the computed backoff) and
    // `0x10`.
    if (RegExp(r'^[0-9]+$').hasMatch(raw)) {
      // Null past 2^63: digits too long for an int are still "a very long
      // time", not a reason to drop the header.
      final seconds = int.tryParse(raw);
      if (seconds == 0) return Duration.zero;
      // Clamped before a Duration is built from it: an absurd value overflows
      // Duration's microsecond count and wraps negative, which then slipped
      // under the maxDelay clamp and retried immediately.
      return seconds == null || seconds >= policy.maxDelay.inSeconds
          ? policy.maxDelay
          : Duration(seconds: seconds);
    }

    try {
      final until = HttpDate.parse(raw);
      final delta = until.difference(DateTime.now());
      return delta.isNegative ? Duration.zero : delta;
    } catch (_) {
      // Unparseable header — fall back to the computed backoff.
      return null;
    }
  }
}
