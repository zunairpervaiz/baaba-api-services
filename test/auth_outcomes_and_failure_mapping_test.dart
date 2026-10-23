import 'dart:io';
import 'dart:typed_data';

import 'package:baaba_api_handler/testing.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records every request that reached the wire and answers via [responder].
class _Adapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final ResponseBody Function(RequestOptions options) responder;

  _Adapter(this.responder);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (requestStream != null) await requestStream.drain<void>();
    requests.add(options);
    return responder(options);
  }

  @override
  void close({bool force = false}) {}

  List<String> get paths => requests.map((r) => r.path).toList();
}

ResponseBody _json(String body, [int status = 200]) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

void _init(
  HttpClientAdapter adapter, {
  AuthConfig? auth,
  Failure? Function(Failure failure)? mapFailure,
  ApiObserver? observer,
  bool offline = false,
}) {
  ApiServices.init(
    ApiConfig(
      baseUrl: 'https://api.test',
      bypassConnectivityCheck: !offline,
      connectivityProbe: () async => false,
      retry: const RetryPolicy.disabled(),
      logging: const ApiLogOptions(enabled: false),
      httpClientAdapter: adapter,
      auth: auth,
      mapFailure: mapFailure,
      observer: observer,
    ),
  );
}

class _RecordingObserver extends ApiObserver {
  final List<Failure> failures = [];

  @override
  void onFailure(Failure failure, RequestOptions? options) =>
      failures.add(failure);
}

const _authPaths = {'/auth/login', '/auth/refresh', '/auth/logout'};

