import 'dart:io';
import 'dart:typed_data';

import 'package:baaba_api_handler/ts_api_handler.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what actually went out, so these tests assert on the request the
/// package built rather than on the arguments it was handed.
class _RecordingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final ResponseBody Function(RequestOptions options)? responder;
  final Duration delay;

  _RecordingAdapter({this.responder, this.delay = Duration.zero});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return responder?.call(options) ?? _json('{"ok":true}');
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(String body, [int status = 200]) =>
    ResponseBody.fromString(body, status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });

void _init(HttpClientAdapter adapter, {ApiConfig? config}) {
  ApiServices.init((config ?? const ApiConfig()).copyWith(
    baseUrl: 'https://api.test',
    bypassConnectivityCheck: true,
    retry: const RetryPolicy.disabled(),
    logging: const ApiLogOptions(enabled: false),
    httpClientAdapter: adapter,
  ));
}

void main() {
  tearDown(ApiServices.reset);

  group('responseType', () {
    test('is left to Dio when the caller does not ask for one', () async {
      final adapter = _RecordingAdapter();
      _init(adapter);

      await ApiServices.instance().get(endpoint: '/users');

      // Dio's own default (json) still applies — the package does not force
      // one of its own.
      expect(adapter.requests.single.responseType, ResponseType.json);
    });

    test('reaches the request when asked for bytes', () async {
      final adapter = _RecordingAdapter(
        responder: (_) => ResponseBody.fromBytes([1, 2, 3], 200),
      );
      _init(adapter);

      final result = await ApiServices.instance().get(
        endpoint: '/avatar.png',
        responseType: ResponseType.bytes,
      );

      expect(adapter.requests.single.responseType, ResponseType.bytes);
      expect(result.getRight().toNullable()!.data, isA<List<int>>());
    });

    test('reaches the request for plain text', () async {
      final adapter = _RecordingAdapter(
        responder: (_) => ResponseBody.fromString('raw body', 200),
      );
      _init(adapter);

      final result = await ApiServices.instance().post(
        endpoint: '/echo',
        data: {'a': 1},
        responseType: ResponseType.plain,
      );

      expect(adapter.requests.single.responseType, ResponseType.plain);
      expect(result.getRight().toNullable()!.data, 'raw body');
    });

    test('survives the *As<T> hop to its untyped sibling', () async {
      final adapter = _RecordingAdapter(
        responder: (_) => ResponseBody.fromString('"hello"', 200),
      );
      _init(adapter);

      final result = await ApiServices.instance().getAs<String>(
        endpoint: '/greeting',
        responseType: ResponseType.plain,
        parser: (data) => (data as String).replaceAll('"', ''),
      );

      expect(adapter.requests.single.responseType, ResponseType.plain);
      expect(result.getRight().toNullable(), 'hello');
    });
  });

  group('head and options', () {
    test('head sends HEAD', () async {
      final adapter = _RecordingAdapter();
      _init(adapter);

      final result = await ApiServices.instance().head(endpoint: '/report.pdf');

      expect(adapter.requests.single.method, 'HEAD');
      expect(result.isRight(), isTrue);
    });

    test('options sends OPTIONS', () async {
      final adapter = _RecordingAdapter();
      _init(adapter);

      await ApiServices.instance().options(endpoint: '/users');

      expect(adapter.requests.single.method, 'OPTIONS');
    });

    test('both are idempotent, so a transient failure is retried', () async {
      // The reason these belong on the public surface at all:
      // RetryPolicy.idempotentMethods already listed them.
      expect(const RetryPolicy().isIdempotent(HttpMethod.head.value), isTrue);
      expect(
          const RetryPolicy().isIdempotent(HttpMethod.options.value), isTrue);
    });

    test('head is de-duplicated like a get', () async {
      final adapter =
          _RecordingAdapter(delay: const Duration(milliseconds: 40));
      _init(adapter);

      final api = ApiServices.instance();
      await Future.wait([
        api.head(endpoint: '/report.pdf'),
        api.head(endpoint: '/report.pdf'),
      ]);

      expect(adapter.requests, hasLength(1));
    });
  });

  group('cancellation by tag', () {
    test('cancels only the requests carrying that tag', () async {
      final adapter =
          _RecordingAdapter(delay: const Duration(milliseconds: 200));
      _init(adapter);
      final api = ApiServices.instance();

      final tagged = api.get(endpoint: '/feed', tag: 'feed');
      final untagged = api.get(endpoint: '/profile');
      final otherTag = api.get(endpoint: '/inbox', tag: 'inbox');

      await Future<void>.delayed(const Duration(milliseconds: 20));
      api.cancelRequest(tag: 'feed', cancellationReason: 'left the feed');

      expect(
          (await tagged).getLeft().toNullable()?.errorType, ErrorSource.cancel);
      expect((await untagged).isRight(), isTrue);
      expect((await otherTag).isRight(), isTrue);
    });

    test('omitting the tag still cancels everything', () async {
      final adapter =
          _RecordingAdapter(delay: const Duration(milliseconds: 200));
      _init(adapter);
      final api = ApiServices.instance();

      final tagged = api.get(endpoint: '/feed', tag: 'feed');
      final untagged = api.get(endpoint: '/profile');

      await Future<void>.delayed(const Duration(milliseconds: 20));
      api.cancelRequest();

      expect(
          (await tagged).getLeft().toNullable()?.errorType, ErrorSource.cancel);
      expect((await untagged).getLeft().toNullable()?.errorType,
          ErrorSource.cancel);
    });

    test('a tagged request opts out of de-duplication', () async {
      // Two callers sharing one network call would let cancelRequest(tag:)
      // abort a request the other caller is still waiting on.
      final adapter =
          _RecordingAdapter(delay: const Duration(milliseconds: 40));
      _init(adapter);
      final api = ApiServices.instance();

      await Future.wait([
        api.get(endpoint: '/feed', tag: 'feed'),
        api.get(endpoint: '/feed'),
      ]);

      expect(adapter.requests, hasLength(2));
    });

    test('a token is released once its request finishes', () async {
      final adapter = _RecordingAdapter();
      _init(adapter);
      final api = ApiServices.instance();

      await api.get(endpoint: '/feed', tag: 'feed');
      // Nothing is in flight, so this must not throw or affect anything.
      api.cancelRequest(tag: 'feed');

      expect((await api.get(endpoint: '/feed', tag: 'feed')).isRight(), isTrue);
    });

    test('download honours its tag', () async {
      final adapter =
          _RecordingAdapter(delay: const Duration(milliseconds: 200));
      _init(adapter);
      final api = ApiServices.instance();

      final download = api.download(
        endpoint: '/big.zip',
        savePath: '${Directory.systemTemp.path}/big.zip',
        tag: 'downloads',
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      api.cancelRequest(tag: 'downloads');

      expect((await download).getLeft().toNullable()?.errorType,
          ErrorSource.cancel);
    });
  });

  group('onRejected', () {
    test('shapes the failure for a 2xx that isSuccess rejected', () async {
      final adapter = _RecordingAdapter(
        responder: (_) => _json(
            '{"success":false,"code":"INSUFFICIENT_FUNDS","msg":"No funds"}'),
      );
      _init(adapter,
          config: ApiConfig(
            isSuccess: (r) => (r.data as Map)['success'] != false,
            onRejected: (r) {
              final body = r.data as Map;
              return Failure(
                ErrorSource.forbidden,
                ResponseCode.forbidden,
                body['msg'] as String,
                data: body,
                statusCode: r.statusCode,
              );
            },
          ));

      final failure =
          (await ApiServices.instance().get(endpoint: '/pay')).getLeft();

      expect(failure.toNullable()!.errorType, ErrorSource.forbidden);
      expect(failure.toNullable()!.message, 'No funds');
      expect(failure.toNullable()!.statusCode, 200);
      expect((failure.toNullable()!.data as Map)['code'], 'INSUFFICIENT_FUNDS');
    });

    test('carries the originating request so the observer can report it',
        () async {
      final adapter = _RecordingAdapter(
        responder: (_) => _json('{"success":false}'),
      );
      _init(adapter,
          config: ApiConfig(
            isSuccess: (r) => (r.data as Map)['success'] != false,
            onRejected: (_) => const Failure(
              ErrorSource.conflict,
              ResponseCode.conflict,
              'nope',
            ),
          ));

      final failure = (await ApiServices.instance().get(endpoint: '/pay'))
          .getLeft()
          .toNullable()!;

      expect(failure.requestOptions?.path, '/pay');
    });

    test('returning null falls back to the generic failure', () async {
      final adapter = _RecordingAdapter(
        responder: (_) => _json('{"success":false,"message":"from body"}'),
      );
      _init(adapter,
          config: ApiConfig(
            isSuccess: (r) => (r.data as Map)['success'] != false,
            onRejected: (_) => null,
          ));

      final failure = (await ApiServices.instance().get(endpoint: '/pay'))
          .getLeft()
          .toNullable()!;

      expect(failure.errorType, ErrorSource.badRequest);
      expect(failure.message, 'from body');
    });

    test('a throwing builder falls back rather than escaping', () async {
      final adapter = _RecordingAdapter(
        responder: (_) => _json('{"success":false,"message":"from body"}'),
      );
      _init(adapter,
          config: ApiConfig(
            isSuccess: (r) => (r.data as Map)['success'] != false,
            onRejected: (_) => throw StateError('broken builder'),
          ));

      final result = await ApiServices.instance().get(endpoint: '/pay');

      expect(result.getLeft().toNullable()!.errorType, ErrorSource.badRequest);
    });

    test('is not consulted when isSuccess accepts the response', () async {
      var called = false;
      final adapter = _RecordingAdapter(responder: (_) => _json('{"ok":true}'));
      _init(adapter,
          config: ApiConfig(
            isSuccess: (r) => true,
            onRejected: (_) {
              called = true;
              return null;
            },
          ));

      expect((await ApiServices.instance().get(endpoint: '/ok')).isRight(),
          isTrue);
      expect(called, isFalse);
    });
  });
}
