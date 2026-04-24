// ignore_for_file: constant_identifier_names

import 'package:baaba_api_handler/src/utils/failure.dart';
import 'package:baaba_api_handler/src/utils/response_code.dart';
import 'package:baaba_api_handler/src/utils/response_messages.dart';

/// Enumeration representing different data sources or error types.
enum ErrorSource {
  success,
  created,
  no_content,
  bad_request,
  forbidden,
  unauthorised,
  not_found,
  request_timeout,
  conflict,
  unprocessable_entity,
  too_many_requests,
  internal_server_error,
  bad_gateway,
  connection_timeout,
  cancel,
  receive_timeout,
  send_timeout,
  cache_error,
  no_internet_connection,
  connection_failure,
  service_not_available,
  default_error
}

/// Extension on [ErrorSource] providing a method to convert each data source into a Failure object.

extension ErrorSourceExtension on ErrorSource {
  /// Converts the DataSource enum value into a Failure object.
  Failure getFailure() {
    // Switch case to convert each DataSource enum value into a Failure object.
    switch (this) {
      case ErrorSource.success:
        return Failure(this, ResponseCode.SUCCESS, ResponseMessage.SUCCESS);
      case ErrorSource.created:
        return Failure(this, ResponseCode.CREATED, ResponseMessage.CREATED);
      case ErrorSource.no_content:
        return Failure(this, ResponseCode.NO_CONTENT, ResponseMessage.NO_CONTENT);
      case ErrorSource.bad_request:
        return Failure(this, ResponseCode.BAD_REQUEST, ResponseMessage.BAD_REQUEST);
      case ErrorSource.forbidden:
        return Failure(this, ResponseCode.FORBIDDEN, ResponseMessage.FORBIDDEN);
      case ErrorSource.unauthorised:
        return Failure(this, ResponseCode.UNAUTHORIZED, ResponseMessage.UNAUTHORISED);
      case ErrorSource.not_found:
        return Failure(this, ResponseCode.NOT_FOUND, ResponseMessage.NOT_FOUND);
      case ErrorSource.request_timeout:
        return Failure(this, ResponseCode.REQUEST_TIMEOUT, ResponseMessage.REQUEST_TIMEOUT);
      case ErrorSource.conflict:
        return Failure(this, ResponseCode.CONFLICT, ResponseMessage.CONFLICT);
      case ErrorSource.unprocessable_entity:
        return Failure(this, ResponseCode.UNPROCESSABLE_ENTITY, ResponseMessage.UNPROCESSABLE_ENTITY);
      case ErrorSource.too_many_requests:
        return Failure(this, ResponseCode.TOO_MANY_REQUESTS, ResponseMessage.TOO_MANY_REQUESTS);
      case ErrorSource.internal_server_error:
        return Failure(this, ResponseCode.INTERNAL_SERVER_ERROR, ResponseMessage.INTERNAL_SERVER_ERROR);
      case ErrorSource.bad_gateway:
        return Failure(this, ResponseCode.BAD_GATEWAY, ResponseMessage.BAD_GATEWAY);
      case ErrorSource.connection_timeout:
        return Failure(this, ResponseCode.CONNECT_TIMEOUT, ResponseMessage.CONNECT_TIMEOUT);
      case ErrorSource.cancel:
        return Failure(this, ResponseCode.CANCEL, ResponseMessage.CANCEL);
      case ErrorSource.receive_timeout:
        return Failure(this, ResponseCode.RECEIVE_TIMEOUT, ResponseMessage.RECEIVE_TIMEOUT);
      case ErrorSource.send_timeout:
        return Failure(this, ResponseCode.SEND_TIMEOUT, ResponseMessage.SEND_TIMEOUT);
      case ErrorSource.cache_error:
        return Failure(this, ResponseCode.CACHE_ERROR, ResponseMessage.CACHE_ERROR);
      case ErrorSource.no_internet_connection:
        return Failure(this, ResponseCode.NO_INTERNET_CONNECTION, ResponseMessage.NO_INTERNET_CONNECTION);
      case ErrorSource.connection_failure:
        return Failure(this, ResponseCode.CONNECTION_FAILURE, ResponseMessage.CONNECTION_FAILURE);
      case ErrorSource.service_not_available:
        return Failure(this, ResponseCode.SERVICE_NOT_AVAILABLE, ResponseMessage.SERVICE_NOT_AVAILABLE);
      case ErrorSource.default_error:
        return Failure(this, ResponseCode.DEFAULT, ResponseMessage.DEFAULT);
    }
  }
}
