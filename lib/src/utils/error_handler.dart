import 'package:baaba_api_handler/src/utils/error_body.dart';
import 'package:baaba_api_handler/src/utils/error_source_extension.dart';
import 'package:baaba_api_handler/src/utils/failure.dart';
import 'package:baaba_api_handler/src/utils/response_code.dart';
import 'package:dio/dio.dart';

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
      return _handleBadResponse(error);
    case DioExceptionType.cancel:
      return ErrorSource.cancel.getFailure();
    case DioExceptionType.connectionError:
    case DioExceptionType.badCertificate:
      return ErrorSource.connectionFailure.getFailure();
    default:
      return ErrorSource.defaultError.getFailure();
  }
}

Failure _handleBadResponse(DioException error) {
  final statusCode = error.response?.statusCode;
  final responseData = error.response?.data;

  if (statusCode == null) {
    // A response with no status is not something we can map — fall back to the
    // generic error, but keep the body so the caller can still inspect it.
    final generic = ErrorSource.defaultError.getFailure();
    return Failure(
      generic.errorType,
      generic.code,
      generic.message,
      data: responseData,
    );
  }

  final responseCode = mapStatusCodeToEnum(statusCode);
  final errorSource = mapResponseCodeToEnum(responseCode);

  // Prefer what the server said; fall back to the generic text for the status
  // rather than handing the caller an empty string.
  final serverMessage = extractErrorMessage(responseData);
  final message = serverMessage.isNotEmpty
      ? serverMessage
      : errorSource.getFailure().message;

  return Failure(
    errorSource,
    responseCode,
    message,
    data: responseData,
    statusCode: statusCode,
  );
}
