import 'package:dio/dio.dart';

class NetworkRetryInterceptor extends Interceptor {
  final Dio dio;
  final int maxRetries;
  final Duration retryInterval;

  NetworkRetryInterceptor({
    required this.dio,
    this.maxRetries = 3,
    this.retryInterval = const Duration(seconds: 2),
  });

  @override
  Future onError(DioException err, ErrorInterceptorHandler handler) async {
    // only retry on network timeout or connection lost errors
    if (_shouldRetry(err)) {
      int attempt = err.requestOptions.extra['networkRetryCount'] ?? 0;

      if (attempt < maxRetries) {
        attempt++;
        err.requestOptions.extra['networkRetryCount'] = attempt;

        //backoff delay
        await Future.delayed(retryInterval * attempt);

        try {
          final response = await dio.fetch(err.requestOptions);
          return handler.resolve(response);
        } on DioException catch (e) {
          return super.onError(e, handler);
        }
      }
    }
    return super.onError(err, handler);
  }

  bool _shouldRetry(DioException err) {
    return err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.receiveTimeout ||
        err.type == DioExceptionType.sendTimeout ||
        err.type == DioExceptionType.connectionError;
  }
}
