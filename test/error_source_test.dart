import 'package:baaba_api_handler/src/utils/error_source_extension.dart';
import 'package:baaba_api_handler/src/utils/response_messages.dart';
import 'package:baaba_api_handler/ts_api_handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ErrorSourceExtension', () {
    test('getFailure() returns correct Failure object for each ErrorSource', () {
      expect(ErrorSource.success.getFailure(), equals(const Failure(ErrorSource.success, ResponseCode.SUCCESS, ResponseMessage.SUCCESS)));

      expect(ErrorSource.no_content.getFailure(),
          equals(const Failure(ErrorSource.no_content, ResponseCode.NO_CONTENT, ResponseMessage.NO_CONTENT)));

      expect(ErrorSource.bad_request.getFailure(),
          equals(const Failure(ErrorSource.bad_request, ResponseCode.BAD_REQUEST, ResponseMessage.BAD_REQUEST)));

      expect(ErrorSource.forbidden.getFailure(),
          equals(const Failure(ErrorSource.forbidden, ResponseCode.FORBIDDEN, ResponseMessage.FORBIDDEN)));

      expect(ErrorSource.unauthorised.getFailure(),
          equals(const Failure(ErrorSource.unauthorised, ResponseCode.UNAUTHORIZED, ResponseMessage.UNAUTHORISED)));

      expect(ErrorSource.not_found.getFailure(),
          equals(const Failure(ErrorSource.not_found, ResponseCode.NOT_FOUND, ResponseMessage.NOT_FOUND)));

      expect(
          ErrorSource.internal_server_error.getFailure(),
          equals(
              const Failure(ErrorSource.internal_server_error, ResponseCode.INTERNAL_SERVER_ERROR, ResponseMessage.INTERNAL_SERVER_ERROR)));

      expect(ErrorSource.connection_timeout.getFailure(),
          equals(const Failure(ErrorSource.connection_timeout, ResponseCode.CONNECT_TIMEOUT, ResponseMessage.CONNECT_TIMEOUT)));

      expect(ErrorSource.cancel.getFailure(), equals(const Failure(ErrorSource.cancel, ResponseCode.CANCEL, ResponseMessage.CANCEL)));

      expect(ErrorSource.receive_timeout.getFailure(),
          equals(const Failure(ErrorSource.receive_timeout, ResponseCode.RECEIVE_TIMEOUT, ResponseMessage.RECEIVE_TIMEOUT)));

      expect(ErrorSource.send_timeout.getFailure(),
          equals(const Failure(ErrorSource.send_timeout, ResponseCode.SEND_TIMEOUT, ResponseMessage.SEND_TIMEOUT)));

      expect(ErrorSource.cache_error.getFailure(),
          equals(const Failure(ErrorSource.cache_error, ResponseCode.CACHE_ERROR, ResponseMessage.CACHE_ERROR)));

      expect(
          ErrorSource.no_internet_connection.getFailure(),
          equals(const Failure(
              ErrorSource.no_internet_connection, ResponseCode.NO_INTERNET_CONNECTION, ResponseMessage.NO_INTERNET_CONNECTION)));

      expect(ErrorSource.connection_failure.getFailure(),
          equals(const Failure(ErrorSource.connection_failure, ResponseCode.CONNECTION_FAILURE, ResponseMessage.CONNECTION_FAILURE)));

      expect(ErrorSource.default_error.getFailure(),
          equals(const Failure(ErrorSource.default_error, ResponseCode.DEFAULT, ResponseMessage.DEFAULT)));
    });
  });
}
