library;

export 'package:api_cache_manager/models/cache_db_model.dart'
    show APICacheDBModel;
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

export 'src/api_cache_helper.dart' show ApiCacheHelper;
export 'src/api_service.dart' show ApiServices, listParser;
export 'src/config/api_config.dart' show ApiConfig;
export 'src/config/auth_config.dart' show AuthConfig;
export 'src/config/cache_policy.dart' show CachePolicy;
export 'src/config/retry_policy.dart' show RetryPolicy;
export 'src/observer/api_observer.dart' show ApiObserver;
export 'src/utils/api_log_options.dart' show ApiLogOptions;
export 'src/utils/base64_log_trimmer.dart' show Base64LogTrimmer;
export 'src/utils/error_source_extension.dart' show ErrorSource;
export 'src/utils/failure.dart' show Failure;
export 'src/utils/http_methods.dart' show HttpMethod, HttpMethodExtension;
export 'src/utils/response_code.dart' show ResponseCode;
export 'src/utils/response_extensions.dart' show CachedResponse;
export 'src/utils/upload_file.dart' show UploadFile;
