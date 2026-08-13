import 'package:baaba_api_handler/src/utils/error_body.dart';
import 'package:baaba_api_handler/src/utils/error_source_extension.dart';
import 'package:baaba_api_handler/src/utils/response_code.dart';
import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';

/// Represents a failure from [ApiServices], carrying the error type, HTTP/internal
/// code, and a human-readable message.
///
/// [message] is what you show the user. [data] is the raw response body, for
/// everything a single string cannot carry:
///
/// ```dart
/// result.fold(
///   (failure) {
///     final fields = failure.validationErrors;
///     if (fields != null) {
///       emailError = fields['email']?.first;
///       nameError = fields['name']?.first;
///     } else {
///       showSnackBar(failure.message);
///     }
///   },
///   (response) => ...,
/// );
/// ```
class Failure extends Equatable implements Exception {
  final ErrorSource errorType;
  final ResponseCode code;
  final String message;

  /// The raw response body, when the server sent one.
  ///
  /// `null` for failures that never reached the server (offline, timeouts,
  /// cancellation) and for responses with an empty body. Usually a decoded
  /// `Map`, but whatever the server actually returned — check the type before
  /// indexing into it, or use [validationErrors].
  final Object? data;

  /// The literal HTTP status, e.g. `418`.
  ///
  /// [code] is a mapped enum and collapses anything unrecognised to
  /// `ResponseCode.defaultError`, so this is the field to read when you need
  /// the status the server actually sent. `null` for non-HTTP failures.
  final int? statusCode;

  /// The request that produced this failure — its method, path, and headers.
  ///
  /// `null` when no request was ever built, which is the case for the offline
  /// short-circuit and for a cache miss under `CachePolicy.cacheOnly`.
  ///
  /// Deliberately **excluded from equality**: it is context about where a
  /// failure came from, not part of what the failure *is*. Two identical
  /// `404`s from different endpoints should still compare equal, and
  /// `RequestOptions` has no value equality of its own, so including it would
  /// make every real failure unequal to every other.
  final RequestOptions? requestOptions;

  const Failure(
    this.errorType,
    this.code,
    this.message, {
    this.data,
    this.statusCode,
    this.requestOptions,
  });

  /// Returns a copy carrying [options] as its originating request.
  Failure withRequest(RequestOptions? options) => Failure(
        errorType,
        code,
        message,
        data: data,
        statusCode: statusCode,
        requestOptions: options,
      );

  /// Per-field validation errors parsed from [data], for a `422`-style body:
  ///
  /// ```json
  /// {"message": "Validation failed", "errors": {"email": ["already taken"]}}
  /// ```
  ///
  /// `null` when the body has no `errors` object — which is the common case,
  /// so always null-check rather than assuming an empty map.
  Map<String, List<String>>? get validationErrors =>
      extractValidationErrors(data);

  @override
  String toString() =>
      '{errorType: $errorType, code: ${code.value}, message: $message}';

  @override
  List<Object?> get props => [errorType, code, message, data, statusCode];
}
