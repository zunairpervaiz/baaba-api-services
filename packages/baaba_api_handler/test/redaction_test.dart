import 'dart:convert';
import 'dart:typed_data';

import 'package:baaba_api_handler/src/utils/redactor.dart';
import 'package:baaba_api_handler/testing.dart';
import 'package:dio/dio.dart' show Headers, RedirectRecord, ResponseBody;
import 'package:flutter_test/flutter_test.dart';

const _jwt =
    'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.c2lnbmF0dXJlLXNpZ25hdHVyZQ';
const _refresh = 'rt_9f8e7d6c5b4a39281706';

class _Adapter implements HttpClientAdapter {
  final int status;
  final List<RequestOptions> requests = [];
  final List<Map<String, dynamic>> sentHeaders = [];

  _Adapter({this.status = 200});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    sentHeaders.add(Map.of(options.headers));
    return ResponseBody.fromString(
      jsonEncode({
        'accessToken': _jwt,
        'refreshToken': _refresh,
        'user': {'name': 'Ada'},
      }),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        'set-cookie': ['session=abcdefghijklmnop; HttpOnly'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Observer extends ApiObserver {
  final List<RequestOptions> requests = [];
  final List<Response> responses = [];
  final List<Failure> failures = [];
  final List<RequestOptions?> failureOptions = [];

  @override
  void onRequest(RequestOptions options) => requests.add(options);

  @override
  void onResponse(Response response) => responses.add(response);

  @override
  void onFailure(Failure failure, RequestOptions? options) {
    failures.add(failure);
    failureOptions.add(options);
  }
}

void main() {
  tearDown(ApiServices.reset);

  group('masking', () {
    final redactor = Redactor.of(const ApiLogOptions())!;

    test('keeps the first few characters', () {
      expect(redactor.mask(_jwt), 'eyJh…[redacted]');
    });

    test('keeps an auth scheme readable in a header', () {
      expect(
        redactor.mask('Bearer $_jwt', header: true),
        'Bearer eyJh…[redacted]',
      );
      expect(
        redactor.mask('Basic dXNlcjpwYXNzd29yZA==', header: true),
        'Basic dXNl…[redacted]',
      );
      // Elsewhere a space is just part of the value.
      expect(redactor.mask('Bearer $_jwt'), 'Bear…[redacted]');
    });

    test('masks a short value entirely', () {
      expect(redactor.mask('hunter2'), '…[redacted]');
      expect(redactor.mask(1234), '…[redacted]');
    });

    test('redactKeepChars sets how much shows', () {
      final wide = Redactor.of(const ApiLogOptions(redactKeepChars: 8))!;
      expect(wide.mask(_jwt), 'eyJhbGci…[redacted]');
      final none = Redactor.of(const ApiLogOptions(redactKeepChars: 0))!;
      expect(none.mask(_jwt), '…[redacted]');
    });

    test('redact: false has no redactor', () {
      expect(Redactor.of(const ApiLogOptions(redact: false)), isNull);
      expect(Redactor.of(const ApiLogOptions.disabled()), isNotNull);
    });
  });

  group('requests', () {
    final redactor = Redactor.of(const ApiLogOptions())!;

    test('masks Authorization and the listed headers, case-insensitively', () {
      final options = RequestOptions(
        path: '/a',
        headers: {
          'Authorization': 'Bearer $_jwt',
          'Cookie': 'session=abcdefghijklmnop',
          'X-API-Key': 'k_1234567890abcdef',
          'X-Trace': 'visible-trace-id',
        },
      );

      final masked = redactor.request(options);

      expect(masked.headers['Authorization'], 'Bearer eyJh…[redacted]');
      expect(masked.headers['Cookie'], 'sess…[redacted]');
      expect(masked.headers['X-API-Key'], 'k_12…[redacted]');
      expect(masked.headers['X-Trace'], 'visible-trace-id');
      // The original is untouched.
      expect(options.headers['Authorization'], 'Bearer $_jwt');
    });

    test('Authorization is masked even when left out of redactHeaders', () {
      final custom = Redactor.of(
        const ApiLogOptions(redactHeaders: {'x-secret'}),
      )!;
      final masked = custom.request(
        RequestOptions(
          path: '/a',
          headers: {'authorization': 'Bearer $_jwt', 'cookie': 'c=1234567890'},
        ),
      );
      expect(masked.headers['authorization'], 'Bearer eyJh…[redacted]');
      expect(masked.headers['cookie'], 'c=1234567890');
    });

    test('masks query parameters, in params and in the path', () {
      final masked = redactor.request(
        RequestOptions(
          path: '/hub?t=$_jwt&group=7#frag',
          queryParameters: {'access_token': _jwt, 'page': 2},
        ),
      );

      expect(masked.queryParameters['access_token'], 'eyJh…[redacted]');
      expect(masked.queryParameters['page'], 2);
      expect(masked.path, '/hub?t=eyJh…[redacted]&group=7#frag');
      expect(masked.uri.toString(), isNot(contains(_jwt)));
    });

    test('masks body fields at any depth, case-insensitively', () {
      final body = {
        'username': 'ada',
        'Password': 'correct horse battery staple',
        'device': {
          'refresh_token': _refresh,
          'tokens': [
            {'token': _jwt},
          ],
        },
      };

      final masked = redactor.request(
        RequestOptions(path: '/login', method: 'POST', data: body),
      );

      expect(masked.data, {
        'username': 'ada',
        'Password': '…[redacted]',
        'device': {
          'refresh_token': 'rt_9…[redacted]',
          'tokens': [
            {'token': 'eyJh…[redacted]'},
          ],
        },
      });
      expect(body['Password'], 'correct horse battery staple');
      expect(masked.data, isA<Map<String, dynamic>>());
    });

    test('masks a JSON string body', () {
      final masked = redactor.body('{"password":"correct horse battery"}');
      expect(jsonDecode(masked! as String), {'password': '…[redacted]'});
      expect(
        redactor.body('<auth><password>x</password></auth>'),
        '<auth><password>x</password></auth>',
      );
    });

    test('masks FormData fields', () {
      final form = FormData.fromMap({
        'username': 'ada',
        'password': 'correct horse battery',
      });
      final masked = redactor.body(form)! as FormData;
      expect(Map.fromEntries(masked.fields), {
        'username': 'ada',
        'password': '…[redacted]',
      });
    });

    test('masks a form-urlencoded string body', () {
      expect(
        redactor.body(
          'grant_type=password&username=ada&password=hunter2-correct'
          '&refresh_token=$_refresh',
        ),
        'grant_type=password&username=ada&password=…[redacted]'
        '&refresh_token=rt_9…[redacted]',
      );
      // Plain text that merely contains "=" is left alone.
      expect(redactor.body('a = b'), 'a = b');
    });

    test('a password keeps no prefix; a token keeps redactKeepChars', () {
      expect(redactor.body({'password': 'hunter2-correct'}), {
        'password': '…[redacted]',
      });
      expect(redactor.body({'accessToken': _jwt}), {
        'accessToken': 'eyJh…[redacted]',
      });
    });

    test('masks secrets in redirect locations, and so in realUri', () {
      final options = RequestOptions(path: '/start');
      final response = Response<dynamic>(
        requestOptions: options,
        statusCode: 200,
        isRedirect: true,
        redirects: [
          RedirectRecord(
            302,
            'GET',
            Uri.parse('https://app.example.com/cb?access_token=$_jwt&s=1'),
          ),
        ],
      );

      final masked = redactor.response(response);

      expect(masked.realUri.toString(), isNot(contains(_jwt)));
      expect(masked.realUri.queryParameters['s'], '1');
      expect(response.realUri.queryParameters['access_token'], _jwt);
    });

    test('a request with nothing to mask is returned as is', () {
      final options = RequestOptions(
        path: '/users?page=2',
        headers: {'accept': 'application/json'},
        data: {
          'name': 'Ada',
          'tags': ['a'],
        },
      );
      expect(identical(redactor.request(options), options), isTrue);
    });

    test('custom field sets replace the defaults', () {
      final custom = Redactor.of(
        const ApiLogOptions(redactBodyFields: {'nationalId'}),
      )!;
      expect(custom.body({'nationalId': 'AB1234567', 'password': 'p'}), {
        'nationalId': '…[redacted]',
        'password': 'p',
      });
    });
  });

  group('the logger', () {
    Future<(String, _Adapter, Either<Failure, Response>)> logged({
      ApiLogOptions? options,
    }) async {
      final lines = <String>[];
      final adapter = _Adapter();
      ApiServices.init(
        ApiConfig(
          baseUrl: 'https://api.test',
          bypassConnectivityCheck: true,
          httpClientAdapter: adapter,
          retry: const RetryPolicy.disabled(),
          logging: (options ?? const ApiLogOptions()).copyWith(
            requestHeader: true,
            responseHeader: true,
            logPrint: (o) => lines.add('$o'),
          ),
          auth: AuthConfig(
            getToken: () async => _jwt,
            onTokenRefresh: () async => true,
          ),
        ),
      );
      final result = await ApiServices.instance().post(
        endpoint: '/login?t=$_jwt',
        data: {'username': 'ada', 'password': 'correct horse battery'},
      );
      return (lines.join('\n'), adapter, result);
    }

    test('prints secrets masked, everywhere they appear', () async {
      final (log, _, _) = await logged();

      expect(log, contains('Bearer eyJh…[redacted]'));
      expect(log, contains('password: …[redacted]'));
      expect(log, isNot(contains('corr')));
      expect(log, isNot(contains(_jwt)));
      expect(log, isNot(contains(_refresh)));
      expect(log, isNot(contains('correct horse battery')));
      expect(log, isNot(contains('abcdefghijklmnop')));
      // Everything else still prints.
      expect(log, contains('ada'));
    });

    test('sends and returns the real values', () async {
      final (_, adapter, result) = await logged();

      expect(adapter.sentHeaders.single['authorization'], 'Bearer $_jwt');
      expect(
        (adapter.requests.single.data as Map)['password'],
        'correct horse battery',
      );
      expect(adapter.requests.single.uri.queryParameters['t'], _jwt);
      expect(
        (result.getRight().toNullable()!.data as Map)['accessToken'],
        _jwt,
      );
    });

    test('redact: false prints everything', () async {
      final (log, _, _) = await logged(
        options: const ApiLogOptions(redact: false),
      );
      expect(log, contains(_jwt));
    });
  });

  group('the observer', () {
    Future<(_Observer, Either<Failure, Response>)> observed({
      int status = 200,
      ApiLogOptions logging = const ApiLogOptions(enabled: false),
    }) async {
      final observer = _Observer();
      ApiServices.init(
        ApiConfig(
          baseUrl: 'https://api.test',
          bypassConnectivityCheck: true,
          httpClientAdapter: _Adapter(status: status),
          retry: const RetryPolicy.disabled(),
          logging: logging,
          observer: observer,
          auth: AuthConfig(
            getToken: () async => _jwt,
            onTokenRefresh: () async => false,
            skipRefresh: (_) => true,
          ),
        ),
      );
      final result = await ApiServices.instance().post(
        endpoint: '/login',
        data: {'password': 'correct horse battery'},
      );
      return (observer, result);
    }

    test(
      'sees masked requests and responses, even with logging disabled',
      () async {
        final (observer, result) = await observed();

        final request = observer.requests.single;
        expect(request.headers['authorization'], 'Bearer eyJh…[redacted]');
        expect((request.data as Map)['password'], '…[redacted]');

        final response = observer.responses.single;
        expect((response.data as Map)['accessToken'], 'eyJh…[redacted]');
        expect((response.data as Map)['user'], {'name': 'Ada'});
        expect(response.headers.value('set-cookie'), 'sess…[redacted]');
        expect(
          response.requestOptions.headers['authorization'],
          'Bearer eyJh…[redacted]',
        );

        // The caller's response is the real one.
        expect(
          (result.getRight().toNullable()!.data as Map)['accessToken'],
          _jwt,
        );
      },
    );

    test('sees a masked failure; the caller gets the real one', () async {
      final (observer, result) = await observed(status: 401);

      final seen = observer.failures.single;
      expect((seen.data as Map)['refreshToken'], 'rt_9…[redacted]');
      expect(
        observer.failureOptions.single?.headers['authorization'],
        'Bearer eyJh…[redacted]',
      );
      expect(seen.statusCode, 401);

      final real = result.getLeft().toNullable()!;
      expect((real.data as Map)['refreshToken'], _refresh);
      expect(real.requestOptions?.headers['authorization'], 'Bearer $_jwt');
    });

    test('redact: false hands it everything', () async {
      final (observer, _) = await observed(
        logging: const ApiLogOptions(enabled: false, redact: false),
      );
      expect(observer.requests.single.headers['authorization'], 'Bearer $_jwt');
    });

    test('FakeApiServices masks the same way', () async {
      final observer = _Observer();
      ApiServices.init(ApiConfig(observer: observer));
      final fake = FakeApiServices()
        ..stubJson(HttpMethod.post, '/login', {'accessToken': _jwt});

      final result = await fake.post(
        endpoint: '/login',
        data: {'password': 'correct horse battery'},
      );

      expect((observer.requests.single.data as Map)['password'], '…[redacted]');
      expect(
        (observer.responses.single.data as Map)['accessToken'],
        'eyJh…[redacted]',
      );
      expect(
        (result.getRight().toNullable()!.data as Map)['accessToken'],
        _jwt,
      );
    });
  });
}
