import 'package:baaba_api_handler/src/utils/failure.dart';
import 'package:baaba_api_handler/src/utils/response_code.dart';
import 'package:baaba_api_handler/src/utils/response_strings.dart';

enum ErrorSource {
  success,
  created,
  noContent,
  badRequest,
  forbidden,
  unauthorized,
  notFound,
  requestTimeout,
  conflict,
  unprocessableEntity,
  tooManyRequests,
  internalServerError,
  badGateway,
  connectionTimeout,
  cancel,
  receiveTimeout,
  sendTimeout,
  cacheError,
  noInternetConnection,
  connectionFailure,
  serviceNotAvailable,
  defaultError,
}

extension ErrorSourceExtension on ErrorSource {
  Failure getFailure() => switch (this) {
        ErrorSource.success =>
          Failure(this, ResponseCode.success, ResponseStrings.success),
        ErrorSource.created =>
          Failure(this, ResponseCode.created, ResponseStrings.created),
        ErrorSource.noContent =>
          Failure(this, ResponseCode.noContent, ResponseStrings.noContent),
        ErrorSource.badRequest =>
          Failure(this, ResponseCode.badRequest, ResponseStrings.badRequest),
        ErrorSource.forbidden =>
          Failure(this, ResponseCode.forbidden, ResponseStrings.forbidden),
        ErrorSource.unauthorized => Failure(
            this, ResponseCode.unauthorized, ResponseStrings.unauthorized),
        ErrorSource.notFound =>
          Failure(this, ResponseCode.notFound, ResponseStrings.notFound),
        ErrorSource.requestTimeout => Failure(
            this, ResponseCode.requestTimeout, ResponseStrings.requestTimeout),
        ErrorSource.conflict =>
          Failure(this, ResponseCode.conflict, ResponseStrings.conflict),
        ErrorSource.unprocessableEntity => Failure(
            this,
            ResponseCode.unprocessableEntity,
            ResponseStrings.unprocessableEntity),
        ErrorSource.tooManyRequests => Failure(this,
            ResponseCode.tooManyRequests, ResponseStrings.tooManyRequests),
        ErrorSource.internalServerError => Failure(
            this,
            ResponseCode.internalServerError,
            ResponseStrings.internalServerError),
        ErrorSource.badGateway =>
          Failure(this, ResponseCode.badGateway, ResponseStrings.badGateway),
        ErrorSource.connectionTimeout => Failure(
            this, ResponseCode.connectTimeout, ResponseStrings.connectTimeout),
        ErrorSource.cancel =>
          Failure(this, ResponseCode.cancel, ResponseStrings.cancel),
        ErrorSource.receiveTimeout => Failure(
            this, ResponseCode.receiveTimeout, ResponseStrings.receiveTimeout),
        ErrorSource.sendTimeout =>
          Failure(this, ResponseCode.sendTimeout, ResponseStrings.sendTimeout),
        ErrorSource.cacheError =>
          Failure(this, ResponseCode.cacheError, ResponseStrings.cacheError),
        ErrorSource.noInternetConnection => Failure(
            this,
            ResponseCode.noInternetConnection,
            ResponseStrings.noInternetConnection),
        ErrorSource.connectionFailure => Failure(this,
            ResponseCode.connectionFailure, ResponseStrings.connectionFailure),
        ErrorSource.serviceNotAvailable => Failure(
            this,
            ResponseCode.serviceNotAvailable,
            ResponseStrings.serviceNotAvailable),
        ErrorSource.defaultError => Failure(
            this, ResponseCode.defaultError, ResponseStrings.defaultError),
      };
}
