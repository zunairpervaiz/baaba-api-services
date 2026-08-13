import 'package:baaba_api_handler/src/config/api_config.dart';
import 'package:baaba_api_handler/src/config/auth_config.dart';
import 'package:baaba_api_handler/src/dio_factory.dart';
import 'package:baaba_api_handler/src/interceptors/network_retry_interceptor.dart';
import 'package:baaba_api_handler/src/interceptors/observer_interceptor.dart';
import 'package:baaba_api_handler/src/interceptors/token_refresh_interceptor.dart';
import 'package:baaba_api_handler/src/observer/api_observer.dart';
import 'package:baaba_api_handler/src/utils/api_log_options.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pretty_dio_logger/pretty_dio_logger.dart';

class _NoopObserver extends ApiObserver {
  const _NoopObserver();
}

void main() {
  group('Dio Factory', () {
    late DioFactory dioFactory;

    setUp(() => dioFactory = DioFactory());

    test('applies default timeouts so a request cannot hang forever', () {
      // Regression guard for the pre-2.0.0 behaviour, where no timeout was set
      // at any layer and a black-holed host hung until the OS gave up.
      final dio = dioFactory.getDio();

      expect(dio.options.connectTimeout, const Duration(seconds: 30));
      expect(dio.options.receiveTimeout, const Duration(seconds: 30));
      expect(dio.options.sendTimeout, const Duration(seconds: 30));
    });

    test('applies baseUrl and default headers from the config', () {
      final dio = dioFactory.getDio(
        config: const ApiConfig(
          baseUrl: 'https://api.example.com',
          defaultHeaders: {'X-Client': 'mobile'},
        ),
      );

      expect(dio.options.baseUrl, 'https://api.example.com');
      expect(dio.options.headers['X-Client'], 'mobile');
    });

    test('leaves baseUrl empty when the config omits it', () {
      final dio = dioFactory.getDio();

      expect(dio.options.baseUrl, isEmpty);
      expect(dio.options.headers, isEmpty);
    });

    test('honours custom timeouts', () {
      final dio = dioFactory.getDio(
        config: const ApiConfig(
          connectTimeout: Duration(seconds: 5),
          receiveTimeout: Duration(minutes: 2),
          sendTimeout: Duration(seconds: 45),
        ),
      );

      expect(dio.options.connectTimeout, const Duration(seconds: 5));
      expect(dio.options.receiveTimeout, const Duration(minutes: 2));
      expect(dio.options.sendTimeout, const Duration(seconds: 45));
    });

    test('attaches the retry interceptor but no auth interceptor by default',
        () {
      final dio = dioFactory.getDio();

      expect(
          dio.interceptors.whereType<NetworkRetryInterceptor>(), hasLength(1));
      expect(dio.interceptors.whereType<TokenRefreshInterceptor>(), isEmpty);
      expect(dio.interceptors.whereType<ObserverInterceptor>(), isEmpty);
    });

    test('orders auth before retry so a retry carries a valid token', () {
      final dio = dioFactory.getDio(
        config: ApiConfig(
          auth: AuthConfig(
            getToken: () async => 'token',
            onTokenRefresh: () async => true,
          ),
          observer: const _NoopObserver(),
        ),
      );

      final authIndex =
          dio.interceptors.indexWhere((i) => i is TokenRefreshInterceptor);
      final retryIndex =
          dio.interceptors.indexWhere((i) => i is NetworkRetryInterceptor);
      final observerIndex =
          dio.interceptors.indexWhere((i) => i is ObserverInterceptor);

      expect(authIndex, isNonNegative);
      expect(authIndex, lessThan(retryIndex));
      // The observer goes last so it sees the final outcome.
      expect(observerIndex, greaterThan(retryIndex));
    });

    test('installs a custom HttpClientAdapter when one is supplied', () {
      final adapter = _RecordingAdapter();
      final dio = dioFactory.getDio(
        config: ApiConfig(httpClientAdapter: adapter),
      );

      expect(dio.httpClientAdapter, same(adapter));
    });

    test(
        'logs the request line, request body, response body and errors '
        'by default', () {
      final dio = dioFactory.getDio();

      final logger = dio.interceptors.whereType<PrettyDioLogger>().single;
      expect(logger.request, isTrue);
      expect(logger.requestBody, isTrue);
      expect(logger.responseBody, isTrue);
      expect(logger.error, isTrue);
      expect(logger.requestHeader, isFalse);
      expect(logger.responseHeader, isFalse);
    });

    test('forwards every ApiLogOptions field to PrettyDioLogger', () {
      final lines = <Object>[];
      final dio = dioFactory.getDio(
        config: ApiConfig(
          logging: ApiLogOptions(
            request: false,
            requestHeader: true,
            requestBody: false,
            responseHeader: true,
            responseBody: false,
            error: false,
            maxWidth: 120,
            compact: false,
            logPrint: lines.add,
          ),
        ),
      );

      final logger = dio.interceptors.whereType<PrettyDioLogger>().single;
      expect(logger.request, isFalse);
      expect(logger.requestHeader, isTrue);
      expect(logger.requestBody, isFalse);
      expect(logger.responseHeader, isTrue);
      expect(logger.responseBody, isFalse);
      expect(logger.error, isFalse);
      expect(logger.maxWidth, 120);
      expect(logger.compact, isFalse);

      logger.logPrint('hello');
      expect(lines, ['hello']);
    });

    test('routes log output to the supplied logPrint sink', () {
      // Consumers wrap this to strip base64 blobs out of the stream, so the
      // sink they pass must be the one PrettyDioLogger actually calls.
      final lines = <Object>[];
      final dio = dioFactory.getDio(
        config: ApiConfig(logging: ApiLogOptions(logPrint: lines.add)),
      );

      dio.interceptors.whereType<PrettyDioLogger>().single.logPrint('hello');

      expect(lines, ['hello']);
    });

    test('attaches no logger when logging is disabled', () {
      final dio = dioFactory.getDio(
        config: const ApiConfig(logging: ApiLogOptions.disabled()),
      );

      expect(dio.interceptors.whereType<PrettyDioLogger>(), isEmpty);
    });
  });
}

class _RecordingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? stream,
          Future<void>? cancelFuture) async =>
      ResponseBody.fromString('{}', 200);

  @override
  void close({bool force = false}) {}
}
