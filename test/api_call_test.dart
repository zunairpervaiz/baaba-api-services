import 'package:baaba_api_handler/src/api_service.dart';
import 'package:baaba_api_handler/src/utils/response_code.dart';
import 'package:baaba_api_handler/ts_api_handler.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mocktail/mocktail.dart';

// Define a mock class for Dio
class MockDio extends Mock implements Dio {}

void main() {
  runApiTestCases();
}

void runApiTestCases() {
  // Define a group of tests for API services
  group('API Services Test', () {
    late ApiServices apiServices;
    late MockDio mockDio;

    setUp(() {
      // Initialize the mock Dio instance and the API services
      mockDio = MockDio();
      apiServices = ApiServicesImplementation.instanceFor(dio: mockDio);
    });

    // Define a function to test HTTP methods
    void testHttpMethod(String methodName, Future<Response> Function(String) mockFunction) {
      // Define a test case for each HTTP method
      test("Test $methodName request", () async {
        // Prepare a mock response
        final response = Response(requestOptions: RequestOptions(baseUrl: "https://example.com"), statusCode: 200);
        // Set up the mock function to return the mock response
        when(() => mockFunction(any())).thenAnswer((_) async => response);

        late final Either<Failure, Response<dynamic>> result;

        // Execute the corresponding API method based on the HTTP method

        switch (methodName) {
          case "GET":
            result = await apiServices.get(endpoint: '/getUser');
            break;
          case "POST":
            result = await apiServices.post(endpoint: '/signup');
            break;
          case "PUT":
            result = await apiServices.put(endpoint: '/update');
            break;
          case "PATCH":
            result = await apiServices.patch(endpoint: '/update');
            break;
          case "DELETE":
            result = await apiServices.delete(endpoint: '/delete');
            break;
        }
        // Assert that the result is of type Either<Failure, Response>
        expect(result, isA<Either<Failure, Response>>());
      });
    }

    // Test each HTTP method using the testHttpMethod function

    testHttpMethod("GET", (endPoint) => mockDio.get(endPoint));
    testHttpMethod("POST", (endPoint) => mockDio.post(endPoint));
    testHttpMethod("PUT", (endPoint) => mockDio.put(endPoint));
    testHttpMethod("PATCH", (endPoint) => mockDio.patch(endPoint));
    testHttpMethod("DELETE", (endPoint) => mockDio.delete(endPoint));
  });

  group('table-driven tests', () {
    final testCases = {
      ResponseCode.SUCCESS: ErrorSource.success,
      ResponseCode.NO_CONTENT: ErrorSource.no_content,
      ResponseCode.BAD_REQUEST: ErrorSource.bad_request,
      ResponseCode.UNAUTHORIZED: ErrorSource.unauthorised,
      ResponseCode.FORBIDDEN: ErrorSource.forbidden,
      ResponseCode.INTERNAL_SERVER_ERROR: ErrorSource.internal_server_error,
      ResponseCode.NOT_FOUND: ErrorSource.not_found,
      ResponseCode.CONNECT_TIMEOUT: ErrorSource.connection_timeout,
      ResponseCode.CANCEL: ErrorSource.cancel,
      ResponseCode.RECEIVE_TIMEOUT: ErrorSource.receive_timeout,
      ResponseCode.SEND_TIMEOUT: ErrorSource.send_timeout,
      ResponseCode.CACHE_ERROR: ErrorSource.cache_error,
      ResponseCode.NO_INTERNET_CONNECTION: ErrorSource.no_internet_connection,
      ResponseCode.DEFAULT: ErrorSource.default_error,
      ResponseCode.CONNECTION_FAILURE: ErrorSource.connection_failure,
    };

    testCases.forEach((responseCode, expectedErrorSource) {
      test('should map $responseCode to $expectedErrorSource', () {
        expect(mapResponseCodeToEnum(responseCode), equals(expectedErrorSource));
      });
    });
  });
}
