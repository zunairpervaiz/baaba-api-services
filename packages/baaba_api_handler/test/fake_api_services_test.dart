import 'package:baaba_api_handler/testing.dart';
import 'package:flutter_test/flutter_test.dart';

class User {
  final int id;
  final String name;

  const User(this.id, this.name);

  factory User.fromJson(Map<String, dynamic> json) =>
      User(json['id'] as int, json['name'] as String);
}

/// A repository of the kind a consumer would actually test with this.
class UserRepository {
  final ApiServices api;

  UserRepository(this.api);

  Future<User?> find(int id) async {
    final result = await api.getAs<User>(
      endpoint: '/users/$id',
      parser: (data) => User.fromJson(data as Map<String, dynamic>),
    );
    return result.fold((_) => null, (user) => user);
  }
}

void main() {
  late FakeApiServices api;

  setUp(() => api = FakeApiServices());

  test('serves a stubbed JSON response', () async {
    api.stubJson(HttpMethod.get, '/users/1', {'id': 1, 'name': 'Ada'});

    final user = await UserRepository(api).find(1);

    expect(user?.name, 'Ada');
  });

  test('records the calls that were made', () async {
    api.stubJson(HttpMethod.post, '/users', {'id': 2});

    await api.post(
      endpoint: '/users',
      data: {'name': 'Grace'},
      params: {'notify': true},
    );

    final call = api.recordedCalls.single;
    expect(call.method, HttpMethod.post);
    expect(call.endpoint, '/users');
    expect(call.data, {'name': 'Grace'});
    expect(call.params, {'notify': true});
  });

  test('an unstubbed endpoint throws with a message naming it', () async {
    await expectLater(
      api.get(endpoint: '/unknown'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('GET'), contains('/unknown')),
        ),
      ),
    );
  });

  test('stubFailure builds a Failure carrying the body', () async {
    api.stubFailure(
      HttpMethod.get,
      '/users/1',
      statusCode: 422,
      body: {
        'errors': {
          'email': ['already taken'],
        },
      },
      message: 'Validation failed',
    );

    final result = await api.get(endpoint: '/users/1');

    result.fold((failure) {
      expect(failure.message, 'Validation failed');
      expect(failure.statusCode, 422);
      expect(failure.validationErrors, {
        'email': ['already taken'],
      });
    }, (_) => fail('Expected a failure'));
  });

  test('stubOffline drives the no-connection path', () async {
    api.stubOffline(HttpMethod.get, '/users');

    final result = await api.get(endpoint: '/users');

    result.fold(
      (failure) => expect(failure.errorType, ErrorSource.noInternetConnection),
      (_) => fail('Expected a failure'),
    );
  });

  test(
    'multiple stubs play back in order, then the last one repeats',
    () async {
      api.stubFailure(HttpMethod.get, '/health', statusCode: 503);
      api.stubJson(HttpMethod.get, '/health', {'status': 'up'});

      expect((await api.get(endpoint: '/health')).isLeft(), isTrue);
      expect((await api.get(endpoint: '/health')).isRight(), isTrue);
      expect((await api.get(endpoint: '/health')).isRight(), isTrue);
    },
  );

  test('records uploads with their files', () async {
    api.stubJson(HttpMethod.post, '/avatar', {'ok': true});

    await api.upload(
      endpoint: '/avatar',
      files: [
        UploadFile.fromBytes(field: 'a', bytes: [1], filename: 'a.png'),
      ],
    );

    expect(api.recordedCalls.single.files.single.field, 'a');
  });

  test(
    'a throwing parser becomes a Failure, as it does in production',
    () async {
      api.stubJson(HttpMethod.get, '/users/1', {'unexpected': 'shape'});

      final result = await api.getAs<User>(
        endpoint: '/users/1',
        parser: (data) => User.fromJson(data as Map<String, dynamic>),
      );

      result.fold((failure) {
        expect(failure.errorType, ErrorSource.parseError);
        expect(failure.data, {'unexpected': 'shape'});
      }, (_) => fail('Expected a parse failure'));
    },
  );

  test('stubDownload captures the save path', () async {
    api.stubDownload('/files/report.pdf');

    final result = await api.download(
      endpoint: '/files/report.pdf',
      savePath: '/tmp/report.pdf',
    );

    expect(result.isRight(), isTrue);
    expect(api.recordedCalls.single.data, '/tmp/report.pdf');
  });

  test('records cancellations', () {
    api.cancelRequest(cancellationReason: 'screen closed');

    expect(api.cancellations, ['screen closed']);
  });

  test('reset clears stubs and history', () async {
    api.stubJson(HttpMethod.get, '/users', {});
    await api.get(endpoint: '/users');

    api.reset();

    expect(api.recordedCalls, isEmpty);
    await expectLater(api.get(endpoint: '/users'), throwsStateError);
  });

  group('builds failures the way production does', () {
    tearDown(ApiServices.reset);

    test('stubFailure maps the status and reads the body\'s message', () async {
      api.stubFailure(
        HttpMethod.get,
        '/me',
        statusCode: 401,
        body: {'message': 'Session expired'},
      );

      final failure = (await api.get(endpoint: '/me')).getLeft().toNullable()!;

      // It used to be badRequest / 400 / the generic text, whatever the
      // status — so code branching on unauthorized could not be tested.
      expect(failure.errorType, ErrorSource.unauthorized);
      expect(failure.code, ResponseCode.unauthorized);
      expect(failure.message, 'Session expired');
      expect(failure.statusCode, 401);
    });

    test(
      'stubJson with a non-2xx status is a failure, as Dio makes it',
      () async {
        api.stubJson(HttpMethod.get, '/missing', {
          'detail': 'No such user',
        }, statusCode: 404);

        final failure = (await api.get(
          endpoint: '/missing',
        )).getLeft().toNullable()!;
        expect(failure.errorType, ErrorSource.notFound);
        expect(failure.message, 'No such user');
      },
    );

    test('ApiConfig.isSuccess applies to stubbed responses', () async {
      ApiServices.init(
        ApiConfig(
          isSuccess: (r) => r.data is! Map || r.data['success'] != false,
        ),
      );
      api.stubJson(HttpMethod.post, '/pay', {
        'success': false,
        'message': 'Insufficient funds',
      });

      final failure = (await api.post(
        endpoint: '/pay',
      )).getLeft().toNullable()!;
      expect(failure.message, 'Insufficient funds');
    });
  });

  group('matches production where it used to diverge', () {
    tearDown(ApiServices.reset);

    test(
      'download ignores ApiConfig.isSuccess, as the real client does',
      () async {
        // A predicate written for an envelope body throws on a download's null
        // body; production never applies it there.
        ApiServices.init(
          ApiConfig(isSuccess: (r) => r.data['success'] == true),
        );
        api.stubDownload('/files/report.pdf');

        final result = await api.download(
          endpoint: '/files/report.pdf',
          savePath: '/tmp/r',
        );

        expect(result.isRight(), isTrue);
      },
    );

    test('head ignores ApiConfig.isSuccess, as the real client does', () async {
      ApiServices.init(ApiConfig(isSuccess: (r) => r.data['success'] == true));
      api.stubJson(HttpMethod.head, '/files/report.pdf', null);

      final result = await api.head(endpoint: '/files/report.pdf');

      expect(result.isRight(), isTrue);
    });

    test('an already-cancelled token fails with ErrorSource.cancel', () async {
      api.stubJson(HttpMethod.get, '/users/1', {'id': 1, 'name': 'Ada'});
      final token = CancelToken()..cancel();

      final result = await api.get(endpoint: '/users/1', cancelToken: token);

      expect(result.getLeft().toNullable()!.errorType, ErrorSource.cancel);
    });

    test('an already-cancelled call needs no stub and uses none up', () async {
      final token = CancelToken()..cancel();

      // No stub at all: production never reaches the server, so neither may
      // the fake demand a response for it.
      final unstubbed = await api.get(endpoint: '/feed', cancelToken: token);
      expect(unstubbed.getLeft().toNullable()!.errorType, ErrorSource.cancel);

      // A scripted sequence is left intact for the next real call.
      api
        ..stubFailure(HttpMethod.get, '/users/1', statusCode: 500)
        ..stubJson(HttpMethod.get, '/users/1', {'id': 1});
      await api.get(endpoint: '/users/1', cancelToken: token);
      final first = await api.get(endpoint: '/users/1');
      expect(first.getLeft().toNullable()?.statusCode, 500);
    });

    test(
      'offline beats an already-cancelled token, as in production',
      () async {
        api.stubOffline(HttpMethod.get, '/users/1');
        final token = CancelToken()..cancel();

        final result = await api.get(endpoint: '/users/1', cancelToken: token);

        expect(
          result.getLeft().toNullable()!.errorType,
          ErrorSource.noInternetConnection,
        );
      },
    );

    test('a typed call forwards the token too', () async {
      api.stubJson(HttpMethod.get, '/users/1', {'id': 1, 'name': 'Ada'});
      final token = CancelToken()..cancel();

      final result = await api.getAs<User>(
        endpoint: '/users/1',
        parser: (data) => User.fromJson(data as Map<String, dynamic>),
        cancelToken: token,
      );

      expect(result.getLeft().toNullable()!.errorType, ErrorSource.cancel);
    });
  });

  group('reports to ApiConfig.observer like the real client', () {
    late _RecordingObserver observer;

    setUp(() {
      observer = _RecordingObserver();
      ApiServices.init(ApiConfig(observer: observer));
    });
    tearDown(ApiServices.reset);

    test('a success is onRequest then onResponse', () async {
      api.stubJson(HttpMethod.get, '/users/1', {'id': 1, 'name': 'Ada'});

      await api.get(endpoint: '/users/1', params: {'full': true});

      expect(observer.events, ['request GET /users/1', 'response 200']);
      expect(observer.requests.single.queryParameters, {'full': true});
    });

    test('a success carries the request that produced it', () async {
      api.stubJson(HttpMethod.post, '/users', {'id': 1});

      final result = await api.post(endpoint: '/users', data: {'name': 'Ada'});

      expect(observer.events, ['request POST /users', 'response 200']);
      final sent = result.getRight().toNullable()!.requestOptions;
      expect(sent.method, 'POST');
      expect(sent.data, {'name': 'Ada'});
    });

    test('a failure carries the request that produced it', () async {
      api.stubFailure(HttpMethod.post, '/users', statusCode: 422);

      final result = await api.post(endpoint: '/users', data: {'name': ''});

      expect(observer.events, [
        'request POST /users',
        'failure unprocessableEntity',
      ]);
      expect(observer.failureOptions.single?.path, '/users');
      expect(result.getLeft().toNullable()!.requestOptions?.method, 'POST');
    });

    test('offline never builds a request', () async {
      api.stubOffline(HttpMethod.get, '/feed');

      await api.get(endpoint: '/feed');

      expect(observer.events, ['failure noInternetConnection']);
      expect(observer.failureOptions.single, isNull);
    });

    test('a parse failure reports both outcomes', () async {
      api.stubJson(HttpMethod.get, '/users/1', {'unexpected': true});

      await api.getAs<User>(
        endpoint: '/users/1',
        parser: (data) => User.fromJson(data as Map<String, dynamic>),
      );

      expect(observer.events, [
        'request GET /users/1',
        'response 200',
        'failure parseError',
      ]);
    });

    test('a throwing observer never breaks a call', () async {
      ApiServices.init(ApiConfig(observer: _ThrowingObserver()));
      api.stubJson(HttpMethod.get, '/users/1', {'id': 1, 'name': 'Ada'});

      final result = await api.get(endpoint: '/users/1');

      expect(result.isRight(), isTrue);
    });
  });
}

class _RecordingObserver extends ApiObserver {
  final List<String> events = [];
  final List<RequestOptions> requests = [];
  final List<RequestOptions?> failureOptions = [];

  @override
  void onRequest(RequestOptions options) {
    requests.add(options);
    events.add('request ${options.method} ${options.path}');
  }

  @override
  void onResponse(Response response) =>
      events.add('response ${response.statusCode}');

  @override
  void onFailure(Failure failure, RequestOptions? options) {
    failureOptions.add(options);
    events.add('failure ${failure.errorType.name}');
  }
}

class _ThrowingObserver extends ApiObserver {
  @override
  void onRequest(RequestOptions options) => throw StateError('boom');

  @override
  void onResponse(Response response) => throw StateError('boom');
}
