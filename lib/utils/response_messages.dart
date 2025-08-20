// ignore_for_file: constant_identifier_names

import 'response_strings.dart';

class ResponseMessage {
  static const String SUCCESS = ResponseStrings.success; // success with data
  static const String NO_CONTENT = ResponseStrings.success; // success with no data (no content)
  static const String BAD_REQUEST = ResponseStrings.strBadRequestError; // failure, API rejected request
  static const String UNAUTORISED = ResponseStrings.strUnauthorizedError; // failure, user is not authorised
  static const String FORBIDDEN = ResponseStrings.strForbiddenError; //  failure, API rejected request
  static const String INTERNAL_SERVER_ERROR = ResponseStrings.strInternalServerError; // failure, crash in server side
  static const String NOT_FOUND = ResponseStrings.strNotFoundError; // failure, crash in server side

  // local status code
  static const String CONNECT_TIMEOUT = ResponseStrings.strTimeoutError;
  static const String CANCEL = ResponseStrings.strCancelError;
  static const String RECIEVE_TIMEOUT = ResponseStrings.strTimeoutError;
  static const String SEND_TIMEOUT = ResponseStrings.strTimeoutError;
  static const String CACHE_ERROR = ResponseStrings.strCacheError;
  static const String NO_INTERNET_CONNECTION = ResponseStrings.strNoInternetError;
  static const String CONNECTION_FAILURE = ResponseStrings.strConnectionFailureError;
  static const String DEFAULT = ResponseStrings.strDefaultError;
}
