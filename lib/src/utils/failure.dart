import 'package:baaba_api_handler/src/utils/error_source_extension.dart';
import 'package:baaba_api_handler/src/utils/response_code.dart';
import 'package:equatable/equatable.dart';

/// Represents a failure from [ApiServices], carrying the error type, HTTP/internal
/// code, and a human-readable message.
class Failure extends Equatable implements Exception {
  final ErrorSource errorType;
  final ResponseCode code;
  final String message;

  const Failure(this.errorType, this.code, this.message);

  @override
  String toString() => '{errorType: $errorType, code: ${code.value}, message: $message}';

  @override
  List<Object?> get props => [errorType, code, message];
}
