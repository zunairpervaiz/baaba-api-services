import 'package:baaba_api_handler/src/config/api_config.dart';
import 'package:baaba_api_handler/src/utils/error_body.dart';
import 'package:baaba_api_handler/src/utils/error_source_extension.dart';
import 'package:baaba_api_handler/src/utils/failure.dart';
import 'package:baaba_api_handler/src/utils/response_code.dart';
import 'package:baaba_api_handler/src/utils/response_strings.dart';
import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';

/// Applies `ApiConfig.isSuccess` (and `onRejected`) to a 2xx response.
///
/// Shared by the real client and `FakeApiServices`, so a body the predicate
/// rejects is a `Left` in consumers' tests exactly as it is in production.
Either<Failure, Response> evaluateSuccess(Response response, ApiConfig config) {
  final isSuccess = config.isSuccess;
  if (isSuccess == null || _accepts(isSuccess, response)) {
    return right(response);
  }

  // A 2xx the consumer's predicate rejected — e.g. {"success": false}.
  // Give them first refusal on the resulting Failure, so an API that
  // reports its own error codes in the body can surface one instead of
  // collapsing to a generic bad request. Wrapped, because a builder that
  // throws must not turn a response into an exception.
  final onRejected = config.onRejected;
  if (onRejected != null) {
    try {
      final custom = onRejected(response);
      if (custom != null) {
        return left(custom.withRequest(response.requestOptions));
      }
    } catch (_) {}
  }

  // Read the message from the body the same way a real error response would.
  final body = response.data;
  final message = extractErrorMessage(body);
  return left(Failure(
    ErrorSource.badRequest,
    ResponseCode.badRequest,
    message.isNotEmpty ? message : ResponseStrings.badRequest,
    data: body,
    statusCode: response.statusCode,
    requestOptions: response.requestOptions,
  ));
}

/// Runs the consumer's `isSuccess`, treating a throw as a rejection.
///
/// Unguarded, a predicate written for an envelope body —
/// `r.data['success'] == true` — threw on a `204`'s null body, and the
/// exception escaped an API that promises none do. Fails closed, as
/// `AuthConfig.sendTokenTo` does: a response the predicate could not
/// confirm is not reported as a success, and the resulting `Failure`
/// carries the body for the caller to inspect.
bool _accepts(bool Function(Response response) isSuccess, Response response) {
  try {
    return isSuccess(response);
  } catch (_) {
    return false;
  }
}
