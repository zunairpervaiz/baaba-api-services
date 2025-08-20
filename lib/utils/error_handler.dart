import 'package:baaba_api_services/utils/error_source_extension.dart';
import 'package:baaba_api_services/utils/failure.dart';
import 'package:baaba_api_services/utils/response_code.dart';
import 'package:dio/dio.dart';

import './constants.dart';

class ErrorHandler implements Exception {
  // Represents the failure object associated with the error.
  late Failure failure;

  /// Constructor for creating an ErrorHandler instance to handle errors.
  /// [error]: The error object to handle.

  ErrorHandler.handle(dynamic error) {
    if (error is DioException) {
      // If the error is a DioException, it indicates an error from the API response or Dio itself.
      // Handle the DioException and assign the resulting Failure object to failure.
      failure = _handleError(error);
    } else {
      // If the error is not a DioException, it is considered a default error.
      // Get the default Failure object.
      failure = ErrorSource.default_error.getFailure();
    }
  }
}

/// Handles a DioException and converts it into a Failure object.
/// [error]: The DioException to handle.

Failure _handleError(DioException error) {
  switch (error.type) {
    case DioExceptionType.connectionTimeout:
      // Returns a Failure object for connection timeout error.
      return ErrorSource.connection_timeout.getFailure();
    case DioExceptionType.sendTimeout:
      // Returns a Failure object for send timeout error.
      return ErrorSource.send_timeout.getFailure();
    case DioExceptionType.receiveTimeout:
      // Returns a Failure object for receive timeout error.
      return ErrorSource.receive_timeout.getFailure();
    case DioExceptionType.badResponse:
      // If the error type is badResponse, it indicates an error from the API response.
      if (error.response != null && error.response?.statusCode != null) {
        // Check if the error response and status code are available.
        // Get the status code from the error response.
        final statusCode = error.response!.statusCode!;
        // Initialize the error message.
        String errorMessage = '';

        // Get the response data from the error.
        final responseData = error.response?.data;

        if (responseData is String) {
          // If the response data is a string, set the error message.
          errorMessage = responseData;
        } else if (responseData is Map<String, dynamic>) {
          // If the response data is a map, check for specific keys to extract the error message.
          if (responseData.containsKey(messageKey)) {
            // If the 'message' key exists, use its value as the error message.
            errorMessage = responseData[messageKey].toString();
          } else if (responseData.containsKey(errorKey)) {
            // If the 'error' key exists, use its value as the error message.
            errorMessage = responseData[errorKey].toString();
          }
        }
        final responseCode = mapStatusCodeToEnum(statusCode);
        final errorSource = mapResponseCodeToEnum(responseCode);
        // Create and return a Failure object with the status code and error message.
        return Failure(errorSource, responseCode, errorMessage);
      } else {
        // If the error response or status code is not available, return a default error Failure object.
        return ErrorSource.default_error.getFailure();
      }

    case DioExceptionType.cancel:
      // Returns a Failure object for cancellation error.
      return ErrorSource.cancel.getFailure();
    case DioExceptionType.connectionError:
      // Returns a Failure object for connection error.
      // coverage:ignore-start
      return ErrorSource.connection_failure.getFailure();
    // coverage:ignore-end

    default:
      // Returns a default error Failure object for other error types.
      return ErrorSource.default_error.getFailure();
  }
}
