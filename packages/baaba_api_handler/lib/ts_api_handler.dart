library;

export 'package:dio/dio.dart'
    show
        CancelToken,
        DioException,
        DioExceptionType,
        // ApiConfig.interceptors takes these, so a consumer can write one
        // without adding a direct dio dependency.
        ErrorInterceptorHandler,
        FormData,
        HttpClientAdapter,
        Interceptor,
        InterceptorsWrapper,
        MultipartFile,
        QueuedInterceptor,
        RequestInterceptorHandler,
        RequestOptions,
        Response,
        ResponseInterceptorHandler,
        // Callers pass this to get/post/... to ask for bytes or plain text
        // instead of decoded JSON, so they need to be able to name it.
        ResponseType;
// Every method returns Either, so callers need to be able to name it without
// taking a direct dependency on fpdart.
export 'package:fpdart/fpdart.dart' show Either, Left, Right;

// decodeObfuscated is @internal, re-exported for generated code only.
// ignore: invalid_export_of_internal_element
export 'annotations.dart';
export 'src/api_service.dart' show ApiServices, listParser;
export 'src/config/api_config.dart' show ApiConfig;
export 'src/config/auth_config.dart' show AuthConfig;
export 'src/config/pinning_config.dart' show PinningConfig, UnlistedHostPolicy;
export 'src/config/proxy_config.dart' show ProxyConfig;
export 'src/config/refresh_outcome.dart' show RefreshOutcome;
export 'src/config/retry_policy.dart' show RetryPolicy;
export 'src/observer/api_observer.dart' show ApiObserver;
export 'src/utils/api_log_options.dart' show ApiLogOptions;
export 'src/utils/api_exception.dart'
    show ApiException, ApiResultOrThrow, EitherOrThrow, guardApi;
export 'src/utils/base64_log_trimmer.dart' show Base64LogTrimmer;
export 'src/utils/error_source_extension.dart' show ErrorSource;
export 'src/utils/failure.dart' show Failure;
export 'src/utils/http_methods.dart' show HttpMethod, HttpMethodExtension;
export 'src/utils/jwt.dart' show jwtExpired, jwtExpiryCheck;
export 'src/utils/response_code.dart' show ResponseCode;
export 'src/utils/upload_file.dart' show UploadFile;
