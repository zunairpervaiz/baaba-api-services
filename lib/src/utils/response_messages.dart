// ignore_for_file: constant_identifier_names

import 'response_strings.dart';

class ResponseMessage {
  static const String SUCCESS = ResponseStrings.success;
  static const String CREATED = ResponseStrings.strCreated;
  static const String NO_CONTENT = ResponseStrings.strNoContent;
  static const String BAD_REQUEST = ResponseStrings.strBadRequestError;
  static const String UNAUTHORISED = ResponseStrings.strUnauthorizedError;
  static const String FORBIDDEN = ResponseStrings.strForbiddenError;
  static const String NOT_FOUND = ResponseStrings.strNotFoundError;
  static const String CONFLICT = ResponseStrings.strConflictError;
  static const String UNPROCESSABLE_ENTITY = ResponseStrings.strUnprocessableEntityError;
  static const String TOO_MANY_REQUESTS = ResponseStrings.strTooManyRequestsError;
  static const String INTERNAL_SERVER_ERROR = ResponseStrings.strInternalServerError;
  static const String BAD_GATEWAY = ResponseStrings.strBadGatewayError;
  static const String SERVICE_NOT_AVAILABLE = ResponseStrings.strServiceNotAvailableError;

  // local status codes
  static const String CONNECT_TIMEOUT = ResponseStrings.strTimeoutError;
  static const String RECEIVE_TIMEOUT = ResponseStrings.strTimeoutError;
  static const String SEND_TIMEOUT = ResponseStrings.strTimeoutError;
  static const String REQUEST_TIMEOUT = ResponseStrings.strRequestTimeoutError;
  static const String CANCEL = ResponseStrings.strCancelError;
  static const String CACHE_ERROR = ResponseStrings.strCacheError;
  static const String NO_INTERNET_CONNECTION = ResponseStrings.strNoInternetError;
  static const String CONNECTION_FAILURE = ResponseStrings.strConnectionFailureError;
  static const String DEFAULT = ResponseStrings.strDefaultError;
}
