import 'dart:typed_data';

import 'package:baaba_api_handler/ts_api_handler.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _OkAdapter implements HttpClientAdapter {
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return ResponseBody.fromString('{"ok":true}', 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  tearDown(ApiServices.reset);

  void init(
    _OkAdapter adapter, {
    required Future<bool> Function() probe,
    Duration ttl = Duration.zero,
  }) {
    ApiServices.init(ApiConfig(
      baseUrl: 'https://api.test',
      httpClientAdapter: adapter,
      connectivityProbe: probe,
      connectivityCacheTtl: ttl,
      retry: const RetryPolicy.disabled(),
      logging: const ApiLogOptions(enabled: false),
    ));
  }

  test('a custom probe replaces the default third-party ping', () async {
    var probed = 0;
    final adapter = _OkAdapter();
    init(adapter, probe: () async {
      probed++;
      return true;
    });

    final result = await ApiServices.instance().get(endpoint: '/users');

    expect(probed, 1, reason: 'the supplied probe should be the one consulted');
    expect(result.isRight(), isTrue);
    expect(adapter.calls, 1);
  });

  test('a probe reporting offline short-circuits the request', () async {
    final adapter = _OkAdapter();
    init(adapter, probe: () async => false);

    final failure = (await ApiServices.instance().get(endpoint: '/users'))
        .getLeft()
        .toNullable()!;

    expect(failure.errorType, ErrorSource.noInternetConnection);
    expect(adapter.calls, 0, reason: 'nothing should reach the network');
  });

  test('a throwing probe reads as offline rather than escaping', () async {
    final adapter = _OkAdapter();
    init(adapter, probe: () async => throw StateError('health check exploded'));

    final result = await ApiServices.instance().get(endpoint: '/users');

    expect(result.getLeft().toNullable()!.errorType,
        ErrorSource.noInternetConnection);
  });

  test('a positive result is reused for connectivityCacheTtl', () async {
    var probed = 0;
    final adapter = _OkAdapter();
    init(
      adapter,
      ttl: const Duration(seconds: 30),
      probe: () async {
        probed++;
        return true;
      },
    );

    final api = ApiServices.instance();
    await api.get(endpoint: '/a');
    await api.get(endpoint: '/b');
    await api.get(endpoint: '/c');

    expect(probed, 1);
    expect(adapter.calls, 3);
  });

  test('a negative result is never cached, so recovery is immediate', () async {
    var online = false;
    final adapter = _OkAdapter();
    init(
      adapter,
      ttl: const Duration(seconds: 30),
      probe: () async => online,
    );

    final api = ApiServices.instance();
    expect((await api.get(endpoint: '/a')).isLeft(), isTrue);

    online = true;
    expect((await api.get(endpoint: '/a')).isRight(), isTrue,
        reason: 'a cached false would keep reporting offline');
  });

  test('bypassConnectivityCheck skips the probe entirely', () async {
    var probed = 0;
    final adapter = _OkAdapter();
    ApiServices.init(ApiConfig(
      baseUrl: 'https://api.test',
      httpClientAdapter: adapter,
      bypassConnectivityCheck: true,
      connectivityProbe: () async {
        probed++;
        return false;
      },
      logging: const ApiLogOptions(enabled: false),
    ));

    expect(
        (await ApiServices.instance().get(endpoint: '/a')).isRight(), isTrue);
    expect(probed, 0);
  });
}
