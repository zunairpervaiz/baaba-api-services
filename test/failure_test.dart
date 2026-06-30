import 'package:baaba_api_handler/src/utils/response_code.dart';
import 'package:baaba_api_handler/ts_api_handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Failure', () {
    test('constructor stores provided values', () {
      const failure = Failure(ErrorSource.badRequest, ResponseCode.badRequest, 'Bad Request');

      expect(failure.errorType, ErrorSource.badRequest);
      expect(failure.code, ResponseCode.badRequest);
      expect(failure.message, 'Bad Request');
    });

    test('toString returns expected representation', () {
      const errorType = ErrorSource.internalServerError;
      const code = ResponseCode.internalServerError;
      const message = 'Internal Server Error';

      const failure = Failure(errorType, code, message);

      expect(failure.toString(), equals('{errorType: $errorType, code: ${code.value}, message: $message}'));
    });

    test('equality is based on all three fields', () {
      const f1 = Failure(ErrorSource.badRequest, ResponseCode.badRequest, 'Bad Request');
      const f2 = Failure(ErrorSource.badRequest, ResponseCode.badRequest, 'Bad Request');
      const f3 = Failure(ErrorSource.notFound, ResponseCode.notFound, 'Not Found');

      expect(f1, equals(f2));
      expect(f1.hashCode, equals(f2.hashCode));
      expect(f1, isNot(equals(f3)));
    });
  });
}
