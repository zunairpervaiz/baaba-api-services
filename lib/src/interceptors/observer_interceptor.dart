import 'package:baaba_api_handler/src/observer/api_observer.dart';
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

  ObserverInterceptor({required this.observer});

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    // A broken observer must never break a request.
    try {
      observer.onRequest(options);
    } catch (_) {}
    handler.next(options);
  }
}
