import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pretty_dio_logger/pretty_dio_logger.dart';

class DioFactory {
  // Method to get a configured Dio instance
  Dio getDio({
    Map<String, String>? header, // Optional parameter: custom headers
    Duration? receivedTimeout, // Optional parameter: receive timeout
    Duration? sendTimeout, // Optional parameter: send timeout
  }) {
    Dio dio = Dio(); // Create a new Dio instance

    // Configure Dio options
    dio.options = BaseOptions(
      headers: header, // Set custom headers
      receiveTimeout: receivedTimeout, // Set receive timeout
      sendTimeout: sendTimeout, // Set send timeout
    );

    // Add PrettyDioLogger interceptor for debugging in non-release mode
    if (!kReleaseMode) {
      dio.interceptors.add(
        PrettyDioLogger(
          requestHeader: false, // Do not log request headers
          responseHeader: false, // Do not log response headers
          request: false, // Do not log request information
          requestBody: true, // Log request body
          responseBody: true, // Log response body
          error: true, // Log errors
        ),
      );
    }

    // Return the configured Dio instance
    return dio;
  }
}
