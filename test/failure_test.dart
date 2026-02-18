import 'package:baaba_api_handler/src/utils/response_code.dart';
import 'package:baaba_api_handler/ts_api_handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Failure', () {
    test('Constructor creates Failure instance with provided parameters', () {
      const errorType = ErrorSource.bad_request;
      const code = ResponseCode.BAD_REQUEST;
      const message = 'Bad Request';

      const failure = Failure(errorType, code, message);

      expect(failure.errorType, equals(errorType));
      expect(failure.code, equals(code));
      expect(failure.message, equals(message));
    });

    test('toString method returns expected string representation', () {
      const errorType = ErrorSource.internal_server_error;
      const code = ResponseCode.INTERNAL_SERVER_ERROR;
      const message = 'Internal Server Error';

      const failure = Failure(errorType, code, message);

      expect(failure.toString(), equals("{errorType: $errorType, code: ${code.value}, message: $message}"));
    });

    test('Equality works correctly', () {
      const failure1 = Failure(ErrorSource.bad_request, ResponseCode.BAD_REQUEST, 'Bad Request');
      const failure2 = Failure(ErrorSource.bad_request, ResponseCode.BAD_REQUEST, 'Bad Request');
      const failure3 = Failure(ErrorSource.not_found, ResponseCode.NOT_FOUND, 'Not Found');

      expect(failure1, equals(failure2));
      expect(failure1.hashCode, equals(failure2.hashCode));

      expect(failure1, isNot(equals(failure3)));
      expect(failure1.hashCode, isNot(equals(failure3.hashCode)));
    });
  });
}
