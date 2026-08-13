import 'dart:async';

import 'package:baaba_api_handler/src/api_service.dart';
import 'package:baaba_api_handler/src/utils/error_source_extension.dart';
import 'package:baaba_api_handler/src/utils/network_info.dart';
import 'package:baaba_api_handler/ts_api_handler.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockDio extends Mock implements Dio {}

class MockNetworkInfo extends Mock implements NetworkInfo {}

class _RecordingObserver extends ApiObserver {
  final List<Response> responses = [];
  final List<Failure> failures = [];
  final List<RequestOptions?> failureOptions = [];

  @override
  void onResponse(Response response) => responses.add(response);

  @override
  void onFailure(Failure failure, RequestOptions? options) {
    failures.add(failure);
    failureOptions.add(options);
  }
}

void main() {
  late MockDio mockDio;
  late MockNetworkInfo mockNetworkInfo;
  late ApiServices api;

  void stubNetwork({Object? body, DioException? error, int statusCode = 200}) {
    when(() => mockDio.request<dynamic>(
          any(),
          data: any(named: 'data'),
          queryParameters: any(named: 'queryParameters'),
          options: any(named: 'options'),
          cancelToken: any(named: 'cancelToken'),
          onSendProgress: any(named: 'onSendProgress'),
          onReceiveProgress: any(named: 'onReceiveProgress'),
        )).thenAnswer((_) async {
      if (error != null) throw error;
      return Response(
        requestOptions: RequestOptions(path: '/users'),
        statusCode: statusCode,
        data: body,
      );
    });
  }

  setUp(() {
    ApiServices.reset();
    mockDio = MockDio();
    mockNetworkInfo = MockNetworkInfo();

    registerFallbackValue(RequestOptions(path: ''));
    registerFallbackValue(Options());
    when(() => mockNetworkInfo.isConnected).thenAnswer((_) async => true);

    api = ApiServicesImplementation.instanceFor(
      dio: mockDio,
      networkInfo: mockNetworkInfo,
    );
  });

  tearDown(ApiServices.reset);

  group('ApiObserver', () {
    late _RecordingObserver observer;

    setUp(() {
      observer = _RecordingObserver();
      ApiServices.init(ApiConfig(observer: observer));
      // init() builds its own client; keep driving the mock one.
      api = ApiServicesImplementation.instanceFor(
        dio: mockDio,
        networkInfo: mockNetworkInfo,
      );
    });

    test('reports a success exactly once', () async {
      stubNetwork(body: {'ok': true});

      await api.get(endpoint: '/users');

      expect(observer.responses, hasLength(1));
      expect(observer.failures, isEmpty);
    });

    test('reports an HTTP failure with the request options', () async {
      stubNetwork(
        error: DioException(
          type: DioExceptionType.badResponse,
          requestOptions: RequestOptions(path: '/users'),
          response: Response(
            statusCode: 500,
            requestOptions: RequestOptions(path: '/users'),
          ),
        ),
      );

      await api.get(endpoint: '/users');

      expect(observer.failures, hasLength(1));
      expect(observer.failures.single.statusCode, 500);
      expect(observer.failureOptions.single, isNotNull);
    });

    test('reports the offline short-circuit, which Dio never sees', () async {
      when(() => mockNetworkInfo.isConnected).thenAnswer((_) async => false);

      await api.get(endpoint: '/users');

      expect(
          observer.failures.single.errorType, ErrorSource.noInternetConnection);
      // No request was ever built.
      expect(observer.failureOptions.single, isNull);
    });

    test('reports once per caller, not once per network call', () async {
      // De-duplication collapses two identical GETs onto one request. The
      // observer counts calls the app made, so both callers must be reported —
      // notifying from inside the shared request would emit only one.
      final gate = Completer<void>();
      when(() => mockDio.request<dynamic>(
            any(),
            data: any(named: 'data'),
            queryParameters: any(named: 'queryParameters'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
            onSendProgress: any(named: 'onSendProgress'),
            onReceiveProgress: any(named: 'onReceiveProgress'),
          )).thenAnswer((_) async {
        await gate.future;
        return Response(
          requestOptions: RequestOptions(path: '/users'),
          statusCode: 200,
          data: {'ok': true},
        );
      });

      final both = Future.wait([
        api.get(endpoint: '/users'),
        api.get(endpoint: '/users'),
      ]);
      gate.complete();
      await both;

      expect(observer.responses, hasLength(2));
    });

    test('attaches the request that failed', () async {
      stubNetwork(
        error: DioException(
          type: DioExceptionType.badResponse,
          requestOptions: RequestOptions(path: '/users', method: 'GET'),
          response: Response(
            statusCode: 404,
            requestOptions: RequestOptions(path: '/users', method: 'GET'),
          ),
        ),
      );

      await api.get(endpoint: '/users');

      final failure = observer.failures.single;
      expect(failure.requestOptions?.path, '/users');
      expect(observer.failureOptions.single?.method, 'GET');
    });

    test('requestOptions is context, not identity', () async {
      // Two identical 404s from different endpoints should still compare
      // equal; RequestOptions has no value equality of its own.
      final a = ErrorSource.notFound
          .getFailure()
          .withRequest(RequestOptions(path: '/a'));
      final b = ErrorSource.notFound
          .getFailure()
          .withRequest(RequestOptions(path: '/b'));

      expect(a, equals(b));
    });

    test('reports a parse failure rather than the underlying success',
        () async {
      stubNetwork(body: {'unexpected': 'shape'});

      await api.getAs<int>(
        endpoint: '/users',
        parser: (data) => (data as Map)['count'] as int,
      );

      expect(observer.failures.single.errorType, ErrorSource.parseError);
    });

    test('a throwing observer does not break the request', () async {
      ApiServices.init(const ApiConfig(observer: _ExplodingObserverHolder.it));
      stubNetwork(body: {'ok': true});

      final result = await ApiServicesImplementation.instanceFor(
        dio: mockDio,
        networkInfo: mockNetworkInfo,
      ).get(endpoint: '/users');

      expect(result.isRight(), isTrue);
    });
  });

  group('isSuccess', () {
    setUp(() {
      ApiServices.init(ApiConfig(
        isSuccess: (response) {
          final data = response.data;
          return data is! Map || data['success'] != false;
        },
      ));
      api = ApiServicesImplementation.instanceFor(
        dio: mockDio,
        networkInfo: mockNetworkInfo,
      );
    });

    test('turns a 200 the predicate rejects into a Failure', () async {
      stubNetwork(body: {'success': false, 'message': 'Insufficient funds'});

      final result = await api.post(endpoint: '/payments');

      result.fold(
        (failure) {
          expect(failure.message, 'Insufficient funds');
          expect(failure.data, {
            'success': false,
            'message': 'Insufficient funds',
          });
          expect(failure.statusCode, 200);
        },
        (_) => fail('Expected the rejected body to become a Failure'),
      );
    });

    test('leaves an accepted 200 alone', () async {
      stubNetwork(body: {'success': true, 'balance': 10});

      final result = await api.post(endpoint: '/payments');

      expect(result.isRight(), isTrue);
    });

    test('falls back to the generic message when the body has none', () async {
      stubNetwork(body: {'success': false});

      final result = await api.post(endpoint: '/payments');

      result.fold(
        (failure) => expect(failure.message, isNotEmpty),
        (_) => fail('Expected a Failure'),
      );
    });

    test('is inert when not configured', () async {
      ApiServices.reset();
      stubNetwork(body: {'success': false});

      final result = await ApiServicesImplementation.instanceFor(
        dio: mockDio,
        networkInfo: mockNetworkInfo,
      ).post(endpoint: '/payments');

      expect(result.isRight(), isTrue);
    });
  });
}

/// Const holder so the exploding observer can live in a const [ApiConfig].
abstract final class _ExplodingObserverHolder {
  static const it = _ConstExplodingObserver();
}

class _ConstExplodingObserver extends ApiObserver {
  const _ConstExplodingObserver();

  @override
  void onResponse(Response response) => throw StateError('broken');

  @override
  void onFailure(Failure failure, RequestOptions? options) =>
      throw StateError('broken');
}
