// ignore_for_file: constant_identifier_names

import 'package:baaba_api_services/utils/error_source_extension.dart';

/// Enumeration representing various response codes and corresponding error states.
enum ResponseCode {
  SUCCESS,
  NO_CONTENT,
  BAD_REQUEST,
  UNAUTHORIZED,
  FORBIDDEN,
  INTERNAL_SERVER_ERROR,
  NOT_FOUND,
  CONNECT_TIMEOUT,
  CANCEL,
  RECEIVE_TIMEOUT,
  SEND_TIMEOUT,
  CACHE_ERROR,
  NO_INTERNET_CONNECTION,
  DEFAULT,
  CONNECTION_FAILURE,
}

/// An extension on the [ResponseCode] enum to provide an integer value for each response code.
extension ResponseCodeExtension on ResponseCode {
  int get value {
    switch (this) {
      case ResponseCode.SUCCESS:
        return 200;
      case ResponseCode.NO_CONTENT:
        return 201;
      case ResponseCode.BAD_REQUEST:
        return 400;
      case ResponseCode.UNAUTHORIZED:
        return 401;
      case ResponseCode.FORBIDDEN:
        return 403;
      case ResponseCode.INTERNAL_SERVER_ERROR:
        return 500;
      case ResponseCode.NOT_FOUND:
        return 404;
      case ResponseCode.CONNECT_TIMEOUT:
        return -1;
      case ResponseCode.CANCEL:
        return -2;
      case ResponseCode.RECEIVE_TIMEOUT:
        return -3;
      case ResponseCode.SEND_TIMEOUT:
        return -4;
      case ResponseCode.CACHE_ERROR:
        return -5;
      case ResponseCode.NO_INTERNET_CONNECTION:
        return -6;
      case ResponseCode.DEFAULT:
        return -7;
      case ResponseCode.CONNECTION_FAILURE:
        return -8;
    }
  }
}

/// Maps an integer status code to a [ResponseCode] enum constant.
ResponseCode mapStatusCodeToEnum(int statusCode) {
  switch (statusCode) {
    case 200:
      return ResponseCode.SUCCESS;
    case 201:
      return ResponseCode.NO_CONTENT;
    case 400:
      return ResponseCode.BAD_REQUEST;
    case 401:
      return ResponseCode.UNAUTHORIZED;
    case 403:
      return ResponseCode.FORBIDDEN;
    case 404:
      return ResponseCode.NOT_FOUND;
    case 500:
      return ResponseCode.INTERNAL_SERVER_ERROR;
    case -1:
      return ResponseCode.CONNECT_TIMEOUT;
    case -2:
      return ResponseCode.CANCEL;
    case -3:
      return ResponseCode.RECEIVE_TIMEOUT;
    case -4:
      return ResponseCode.SEND_TIMEOUT;
    case -5:
      return ResponseCode.CACHE_ERROR;
    case -6:
      return ResponseCode.NO_INTERNET_CONNECTION;
    case -7:
      return ResponseCode.DEFAULT;
    case -8:
      return ResponseCode.CONNECTION_FAILURE;
    default:
      return ResponseCode.DEFAULT;
  }
}

ErrorSource mapResponseCodeToEnum(ResponseCode code) => switch (code) {
  ResponseCode.SUCCESS => ErrorSource.success,
  ResponseCode.NO_CONTENT => ErrorSource.no_content,
  ResponseCode.BAD_REQUEST => ErrorSource.bad_request,
  ResponseCode.UNAUTHORIZED => ErrorSource.unauthorised,
  ResponseCode.FORBIDDEN => ErrorSource.forbidden,
  ResponseCode.INTERNAL_SERVER_ERROR => ErrorSource.internal_server_error,
  ResponseCode.NOT_FOUND => ErrorSource.not_found,
  ResponseCode.CONNECT_TIMEOUT => ErrorSource.connection_timeout,
  ResponseCode.CANCEL => ErrorSource.cancel,
  ResponseCode.RECEIVE_TIMEOUT => ErrorSource.receive_timeout,
  ResponseCode.SEND_TIMEOUT => ErrorSource.send_timeout,
  ResponseCode.CACHE_ERROR => ErrorSource.cache_error,
  ResponseCode.NO_INTERNET_CONNECTION => ErrorSource.no_internet_connection,
  ResponseCode.DEFAULT => ErrorSource.default_error,
  ResponseCode.CONNECTION_FAILURE => ErrorSource.connection_failure,
};
