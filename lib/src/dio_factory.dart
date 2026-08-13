import 'package:baaba_api_handler/src/config/api_config.dart';
import 'package:baaba_api_handler/src/interceptors/network_retry_interceptor.dart';
import 'package:baaba_api_handler/src/interceptors/observer_interceptor.dart';
import 'package:baaba_api_handler/src/interceptors/token_refresh_interceptor.dart';
import 'package:baaba_api_handler/src/utils/api_log_options.dart';
import 'package:baaba_api_handler/src/utils/base64_log_trimmer.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pretty_dio_logger/pretty_dio_logger.dart';

class DioFactory {
  /// Builds the Dio client described by [config], with the full interceptor
  /// chain attached.
  ///
  /// **Order matters and is fixed here** rather than being assembled across
  /// several call sites:
  ///
  /// 1. [TokenRefreshInterceptor] — attaches auth headers on the way out; on a
  ///    `401`, refreshes and replays. First, so that a replayed request still
  ///    passes through everything below it.
  /// 2. [NetworkRetryInterceptor] — retries transient failures. After auth, so
  ///    a retry carries a valid token.
  /// 3. [PrettyDioLogger] — non-release builds only.
  /// 4. [ObserverInterceptor] — last, so it reports the final outcome rather
  ///    than each failure the chain above went on to recover from.
  Dio getDio({ApiConfig config = const ApiConfig()}) {
    final dio = Dio(BaseOptions(
      baseUrl: config.baseUrl ?? '',
      // Copied into a Map<String, dynamic> because Dio writes non-string
      // values (content-length) into this map as requests go out.
      headers: Map<String, dynamic>.from(config.defaultHeaders),
      connectTimeout: config.connectTimeout,
      receiveTimeout: config.receiveTimeout,
      sendTimeout: config.sendTimeout,
    ));

    final adapter = config.httpClientAdapter;
    if (adapter != null) dio.httpClientAdapter = adapter;

    final auth = config.auth;
    if (auth != null) {
      dio.interceptors
          .add(TokenRefreshInterceptor.fromConfig(dio: dio, config: auth));
    }

    dio.interceptors
        .add(NetworkRetryInterceptor(dio: dio, policy: config.retry));

    if (!kReleaseMode && config.logging.enabled) {
      dio.interceptors.add(PrettyDioLogger(
        request: config.logging.request,
        requestHeader: config.logging.requestHeader,
        requestBody: config.logging.requestBody,
        responseHeader: config.logging.responseHeader,
        responseBody: config.logging.responseBody,
        error: config.logging.error,
        maxWidth: config.logging.maxWidth,
        compact: config.logging.compact,
        logPrint: _logSink(config.logging),
      ));
    }

    final observer = config.observer;
    if (observer != null) {
      dio.interceptors.add(ObserverInterceptor(observer: observer));
    }

    return dio;
  }

  /// Builds the sink the logger writes to.
  ///
  /// The trimmer goes in front of the caller's own sink rather than replacing
  /// it, so a custom `logPrint` still receives every line — already trimmed.
  /// A fresh trimmer per client: it carries a running count of elided
  /// characters that two clients must not share.
  static void Function(Object object) _logSink(ApiLogOptions logging) {
    final sink = logging.logPrint ?? defaultLogPrint;
    if (!logging.trimBase64) return sink;
    return Base64LogTrimmer(sink: sink).call;
  }

  /// Default log sink.
  ///
  /// `debugPrint` rather than `print`: Android's logcat truncates lines past
  /// ~1024 characters, which silently cuts response bodies in half.
  static void defaultLogPrint(Object object) => debugPrint(object.toString());
}
