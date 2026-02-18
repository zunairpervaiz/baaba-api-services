import 'package:baaba_api_handler/src/utils/error_handler.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ErrorHandler', () {
    test('handles DioException with connection timeout', () {
      final error = DioException(
        type: DioExceptionType.connectionTimeout,
        requestOptions: RequestOptions(path: '/test'),
      );
      final errorHandler = ErrorHandler.handle(error);
      expect(errorHandler, isA<ErrorHandler>());
    });

    test('handles DioException with send timeout', () {
      final error = DioException(
        type: DioExceptionType.sendTimeout,
        requestOptions: RequestOptions(path: '/test'),
      );
      final errorHandler = ErrorHandler.handle(error);
      expect(errorHandler, isA<ErrorHandler>());
    });

    test('handles DioException with receive timeout', () {
      final error = DioException(
        type: DioExceptionType.receiveTimeout,
        requestOptions: RequestOptions(path: '/test'),
      );
      final errorHandler = ErrorHandler.handle(error);
      expect(errorHandler, isA<ErrorHandler>());
    });

    test('handles DioException with bad response containing message', () {
      final response = Response(
        statusCode: 400,
        data: {'message': 'Bad request'},
        requestOptions: RequestOptions(path: '/test'),
      );
      final error = DioException(
        type: DioExceptionType.badResponse,
        response: response,
        requestOptions: RequestOptions(path: '/test'),
      );
      final errorHandler = ErrorHandler.handle(error);
      expect(errorHandler, isA<ErrorHandler>());
    });

    test('handles DioException with bad response containing error', () {
      final response = Response(
        statusCode: 400,
        data: {'error': 'Bad request'},
        requestOptions: RequestOptions(path: '/test'),
      );
      final error = DioException(
        type: DioExceptionType.badResponse,
        response: response,
        requestOptions: RequestOptions(path: '/test'),
      );
      final errorHandler = ErrorHandler.handle(error);
      expect(errorHandler, isA<ErrorHandler>());
    });

    test('handles DioException with cancel', () {
      final error = DioException(
        type: DioExceptionType.cancel,
        requestOptions: RequestOptions(path: '/test'),
      );
      final errorHandler = ErrorHandler.handle(error);
      expect(errorHandler, isA<ErrorHandler>());
    });

    test('handles DioException with connection error', () {
      final error = DioException(
        type: DioExceptionType.unknown,
        error: 'Connection error',
        requestOptions: RequestOptions(path: '/test'),
      );
      final errorHandler = ErrorHandler.handle(error);
      expect(errorHandler, isA<ErrorHandler>());
    });

    test('handles default DioException', () {
      final error = DioException(
        type: DioExceptionType.unknown,
        requestOptions: RequestOptions(path: '/test'),
      );
      final errorHandler = ErrorHandler.handle(error);
      expect(errorHandler, isA<ErrorHandler>());
    });
  });

  group('_handleError', () {
    test('handles DioException with bad response without message or error', () {
      final error = DioException(
        type: DioExceptionType.badResponse,
        response: Response(
          statusCode: 400,
          data: {},
          requestOptions: RequestOptions(path: '/test'),
        ),
        requestOptions: RequestOptions(path: '/test'),
      );
      final failure = ErrorHandler.handle(error);
      expect(failure, isA<ErrorHandler>());
    });

    test('handles DioException with null response', () {
      final error = DioException(
        type: DioExceptionType.badResponse,
        requestOptions: RequestOptions(path: '/test'),
      );
      final failure = ErrorHandler.handle(error);
      expect(failure, isA<ErrorHandler>());
    });

    test('handles DioException with null response status code', () {
      final error = DioException(
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/test'),
        ),
        requestOptions: RequestOptions(path: '/test'),
      );
      final failure = ErrorHandler.handle(error);
      expect(failure, isA<ErrorHandler>());
    });
  });
}
