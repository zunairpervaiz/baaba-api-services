import 'dart:async';

import 'package:baaba_api_handler/src/api_service.dart';
import 'package:baaba_api_handler/src/utils/network_info.dart';
import 'package:baaba_api_handler/ts_api_handler.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockDio extends Mock implements Dio {}

class MockNetworkInfo extends Mock implements NetworkInfo {}

void main() {
  late MockDio mockDio;
  late MockNetworkInfo mockNetworkInfo;
  late ApiServices api;
  late int networkCalls;
  late Completer<void> gate;

  setUp(() {
    ApiServices.reset();
    networkCalls = 0;
    gate = Completer<void>();
    mockDio = MockDio();
    mockNetworkInfo = MockNetworkInfo();

    registerFallbackValue(RequestOptions(path: ''));
    registerFallbackValue(Options());
    when(() => mockNetworkInfo.isConnected).thenAnswer((_) async => true);

    // Every call parks on `gate`, so two requests are genuinely in flight at
    // the same time — which is the only situation de-duplication applies to.
    when(() => mockDio.request<dynamic>(
          any(),
          data: any(named: 'data'),
          queryParameters: any(named: 'queryParameters'),
          options: any(named: 'options'),
          cancelToken: any(named: 'cancelToken'),
          onSendProgress: any(named: 'onSendProgress'),
          onReceiveProgress: any(named: 'onReceiveProgress'),
        )).thenAnswer((_) async {
      networkCalls++;
      await gate.future;
      return Response(
        requestOptions: RequestOptions(path: '/users'),
        statusCode: 200,
        data: {'ok': true},
      );
    });

    api = ApiServicesImplementation.instanceFor(
      dio: mockDio,
      networkInfo: mockNetworkInfo,
    );
  });

  tearDown(ApiServices.reset);

  test('two concurrent identical GETs share one network call', () async {
    final both = Future.wait([
      api.get(endpoint: '/users'),
      api.get(endpoint: '/users'),
    ]);
    gate.complete();

    final results = await both;

    expect(networkCalls, 1);
    expect(results, hasLength(2));
    for (final result in results) {
      result.fold((f) => fail('$f'), (r) => expect(r.data, {'ok': true}));
    }
  });

  test('differing query parameters are not collapsed', () async {
    final both = Future.wait([
      api.get(endpoint: '/users', params: {'page': 1}),
      api.get(endpoint: '/users', params: {'page': 2}),
    ]);
    gate.complete();
    await both;

    expect(networkCalls, 2);
  });

  test('sequential identical GETs each hit the network', () async {
    gate.complete();

    await api.get(endpoint: '/users');
    await api.get(endpoint: '/users');

    // De-duplication only collapses overlapping calls; it is not a cache.
    expect(networkCalls, 2);
  });

  test('dedupe: false forces a separate request', () async {
    final both = Future.wait([
      api.get(endpoint: '/users'),
      api.get(endpoint: '/users', dedupe: false),
    ]);
    gate.complete();
    await both;

    expect(networkCalls, 2);
  });

  test('a caller-supplied CancelToken opts out', () async {
    // Sharing one call between two callers would let either cancel the
    // other's request, so a custom token must always get its own.
    final both = Future.wait([
      api.get(endpoint: '/users'),
      api.get(endpoint: '/users', cancelToken: CancelToken()),
    ]);
    gate.complete();
    await both;

    expect(networkCalls, 2);
  });

  test('POST is never de-duplicated', () async {
    final both = Future.wait([
      api.post(endpoint: '/orders', data: {'id': 1}),
      api.post(endpoint: '/orders', data: {'id': 1}),
    ]);
    gate.complete();
    await both;

    expect(networkCalls, 2);
  });

  test('the loader shows once and hides once for a de-duplicated pair',
      () async {
    var shows = 0;
    var hides = 0;
    ApiServices.configureLoader(
      onShow: () => shows++,
      onHide: () => hides++,
    );

    final both = Future.wait([
      api.get(endpoint: '/users'),
      api.get(endpoint: '/users'),
    ]);
    gate.complete();
    await both;

    // Reference counting is per caller, not per network call — otherwise the
    // second caller's hide would fire while the first still waits.
    expect(shows, 1);
    expect(hides, 1);
  });

  test('the loader is counted globally, not per client', () async {
    // The callbacks are static because the indicator is one global widget, so
    // the count has to be too. Re-configuring mid-flight must not let a second
    // client start a fresh count against a dialog the first is still driving.
    var shows = 0;
    var hides = 0;
    ApiServices.configureLoader(onShow: () => shows++, onHide: () => hides++);

    final second = ApiServicesImplementation.instanceFor(
      dio: mockDio,
      networkInfo: mockNetworkInfo,
    );

    final both = Future.wait([
      api.get(endpoint: '/users'),
      second.get(endpoint: '/others'),
    ]);
    gate.complete();
    await both;

    expect(shows, 1);
    expect(hides, 1);
  });

  test('a shared in-flight entry is released once it completes', () async {
    final both = Future.wait([
      api.get(endpoint: '/users'),
      api.get(endpoint: '/users'),
    ]);
    gate.complete();
    await both;

    gate = Completer<void>()..complete();
    await api.get(endpoint: '/users');

    expect(networkCalls, 2);
  });

  test('both callers see the same failure', () async {
    when(() => mockDio.request<dynamic>(
          any(),
          data: any(named: 'data'),
          queryParameters: any(named: 'queryParameters'),
          options: any(named: 'options'),
          cancelToken: any(named: 'cancelToken'),
          onSendProgress: any(named: 'onSendProgress'),
          onReceiveProgress: any(named: 'onReceiveProgress'),
        )).thenAnswer((_) async {
      networkCalls++;
      await gate.future;
      throw DioException(
        type: DioExceptionType.connectionError,
        requestOptions: RequestOptions(path: '/users'),
      );
    });

    final both = Future.wait([
      api.get(endpoint: '/users'),
      api.get(endpoint: '/users'),
    ]);
    gate.complete();
    final results = await both;

    expect(networkCalls, 1);
    for (final result in results) {
      result.fold(
        (failure) => expect(failure.errorType, ErrorSource.connectionFailure),
        (_) => fail('Expected a failure'),
      );
    }
  });
}
