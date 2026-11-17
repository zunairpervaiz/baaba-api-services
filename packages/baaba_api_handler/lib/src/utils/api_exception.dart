import 'package:baaba_api_handler/src/api_service.dart';
import 'package:baaba_api_handler/src/utils/error_handler.dart';
import 'package:baaba_api_handler/src/utils/error_source_extension.dart';
import 'package:baaba_api_handler/src/utils/failure.dart';
import 'package:baaba_api_handler/src/utils/failure_mapper.dart';
import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';

/// A [Failure], thrown.
///
/// Every request returns `Either`, which is right for one call and clumsy
/// for a flow of several, each depending on the last: the `fold`s nest. Throw
/// out of the flow with [ApiResultOrThrow.orThrow] instead, and turn the
/// whole thing back into an `Either` at its edge with [guardApi]:
///
/// ```dart
/// Future<Either<Failure, Receipt>> checkout(Cart cart) => guardApi(() async {
///   final order = await api.postAs(endpoint: '/orders', parser: Order.fromJson,
///       data: cart.toJson()).orThrow();
///   final payment = await api.postAs(endpoint: '/orders/${order.id}/pay',
///       parser: Payment.fromJson).orThrow();
///   return api.getAs(endpoint: '/receipts/${payment.receiptId}',
///       parser: Receipt.fromJson).orThrow();
/// });
/// ```
///
/// The first failure stops the flow and becomes the result, exactly as it
/// came back from the client.
class ApiException implements Exception {
  /// The failure the request returned, unchanged.
  final Failure failure;

  const ApiException(this.failure);

  /// The literal HTTP status — see [Failure.statusCode].
  int? get statusCode => failure.statusCode;

  /// The raw response body — see [Failure.data].
  Object? get data => failure.data;

  /// The user-facing message — see [Failure.message].
  String get message => failure.message;

  /// What kind of failure it was — see [Failure.errorType].
  ErrorSource get errorType => failure.errorType;

  @override
  String toString() => 'ApiException$failure';
}

/// `orThrow()` on a request's result, for chaining calls.
extension ApiResultOrThrow<T> on Future<Either<Failure, T>> {
  /// The value on success; throws an [ApiException] carrying the [Failure]
  /// otherwise. Pair with [guardApi], which turns it back into an `Either`.
  Future<T> orThrow() async => (await this).orThrow();
}

/// `orThrow()` on a result already awaited.
extension EitherOrThrow<T> on Either<Failure, T> {
  /// The value on success; throws an [ApiException] carrying the [Failure]
  /// otherwise.
  T orThrow() =>
      fold((failure) => throw ApiException(failure), (value) => value);
}

/// Runs [body] and returns its result as an `Either`, so a flow written with
/// `orThrow()` hands its caller the same type a single request does.
///
/// - An [ApiException] becomes its [Failure], unchanged.
/// - A [Failure] thrown directly is returned as it is.
/// - A `DioException` — from Dio used directly inside the flow — becomes the
///   `Failure` the client would have built for it.
/// - Anything else becomes `ErrorSource.defaultError`. Pass [onUnexpected]
///   to report it: a `TypeError` here is a bug, not a network problem, and
///   the `Failure` alone would hide it.
///
/// The two failures built here — from a `DioException`, and the
/// `defaultError` — go through `ApiConfig.mapFailure` of the client named
/// [client] (the default client unless given), as the client's own would.
/// The other two arrive already mapped, or as the caller built them.
///
/// Never throws. An [onUnexpected] that throws is ignored.
Future<Either<Failure, T>> guardApi<T>(
  Future<T> Function() body, {
  void Function(Object error, StackTrace stackTrace)? onUnexpected,
  String client = ApiServices.defaultClient,
}) async {
  try {
    return right(await body());
  } on ApiException catch (e) {
    return left(e.failure);
  } on Failure catch (failure) {
    return left(failure);
  } on DioException catch (e) {
    return left(
      mapFailure(
        ErrorHandler.handle(e).failure.withRequest(e.requestOptions),
        ApiServices.configOf(client),
      ),
    );
  } catch (error, stackTrace) {
    try {
      onUnexpected?.call(error, stackTrace);
    } catch (_) {}
    return left(
      mapFailure(
        ErrorSource.defaultError.getFailure(),
        ApiServices.configOf(client),
      ),
    );
  }
}
