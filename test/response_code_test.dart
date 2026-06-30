import 'package:baaba_api_handler/src/utils/response_code.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ResponseCode', () {
    test('value getter returns correct integer for each code', () {
      expect(ResponseCode.success.value, 200);
      expect(ResponseCode.created.value, 201);
      expect(ResponseCode.noContent.value, 204);
      expect(ResponseCode.badRequest.value, 400);
      expect(ResponseCode.unauthorized.value, 401);
      expect(ResponseCode.forbidden.value, 403);
      expect(ResponseCode.notFound.value, 404);
      expect(ResponseCode.internalServerError.value, 500);
      expect(ResponseCode.connectTimeout.value, -1);
      expect(ResponseCode.cancel.value, -2);
      expect(ResponseCode.receiveTimeout.value, -3);
      expect(ResponseCode.sendTimeout.value, -4);
      expect(ResponseCode.cacheError.value, -5);
      expect(ResponseCode.noInternetConnection.value, -6);
      expect(ResponseCode.defaultError.value, -7);
      expect(ResponseCode.connectionFailure.value, -8);
    });

    test('mapStatusCodeToEnum maps integers to the correct ResponseCode', () {
      expect(mapStatusCodeToEnum(200), ResponseCode.success);
      expect(mapStatusCodeToEnum(201), ResponseCode.created);
      expect(mapStatusCodeToEnum(204), ResponseCode.noContent);
      expect(mapStatusCodeToEnum(400), ResponseCode.badRequest);
      expect(mapStatusCodeToEnum(401), ResponseCode.unauthorized);
      expect(mapStatusCodeToEnum(403), ResponseCode.forbidden);
      expect(mapStatusCodeToEnum(404), ResponseCode.notFound);
      expect(mapStatusCodeToEnum(500), ResponseCode.internalServerError);
      expect(mapStatusCodeToEnum(-1), ResponseCode.connectTimeout);
      expect(mapStatusCodeToEnum(-2), ResponseCode.cancel);
      expect(mapStatusCodeToEnum(-3), ResponseCode.receiveTimeout);
      expect(mapStatusCodeToEnum(-4), ResponseCode.sendTimeout);
      expect(mapStatusCodeToEnum(-5), ResponseCode.cacheError);
      expect(mapStatusCodeToEnum(-6), ResponseCode.noInternetConnection);
      expect(mapStatusCodeToEnum(-7), ResponseCode.defaultError);
      expect(mapStatusCodeToEnum(-8), ResponseCode.connectionFailure);
      expect(mapStatusCodeToEnum(9999), ResponseCode.defaultError);
    });
  });
}
