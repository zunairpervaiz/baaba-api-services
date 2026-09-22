import 'dart:typed_data';

import 'package:baaba_api_handler/ts_api_handler.dart';
import 'package:dio/dio.dart' show Headers, ResponseBody;
import 'package:flutter_test/flutter_test.dart';

/// The token must not travel to hosts that are not ours.
///
/// `ApiConfig.baseUrl` documents absolute endpoints as a supported way to hit
/// a CDN or a third party from the same client, so this is the ordinary path,
/// not an exotic one. Two things go wrong without the check: a session token
/// is handed to whoever the caller names, and S3 presigned URLs break outright
/// — AWS rejects a request carrying both a presigned signature and an
/// `Authorization` header.
class _Adapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final int Function(RequestOptions options)? status;

  _Adapter({this.status});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString('{}', status?.call(options) ?? 200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        });
  }

  String? authFor(String host) =>
      requests.firstWhere((r) => r.uri.host == host).headers['authorization']
          as String?;

  @override
  void close({bool force = false}) {}
}

const _s3 = 'https://s3.amazonaws.com/bucket/presigned';
const _analytics = 'https://analytics.thirdparty.io/track';

void main() {
  tearDown(ApiServices.reset);

  void init(
    _Adapter adapter, {
    String? baseUrl = 'https://api.mycompany.com',
    bool Function(Uri uri)? sendTokenTo,
    Future<bool> Function()? onTokenRefresh,
    void Function()? onRefreshFailed,
  }) {
    ApiServices.init(ApiConfig(
      baseUrl: baseUrl,
      bypassConnectivityCheck: true,
      httpClientAdapter: adapter,
      retry: const RetryPolicy.disabled(),
      logging: const ApiLogOptions(enabled: false),
      auth: AuthConfig(
        getToken: () async => 'SECRET',
        onTokenRefresh: onTokenRefresh ?? () async => true,
        onRefreshFailed: onRefreshFailed,
        sendTokenTo: sendTokenTo,
      ),
    ));
  }

  group('by default, only the baseUrl host receives the token', () {
    test('our own host still gets it', () async {
      final adapter = _Adapter();
      init(adapter);

      await ApiServices.instance().get(endpoint: '/me');

      expect(adapter.authFor('api.mycompany.com'), 'Bearer SECRET');
    });

    test('an S3 presigned URL does not', () async {
      final adapter = _Adapter();
      init(adapter);

      await ApiServices.instance().get(endpoint: _s3);

      expect(adapter.authFor('s3.amazonaws.com'), isNull);
    });

    test('a third-party host does not', () async {
      final adapter = _Adapter();
      init(adapter);

      await ApiServices.instance().get(endpoint: _analytics);

      expect(adapter.authFor('analytics.thirdparty.io'), isNull);
    });

    test('a sibling host is not assumed to be ours', () async {
      final adapter = _Adapter();
      init(adapter);

      await ApiServices.instance()
          .get(endpoint: 'https://cdn.mycompany.com/assets/logo.png');

      expect(adapter.authFor('cdn.mycompany.com'), isNull,
          reason: 'use sendTokenTo to opt a sibling host in');
    });

    test('uploads and downloads are scoped too', () async {
      final adapter = _Adapter();
      init(adapter);

      await ApiServices.instance().upload(
        endpoint: _s3,
        files: [
          UploadFile.fromBytes(field: 'f', bytes: [1, 2], filename: 'a.bin'),
        ],
      );

      expect(adapter.authFor('s3.amazonaws.com'), isNull);
    });
  });

  group('sendTokenTo', () {
    test('opts several owned hosts in', () async {
      final adapter = _Adapter();
      init(adapter, sendTokenTo: (uri) => uri.host.endsWith('mycompany.com'));

      final api = ApiServices.instance();
      await api.get(endpoint: '/me');
      await api.get(endpoint: 'https://cdn.mycompany.com/logo.png');
      await api.get(endpoint: _s3);

      expect(adapter.authFor('api.mycompany.com'), 'Bearer SECRET');
      expect(adapter.authFor('cdn.mycompany.com'), 'Bearer SECRET');
      expect(adapter.authFor('s3.amazonaws.com'), isNull);
    });

    test('can withhold the token from our own host', () async {
      final adapter = _Adapter();
      init(adapter, sendTokenTo: (_) => false);

      await ApiServices.instance().get(endpoint: '/me');

      expect(adapter.authFor('api.mycompany.com'), isNull);
    });

    test('a throwing predicate fails closed', () async {
      final adapter = _Adapter();
      init(adapter, sendTokenTo: (_) => throw StateError('bad predicate'));

      await ApiServices.instance().get(endpoint: '/me');

      expect(adapter.authFor('api.mycompany.com'), isNull,
          reason: 'a broken check must not leak the token');
    });
  });

  test('without a baseUrl the token still goes everywhere', () async {
    // Nothing to compare against, and withholding it would break every client
    // that works purely in absolute urls.
    final adapter = _Adapter();
    init(adapter, baseUrl: null);

    await ApiServices.instance().get(endpoint: _analytics);

    expect(adapter.authFor('analytics.thirdparty.io'), 'Bearer SECRET');
  });

  group('a 401 from a host we never authenticated to', () {
    test('does not trigger a token refresh', () async {
      var refreshes = 0;
      final adapter = _Adapter(status: (_) => 401);
      init(adapter, onTokenRefresh: () async {
        refreshes++;
        return true;
      });

      await ApiServices.instance().get(endpoint: _s3);

      expect(refreshes, 0, reason: 'their 401 says nothing about our token');
      expect(adapter.requests, hasLength(1), reason: 'and nothing is replayed');
    });

    test('cannot log the user out', () async {
      // The cascade worth preventing: a third party 401s, the refresh that
      // follows fails, onRefreshFailed fires, and the user is signed out of an
      // app whose own session was never in question.
      var loggedOut = false;
      final adapter = _Adapter(status: (_) => 401);
      init(
        adapter,
        onTokenRefresh: () async => false,
        onRefreshFailed: () => loggedOut = true,
      );

      await ApiServices.instance().get(endpoint: _analytics);

      expect(loggedOut, isFalse);
    });

    test('a 401 from our own host still refreshes and replays', () async {
      var refreshes = 0;
      final adapter = _Adapter(
        status: (options) => options.extra['_tokenRetried'] == true ? 200 : 401,
      );
      init(adapter, onTokenRefresh: () async {
        refreshes++;
        return true;
      });

      final result = await ApiServices.instance().get(endpoint: '/me');

      expect(refreshes, 1);
      expect(result.isRight(), isTrue);
    });
  });
}
