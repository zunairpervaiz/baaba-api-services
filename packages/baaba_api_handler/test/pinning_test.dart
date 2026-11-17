@TestOn('vm')
library;

import 'dart:io';

import 'package:baaba_api_handler/io.dart';
import 'package:baaba_api_handler/ts_api_handler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/tls_server.dart';

void main() {
  late TlsServer server;

  setUp(() async => server = await TlsServer.start());
  tearDown(() async {
    ApiServices.reset();
    await server.close();
  });

  ApiServices client(PinningConfig pinning, {String host = 'localhost'}) {
    ApiServices.init(
      ApiConfig(
        baseUrl: 'https://$host:${server.port}',
        bypassConnectivityCheck: true,
        retry: const RetryPolicy.disabled(),
        logging: const ApiLogOptions(enabled: false),
        pinning: pinning,
      ),
    );
    return ApiServices.instance();
  }

  ErrorSource? errorOf(Either<Failure, Response> result) =>
      result.getLeft().toNullable()?.errorType;

  group('ApiConfig.pinning', () {
    test('a certificate chaining to the pinned root is accepted', () async {
      final api = client(
        PinningConfig(
          rootsPemByHost: {
            'localhost': [TestCerts.ca],
          },
        ),
      );

      final result = await api.get(endpoint: '/ping');

      expect(result.getRight().toNullable()?.data, {'ok': true});
      expect(server.paths, ['/ping']);
    });

    test('a certificate that does not chain to the pinned roots fails the '
        'handshake as certificateRejected', () async {
      final api = client(
        PinningConfig(
          rootsPemByHost: {
            'localhost': [TestCerts.otherCa],
          },
        ),
      );

      final result = await api.get(endpoint: '/ping');

      expect(errorOf(result), ErrorSource.certificateRejected);
      expect(result.getLeft().toNullable()?.code.value, -10);
      // Rejected in the handshake: the server never saw a request.
      expect(server.paths, isEmpty);
    });

    test('any one of several pinned roots is enough', () async {
      final api = client(
        PinningConfig(
          rootsPemByHost: {
            'localhost': [TestCerts.otherCa, TestCerts.ca],
          },
        ),
      );

      expect((await api.get(endpoint: '/ping')).isRight(), isTrue);
    });

    test('a wildcard entry pins subdomains', () async {
      // `localhost` cannot be a subdomain, so match it through a wildcard on
      // the same suffix the lookup uses.
      const pinning = PinningConfig(rootsPemByHost: {'*.example.com': []});
      expect(pinning.rootsFor('api.example.com'), isEmpty);
      expect(pinning.rootsFor('a.b.example.com'), isEmpty);
      expect(pinning.rootsFor('example.com'), isNull);
      expect(pinning.rootsFor('notexample.com'), isNull);
    });

    test(
      'an exact entry beats a wildcard, a longer wildcard a shorter one',
      () {
        const pinning = PinningConfig(
          rootsPemByHost: {
            '*.example.com': ['wide'],
            '*.api.example.com': ['narrow'],
            'v1.api.example.com': ['exact'],
          },
        );
        expect(pinning.rootsFor('V1.API.example.com'), ['exact']);
        expect(pinning.rootsFor('v2.api.example.com'), ['narrow']);
        expect(pinning.rootsFor('cdn.example.com'), ['wide']);
      },
    );

    test('an unlisted host uses the system trust store by default', () async {
      // Pinned for `localhost` only; reaching the same server as 127.0.0.1
      // falls back to the platform store, which does not trust the test CA.
      final api = client(
        PinningConfig(
          rootsPemByHost: {
            'localhost': [TestCerts.ca],
          },
        ),
        host: '127.0.0.1',
      );

      expect(
        errorOf(await api.get(endpoint: '/ping')),
        ErrorSource.certificateRejected,
      );
    });

    test('an unlisted host is refused without connecting when asked', () async {
      final api = client(
        PinningConfig(
          rootsPemByHost: {
            'localhost': [TestCerts.ca],
          },
          unlistedHosts: UnlistedHostPolicy.refuse,
        ),
        host: '127.0.0.1',
      );

      final result = await api.get(endpoint: '/ping');

      expect(errorOf(result), ErrorSource.certificateRejected);
      expect(result.getLeft().toNullable()?.requestOptions, isNotNull);
      expect(server.paths, isEmpty);
    });

    test('a PEM that does not parse fails closed', () async {
      final api = client(
        const PinningConfig(
          rootsPemByHost: {
            'localhost': ['not a certificate'],
          },
        ),
      );

      expect(
        errorOf(await api.get(endpoint: '/ping')),
        ErrorSource.certificateRejected,
      );
      expect(server.paths, isEmpty);
    });

    test('a rejected certificate is not retried', () async {
      ApiServices.init(
        ApiConfig(
          baseUrl: 'https://localhost:${server.port}',
          bypassConnectivityCheck: true,
          logging: const ApiLogOptions(enabled: false),
          retry: const RetryPolicy(maxRetries: 3, baseDelay: Duration.zero),
          pinning: PinningConfig(
            rootsPemByHost: {
              'localhost': [TestCerts.otherCa],
            },
          ),
        ),
      );
      final stopwatch = Stopwatch()..start();
      final result = await ApiServices.instance().get(endpoint: '/ping');
      expect(errorOf(result), ErrorSource.certificateRejected);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('pinning and httpClientAdapter cannot both be set', () {
      expect(
        () => ApiConfig(
          httpClientAdapter: HttpClientAdapter(),
          pinning: const PinningConfig(rootsPemByHost: {}),
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('redirects', () {
    String redirectTo(String url) =>
        '/redirect?to=${Uri.encodeQueryComponent(url)}';

    test('each hop is checked against its own host\'s pins', () async {
      // 127.0.0.1 is pinned correctly; localhost to an unrelated CA. A direct
      // request to localhost fails — so must one redirected there.
      final api = client(
        PinningConfig(
          rootsPemByHost: {
            '127.0.0.1': [TestCerts.ca],
            'localhost': [TestCerts.otherCa],
          },
        ),
        host: '127.0.0.1',
      );

      final result = await api.get(
        endpoint: redirectTo('https://localhost:${server.port}/end'),
      );

      expect(errorOf(result), ErrorSource.certificateRejected);
      expect(server.paths, ['/redirect']);
    });

    test('a redirect to a host the refuse policy blocks is refused', () async {
      final api = client(
        PinningConfig(
          rootsPemByHost: {
            '127.0.0.1': [TestCerts.ca],
          },
          unlistedHosts: UnlistedHostPolicy.refuse,
        ),
        host: '127.0.0.1',
      );

      final result = await api.get(
        endpoint: redirectTo('https://localhost:${server.port}/end'),
      );

      expect(errorOf(result), ErrorSource.certificateRejected);
      expect(server.paths, ['/redirect']);
    });

    test('a redirect between pinned hosts is followed and recorded', () async {
      final api = client(
        PinningConfig(
          rootsPemByHost: {
            '127.0.0.1': [TestCerts.ca],
            'localhost': [TestCerts.ca],
          },
        ),
        host: '127.0.0.1',
      );

      final result = await api.get(
        endpoint: redirectTo('https://localhost:${server.port}/end'),
      );

      final response = result.getRight().toNullable()!;
      expect(response.data, {'ok': true});
      expect(
        response.realUri.toString(),
        'https://localhost:${server.port}/end',
      );
      expect(response.redirects.single.statusCode, 302);
      expect(server.paths, ['/redirect', '/end']);
    });

    test('plain http to a pinned host is refused unsent', () async {
      final api = client(
        PinningConfig(
          rootsPemByHost: {
            '127.0.0.1': [TestCerts.ca],
          },
        ),
        host: '127.0.0.1',
      );

      final result = await api.get(
        endpoint: 'http://127.0.0.1:${server.port}/ping',
      );

      expect(errorOf(result), ErrorSource.certificateRejected);
      expect(server.paths, isEmpty);
    });
  });

  test('without pinning, a certificate the platform does not trust is '
      'certificateRejected too', () async {
    ApiServices.init(
      ApiConfig(
        baseUrl: 'https://localhost:${server.port}',
        bypassConnectivityCheck: true,
        retry: const RetryPolicy.disabled(),
        logging: const ApiLogOptions(enabled: false),
      ),
    );

    final result = await ApiServices.instance().get(endpoint: '/ping');

    expect(errorOf(result), ErrorSource.certificateRejected);
  });

  group('io.dart', () {
    test('pinnedHttpClient trusts the given roots', () async {
      final client = pinnedHttpClient([TestCerts.ca]);
      addTearDown(client.close);

      final request = await client.getUrl(
        Uri.parse('https://localhost:${server.port}/ws'),
      );
      final response = await request.close();
      await response.drain<void>();

      expect(response.statusCode, 200);
      expect(server.paths, ['/ws']);
    });

    test('pinnedHttpClient fails the handshake for other roots', () async {
      final client = pinnedHttpClient([TestCerts.otherCa]);
      addTearDown(client.close);

      await expectLater(
        client.getUrl(Uri.parse('https://localhost:${server.port}/ws')),
        throwsA(isA<HandshakeException>()),
      );
      expect(server.paths, isEmpty);
    });

    test('pinnedHttpClient rejects a PEM that does not parse', () {
      expect(() => pinnedHttpClient(['nope']), throwsA(isA<TlsException>()));
    });

    test(
      'pinnedIoClient is a package:http client over the same trust',
      () async {
        final client = pinnedIoClient([TestCerts.ca]);
        addTearDown(client.close);

        final response = await client.get(
          Uri.parse('https://localhost:${server.port}/negotiate'),
        );

        expect(response.statusCode, 200);
        expect(response.body, '{"ok": true}');

        final rejecting = pinnedIoClient([TestCerts.otherCa]);
        addTearDown(rejecting.close);
        await expectLater(
          rejecting.get(Uri.parse('https://localhost:${server.port}/x')),
          throwsA(anything),
        );
      },
    );
  });
}
