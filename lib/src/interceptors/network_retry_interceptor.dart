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
  })  : policy = policy ?? const RetryPolicy(),
        _random = random ?? Random();

  @override
  Future<void> onError(
      DioException err, ErrorInterceptorHandler handler) async {
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
    return policy.retryIf?.call(err, attempt) ?? true;
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

    // Exponential: attempt 1 -> base, 2 -> 2x base, 3 -> 4x base. A large
    // attempt count needs no special handling: the multiplication saturates
    // rather than throwing, and _clamp reduces it to maxDelay regardless.
    final backoff = policy.baseDelay * pow(2, attempt - 1).toDouble();
    final capped = _clamp(backoff);
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
    final raw = headers?.value('retry-after')?.trim();
    if (raw == null || raw.isEmpty) return null;

    final seconds = int.tryParse(raw);
    if (seconds != null) {
      return seconds <= 0 ? Duration.zero : Duration(seconds: seconds);
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
