import 'package:baaba_api_handler/src/utils/response_code.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Response Code Test', () {
    test('ResponseCodeExtension value getter', () {
      expect(ResponseCode.SUCCESS.value, 200);
      expect(ResponseCode.NO_CONTENT.value, 201);
      expect(ResponseCode.BAD_REQUEST.value, 400);
      expect(ResponseCode.UNAUTHORIZED.value, 401);
      expect(ResponseCode.FORBIDDEN.value, 403);
      expect(ResponseCode.NOT_FOUND.value, 404);
      expect(ResponseCode.INTERNAL_SERVER_ERROR.value, 500);
      expect(ResponseCode.CONNECT_TIMEOUT.value, -1);
      expect(ResponseCode.CANCEL.value, -2);
      expect(ResponseCode.RECEIVE_TIMEOUT.value, -3);
      expect(ResponseCode.SEND_TIMEOUT.value, -4);
      expect(ResponseCode.CACHE_ERROR.value, -5);
      expect(ResponseCode.NO_INTERNET_CONNECTION.value, -6);
      expect(ResponseCode.DEFAULT.value, -7);
      expect(ResponseCode.CONNECTION_FAILURE.value, -8);
    });

    test('mapStatusCodeToEnum', () {
      expect(mapStatusCodeToEnum(200), ResponseCode.SUCCESS);
      expect(mapStatusCodeToEnum(201), ResponseCode.NO_CONTENT);
      expect(mapStatusCodeToEnum(400), ResponseCode.BAD_REQUEST);
      expect(mapStatusCodeToEnum(401), ResponseCode.UNAUTHORIZED);
      expect(mapStatusCodeToEnum(403), ResponseCode.FORBIDDEN);
      expect(mapStatusCodeToEnum(404), ResponseCode.NOT_FOUND);
      expect(mapStatusCodeToEnum(500), ResponseCode.INTERNAL_SERVER_ERROR);
      expect(mapStatusCodeToEnum(-1), ResponseCode.CONNECT_TIMEOUT);
      expect(mapStatusCodeToEnum(-2), ResponseCode.CANCEL);
      expect(mapStatusCodeToEnum(-3), ResponseCode.RECEIVE_TIMEOUT);
      expect(mapStatusCodeToEnum(-4), ResponseCode.SEND_TIMEOUT);
      expect(mapStatusCodeToEnum(-5), ResponseCode.CACHE_ERROR);
      expect(mapStatusCodeToEnum(-6), ResponseCode.NO_INTERNET_CONNECTION);
      expect(mapStatusCodeToEnum(-7), ResponseCode.DEFAULT);
      expect(mapStatusCodeToEnum(-8), ResponseCode.CONNECTION_FAILURE);
    });
  });
}
