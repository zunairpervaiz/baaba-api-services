import 'package:baaba_api_handler/src/utils/redactor.dart';
import 'package:dio/dio.dart';

/// Puts a [Redactor] in front of a logging interceptor.
///
/// The logger is handed masked *copies* and a handler that goes nowhere; the
/// real request, response and error continue down the chain untouched. That
/// way the logger needs no knowledge of redaction, and swapping the logging
/// library keeps it — unlike line-filtering in `logPrint`, which would be
/// tied to one logger's output format.
class RedactingLogInterceptor extends Interceptor {
  final Interceptor logger;
  final Redactor redactor;

  RedactingLogInterceptor({required this.logger, required this.redactor});

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    _quietly(() => logger.onRequest(redactor.request(options), _Discard()));
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    _quietly(
      () => logger.onResponse(redactor.response(response), _DiscardResponse()),
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _quietly(() => logger.onError(redactor.error(err), _DiscardError()));
    handler.next(err);
  }

  /// Logging must never break a request.
  static void _quietly(void Function() log) {
    try {
      log();
    } catch (_) {}
  }
}

// Handlers whose outcome nobody reads. The error one completes its future
// with an error, which would surface as an unhandled one without `ignore()`.

class _Discard extends RequestInterceptorHandler {
  _Discard() {
    future.ignore();
  }
}

class _DiscardResponse extends ResponseInterceptorHandler {
  _DiscardResponse() {
    future.ignore();
  }
}

class _DiscardError extends ErrorInterceptorHandler {
  _DiscardError() {
    future.ignore();
  }
}
