import 'package:baaba_api_handler/src/utils/error_source_extension.dart';
import 'package:baaba_api_handler/src/utils/response_strings.dart';
import 'package:baaba_api_handler/ts_api_handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ErrorSourceExtension', () {
    test('getFailure() returns correct Failure for each ErrorSource', () {
      expect(
        ErrorSource.success.getFailure(),
        equals(const Failure(ErrorSource.success, ResponseCode.success, ResponseStrings.success)),
      );
      expect(
        ErrorSource.noContent.getFailure(),
        equals(const Failure(ErrorSource.noContent, ResponseCode.noContent, ResponseStrings.noContent)),
      );
      expect(
        ErrorSource.badRequest.getFailure(),
        equals(const Failure(ErrorSource.badRequest, ResponseCode.badRequest, ResponseStrings.badRequest)),
      );
      expect(
        ErrorSource.forbidden.getFailure(),
        equals(const Failure(ErrorSource.forbidden, ResponseCode.forbidden, ResponseStrings.forbidden)),
      );
      expect(
        ErrorSource.unauthorized.getFailure(),
        equals(const Failure(ErrorSource.unauthorized, ResponseCode.unauthorized, ResponseStrings.unauthorized)),
      );
      expect(
        ErrorSource.notFound.getFailure(),
        equals(const Failure(ErrorSource.notFound, ResponseCode.notFound, ResponseStrings.notFound)),
      );
      expect(
        ErrorSource.internalServerError.getFailure(),
        equals(const Failure(
            ErrorSource.internalServerError, ResponseCode.internalServerError, ResponseStrings.internalServerError)),
      );
      expect(
        ErrorSource.connectionTimeout.getFailure(),
        equals(const Failure(ErrorSource.connectionTimeout, ResponseCode.connectTimeout, ResponseStrings.connectTimeout)),
      );
      expect(
        ErrorSource.cancel.getFailure(),
        equals(const Failure(ErrorSource.cancel, ResponseCode.cancel, ResponseStrings.cancel)),
      );
      expect(
        ErrorSource.receiveTimeout.getFailure(),
        equals(const Failure(ErrorSource.receiveTimeout, ResponseCode.receiveTimeout, ResponseStrings.receiveTimeout)),
      );
      expect(
        ErrorSource.sendTimeout.getFailure(),
        equals(const Failure(ErrorSource.sendTimeout, ResponseCode.sendTimeout, ResponseStrings.sendTimeout)),
      );
      expect(
        ErrorSource.cacheError.getFailure(),
        equals(const Failure(ErrorSource.cacheError, ResponseCode.cacheError, ResponseStrings.cacheError)),
      );
      expect(
        ErrorSource.noInternetConnection.getFailure(),
        equals(const Failure(
            ErrorSource.noInternetConnection, ResponseCode.noInternetConnection, ResponseStrings.noInternetConnection)),
      );
      expect(
        ErrorSource.connectionFailure.getFailure(),
        equals(
            const Failure(ErrorSource.connectionFailure, ResponseCode.connectionFailure, ResponseStrings.connectionFailure)),
      );
      expect(
        ErrorSource.defaultError.getFailure(),
        equals(const Failure(ErrorSource.defaultError, ResponseCode.defaultError, ResponseStrings.defaultError)),
      );
    });
  });
}
