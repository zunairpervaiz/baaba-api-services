@TestOn('vm')
library;

import 'dart:io';

import 'package:baaba_api_handler/ts_api_handler.dart';
import 'package:flutter_test/flutter_test.dart';

/// A token in a custom header (`AuthConfig.headerBuilder`) must not follow a
/// redirect to another origin.
///
/// `HttpClient` drops only a fixed list of credential headers — Authorization,
/// Cookie and the like — on a cross-origin redirect, so `X-Auth-Token` went to
/// whatever host the server redirected to. A real round trip is the only
/// proof, hence two local servers; ports differ, so they are two origins.
class _Server {
  final HttpServer _server;

  /// The headers of every request served, by path.
  final Map<String, HttpHeaders> received = {};

  /// The method of every request served, by path.
  final Map<String, String> methods = {};

  _Server._(this._server) {
    _server.listen((request) async {
      received[request.uri.path] = request.headers;
      methods[request.uri.path] = request.method;
      await request.drain<void>();
      final to = request.uri.queryParameters['to'];
      if (request.uri.path == '/redirect' && to != null) {
        request.response
          ..statusCode = request.uri.queryParameters['status'] == '303'
              ? HttpStatus.seeOther
              : HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, to);
      } else {
        request.response
          ..headers.contentType = ContentType.json
          ..write('{"ok": true}');
      }
      await request.response.close();
    }, onError: (_) {});
  }

  static Future<_Server> start() async =>
      _Server._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  String get origin => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);
}

void main() {
  late _Server api;
  late _Server elsewhere;

  setUp(() async {
    api = await _Server.start();
    elsewhere = await _Server.start();
  });
  tearDown(() async {
    ApiServices.reset();
    await api.close();
    await elsewhere.close();
  });

  ApiServices client() {
    ApiServices.init(
      ApiConfig(
        baseUrl: api.origin,
        bypassConnectivityCheck: true,
        retry: const RetryPolicy.disabled(),
        logging: const ApiLogOptions(enabled: false),
        auth: AuthConfig(
          getToken: () async => 'SECRET',
          onTokenRefresh: () async => true,
          headerBuilder: (token) => {'X-Auth-Token': token, 'X-Tenant': 't1'},
          // Both servers are 127.0.0.1, so the default same-host rule would
          // send the token to either. Only the api's port is ours.
          sendTokenTo: (uri) => uri.port == Uri.parse(api.origin).port,
        ),
      ),
    );
    return ApiServices.instance();
  }

  String redirectTo(String url) =>
      '/redirect?to=${Uri.encodeQueryComponent(url)}';

  test('is dropped on a redirect to another origin', () async {
    final result = await client().get(
      endpoint: redirectTo('${elsewhere.origin}/cdn'),
      headers: {'X-Request-Id': 'r1'},
    );

    expect(result.isRight(), isTrue);
    expect(api.received['/redirect']?.value('x-auth-token'), 'SECRET');
    final hop = elsewhere.received['/cdn'];
    expect(hop, isNotNull, reason: 'the redirect is still followed');
    expect(hop!.value('x-auth-token'), isNull);
    // Everything headerBuilder returns is dropped: which of them holds the
    // token is not something the package can tell.
    expect(hop.value('x-tenant'), isNull);
    // The caller's own headers travel on, as they always have.
    expect(hop.value('x-request-id'), 'r1');
  });

  test('is kept on a redirect within the same origin', () async {
    final result = await client().get(
      endpoint: redirectTo('${api.origin}/moved'),
    );

    expect(result.isRight(), isTrue);
    expect(api.received['/moved']?.value('x-auth-token'), 'SECRET');
  });

  test(
    'a POST answered with 303 is followed as a GET, as with HttpClient',
    () async {
      final result = await client().post(
        endpoint: '${redirectTo('${elsewhere.origin}/done')}&status=303',
        data: {'a': 1},
      );

      expect(result.isRight(), isTrue);
      expect(elsewhere.methods['/done'], 'GET');
      final hop = elsewhere.received['/done']!;
      expect(hop.value('x-auth-token'), isNull);
      expect(
        hop.contentLength,
        anyOf(-1, 0),
        reason: 'the body is not re-sent',
      );
    },
  );

  test('a write is not redirected, as with HttpClient', () async {
    final result = await client().post(
      endpoint: redirectTo('${elsewhere.origin}/cdn'),
      data: {'a': 1},
    );

    expect(result.getLeft().toNullable()?.statusCode, 302);
    expect(elsewhere.received, isEmpty);
  });
}
