import 'dart:typed_data';

import 'package:baaba_api_handler/ts_api_handler.dart';
import 'package:dio/dio.dart' show Headers, ResponseBody;
import 'package:flutter_test/flutter_test.dart';

class _Adapter implements HttpClientAdapter {
  final List<Uri> uris = [];
  final List<String> paths = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    uris.add(options.uri);
    paths.add(options.path);
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  tearDown(ApiServices.reset);

  group('ApiEndpoint.fill', () {
    test('replaces placeholders in order', () {
      const endpoint = ApiEndpoint('orders/{}/attachments/{}');
      expect(endpoint.fill([42, 'abc']), 'orders/42/attachments/abc');
    });

    test('encodes each argument as a single path segment', () {
      const endpoint = ApiEndpoint('files/{}/v/{}');
      expect(
        endpoint.fill(['a/b c', 'x?y#z&w']),
        'files/a%2Fb%20c/v/x%3Fy%23z%26w',
      );
    });

    test('encodes non-ASCII as UTF-8', () {
      expect(
        const ApiEndpoint('u/{}').fill(['زبیر']),
        'u/%D8%B2%D8%A8%DB%8C%D8%B1',
      );
    });

    test('a template without placeholders is returned unchanged', () {
      const endpoint = ApiEndpoint('/users');
      expect(endpoint.fill(const []), '/users');
      expect(endpoint.placeholderCount, 0);
    });

    test('throws when there are too few arguments', () {
      expect(
        () => const ApiEndpoint('a/{}/b/{}').fill([1]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('2 placeholders'),
          ),
        ),
      );
    });

    test('throws when there are too many arguments', () {
      expect(() => const ApiEndpoint('a/{}').fill([1, 2]), throwsArgumentError);
    });

    test('rejects arguments that cannot survive as a segment', () {
      const endpoint = ApiEndpoint('a/{}/b');
      // Empty would collapse to a/b; dot segments are resolved away.
      expect(() => endpoint.fill(['']), throwsArgumentError);
      expect(() => endpoint.fill(['.']), throwsArgumentError);
      expect(() => endpoint.fill(['..']), throwsArgumentError);
      // ...but a dot inside a segment is fine.
      expect(endpoint.fill(['v1.2']), 'a/v1.2/b');
    });

    test('is a String, so it passes anywhere an endpoint goes', () {
      const ApiEndpoint endpoint = ApiEndpoint('/users');
      final String asString = endpoint;
      expect(asString, '/users');
      expect(endpoint.startsWith('/'), isTrue);
    });
  });

  group('joining with baseUrl', () {
    Future<_Adapter> send(String? baseUrl, String endpoint) async {
      final adapter = _Adapter();
      ApiServices.init(
        ApiConfig(
          baseUrl: baseUrl,
          bypassConnectivityCheck: true,
          httpClientAdapter: adapter,
          retry: const RetryPolicy.disabled(),
          logging: const ApiLogOptions(enabled: false),
        ),
      );
      final result = await ApiServices.instance().get(endpoint: endpoint);
      expect(result.isRight(), isTrue);
      return adapter;
    }

    const cases = {
      ('https://api.test', '/users'): 'https://api.test/users',
      ('https://api.test', 'users'): 'https://api.test/users',
      ('https://api.test/', '/users'): 'https://api.test/users',
      ('https://api.test/', 'users'): 'https://api.test/users',
      ('https://api.test/v1', 'users'): 'https://api.test/v1/users',
      ('https://api.test/v1/', '/users'): 'https://api.test/v1/users',
      ('https://api.test/v1//', 'users'): 'https://api.test/v1/users',
    };

    for (final MapEntry(key: (base, endpoint), value: expected)
        in cases.entries) {
      test('"$base" + "$endpoint"', () async {
        final adapter = await send(base, endpoint);
        expect(adapter.uris.single.toString(), expected);
      });
    }

    test('a filled ApiEndpoint joins the same way', () async {
      final adapter = await send(
        'https://api.test/v1/',
        const ApiEndpoint('orders/{}/attachments/{}').fill([7, 'a b']),
      );
      expect(
        adapter.uris.single.toString(),
        'https://api.test/v1/orders/7/attachments/a%20b',
      );
    });

    test('a url inside the query does not keep a double slash', () async {
      // Dio only collapses `//` when the url contains `:/` once.
      final adapter = await send(
        'https://api.test/',
        '/cb?next=https://other.test/x',
      );
      expect(adapter.uris.single.path, '/cb');
    });

    test('an endpoint written with a leading slash reaches the chain as '
        'written', () async {
      final adapter = await send('https://api.test/', '/auth/login');
      expect(adapter.paths.single, '/auth/login');
    });

    test('an absolute endpoint bypasses baseUrl', () async {
      final adapter = await send(
        'https://api.test/v1',
        const ApiEndpoint('https://cdn.test/files/{}').fill(['a b.pdf']),
      );
      expect(
        adapter.uris.single.toString(),
        'https://cdn.test/files/a%20b.pdf',
      );
    });

    test('an empty endpoint keeps the base exactly as written', () async {
      expect(
        (await send('https://api.test/rpc/', '')).uris.single.toString(),
        'https://api.test/rpc/',
      );
      expect(
        (await send('https://api.test/rpc', '')).uris.single.toString(),
        'https://api.test/rpc',
      );
    });

    test('without a baseUrl a relative endpoint is left alone', () async {
      final adapter = await send(null, 'https://api.test/users');
      expect(adapter.uris.single.toString(), 'https://api.test/users');
    });
  });
}
