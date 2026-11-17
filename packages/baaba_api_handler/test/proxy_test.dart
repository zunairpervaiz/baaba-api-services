@TestOn('vm')
library;

import 'dart:io';

import 'package:baaba_api_handler/io.dart';
import 'package:baaba_api_handler/ts_api_handler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/connect_proxy.dart';
import 'support/tls_server.dart';

void main() {
  group('ProxyConfig', () {
    test('routes only the listed hosts through the proxy', () {
      const config = ProxyConfig(
        proxy: 'proxy.example.com:3128',
        hosts: {'partner.example.net', '*.internal.example.org'},
      );

      expect(
        config.findProxy(Uri.parse('https://partner.example.net/x')),
        'PROXY proxy.example.com:3128',
      );
      expect(
        config.findProxy(Uri.parse('https://a.b.internal.example.org/')),
        'PROXY proxy.example.com:3128',
      );
      expect(config.findProxy(Uri.parse('https://api.example.com/')), 'DIRECT');
      expect(
        config.findProxy(Uri.parse('https://internal.example.org/')),
        'DIRECT',
      );
    });

    test('a null or empty proxy sends everything direct', () {
      const none = ProxyConfig(hosts: {'partner.example.net'});
      const empty = ProxyConfig(proxy: '', hosts: {'partner.example.net'});
      final uri = Uri.parse('https://partner.example.net/');
      expect(none.findProxy(uri), 'DIRECT');
      expect(empty.findProxy(uri), 'DIRECT');
      expect(none.isActive, isFalse);
      expect(const ProxyConfig(proxy: 'p:1', hosts: {'h'}).isActive, isTrue);
    });

    test('proxy and httpClientAdapter cannot both be set', () {
      expect(
        () => ApiConfig(
          httpClientAdapter: HttpClientAdapter(),
          proxy: const ProxyConfig(proxy: 'p:1', hosts: {'h'}),
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('through a real proxy', () {
    late TlsServer server;
    late ConnectProxy proxy;

    setUp(() async {
      server = await TlsServer.start();
      proxy = await ConnectProxy.start();
    });

    tearDown(() async {
      ApiServices.reset();
      await server.close();
      await proxy.close();
    });

    ApiServices client({
      required String host,
      required Set<String> proxied,
      PinningConfig? pinning,
    }) {
      ApiServices.init(
        ApiConfig(
          baseUrl: 'https://$host:${server.port}',
          bypassConnectivityCheck: true,
          retry: const RetryPolicy.disabled(),
          logging: const ApiLogOptions(enabled: false),
          pinning: pinning,
          proxy: ProxyConfig(proxy: proxy.address, hosts: proxied),
        ),
      );
      return ApiServices.instance();
    }

    test('a listed host is tunnelled, and still verified against the pinned '
        'roots', () async {
      final api = client(
        host: 'localhost',
        proxied: {'localhost'},
        pinning: PinningConfig(
          rootsPemByHost: {
            'localhost': [TestCerts.ca],
          },
        ),
      );

      final result = await api.get(endpoint: '/ping');

      expect(result.getRight().toNullable()?.data, {'ok': true});
      expect(proxy.targets, ['localhost:${server.port}']);
      expect(server.paths, ['/ping']);
    });

    test('pinning still rejects through the tunnel', () async {
      final api = client(
        host: 'localhost',
        proxied: {'localhost'},
        pinning: PinningConfig(
          rootsPemByHost: {
            'localhost': [TestCerts.otherCa],
          },
        ),
      );

      final result = await api.get(endpoint: '/ping');

      expect(
        result.getLeft().toNullable()?.errorType,
        ErrorSource.certificateRejected,
      );
      // The tunnel was opened; the handshake inside it failed.
      expect(proxy.targets, hasLength(1));
      expect(server.paths, isEmpty);
    });

    test('an unlisted host goes direct', () async {
      final api = client(
        host: 'localhost',
        proxied: {'partner.example.net'},
        pinning: PinningConfig(
          rootsPemByHost: {
            'localhost': [TestCerts.ca],
          },
        ),
      );

      final result = await api.get(endpoint: '/direct');

      expect(result.isRight(), isTrue);
      expect(proxy.targets, isEmpty);
      expect(server.paths, ['/direct']);
    });

    test('works without pinning, on the system trust store', () async {
      // The system store does not trust the test CA, so the request fails —
      // but only after the proxy has tunnelled it.
      final api = client(host: 'localhost', proxied: {'localhost'});

      final result = await api.get(endpoint: '/x');

      expect(proxy.targets, ['localhost:${server.port}']);
      expect(
        result.getLeft().toNullable()?.errorType,
        ErrorSource.certificateRejected,
      );
    });

    test('pinnedHttpClient takes the same proxy', () async {
      final http = pinnedHttpClient([
        TestCerts.ca,
      ], proxy: ProxyConfig(proxy: proxy.address, hosts: {'localhost'}));
      addTearDown(http.close);

      final request = await http.getUrl(
        Uri.parse('https://localhost:${server.port}/ws'),
      );
      final response = await request.close();
      await response.drain<void>();

      expect(response.statusCode, 200);
      expect(proxy.targets, ['localhost:${server.port}']);
    });

    test('pinnedIoClient takes the same proxy', () async {
      final http = pinnedIoClient([
        TestCerts.ca,
      ], proxy: ProxyConfig(proxy: proxy.address, hosts: {'localhost'}));
      addTearDown(http.close);

      final response = await http.get(
        Uri.parse('https://localhost:${server.port}/negotiate'),
      );

      expect(response.statusCode, 200);
      expect(proxy.targets, ['localhost:${server.port}']);
    });
  });

  test('the proxy is honoured for plain http too', () async {
    // A plain-http request through a proxy is sent to the proxy as an
    // absolute-form request, not CONNECT — the test proxy refuses it with a
    // 405, which proves the request went there.
    final proxy = await ConnectProxy.start();
    addTearDown(proxy.close);
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => upstream.close(force: true));
    upstream.listen((r) => r.response.close());

    ApiServices.init(
      ApiConfig(
        baseUrl: 'http://localhost:${upstream.port}',
        bypassConnectivityCheck: true,
        retry: const RetryPolicy.disabled(),
        logging: const ApiLogOptions(enabled: false),
        proxy: ProxyConfig(proxy: proxy.address, hosts: {'localhost'}),
      ),
    );
    addTearDown(ApiServices.reset);

    final result = await ApiServices.instance().get(endpoint: '/');
    expect(result.getLeft().toNullable()?.statusCode, 405);
  });
}
