import 'dart:async';

import 'package:baaba_api_handler/src/api_service.dart';
import 'package:baaba_api_handler/src/utils/network_info.dart';
import 'package:baaba_api_handler/ts_api_handler.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockDio extends Mock implements Dio {}

class MockNetworkInfo extends Mock implements NetworkInfo {}

/// A request body with `toJson` but no `toString`.
class _Query {
  final String term;
  _Query(this.term);
  Map<String, dynamic> toJson() => {'term': term};
}

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
    when(
      () => mockDio.request<dynamic>(
        any(),
        data: any(named: 'data'),
        queryParameters: any(named: 'queryParameters'),
        options: any(named: 'options'),
        cancelToken: any(named: 'cancelToken'),
        onSendProgress: any(named: 'onSendProgress'),
        onReceiveProgress: any(named: 'onReceiveProgress'),
      ),
    ).thenAnswer((_) async {
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

  test(
    'the loader shows once and hides once for a de-duplicated pair',
    () async {
      var shows = 0;
      var hides = 0;
      ApiServices.configureLoader(onShow: () => shows++, onHide: () => hides++);

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
    },
  );

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
    when(
      () => mockDio.request<dynamic>(
        any(),
        data: any(named: 'data'),
        queryParameters: any(named: 'queryParameters'),
        options: any(named: 'options'),
        cancelToken: any(named: 'cancelToken'),
        onSendProgress: any(named: 'onSendProgress'),
        onReceiveProgress: any(named: 'onReceiveProgress'),
      ),
    ).thenAnswer((_) async {
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

  test('a reset() mid-request does not break the loader for good', () async {
    ApiServices.configureLoader(onShow: () {}, onHide: () {});
    final inFlight = api.get(endpoint: '/users');

    // reset() zeroes the count while that request still holds the loader.
    ApiServices.reset();
    var shows = 0;
    var hides = 0;
    ApiServices.configureLoader(onShow: () => shows++, onHide: () => hides++);

    gate.complete();
    await inFlight;
    // Its release used to take the count to -1, so the next request's
    // increment landed on 0 and the loader never showed again.
    await api.get(endpoint: '/users', dedupe: false);

    expect(shows, 1);
    expect(hides, 1);
  });

  group('a broken loader callback never breaks a request', () {
    setUp(() => gate.complete());

    test('a throwing onShow', () async {
      // `showDialog(context: navigatorKey.currentContext!, ...)` before the
      // navigator has mounted.
      var shows = 0;
      ApiServices.configureLoader(
        onShow: () {
          shows++;
          throw StateError('no navigator yet');
        },
        onHide: () {},
      );

      final first = await api.get(endpoint: '/users', dedupe: false);
      final second = await api.get(endpoint: '/users', dedupe: false);

      expect(first.isRight(), isTrue);
      expect(second.isRight(), isTrue);
      expect(shows, 2, reason: 'the count must not be left stuck at one');
    });

    test('a throwing onHide', () async {
      // `navigatorKey.currentState!.pop()` with the dialog already gone.
      ApiServices.configureLoader(
        onShow: () {},
        onHide: () => throw StateError('nothing to pop'),
      );

      final result = await api.get(endpoint: '/users');

      expect(
        result.isRight(),
        isTrue,
        reason: 'onHide runs in a finally, so its throw replaced the result',
      );
    });
  });

  group('only collapses requests that would get the same answer', () {
    Future<void> expectSeparate(List<Future<Object>> calls) async {
      final all = Future.wait(calls);
      gate.complete();
      await all;
      expect(networkCalls, calls.length);
    }

    test('differing headers are not collapsed', () async {
      // Otherwise the Urdu caller is handed the English response.
      await expectSeparate([
        api.get(endpoint: '/users', headers: {'Accept-Language': 'en'}),
        api.get(endpoint: '/users', headers: {'Accept-Language': 'ur'}),
      ]);
    });

    test('header names compare case-insensitively', () async {
      final both = Future.wait([
        api.get(endpoint: '/users', headers: {'Accept-Language': 'en'}),
        api.get(endpoint: '/users', headers: {'accept-language': 'en'}),
      ]);
      gate.complete();
      await both;

      expect(networkCalls, 1);
    });

    test('differing response types are not collapsed', () async {
      // Otherwise the bytes caller is handed a decoded map.
      await expectSeparate([
        api.get(endpoint: '/avatar'),
        api.get(endpoint: '/avatar', responseType: ResponseType.bytes),
      ]);
    });

    test('bodies are compared by content, not by toString()', () async {
      // Neither has a toString of its own, so both print as
      // "Instance of '_Query'" — which made them the same request.
      await expectSeparate([
        api.get(endpoint: '/search', data: _Query('cats')),
        api.get(endpoint: '/search', data: _Query('dogs')),
      ]);
    });

    test('a body that cannot be encoded is never collapsed', () async {
      final body = Object();
      await expectSeparate([
        api.get(endpoint: '/search', data: body),
        api.get(endpoint: '/search', data: body),
      ]);
    });

    test('a caller with a progress callback gets its own request', () async {
      // Only the originator's callback reaches Dio, so a collapsed follower's
      // progress bar would never move.
      await expectSeparate([
        api.get(endpoint: '/report'),
        api.get(endpoint: '/report', onReceiveProgress: (_, _) {}),
      ]);
    });
  });
}
