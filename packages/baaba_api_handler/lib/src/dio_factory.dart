import 'package:baaba_api_handler/src/config/api_config.dart';
import 'package:baaba_api_handler/src/interceptors/network_retry_interceptor.dart';
import 'package:baaba_api_handler/src/interceptors/observer_interceptor.dart';
import 'package:baaba_api_handler/src/interceptors/redacting_log_interceptor.dart';
import 'package:baaba_api_handler/src/interceptors/token_refresh_interceptor.dart';
import 'package:baaba_api_handler/src/transport/transport.dart';
import 'package:baaba_api_handler/src/utils/api_log_options.dart';
import 'package:baaba_api_handler/src/utils/base64_log_trimmer.dart';
import 'package:baaba_api_handler/src/utils/redactor.dart';
import 'package:baaba_api_handler/src/utils/url_join.dart';
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
  /// 2. `ApiConfig.interceptors` — the caller's own, if any. After auth so
  ///    they can sign or amend an already-authenticated request; before retry
  ///    and the logger so replays re-run them and the log shows their work.
  /// 3. [NetworkRetryInterceptor] — retries transient failures. After auth, so
  ///    a retry carries a valid token.
  /// 4. [PrettyDioLogger] — non-release builds only, behind
  ///    [RedactingLogInterceptor], which masks secrets and prints a binary
  ///    body as `<N bytes, type>`.
  /// 5. [ObserverInterceptor] — last, so `onRequest` sees the request as it
  ///    actually goes out, once per attempt. Outcomes (`onResponse`,
  ///    `onFailure`) are reported by the service layer, not from here.
  Dio getDio({ApiConfig config = const ApiConfig()}) {
    final dio = Dio(
      BaseOptions(
        // Trimmed of trailing slashes; the service layer gives every relative
        // endpoint a leading one, so the join never doubles or drops a slash.
        baseUrl: normalizeBaseUrl(config.baseUrl),
        // Copied into a Map<String, dynamic> because Dio writes non-string
        // values (content-length) into this map as requests go out.
        headers: Map<String, dynamic>.from(config.defaultHeaders),
        connectTimeout: config.connectTimeout,
        receiveTimeout: config.receiveTimeout,
        sendTimeout: config.sendTimeout,
      ),
    );

    // A caller's own adapter wins; failing that, pinning and proxy get one
    // that honours them (on IO — on web the browser owns the transport), as
    // does a token in a custom header, which only that adapter keeps off a
    // cross-origin redirect. Otherwise Dio's default stays.
    // ApiConfig asserts against this, but asserts are gone in release, where
    // the caller's adapter would win and pinning would be dropped without a
    // word. A pin that silently stops pinning is the worst way for it to
    // fail, so it is refused in every build.
    if (config.httpClientAdapter != null &&
        (config.pinning != null || (config.proxy?.isActive ?? false))) {
      throw ArgumentError(
        'httpClientAdapter replaces the transport that pinning and proxy '
        'configure. Use one or the other.',
      );
    }
    final adapter =
        config.httpClientAdapter ??
        createTransportAdapter(
          pinning: config.pinning,
          proxy: config.proxy,
          tokenInCustomHeader: config.auth?.headerBuilder != null,
        );
    if (adapter != null) dio.httpClientAdapter = adapter;

    final auth = config.auth;
    if (auth != null) {
      dio.interceptors.add(
        TokenRefreshInterceptor.fromConfig(dio: dio, config: auth),
      );
    }

    // After auth, so a signing interceptor sees the Authorization header it
    // has to cover. Before retry, so a replayed request passes through them
    // again rather than carrying a stale timestamp, and before the logger, so
    // what the caller adds is what gets printed.
    dio.interceptors.addAll(config.interceptors);

    dio.interceptors.add(
      NetworkRetryInterceptor(dio: dio, policy: config.retry),
    );

    if (!kReleaseMode && config.logging.enabled) {
      final redactor = Redactor.of(config.logging);
      final logger = PrettyDioLogger(
        request: config.logging.request,
        requestHeader: config.logging.requestHeader,
        requestBody: config.logging.requestBody,
        responseHeader: config.logging.responseHeader,
        responseBody: config.logging.responseBody,
        error: config.logging.error,
        maxWidth: config.logging.maxWidth,
        compact: config.logging.compact,
        logPrint: _logSink(config.logging),
      );
      // Always wrapped: binary bodies are summarized even with redaction off.
      dio.interceptors.add(
        RedactingLogInterceptor(logger: logger, redactor: redactor),
      );
    }

    final observer = config.observer;
    if (observer != null) {
      dio.interceptors.add(
        ObserverInterceptor(
          observer: observer,
          redactor: Redactor.of(config.logging),
        ),
      );
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
