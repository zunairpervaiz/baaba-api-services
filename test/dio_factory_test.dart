import 'package:baaba_api_handler/src/dio_factory.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

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
