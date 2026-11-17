import 'dart:async';
import 'dart:typed_data';

import 'package:baaba_api_handler/testing.dart';
import 'package:dio/dio.dart' show Headers, ResponseBody;
import 'package:flutter_test/flutter_test.dart';

class _Adapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final List<Map<String, dynamic>> sentHeaders = [];
  final int Function(RequestOptions options)? status;
  final String body;
  final bool manual;
  final List<Completer<void>> gates = [];

  _Adapter({this.status, this.body = '{}', this.manual = false});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    sentHeaders.add(Map<String, dynamic>.of(options.headers));
    if (manual) {
      final gate = Completer<void>();
      gates.add(gate);
      await Future.any([gate.future, ?cancelFuture]);
    }
    return ResponseBody.fromString(
      body,
      status?.call(options) ?? 200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  void releaseAll() {
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
  }

  @override
  void close({bool force = false}) {}
}

class _Observer extends ApiObserver {
  final List<Response> responses = [];
  final List<Failure> failures = [];

  @override
  void onResponse(Response response) => responses.add(response);

  @override
  void onFailure(Failure failure, RequestOptions? options) =>
      failures.add(failure);
}

ApiConfig _config(
  _Adapter adapter, {
  required String baseUrl,
  RetryPolicy retry = const RetryPolicy.disabled(),
  AuthConfig? auth,
  ApiObserver? observer,
  bool Function(Response)? isSuccess,
  int? maxConcurrentRequests,
}) {
  return ApiConfig(
    baseUrl: baseUrl,
    bypassConnectivityCheck: true,
    httpClientAdapter: adapter,
    logging: const ApiLogOptions(enabled: false),
    retry: retry,
    auth: auth,
    observer: observer,
    isSuccess: isSuccess,
    maxConcurrentRequests: maxConcurrentRequests,
  );
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  tearDown(ApiServices.reset);

  group('lookup', () {
    test('each name reaches its own client and host', () async {
      final main = _Adapter();
      final partner = _Adapter();
      ApiServices.init(_config(main, baseUrl: 'https://api.test'));
      ApiServices.init(
        _config(partner, baseUrl: 'https://partner.test/api'),
        name: 'partner',
      );

      await ApiServices.instance().get(endpoint: '/users');
      await ApiServices.named('partner').post(endpoint: 'graphql');

      expect(main.requests.single.uri.toString(), 'https://api.test/users');
      expect(
        partner.requests.single.uri.toString(),
        'https://partner.test/api/graphql',
      );
    });

    test('a client kept across a re-init joins against its own base', () async {
      final old = _Adapter();
      ApiServices.init(_config(old, baseUrl: 'https://a.test'));
      final kept = ApiServices.instance();
      ApiServices.init(_config(_Adapter(), baseUrl: ''));

      await kept.get(endpoint: 'users');

      expect(old.requests.single.uri.toString(), 'https://a.test/users');
    });

    test('a name that was never initialised throws a StateError', () {
      expect(
        () => ApiServices.named('partner'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('"partner"'),
          ),
        ),
      );
    });

    test('the default name is the default client', () {
      ApiServices.init(const ApiConfig());
      expect(
        identical(
          ApiServices.named(ApiServices.defaultClient),
          ApiServices.instance(),
        ),
        isTrue,
      );
    });

    test('init without a name leaves named clients alone', () {
      ApiServices.init(const ApiConfig(baseUrl: 'https://p.test'), name: 'p');
      final partner = ApiServices.named('p');
      ApiServices.init(const ApiConfig(baseUrl: 'https://api.test'));

      expect(identical(ApiServices.named('p'), partner), isTrue);
      expect(ApiServices.config.baseUrl, 'https://api.test');
      expect(ApiServices.configOf('p').baseUrl, 'https://p.test');
      expect(ApiServices.isInitialized('p'), isTrue);
      expect(ApiServices.isInitialized('other'), isFalse);
    });
  });

  group('each client uses its own configuration', () {
    test('isSuccess and observer', () async {
      final mainObserver = _Observer();
      final partnerObserver = _Observer();
      final main = _Adapter(body: '{"success": false}');
      final partner = _Adapter(body: '{"success": false}');
      ApiServices.init(
        _config(main, baseUrl: 'https://api.test', observer: mainObserver),
      );
      ApiServices.init(
        _config(
          partner,
          baseUrl: 'https://partner.test',
          observer: partnerObserver,
          isSuccess: (r) => (r.data as Map)['success'] == true,
        ),
        name: 'partner',
      );

      final fromMain = await ApiServices.instance().get(endpoint: '/a');
      final fromPartner = await ApiServices.named(
        'partner',
      ).get(endpoint: '/a');

      expect(fromMain.isRight(), isTrue);
      expect(fromPartner.isLeft(), isTrue);
      expect(mainObserver.responses, hasLength(1));
      expect(mainObserver.failures, isEmpty);
      expect(partnerObserver.responses, isEmpty);
      expect(partnerObserver.failures, hasLength(1));
    });

    test(
      'auth: the token goes only to the client configured with it',
      () async {
        final main = _Adapter();
        final partner = _Adapter();
        ApiServices.init(
          _config(
            main,
            baseUrl: 'https://api.test',
            auth: AuthConfig(
              getToken: () async => 'MAIN',
              onTokenRefresh: () async => true,
            ),
          ),
        );
        ApiServices.init(
          _config(partner, baseUrl: 'https://partner.test'),
          name: 'partner',
        );

        await ApiServices.instance().get(endpoint: '/a');
        await ApiServices.named('partner').get(endpoint: '/a');

        expect(main.sentHeaders.single['authorization'], 'Bearer MAIN');
        expect(
          partner.sentHeaders.single.containsKey('authorization'),
          isFalse,
        );
      },
    );

    test('retry policy', () async {
      final main = _Adapter(status: (_) => 503);
      final partner = _Adapter(status: (_) => 503);
      ApiServices.init(_config(main, baseUrl: 'https://api.test'));
      ApiServices.init(
        _config(
          partner,
          baseUrl: 'https://partner.test',
          retry: const RetryPolicy(maxRetries: 2, baseDelay: Duration.zero),
        ),
        name: 'partner',
      );

      await ApiServices.instance().get(endpoint: '/a');
      await ApiServices.named('partner').get(endpoint: '/a');

      expect(main.requests, hasLength(1));
      expect(partner.requests, hasLength(3));
    });

    test('concurrency cap', () async {
      final main = _Adapter(manual: true);
      final partner = _Adapter(manual: true);
      ApiServices.init(
        _config(main, baseUrl: 'https://api.test', maxConcurrentRequests: 1),
      );
      ApiServices.init(
        _config(partner, baseUrl: 'https://partner.test'),
        name: 'partner',
      );

      final pending = [
        ApiServices.instance().get(endpoint: '/1', dedupe: false),
        ApiServices.instance().get(endpoint: '/2', dedupe: false),
        ApiServices.named('partner').get(endpoint: '/1', dedupe: false),
        ApiServices.named('partner').get(endpoint: '/2', dedupe: false),
      ];
      await _settle();

      // The default client's cap holds its second request back; the partner
      // client, uncapped, sends both.
      expect(main.requests, hasLength(1));
      expect(partner.requests, hasLength(2));

      main.releaseAll();
      partner.releaseAll();
      await _settle();
      main.releaseAll();
      await Future.wait(pending);
      expect(main.requests, hasLength(2));
    });

    test('identical GETs on two clients are not collapsed together', () async {
      final main = _Adapter();
      final partner = _Adapter();
      ApiServices.init(_config(main, baseUrl: 'https://same.test'));
      ApiServices.init(
        _config(partner, baseUrl: 'https://same.test'),
        name: 'partner',
      );

      await Future.wait([
        ApiServices.instance().get(endpoint: '/a'),
        ApiServices.named('partner').get(endpoint: '/a'),
      ]);

      expect(main.requests, hasLength(1));
      expect(partner.requests, hasLength(1));
    });
  });

  group('loader', () {
    test('clients without their own loader share one indicator', () async {
      final main = _Adapter(manual: true);
      final partner = _Adapter(manual: true);
      ApiServices.init(_config(main, baseUrl: 'https://api.test'));
      ApiServices.init(
        _config(partner, baseUrl: 'https://partner.test'),
        name: 'partner',
      );
      var shows = 0;
      var hides = 0;
      ApiServices.configureLoader(onShow: () => shows++, onHide: () => hides++);

      final a = ApiServices.instance().get(endpoint: '/a');
      final b = ApiServices.named('partner').get(endpoint: '/b');
      await _settle();
      expect((shows, hides), (1, 0));

      main.releaseAll();
      await a;
      expect((shows, hides), (1, 0));

      partner.releaseAll();
      await b;
      expect((shows, hides), (1, 1));
    });

    test('a client with its own loader keeps its own count', () async {
      final main = _Adapter(manual: true);
      final partner = _Adapter(manual: true);
      ApiServices.init(_config(main, baseUrl: 'https://api.test'));
      ApiServices.init(
        _config(partner, baseUrl: 'https://partner.test'),
        name: 'partner',
      );
      final events = <String>[];
      ApiServices.configureLoader(
        onShow: () => events.add('shared+'),
        onHide: () => events.add('shared-'),
      );
      ApiServices.configureLoader(
        name: 'partner',
        onShow: () => events.add('partner+'),
        onHide: () => events.add('partner-'),
      );

      final a = ApiServices.instance().get(endpoint: '/a');
      final b = ApiServices.named('partner').get(endpoint: '/b');
      await _settle();
      partner.releaseAll();
      await b;
      main.releaseAll();
      await a;

      expect(events, ['shared+', 'partner+', 'partner-', 'shared-']);
    });
  });

  group('reset', () {
    test(
      'reset(name:) discards only that client, cancelling its requests',
      () async {
        final main = _Adapter(manual: true);
        final partner = _Adapter(manual: true);
        ApiServices.init(_config(main, baseUrl: 'https://api.test'));
        ApiServices.init(
          _config(partner, baseUrl: 'https://partner.test'),
          name: 'partner',
        );

        final fromMain = ApiServices.instance().get(endpoint: '/a');
        final fromPartner = ApiServices.named('partner').get(endpoint: '/b');
        await _settle();

        ApiServices.reset(name: 'partner');

        final partnerResult = await fromPartner;
        expect(
          partnerResult.getLeft().toNullable()?.errorType,
          ErrorSource.cancel,
        );
        expect(() => ApiServices.named('partner'), throwsStateError);
        expect(ApiServices.configOf('partner').baseUrl, isNull);

        // The default client is untouched and its request completes.
        main.releaseAll();
        expect((await fromMain).isRight(), isTrue);
        expect(ApiServices.config.baseUrl, 'https://api.test');
      },
    );

    test('reset(name:) hides and drops that client\'s own loader', () async {
      final partner = _Adapter(manual: true);
      ApiServices.init(
        _config(partner, baseUrl: 'https://partner.test'),
        name: 'partner',
      );
      var sharedHides = 0;
      var partnerHides = 0;
      ApiServices.configureLoader(onShow: () {}, onHide: () => sharedHides++);
      ApiServices.configureLoader(
        name: 'partner',
        onShow: () {},
        onHide: () => partnerHides++,
      );

      final pending = ApiServices.named('partner').get(endpoint: '/b');
      await _settle();
      ApiServices.reset(name: 'partner');
      await pending;

      expect(partnerHides, 1);
      expect(sharedHides, 0);
    });

    test('reset() with no name discards every client', () {
      ApiServices.init(const ApiConfig(baseUrl: 'https://api.test'));
      ApiServices.init(const ApiConfig(baseUrl: 'https://p.test'), name: 'p');

      ApiServices.reset();

      expect(ApiServices.config.baseUrl, isNull);
      expect(() => ApiServices.named('p'), throwsStateError);
      expect(ApiServices.isInitialized(), isFalse);
    });
  });

  group('FakeApiServices', () {
    test('answers to the named client it was given', () async {
      ApiServices.init(
        ApiConfig(isSuccess: (r) => (r.data as Map)['ok'] == true),
        name: 'partner',
      );
      final fakeDefault = FakeApiServices()
        ..stubJson(HttpMethod.get, '/a', {'ok': false});
      final fakePartner = FakeApiServices(client: 'partner')
        ..stubJson(HttpMethod.get, '/a', {'ok': false});

      expect((await fakeDefault.get(endpoint: '/a')).isRight(), isTrue);
      expect((await fakePartner.get(endpoint: '/a')).isLeft(), isTrue);
    });
  });
}
