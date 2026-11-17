import 'package:baaba_api_handler/src/transport/transport.dart';
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
  // Dio's default adapter does not catch a failed TLS handshake, so an
  // unpinned client's bad certificate arrives as `unknown` wrapping it.
  if (isTlsError(error.error)) {
    return ErrorSource.certificateRejected.getFailure();
  }
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
      return ErrorSource.connectionFailure.getFailure();
    case DioExceptionType.badCertificate:
      // A refused certificate is not a network blip: telling the user to
      // check their connection would be wrong, and on a pinned client it may
      // be an interception attempt the app wants to report.
      return ErrorSource.certificateRejected.getFailure();
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

  return failureForStatus(statusCode, responseData);
}

/// The `Failure` for an HTTP error response with [statusCode] and [body].
///
/// Shared with `FakeApiServices`, so a stubbed failure is built exactly as a
/// real one is — a test double that disagreed would let consumer tests pass
/// against behaviour production does not have.
Failure failureForStatus(int statusCode, Object? body) {
  final responseCode = mapStatusCodeToEnum(statusCode);
  final errorSource = mapResponseCodeToEnum(responseCode);

  // Prefer what the server said; fall back to the generic text for the status
  // rather than handing the caller an empty string.
  final serverMessage = extractErrorMessage(body);
  final message = serverMessage.isNotEmpty
      ? serverMessage
      : errorSource.getFailure().message;

  return Failure(
    errorSource,
    responseCode,
    message,
    data: body,
    statusCode: statusCode,
  );
}
