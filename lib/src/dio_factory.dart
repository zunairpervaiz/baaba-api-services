import 'package:baaba_api_handler/src/interceptors/network_retry_interceptor.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pretty_dio_logger/pretty_dio_logger.dart';

class DioFactory {
  Dio getDio({
    Map<String, String>? header,
    Duration? receiveTimeout,
    Duration? sendTimeout,
  }) {
    final dio = Dio(BaseOptions(
      headers: header,
      receiveTimeout: receiveTimeout,
      sendTimeout: sendTimeout,
    ));

    dio.interceptors.add(NetworkRetryInterceptor(dio: dio));

    if (!kReleaseMode) {
      dio.interceptors.add(PrettyDioLogger(
        requestHeader: false,
        responseHeader: false,
        request: true,
        requestBody: true,
        responseBody: true,
        error: true,
      ));
    }

    return dio;
  }
}
