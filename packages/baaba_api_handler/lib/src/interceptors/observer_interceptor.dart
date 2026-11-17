import 'package:baaba_api_handler/src/observer/api_observer.dart';
import 'package:baaba_api_handler/src/utils/redactor.dart';
import 'package:dio/dio.dart';

/// Reports outgoing attempts to an [ApiObserver].
///
/// **Only `onRequest` lives here.** Outcomes are reported by
/// `ApiServicesImplementation` instead, for a reason worth stating: when
/// `TokenRefreshInterceptor` recovers a `401` it calls `handler.resolve(...)`,
/// which completes the request without running the rest of the chain. An
/// observer wired to Dio's response and error events would therefore miss
/// every refreshed success and see intermediate failures the package went on
/// to recover from. Reporting from the service layer gives exactly one
/// outcome per call the caller made, and covers failures Dio never produces
/// an exception for (offline, parse errors, `isSuccess` rejections).
class ObserverInterceptor extends Interceptor {
  final ApiObserver observer;

  /// Masks secrets in the copy the observer sees; `null` when redaction is
  /// off. The request itself goes on unmasked.
  final Redactor? redactor;

  ObserverInterceptor({required this.observer, this.redactor});

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    // A broken observer must never break a request.
    try {
      observer.onRequest(redactor?.request(options) ?? options);
    } catch (_) {}
    handler.next(options);
  }
}
