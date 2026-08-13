import 'package:baaba_api_handler/src/utils/failure.dart';
import 'package:dio/dio.dart';

/// A single place to watch every request the package makes — for crash
/// reporting, analytics, or a debug overlay.
///
/// Without this, error reporting has to be duplicated inside every caller's
/// `fold`. Register one observer instead:
///
/// ```dart
/// class SentryObserver extends ApiObserver {
///   @override
///   void onFailure(Failure failure, RequestOptions? options) {
///     Sentry.captureMessage(
///       '${options?.method} ${options?.path} -> ${failure.code.value}',
///       withScope: (scope) => scope.setContexts('api', {
///         'message': failure.message,
///         'body': failure.data,
///       }),
///     );
///   }
/// }
///
/// ApiServices.init(ApiConfig(observer: SentryObserver()));
/// ```
///
/// Every method has a no-op default, so override only what you need.
///
/// **Failures you would not otherwise see.** [onFailure] fires for failures
/// Dio never produces an exception for — the offline short-circuit, response
/// parsing errors from the `*As<T>` methods, and bodies rejected by
/// `ApiConfig.isSuccess`. That is the main reason to observe here rather than
/// adding your own Dio interceptor.
///
/// **Callbacks must not throw.** They are invoked inside the request path and
/// wrapped in a `try`/`catch`, so a throwing observer cannot break a request —
/// but the error is swallowed, not reported. Keep the bodies cheap and
/// defensive; hand off anything slow to a queue.
abstract class ApiObserver {
  const ApiObserver();

  /// Fires as a request leaves, after auth headers have been attached.
  ///
  /// Fires again for each automatic retry, so read it as "an attempt started"
  /// rather than "the caller made a call" — unlike [onResponse] and
  /// [onFailure], which fire exactly once per call.
  void onRequest(RequestOptions options) {}

  /// Fires once per call for each response handed back as `Right`, including
  /// one served from the cache.
  ///
  /// Not called for a `2xx` that `ApiConfig.isSuccess` rejected — that goes to
  /// [onFailure] instead, since that is what the caller receives.
  ///
  /// A `*As<T>` call whose parser then throws fires **both**: this first, for
  /// the HTTP outcome, then [onFailure] with `ErrorSource.parseError`. They
  /// are genuinely two events — the request succeeded and the body could not
  /// be understood — and collapsing them would hide one or the other.
  void onResponse(Response response) {}

  /// Fires once per call for every `Left` the package returns, whatever
  /// produced it: an HTTP error, a timeout, the offline short-circuit, a
  /// rejected `isSuccess` body, a `cacheOnly` miss, or a parse failure.
  ///
  /// [options] is `null` when no request was ever built — the offline
  /// short-circuit and a `cacheOnly` miss are the cases. It is also available
  /// as `failure.requestOptions`.
  ///
  /// "Once per call" counts calls you made, not network round-trips: two
  /// concurrent identical `GET`s that de-duplication collapses onto one
  /// request still produce two events, one for each caller.
  void onFailure(Failure failure, RequestOptions? options) {}
}
