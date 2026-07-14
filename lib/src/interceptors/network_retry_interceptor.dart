import 'package:dio/dio.dart';

class NetworkRetryInterceptor extends Interceptor {
  // GET/HEAD/OPTIONS/PUT/DELETE are safe to retry blindly — repeating them has
  // the same effect as the original call. POST/PATCH are not: if the server
  // already processed the request before the timeout, an automatic retry can
  // duplicate the side effect (e.g. creating the same order twice).
  static const Set<String> _idempotentMethods = {
    'GET',
    'HEAD',
    'OPTIONS',
    'PUT',
    'DELETE',
  };

  final Dio dio;
  final int maxRetries;
  final Duration retryInterval;

  NetworkRetryInterceptor({
    required this.dio,
    this.maxRetries = 3,
    this.retryInterval = const Duration(seconds: 2),
  });

  @override
  Future<void> onError(
      DioException err, ErrorInterceptorHandler handler) async {
    if (!_shouldRetry(err)) {
      return handler.next(err);
    }

    int attempt = err.requestOptions.extra['networkRetryCount'] ?? 0;
    if (attempt >= maxRetries) {
      return handler.next(err);
    }

    attempt++;
    err.requestOptions.extra['networkRetryCount'] = attempt;
    await Future.delayed(retryInterval * attempt);

    try {
      final response = await dio.fetch(err.requestOptions);
      return handler.resolve(response);
    } catch (e) {
      return handler.next(
        e is DioException
            ? e
            : DioException(
                requestOptions: err.requestOptions,
                error: e,
                type: DioExceptionType.unknown,
              ),
      );
    }
  }

  bool _shouldRetry(DioException err) {
    final isTransientError = err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.receiveTimeout ||
        err.type == DioExceptionType.sendTimeout ||
        err.type == DioExceptionType.connectionError;
    if (!isTransientError) return false;

    return _idempotentMethods.contains(
      err.requestOptions.method.toUpperCase(),
    );
  }
}
