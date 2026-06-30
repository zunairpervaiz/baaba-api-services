import 'package:baaba_api_handler/src/utils/error_source_extension.dart';

enum ResponseCode {
  success(200),
  created(201),
  noContent(204),
  badRequest(400),
  unauthorized(401),
  forbidden(403),
  notFound(404),
  requestTimeout(408),
  conflict(409),
  unprocessableEntity(422),
  tooManyRequests(429),
  internalServerError(500),
  badGateway(502),
  serviceNotAvailable(503),
  connectTimeout(-1),
  cancel(-2),
  receiveTimeout(-3),
  sendTimeout(-4),
  cacheError(-5),
  noInternetConnection(-6),
  defaultError(-7),
  connectionFailure(-8);

  const ResponseCode(this.value);
  final int value;
}

final _statusCodeMap = Map<int, ResponseCode>.unmodifiable({
  for (final rc in ResponseCode.values) rc.value: rc,
});

ResponseCode mapStatusCodeToEnum(int statusCode) =>
    _statusCodeMap[statusCode] ?? ResponseCode.defaultError;

ErrorSource mapResponseCodeToEnum(ResponseCode code) => switch (code) {
      ResponseCode.success => ErrorSource.success,
      ResponseCode.created => ErrorSource.created,
      ResponseCode.noContent => ErrorSource.noContent,
      ResponseCode.badRequest => ErrorSource.badRequest,
      ResponseCode.unauthorized => ErrorSource.unauthorized,
      ResponseCode.forbidden => ErrorSource.forbidden,
      ResponseCode.internalServerError => ErrorSource.internalServerError,
      ResponseCode.notFound => ErrorSource.notFound,
      ResponseCode.requestTimeout => ErrorSource.requestTimeout,
      ResponseCode.conflict => ErrorSource.conflict,
      ResponseCode.unprocessableEntity => ErrorSource.unprocessableEntity,
      ResponseCode.tooManyRequests => ErrorSource.tooManyRequests,
      ResponseCode.badGateway => ErrorSource.badGateway,
      ResponseCode.connectTimeout => ErrorSource.connectionTimeout,
      ResponseCode.cancel => ErrorSource.cancel,
      ResponseCode.receiveTimeout => ErrorSource.receiveTimeout,
      ResponseCode.sendTimeout => ErrorSource.sendTimeout,
      ResponseCode.cacheError => ErrorSource.cacheError,
      ResponseCode.noInternetConnection => ErrorSource.noInternetConnection,
      ResponseCode.serviceNotAvailable => ErrorSource.serviceNotAvailable,
      ResponseCode.defaultError => ErrorSource.defaultError,
      ResponseCode.connectionFailure => ErrorSource.connectionFailure,
    };
