import 'package:baaba_api_handler/src/utils/error_body.dart';
import 'package:baaba_api_handler/src/utils/error_handler.dart';
import 'package:baaba_api_handler/ts_api_handler.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

Failure _failureFor(int statusCode, Object? body) {
  return ErrorHandler.handle(DioException(
    type: DioExceptionType.badResponse,
    requestOptions: RequestOptions(path: '/test'),
    response: Response(
      statusCode: statusCode,
      data: body,
      requestOptions: RequestOptions(path: '/test'),
    ),
  )).failure;
}

void main() {
  group('Failure payload', () {
    test('carries the raw body and the literal status code', () {
      final body = {'message': 'Validation failed', 'code': 'VALIDATION'};
      final failure = _failureFor(422, body);

      expect(failure.message, 'Validation failed');
      expect(failure.data, body);
      expect(failure.statusCode, 422);
      expect(failure.errorType, ErrorSource.unprocessableEntity);
    });

    test('statusCode keeps a status the ResponseCode enum cannot represent',
        () {
      final failure = _failureFor(418, {'message': 'I am a teapot'});

      // code collapses to defaultError, but the real status survives.
      expect(failure.code, ResponseCode.defaultError);
      expect(failure.statusCode, 418);
    });

    test('falls back to the generic message when the body has none', () {
      final failure = _failureFor(404, {});

      expect(failure.message, isNotEmpty);
      expect(failure.data, isEmpty);
    });

    test('is null for a failure that never reached the server', () {
      final failure = ErrorHandler.handle(DioException(
        type: DioExceptionType.connectionTimeout,
        requestOptions: RequestOptions(path: '/test'),
      )).failure;

      expect(failure.data, isNull);
      expect(failure.statusCode, isNull);
    });

    test('equality accounts for the payload', () {
      const a = Failure(ErrorSource.badRequest, ResponseCode.badRequest, 'x',
          statusCode: 400);
      const b = Failure(ErrorSource.badRequest, ResponseCode.badRequest, 'x',
          statusCode: 400);
      const c = Failure(ErrorSource.badRequest, ResponseCode.badRequest, 'x',
          statusCode: 409);

      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });
  });

  group('validationErrors', () {
    test('parses the errors object into per-field messages', () {
      final failure = _failureFor(422, {
        'message': 'Validation failed',
        'errors': {
          'email': ['already taken', 'must be a work address'],
          'name': 'is required',
        },
      });

      expect(failure.validationErrors, {
        'email': ['already taken', 'must be a work address'],
        'name': ['is required'],
      });
    });

    test('is null when the body has no errors object', () {
      expect(_failureFor(400, {'message': 'nope'}).validationErrors, isNull);
      expect(_failureFor(400, 'plain text').validationErrors, isNull);
      expect(_failureFor(500, null).validationErrors, isNull);
    });

    test('tolerates a junk errors payload without throwing', () {
      expect(_failureFor(422, {'errors': 'not an object'}).validationErrors,
          isNull);
      expect(
        _failureFor(422, {
          'errors': {'field': 42}
        }).validationErrors,
        {
          'field': ['42']
        },
      );
    });
  });

  group('extractErrorMessage', () {
    test('reads a plain string body', () {
      expect(extractErrorMessage('Something broke'), 'Something broke');
    });

    test('prefers message, then detail, then error', () {
      expect(extractErrorMessage({'message': 'a', 'detail': 'b', 'error': 'c'}),
          'a');
      expect(extractErrorMessage({'detail': 'b', 'error': 'c'}), 'b');
      expect(extractErrorMessage({'error': 'c'}), 'c');
    });

    test('follows one level into a nested object', () {
      expect(
        extractErrorMessage({
          'error': {'message': 'Email already taken'}
        }),
        'Email already taken',
      );
    });

    test('joins a list of messages', () {
      expect(
        extractErrorMessage({
          'detail': ['first problem', 'second problem']
        }),
        'first problem second problem',
      );
    });

    test('returns empty for a body with nothing usable', () {
      expect(extractErrorMessage({}), isEmpty);
      expect(extractErrorMessage(null), isEmpty);
      expect(extractErrorMessage(42), isEmpty);
      expect(extractErrorMessage({'unrelated': 'value'}), isEmpty);
    });
  });
}
