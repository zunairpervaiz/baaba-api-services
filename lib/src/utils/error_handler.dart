import 'package:baaba_api_handler/src/utils/error_source_extension.dart';
import 'package:baaba_api_handler/src/utils/failure.dart';
import 'package:baaba_api_handler/src/utils/response_code.dart';
import 'package:dio/dio.dart';

import 'constants.dart';

class ErrorHandler {
  late Failure failure;

  ErrorHandler.handle(dynamic error) {
    if (error is DioException) {
      failure = _handleError(error);
    } else {
      failure = ErrorSource.defaultError.getFailure();
    }
  }
}

Failure _handleError(DioException error) {
  switch (error.type) {
    case DioExceptionType.connectionTimeout:
      return ErrorSource.connectionTimeout.getFailure();
    case DioExceptionType.sendTimeout:
      return ErrorSource.sendTimeout.getFailure();
    case DioExceptionType.receiveTimeout:
      return ErrorSource.receiveTimeout.getFailure();
    case DioExceptionType.badResponse:
      if (error.response != null && error.response?.statusCode != null) {
        final statusCode = error.response!.statusCode!;
        String errorMessage = '';

        final responseData = error.response?.data;
        if (responseData is String) {
          errorMessage = responseData;
        } else if (responseData is Map<String, dynamic>) {
          if (responseData.containsKey(messageKey)) {
            errorMessage = responseData[messageKey].toString();
          } else if (responseData.containsKey(detailKey)) {
            errorMessage = responseData[detailKey].toString();
          } else if (responseData.containsKey(errorKey)) {
            errorMessage = responseData[errorKey].toString();
          }
        }

        final responseCode = mapStatusCodeToEnum(statusCode);
        final errorSource = mapResponseCodeToEnum(responseCode);
        return Failure(errorSource, responseCode, errorMessage);
      }
      return ErrorSource.defaultError.getFailure();

    case DioExceptionType.cancel:
      return ErrorSource.cancel.getFailure();
    case DioExceptionType.connectionError:
      return ErrorSource.connectionFailure.getFailure();
    default:
      return ErrorSource.defaultError.getFailure();
  }
}
