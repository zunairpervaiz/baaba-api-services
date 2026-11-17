import 'package:baaba_api_handler/testing.dart';
import 'package:flutter_test/flutter_test.dart';

class _Order {
  final int id;
  _Order(this.id);
}

void main() {
  late FakeApiServices api;

  setUp(() => api = FakeApiServices());
  tearDown(ApiServices.reset);

  group('ApiException', () {
    test('exposes the failure and its fields', () {
      const failure = Failure(
        ErrorSource.conflict,
        ResponseCode.conflict,
        'Already paid',
        data: {'code': 'PAID'},
        statusCode: 409,
      );
      const e = ApiException(failure);

      expect(e.failure, same(failure));
      expect(e.statusCode, 409);
      expect(e.data, {'code': 'PAID'});
      expect(e.message, 'Already paid');
      expect(e.errorType, ErrorSource.conflict);
      expect(e, isA<Exception>());
      expect('$e', contains('409'));
    });
  });

  group('orThrow', () {
    test('returns the response on success', () async {
      api.stubJson(HttpMethod.get, '/a', {'ok': true});
      final response = await api.get(endpoint: '/a').orThrow();
      expect(response.data, {'ok': true});
    });

    test('works on the typed variants', () async {
      api.stubJson(HttpMethod.get, '/orders/1', {'id': 1});
      final order = await api
          .getAs(
            endpoint: '/orders/1',
            parser: (d) => _Order((d as Map)['id'] as int),
          )
          .orThrow();
      expect(order.id, 1);
    });

    test('throws an ApiException carrying the failure', () async {
      api.stubFailure(HttpMethod.get, '/a', statusCode: 404);
      await expectLater(
        api.get(endpoint: '/a').orThrow(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.errorType, 'errorType', ErrorSource.notFound),
        ),
      );
    });

    test('works on an Either already awaited', () async {
      api.stubOffline(HttpMethod.get, '/a');
      final result = await api.get(endpoint: '/a');
      expect(
        result.orThrow,
        throwsA(
          isA<ApiException>().having(
            (e) => e.errorType,
            'errorType',
            ErrorSource.noInternetConnection,
          ),
        ),
      );
    });
  });

  group('guardApi', () {
    test('returns the flow\'s value', () async {
      api
        ..stubJson(HttpMethod.post, '/orders', {'id': 7})
        ..stubJson(HttpMethod.post, '/orders/7/pay', {'receipt': 'R-1'});

      final result = await guardApi(() async {
        final order = await api
            .postAs(
              endpoint: '/orders',
              parser: (d) => _Order((d as Map)['id'] as int),
            )
            .orThrow();
        final paid = await api
            .post(endpoint: '/orders/${order.id}/pay')
            .orThrow();
        return (paid.data as Map)['receipt'] as String;
      });

      expect(result.getRight().toNullable(), 'R-1');
    });

    test(
      'the first failure stops the flow and is returned unchanged',
      () async {
        api
          ..stubFailure(
            HttpMethod.post,
            '/orders',
            statusCode: 422,
            body: {'message': 'Cart is empty'},
          )
          ..stubJson(HttpMethod.post, '/orders/7/pay', {});

        final result = await guardApi(() async {
          await api.post(endpoint: '/orders').orThrow();
          await api.post(endpoint: '/orders/7/pay').orThrow();
          return 'done';
        });

        final failure = result.getLeft().toNullable()!;
        expect(failure.statusCode, 422);
        expect(failure.message, 'Cart is empty');
        expect(api.recordedCalls, hasLength(1));
      },
    );

    test('a thrown Failure is returned as is', () async {
      const failure = Failure(
        ErrorSource.forbidden,
        ResponseCode.forbidden,
        'no',
      );
      final result = await guardApi<int>(() async => throw failure);
      expect(result.getLeft().toNullable(), same(failure));
    });

    test('a DioException becomes the failure the client would build', () async {
      final options = RequestOptions(path: '/raw');
      final result = await guardApi<int>(
        () async => throw DioException.badResponse(
          statusCode: 503,
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: 503),
        ),
      );
      final failure = result.getLeft().toNullable()!;
      expect(failure.errorType, ErrorSource.serviceNotAvailable);
      expect(failure.requestOptions, same(options));
    });

    test(
      'a DioException goes through the named client\'s mapFailure',
      () async {
        ApiServices.init(
          ApiConfig(
            mapFailure: (f) => Failure(
              f.errorType,
              f.code,
              'mapped: ${f.statusCode}',
              statusCode: f.statusCode,
            ),
          ),
          name: 'partner',
        );
        final options = RequestOptions(path: '/raw');
        DioException dio() => DioException.badResponse(
          statusCode: 503,
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: 503),
        );

        final mapped = await guardApi<int>(
          () async => throw dio(),
          client: 'partner',
        );
        expect(mapped.getLeft().toNullable()?.message, 'mapped: 503');

        // The default client has no mapper: the failure is left as built.
        final plain = await guardApi<int>(() async => throw dio());
        expect(
          plain.getLeft().toNullable()?.message,
          isNot(startsWith('mapped')),
        );
      },
    );

    test(
      'anything else is an unknown failure, reported to onUnexpected',
      () async {
        Object? reported;
        final result = await guardApi<int>(
          () async => throw StateError('bug'),
          onUnexpected: (error, _) => reported = error,
        );
        expect(
          result.getLeft().toNullable()?.errorType,
          ErrorSource.defaultError,
        );
        expect(reported, isA<StateError>());
      },
    );

    test('never throws, even if onUnexpected does', () async {
      final result = await guardApi<int>(
        () => throw ArgumentError('sync throw'),
        onUnexpected: (_, _) => throw Exception('reporter down'),
      );
      expect(result.isLeft(), isTrue);
    });
  });
}
