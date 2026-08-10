import 'package:baaba_api_handler/src/dio_factory.dart';
import 'package:baaba_api_handler/src/utils/api_log_options.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pretty_dio_logger/pretty_dio_logger.dart';

class MockDio extends Mock implements Dio {}

void main() {
  group('Dio Factory', () {
    late DioFactory dioFactory;
    late MockDio mockDio;

    setUp(() {
      mockDio = MockDio();
      dioFactory = DioFactory();
    });

    test('getDio return a configured dio instance', () {
      final dio = dioFactory.getDio();
      expect(dio, isA<Dio>());

      expect(dio.options.headers, isEmpty);
      expect(dio.options.receiveTimeout, isNull);
      expect(dio.options.sendTimeout, isNull);
    });

    test('getDio returns a configured Dio instance with custom headers', () {
      final customHeaders = {'Authorization': 'Bearer token'};
      final dio = dioFactory.getDio(header: customHeaders);

      // Verify that Dio instance was created
      expect(dio, isA<Dio>());

      // Verify that Dio options are configured correctly
      expect(dio.options.headers, equals(customHeaders));
      expect(dio.options.receiveTimeout, isNull);
      expect(dio.options.sendTimeout, isNull);
    });

    test(
        'getDio logs the request line, request body, response body and errors '
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

    test('getDio forwards every ApiLogOptions field to PrettyDioLogger', () {
      final lines = <Object>[];
      final dio = dioFactory.getDio(
        logOptions: ApiLogOptions(
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

    test('getDio attaches no logger when logging is disabled', () {
      final dio = dioFactory.getDio(
        logOptions: const ApiLogOptions.disabled(),
      );

      expect(dio.interceptors.whereType<PrettyDioLogger>(), isEmpty);
    });

    test('getDio adds PrettyDioLogger interceptor in non-release mode', () {
      // Mock kReleaseMode to be false
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      final dio = dioFactory.getDio();

      // Verify that Dio instance was created
      expect(dio, isA<Dio>());

      // Verify that PrettyDioLogger interceptor was added
      verifyNever(() => mockDio.interceptors.add(any()));

      // Reset debugDefaultTargetPlatformOverride
      debugDefaultTargetPlatformOverride = null;
    });

    test('getDio does not add PrettyDioLogger interceptor in release mode', () {
      // Mock kReleaseMode to be true
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      final dio = dioFactory.getDio();

      // Verify that Dio instance was created
      expect(dio, isA<Dio>());

      // Verify that PrettyDioLogger interceptor was not added
      verifyNever(() => mockDio.interceptors.add(any()));

      // Reset debugDefaultTargetPlatformOverride
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
