import 'dart:async';

import 'package:baaba_api_handler/src/api_service.dart';
import 'package:baaba_api_handler/src/utils/network_info.dart';
import 'package:baaba_api_handler/src/utils/response_code.dart';
import 'package:baaba_api_handler/ts_api_handler.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockDio extends Mock implements Dio {}

class MockNetworkInfo extends Mock implements NetworkInfo {}

void main() {
  runApiTestCases();
}

void runApiTestCases() {
  group('API Services Test', () {
    late ApiServices apiServices;
    late MockDio mockDio;
    late MockNetworkInfo mockNetworkInfo;

    final successResponse = Response(
      requestOptions: RequestOptions(path: ''),
      statusCode: 200,
    );

    setUp(() {
      mockDio = MockDio();
      mockNetworkInfo = MockNetworkInfo();

      registerFallbackValue(RequestOptions(path: ''));
      registerFallbackValue(Options());

      when(() => mockNetworkInfo.isConnected).thenAnswer((_) async => true);
      when(() => mockDio.request<dynamic>(
            any(),
            data: any(named: 'data'),
            queryParameters: any(named: 'queryParameters'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
            onSendProgress: any(named: 'onSendProgress'),
            onReceiveProgress: any(named: 'onReceiveProgress'),
          )).thenAnswer((_) async => successResponse);

      apiServices = ApiServicesImplementation.instanceFor(
        dio: mockDio,
        networkInfo: mockNetworkInfo,
      );
    });

    test('GET returns Right(Response) on success', () async {
      final result = await apiServices.get(endpoint: '/users');
      expect(result.isRight(), isTrue);
      result.fold(
        (f) => fail('Expected success, got $f'),
        (r) => expect(r.statusCode, 200),
      );
    });

    test('POST returns Right(Response) on success', () async {
      final result =
          await apiServices.post(endpoint: '/users', data: {'name': 'test'});
      expect(result.isRight(), isTrue);
    });

    test('PUT returns Right(Response) on success', () async {
      final result =
          await apiServices.put(endpoint: '/users/1', data: {'name': 'test'});
      expect(result.isRight(), isTrue);
    });

    test('PATCH returns Right(Response) on success', () async {
      final result =
          await apiServices.patch(endpoint: '/users/1', data: {'name': 'test'});
      expect(result.isRight(), isTrue);
    });

    test('DELETE returns Right(Response) on success', () async {
      final result = await apiServices.delete(endpoint: '/users/1');
      expect(result.isRight(), isTrue);
    });

    test('returns Left(Failure) when offline', () async {
      when(() => mockNetworkInfo.isConnected).thenAnswer((_) async => false);
      final result = await apiServices.get(endpoint: '/users');
      expect(result.isLeft(), isTrue);
      result.fold(
        (f) => expect(f.errorType, ErrorSource.noInternetConnection),
        (_) => fail('Expected failure'),
      );
    });

    test('returns Left(Failure) on DioException', () async {
      when(() => mockDio.request<dynamic>(
            any(),
            data: any(named: 'data'),
            queryParameters: any(named: 'queryParameters'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
            onSendProgress: any(named: 'onSendProgress'),
            onReceiveProgress: any(named: 'onReceiveProgress'),
          )).thenThrow(DioException(
        requestOptions: RequestOptions(path: ''),
        type: DioExceptionType.connectionTimeout,
      ));

      final result = await apiServices.get(endpoint: '/users');
      expect(result.isLeft(), isTrue);
      result.fold(
        (f) => expect(f.errorType, ErrorSource.connectionTimeout),
        (_) => fail('Expected failure'),
      );
    });
  });

  group('configureLoader', () {
    late MockDio mockDio;
    late MockNetworkInfo mockNetworkInfo;
    late ApiServicesImplementation apiServices;
    late List<String> events;

    final successResponse = Response(
      requestOptions: RequestOptions(path: ''),
      statusCode: 200,
    );

    setUp(() {
      mockDio = MockDio();
      mockNetworkInfo = MockNetworkInfo();
      events = [];

      registerFallbackValue(RequestOptions(path: ''));
      registerFallbackValue(Options());

      when(() => mockNetworkInfo.isConnected).thenAnswer((_) async => true);

      apiServices = ApiServicesImplementation.instanceFor(
        dio: mockDio,
        networkInfo: mockNetworkInfo,
      );

      ApiServices.configureLoader(
        onShow: () => events.add('show'),
        onHide: () => events.add('hide'),
      );
    });

    test('shows and hides the loader around a successful request', () async {
      when(() => mockDio.request<dynamic>(
            any(),
            data: any(named: 'data'),
            queryParameters: any(named: 'queryParameters'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
            onSendProgress: any(named: 'onSendProgress'),
            onReceiveProgress: any(named: 'onReceiveProgress'),
          )).thenAnswer((_) async => successResponse);

      await apiServices.get(endpoint: '/users');

      expect(events, ['show', 'hide']);
    });

    test('shows and hides the loader when the request throws', () async {
      when(() => mockDio.request<dynamic>(
            any(),
            data: any(named: 'data'),
            queryParameters: any(named: 'queryParameters'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
            onSendProgress: any(named: 'onSendProgress'),
            onReceiveProgress: any(named: 'onReceiveProgress'),
          )).thenThrow(DioException(
        requestOptions: RequestOptions(path: ''),
        type: DioExceptionType.connectionTimeout,
      ));

      await apiServices.get(endpoint: '/users');

      expect(events, ['show', 'hide']);
    });

    test('shows and hides the loader when offline', () async {
      when(() => mockNetworkInfo.isConnected).thenAnswer((_) async => false);

      await apiServices.get(endpoint: '/users');

      expect(events, ['show', 'hide']);
    });

    test('skips the loader when showLoader is false', () async {
      when(() => mockDio.request<dynamic>(
            any(),
            data: any(named: 'data'),
            queryParameters: any(named: 'queryParameters'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
            onSendProgress: any(named: 'onSendProgress'),
            onReceiveProgress: any(named: 'onReceiveProgress'),
          )).thenAnswer((_) async => successResponse);

      await apiServices.get(endpoint: '/users', showLoader: false);

      expect(events, isEmpty);
    });

    test('shows once and hides once for two concurrent requests', () async {
      final completer = Completer<Response>();
      when(() => mockDio.request<dynamic>(
            any(),
            data: any(named: 'data'),
            queryParameters: any(named: 'queryParameters'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
            onSendProgress: any(named: 'onSendProgress'),
            onReceiveProgress: any(named: 'onReceiveProgress'),
          )).thenAnswer((_) => completer.future);

      final first = apiServices.get(endpoint: '/users');
      final second = apiServices.get(endpoint: '/orders');
      await Future<void>.delayed(Duration.zero);

      expect(events, ['show']);

      completer.complete(successResponse);
      await Future.wait([first, second]);

      expect(events, ['show', 'hide']);
    });
  });

  group('mapResponseCodeToEnum', () {
    final testCases = {
      ResponseCode.success: ErrorSource.success,
      ResponseCode.noContent: ErrorSource.noContent,
      ResponseCode.badRequest: ErrorSource.badRequest,
      ResponseCode.unauthorized: ErrorSource.unauthorized,
      ResponseCode.forbidden: ErrorSource.forbidden,
      ResponseCode.internalServerError: ErrorSource.internalServerError,
      ResponseCode.notFound: ErrorSource.notFound,
      ResponseCode.connectTimeout: ErrorSource.connectionTimeout,
      ResponseCode.cancel: ErrorSource.cancel,
      ResponseCode.receiveTimeout: ErrorSource.receiveTimeout,
      ResponseCode.sendTimeout: ErrorSource.sendTimeout,
      ResponseCode.cacheError: ErrorSource.cacheError,
      ResponseCode.noInternetConnection: ErrorSource.noInternetConnection,
      ResponseCode.defaultError: ErrorSource.defaultError,
      ResponseCode.connectionFailure: ErrorSource.connectionFailure,
    };

    testCases.forEach((responseCode, expectedErrorSource) {
      test('$responseCode maps to $expectedErrorSource', () {
        expect(
            mapResponseCodeToEnum(responseCode), equals(expectedErrorSource));
      });
    });
  });
}
