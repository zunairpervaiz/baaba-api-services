import 'package:baaba_api_services/utils/error_source_extension.dart';
import 'package:baaba_api_services/utils/response_code.dart';
import 'package:equatable/equatable.dart';

/// A class for handling [Exception] in [ApiServices].
///
/// Represents a failure in an operation, typically encountered during data fetching or processing.
class Failure extends Equatable implements Exception {
  /// Error source type to handle error.
  final ErrorSource errorType;

  /// Response code from [ResponseCode].
  final ResponseCode code; // 200, 201, 400, 303..500 and so on

  /// message string which can be null.
  final String message; // error , success

  /// Constructor for creating a Failure instance with a code and message.
  const Failure(this.errorType, this.code, this.message);

  /// Overrides the toString method to provide a string representation of the Failure instance.
  @override
  String toString() {
    // Returns a string with the code and message.
    return "{errorType: $errorType, code: ${code.value}, message: $message}";
  }

  // coverage:ignore-start

  @override
  List<Object?> get props => [errorType, code, message];

  @override
  bool get stringify => true;

  // coverage:ignore-end

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Failure &&
          runtimeType == other.runtimeType &&
          errorType == other.errorType &&
          code == other.code &&
          message == other.message;

  @override
  int get hashCode => errorType.hashCode ^ code.hashCode ^ message.hashCode;
}
