import 'package:dio/dio.dart';

/// Controls how transient failures are retried by `NetworkRetryInterceptor`.
///
/// Two separate things decide whether a request is retried:
///
/// - **Transport errors** (connection/receive/send timeouts, connection
///   failures) — retried for idempotent methods only, since the server may
///   have already processed a `POST`/`PATCH` before the timeout.
/// - **Status codes** in [retryableStatusCodes] — see
///   [alwaysRetryableStatusCodes] for the nuance about which of those are safe
///   to retry regardless of method.
///
/// **Example — be more patient with a flaky internal API:**
///
/// ```dart
/// ApiServices.init(ApiConfig(
///   baseUrl: 'https://internal.example.com',
///   retry: const RetryPolicy(maxRetries: 5, baseDelay: Duration(seconds: 1)),
/// ));
/// ```
///
/// **Example — never retry anything:**
///
/// ```dart
/// retry: const RetryPolicy.disabled(),
/// ```
class RetryPolicy {
  /// Status codes where the server has explicitly told us it did **not**
  /// process the request, so retrying cannot duplicate a side effect.
  ///
  /// These are retried for every method, including `POST` and `PATCH`:
  ///
  /// - `429 Too Many Requests` — rate limited, request rejected.
  /// - `503 Service Unavailable` — server not accepting work right now.
  ///
  /// Every other retryable status (`408`, `500`, `502`, `504`) is ambiguous —
  /// the request may or may not have been processed — so those are gated on
  /// the method being idempotent.
  static const Set<int> alwaysRetryableStatusCodes = {429, 503};

  /// Methods that are safe to repeat blindly: repeating them has the same
  /// effect as the original call.
  static const Set<String> idempotentMethods = {
    'GET',
    'HEAD',
    'OPTIONS',
    'PUT',
    'DELETE',
  };

  /// How many times to retry after the initial attempt. `0` disables retries.
  final int maxRetries;

  /// Base of the exponential backoff: attempt _n_ waits up to
  /// `baseDelay * 2^(n-1)`, capped at [maxDelay].
  final Duration baseDelay;

  /// Upper bound on any single wait, including one derived from `Retry-After`.
  final Duration maxDelay;

  /// Spread retries randomly across the backoff window instead of waiting the
  /// full computed delay.
  ///
  /// Without jitter, a burst of requests that all fail together also all retry
  /// together, hammering a recovering server in lockstep. With it enabled the
  /// wait is `random(0, computedDelay)` — "full jitter".
  final bool useJitter;

  /// Honour the `Retry-After` response header when the server sends one.
  ///
  /// Both forms are understood: delta-seconds (`Retry-After: 30`) and the
  /// HTTP-date form (`Retry-After: Wed, 21 Oct 2015 07:28:00 GMT`). The
  /// resulting delay is clamped to [maxDelay]. When present it takes
  /// precedence over the computed backoff.
  final bool respectRetryAfter;

  /// HTTP status codes worth retrying. See [alwaysRetryableStatusCodes] for
  /// which of these bypass the idempotency check.
  final Set<int> retryableStatusCodes;

  /// Has the final say on whether a given failure is retried.
  ///
  /// Called only for failures that passed every built-in check, with the
  /// 1-based [attempt] number about to be made. Return `false` to veto.
  ///
  /// ```dart
  /// retryIf: (err, attempt) => !err.requestOptions.path.contains('/payments'),
  /// ```
  final bool Function(DioException error, int attempt)? retryIf;

  const RetryPolicy({
    this.maxRetries = 3,
    this.baseDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 30),
    this.useJitter = true,
    this.respectRetryAfter = true,
    this.retryableStatusCodes = const {408, 429, 500, 502, 503, 504},
    this.retryIf,
  });

  /// No retries at all — a failure surfaces immediately.
  const RetryPolicy.disabled()
      : maxRetries = 0,
        baseDelay = const Duration(milliseconds: 500),
        maxDelay = const Duration(seconds: 30),
        useJitter = true,
        respectRetryAfter = true,
        retryableStatusCodes = const {},
        retryIf = null;

  /// Whether [method] may be repeated without risking a duplicate side effect.
  bool isIdempotent(String method) =>
      idempotentMethods.contains(method.toUpperCase());

  RetryPolicy copyWith({
    int? maxRetries,
    Duration? baseDelay,
    Duration? maxDelay,
    bool? useJitter,
    bool? respectRetryAfter,
    Set<int>? retryableStatusCodes,
    bool Function(DioException error, int attempt)? retryIf,
  }) {
    return RetryPolicy(
      maxRetries: maxRetries ?? this.maxRetries,
      baseDelay: baseDelay ?? this.baseDelay,
      maxDelay: maxDelay ?? this.maxDelay,
      useJitter: useJitter ?? this.useJitter,
      respectRetryAfter: respectRetryAfter ?? this.respectRetryAfter,
      retryableStatusCodes: retryableStatusCodes ?? this.retryableStatusCodes,
      retryIf: retryIf ?? this.retryIf,
    );
  }
}