void main() {
  tearDown(ApiServices.reset);

  group('AuthConfig.skipRefresh', () {
    test('a 401 from login does not refresh or sign out', () async {
      var refreshes = 0;
      var signedOut = false;
      final adapter = _Adapter(
        (o) => _json('{"message":"Invalid username or password"}', 401),
      );
      _init(
        adapter,
        auth: AuthConfig(
          getToken: () async => null,
          onTokenRefresh: () async {
            refreshes++;
            return false;
          },
          onRefreshFailed: () => signedOut = true,
          skipRefresh: (o) => _authPaths.contains(o.path),
        ),
      );

      final result = await ApiServices.instance().post(endpoint: '/auth/login');

      final failure = result.getLeft().toNullable()!;
      expect(failure.errorType, ErrorSource.unauthorized);
      expect(failure.message, 'Invalid username or password');
      expect(refreshes, 0);
      expect(signedOut, isFalse);
    });

    test('other paths still refresh on 401', () async {
      var token = 'old';
      final adapter = _Adapter((o) {
        final auth = o.headers['authorization'];
        return auth == 'Bearer new' ? _json('{}') : _json('{}', 401);
      });
      _init(
        adapter,
        auth: AuthConfig(
          getToken: () async => token,
          onTokenRefresh: () async {
            token = 'new';
            return true;
          },
          skipRefresh: (o) => _authPaths.contains(o.path),
        ),
      );

      final result = await ApiServices.instance().get(endpoint: '/me');

      expect(result.isRight(), isTrue);
    });

    test('a throwing predicate exempts nothing', () async {
      var refreshes = 0;
      _init(
        _Adapter((o) => _json('{}', 401)),
        auth: AuthConfig(
          getToken: () async => 't',
          onTokenRefresh: () async {
            refreshes++;
            return false;
          },
          skipRefresh: (o) => throw StateError('broken'),
        ),
      );

      await ApiServices.instance().get(endpoint: '/me');

      expect(refreshes, 1);
    });
  });

  group('AuthConfig.refreshSession', () {
    Future<(Failure?, bool)> run(
      Future<RefreshOutcome> Function() refresh,
    ) async {
      var signedOut = false;
      _init(
        _Adapter((o) => _json('{}', 401)),
        auth: AuthConfig(
          getToken: () async => 't',
          refreshSession: refresh,
          onRefreshFailed: () => signedOut = true,
        ),
      );
      final result = await ApiServices.instance().get(endpoint: '/me');
      return (result.getLeft().toNullable(), signedOut);
    }

    test('failed keeps the session', () async {
      final (failure, signedOut) = await run(() async => RefreshOutcome.failed);
      expect(failure?.errorType, ErrorSource.unauthorized);
      expect(signedOut, isFalse);
    });

    test('a throw counts as failed, not as the session ending', () async {
      final (failure, signedOut) = await run(
        () async => throw const SocketException('offline'),
      );
      expect(failure?.errorType, ErrorSource.unauthorized);
      expect(signedOut, isFalse);
    });

    test('sessionExpired signs out', () async {
      final (_, signedOut) = await run(
        () async => RefreshOutcome.sessionExpired,
      );
      expect(signedOut, isTrue);
    });

    test('refreshed replays the request', () async {
      var token = 'old';
      _init(
        _Adapter(
          (o) => o.headers['authorization'] == 'Bearer new'
              ? _json('{"ok":true}')
              : _json('{}', 401),
        ),
        auth: AuthConfig(
          getToken: () async => token,
          refreshSession: () async {
            token = 'new';
            return RefreshOutcome.refreshed;
          },
        ),
      );

      final result = await ApiServices.instance().get(endpoint: '/me');

      expect(result.getRight().toNullable()?.data, {'ok': true});
    });

    test('onTokenRefresh still ends the session when it throws', () async {
      var signedOut = false;
      _init(
        _Adapter((o) => _json('{}', 401)),
        auth: AuthConfig(
          getToken: () async => 't',
          onTokenRefresh: () async => throw const SocketException('offline'),
          onRefreshFailed: () => signedOut = true,
        ),
      );

      await ApiServices.instance().get(endpoint: '/me');

      expect(signedOut, isTrue);
    });

    test('copyWith swaps one refresh callback for the other', () {
      final original = AuthConfig(
        getToken: () async => 't',
        onTokenRefresh: () async => true,
      );
      final swapped = original.copyWith(
        refreshSession: () async => RefreshOutcome.refreshed,
      );
      expect(swapped.onTokenRefresh, isNull);
      expect(swapped.refreshSession, isNotNull);
      expect(original.copyWith().onTokenRefresh, isNotNull);
    });
  });

  group('AuthConfig.isTokenExpired', () {
    test('refreshes before sending, once for concurrent requests', () async {
      var token = 'old';
      var expired = true;
      var refreshes = 0;
      final adapter = _Adapter((o) => _json('{}'));
      _init(
        adapter,
        auth: AuthConfig(
          getToken: () async => token,
          isTokenExpired: () => expired,
          refreshSession: () async {
            refreshes++;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            token = 'new';
            expired = false;
            return RefreshOutcome.refreshed;
          },
        ),
      );

      final api = ApiServices.instance();
      final results = await Future.wait([
        api.get(endpoint: '/a', dedupe: false),
        api.get(endpoint: '/b', dedupe: false),
        api.get(endpoint: '/c', dedupe: false),
      ]);

      expect(results.every((r) => r.isRight()), isTrue);
      expect(refreshes, 1);
      expect(adapter.requests, hasLength(3));
      expect(
        adapter.requests.map((r) => r.headers['authorization']),
        everyElement('Bearer new'),
      );
    });

    test('a refresh made through the client is not held for itself', () async {
      var token = 'old';
      var expired = true;
      final adapter = _Adapter((o) => _json('{}'));
      _init(
        adapter,
        auth: AuthConfig(
          getToken: () async => token,
          isTokenExpired: () => expired,
          refreshSession: () async {
            final r = await ApiServices.instance().post(
              endpoint: '/auth/refresh',
              showLoader: false,
            );
            if (r.isLeft()) return RefreshOutcome.failed;
            token = 'new';
            expired = false;
            return RefreshOutcome.refreshed;
          },
        ),
      );

      final result = await ApiServices.instance()
          .get(endpoint: '/me')
          .timeout(const Duration(seconds: 2));

      expect(result.isRight(), isTrue);
      expect(adapter.paths, ['/auth/refresh', '/me']);
    });

    test('sessionExpired fails the request without sending it', () async {
      var signedOut = 0;
      final adapter = _Adapter((o) => _json('{}'));
      _init(
        adapter,
        auth: AuthConfig(
          getToken: () async => 'old',
          isTokenExpired: () => true,
          refreshSession: () async => RefreshOutcome.sessionExpired,
          onRefreshFailed: () => signedOut++,
        ),
      );

      final result = await ApiServices.instance().get(endpoint: '/me');

      expect(
        result.getLeft().toNullable()?.errorType,
        ErrorSource.unauthorized,
      );
      expect(result.getLeft().toNullable()?.statusCode, 401);
      expect(adapter.requests, isEmpty);
      expect(signedOut, 1);
    });

    test('failed sends the request with the token it has', () async {
      final adapter = _Adapter((o) => _json('{}'));
      _init(
        adapter,
        auth: AuthConfig(
          getToken: () async => 'old',
          isTokenExpired: () => true,
          refreshSession: () async => RefreshOutcome.failed,
        ),
      );

      final result = await ApiServices.instance().get(endpoint: '/me');

      expect(result.isRight(), isTrue);
      expect(adapter.requests.single.headers['authorization'], 'Bearer old');
    });

    test('a 401 after a failed refresh does not refresh again', () async {
      var refreshes = 0;
      final adapter = _Adapter((o) => _json('{}', 401));
      _init(
        adapter,
        auth: AuthConfig(
          getToken: () async => 'old',
          isTokenExpired: () => true,
          refreshSession: () async {
            refreshes++;
            return RefreshOutcome.failed;
          },
        ),
      );

      final result = await ApiServices.instance().get(endpoint: '/me');

      expect(result.getLeft().toNullable()?.statusCode, 401);
      expect(refreshes, 1);
      expect(adapter.requests, hasLength(1));
    });

    test('is not asked for skipRefresh requests', () async {
      var asked = 0;
      _init(
        _Adapter((o) => _json('{}')),
        auth: AuthConfig(
          getToken: () async => null,
          isTokenExpired: () {
            asked++;
            return true;
          },
          onTokenRefresh: () async => false,
          skipRefresh: (o) => _authPaths.contains(o.path),
        ),
      );

      await ApiServices.instance().post(endpoint: '/auth/login');

      expect(asked, 0);
    });

    test('a throwing check counts as not expired', () async {
      var refreshes = 0;
      final adapter = _Adapter((o) => _json('{}'));
      _init(
        adapter,
        auth: AuthConfig(
          getToken: () async => 't',
          isTokenExpired: () => throw StateError('no clock'),
          onTokenRefresh: () async {
            refreshes++;
            return true;
          },
        ),
      );

      final result = await ApiServices.instance().get(endpoint: '/me');

      expect(result.isRight(), isTrue);
      expect(refreshes, 0);
    });
  });

  group('Accept for files', () {
    test('download accepts any type by default', () async {
      final adapter = _Adapter((o) => ResponseBody.fromString('%PDF-1.4', 200));
      _init(adapter);
      final dir = await Directory.systemTemp.createTemp('baaba');
      addTearDown(() => dir.delete(recursive: true));

      final result = await ApiServices.instance().download(
        endpoint: '/kb/guide.pdf',
        savePath: '${dir.path}/guide.pdf',
      );

      expect(result.isRight(), isTrue);
      expect(adapter.requests.single.headers['accept'], '*/*');
    });

    test('a bytes response accepts any type by default', () async {
      final adapter = _Adapter((o) => ResponseBody.fromString('x', 200));
      _init(adapter);

      await ApiServices.instance().get(
        endpoint: '/photo.jpg',
        responseType: ResponseType.bytes,
      );

      expect(adapter.requests.single.headers['accept'], '*/*');
    });

    test("the caller's own headers still win", () async {
      final adapter = _Adapter((o) => ResponseBody.fromString('x', 200));
      _init(adapter);

      await ApiServices.instance().get(
        endpoint: '/photo.jpg',
        responseType: ResponseType.bytes,
        headers: {'accept': 'image/jpeg'},
      );

      expect(adapter.requests.single.headers['accept'], 'image/jpeg');
    });

    test('a JSON request still asks for JSON', () async {
      final adapter = _Adapter((o) => _json('{}'));
      _init(adapter);

      await ApiServices.instance().get(endpoint: '/users');

      expect(adapter.requests.single.headers['accept'], 'application/json');
    });
  });

  group('ApiConfig.mapFailure', () {
    Failure? loginMapper(Failure f) =>
        f.statusCode == 401 && f.requestOptions?.path == '/auth/login'
        ? const Failure(
            ErrorSource.unauthorized,
            ResponseCode.unauthorized,
            'Wrong employee ID or password.',
            statusCode: 401,
          )
        : null;

    test('rewrites an HTTP failure and keeps its request', () async {
      final observer = _RecordingObserver();
      _init(
        _Adapter((o) => _json('{"message":"Invalid username"}', 401)),
        mapFailure: loginMapper,
        observer: observer,
      );

      final result = await ApiServices.instance().post(endpoint: '/auth/login');
      final failure = result.getLeft().toNullable()!;

      expect(failure.message, 'Wrong employee ID or password.');
      expect(failure.requestOptions?.path, '/auth/login');
      expect(observer.failures.single.message, failure.message);
    });

    test('null keeps the failure as it was', () async {
      _init(
        _Adapter((o) => _json('{"message":"Nope"}', 401)),
        mapFailure: loginMapper,
      );

      final result = await ApiServices.instance().get(endpoint: '/me');

      expect(result.getLeft().toNullable()?.message, 'Nope');
    });

    test('a throwing mapper leaves the failure unchanged', () async {
      _init(
        _Adapter((o) => _json('{"message":"Nope"}', 500)),
        mapFailure: (_) => throw StateError('broken'),
      );

      final result = await ApiServices.instance().get(endpoint: '/me');

      expect(result.getLeft().toNullable()?.message, 'Nope');
    });

    test('sees the offline short-circuit', () async {
      _init(
        _Adapter((o) => _json('{}')),
        offline: true,
        mapFailure: (f) => f.errorType == ErrorSource.noInternetConnection
            ? const Failure(
                ErrorSource.noInternetConnection,
                ResponseCode.noInternetConnection,
                'You are offline.',
              )
            : null,
      );

      final result = await ApiServices.instance().get(endpoint: '/me');

      expect(result.getLeft().toNullable()?.message, 'You are offline.');
    });

    test('sees parse errors', () async {
      _init(
        _Adapter((o) => _json('[]')),
        mapFailure: (f) => f.errorType == ErrorSource.parseError
            ? const Failure(
                ErrorSource.parseError,
                ResponseCode.parseError,
                'Unexpected reply.',
              )
            : null,
      );

      final result = await ApiServices.instance().getAs<String>(
        endpoint: '/me',
        parser: (data) => (data as Map)['name'] as String,
      );

      expect(result.getLeft().toNullable()?.message, 'Unexpected reply.');
    });

    test('applies to FakeApiServices as in production', () async {
      ApiServices.init(ApiConfig(mapFailure: loginMapper));
      final fake = FakeApiServices()
        ..stubFailure(HttpMethod.post, '/auth/login', statusCode: 401);

      final result = await fake.post(endpoint: '/auth/login');

      expect(
        result.getLeft().toNullable()?.message,
        'Wrong employee ID or password.',
      );
    });
  });

  group('error bodies', () {
    Future<Failure> failureFor(String body, [int status = 400]) async {
      _init(_Adapter((o) => _json(body, status)));
      final result = await ApiServices.instance().get(endpoint: '/x');
      return result.getLeft().toNullable()!;
    }

    test('ASP.NET validation problem shows the field messages', () async {
      final failure = await failureFor(
        '{"type":"https://tools.ietf.org/html/rfc9110#section-15.5.1",'
        '"title":"One or more validation errors occurred.","status":400,'
        '"errors":{"Email":["The Email field is required."],'
        '"Name":["The Name field is required."]}}',
      );

      expect(
        failure.message,
        'The Email field is required. The Name field is required.',
      );
      expect(failure.validationErrors?['Email'], [
        'The Email field is required.',
      ]);
    });

    test('a problem with only a title shows the title', () async {
      final failure = await failureFor(
        '{"title":"Not Found","status":404}',
        404,
      );
      expect(failure.message, 'Not Found');
    });

    test('message still beats errors and title', () async {
      final failure = await failureFor(
        '{"message":"Validation failed","title":"Bad","errors":{"a":["b"]}}',
      );
      expect(failure.message, 'Validation failed');
    });

    test('errorCode reads code, errorCode, and a nested error', () async {
      expect(
        (await failureFor(
          '{"code":"ACCOUNT_LOCKED","message":"x"}',
          423,
        )).errorCode,
        'ACCOUNT_LOCKED',
      );
      expect((await failureFor('{"errorCode":42}')).errorCode, '42');
      expect(
        (await failureFor('{"error":{"code":"INSUFFICIENT_FUNDS"}}')).errorCode,
        'INSUFFICIENT_FUNDS',
      );
      expect((await failureFor('{"message":"x"}')).errorCode, isNull);
    });
  });
}
