import 'package:baaba_api_handler/src/interceptors/network_retry_interceptor.dart';
import 'package:baaba_api_handler/src/utils/api_log_options.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pretty_dio_logger/pretty_dio_logger.dart';

class DioFactory {
  /// Builds a Dio client with the retry interceptor and — outside release
  /// builds — the console logger.
  ///
  /// [logOptions] controls what the logger prints; pass
  /// `ApiLogOptions.disabled()` to leave it off entirely.
  Dio getDio({
    Map<String, String>? header,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    ApiLogOptions logOptions = const ApiLogOptions(),
  }) {
    final dio = Dio(BaseOptions(
      headers: header,
      receiveTimeout: receiveTimeout,
      sendTimeout: sendTimeout,
    ));

    dio.interceptors.add(NetworkRetryInterceptor(dio: dio));

    if (!kReleaseMode && logOptions.enabled) {
      dio.interceptors.add(PrettyDioLogger(
        request: logOptions.request,
        requestHeader: logOptions.requestHeader,
        requestBody: logOptions.requestBody,
        responseHeader: logOptions.responseHeader,
        responseBody: logOptions.responseBody,
        error: logOptions.error,
        maxWidth: logOptions.maxWidth,
        compact: logOptions.compact,
        logPrint: logOptions.logPrint ?? print,
      ));
    }

    return dio;
  }
}
