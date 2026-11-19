import 'package:baaba_api_handler/src/utils/binary_log_summary.dart';
import 'package:baaba_api_handler/src/utils/redactor.dart';
import 'package:dio/dio.dart';

/// Hands the logging interceptor a copy fit to print: binary bodies
/// summarized ([BinaryLogSummary]) and, unless redaction is off, secrets
/// masked by a [Redactor].
///
/// The logger is handed these *copies* and a handler that goes nowhere; the
/// real request, response and error continue down the chain untouched. That
/// way the logger needs no knowledge of either, and swapping the logging
/// library keeps both — unlike line-filtering in `logPrint`, which would be
/// tied to one logger's output format.
class RedactingLogInterceptor extends Interceptor {
  final Interceptor logger;

  /// `null` when redaction is off; binary bodies are summarized regardless.
  final Redactor? redactor;

  RedactingLogInterceptor({required this.logger, this.redactor});

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    _quietly(() {
      final copy = BinaryLogSummary.request(options);
      logger.onRequest(redactor?.request(copy) ?? copy, _Discard());
    });
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    _quietly(() {
      final copy = BinaryLogSummary.response(response);
      logger.onResponse(redactor?.response(copy) ?? copy, _DiscardResponse());
    });
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _quietly(() {
      final copy = BinaryLogSummary.error(err);
      logger.onError(redactor?.error(copy) ?? copy, _DiscardError());
    });
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
