import 'package:baaba_api_services/dio_factory.dart';
import 'package:baaba_api_services/utils/constants.dart';
import 'package:baaba_api_services/utils/error_handler.dart';
import 'package:baaba_api_services/utils/error_source_extension.dart';
import 'package:baaba_api_services/utils/failure.dart';
import 'package:baaba_api_services/utils/http_methods.dart';
import 'package:baaba_api_services/utils/network_info.dart';
import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';

/// A class responsible for handling various API services.
abstract interface class ApiServices {
  /// Sends a GET request to the specified [endpoint].
  ///
  /// Parameters:
  ///
  /// - `endPoint`: URL endpoint of the API.
  /// - `data`: Request body data (optional).
  /// - `params`: Query parameters for the request (optional).
  /// - `receiveTimeout`: Duration for the receive timeout (optional).
  /// - `sendTimeout`: Duration for the send timeout (optional).
  /// - `headers`: Custom headers for the request (optional).
  ///
  /// Returns an [Either] containing a [Failure] on error and a [Response] on success.
  Future<Either<Failure, Response>> get({
    required String endpoint,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  });

  /// Sends a POST request to the specified [endpoint].
  ///
  /// Parameters:
  ///
  /// - `endPoint`: URL endpoint of the API.
  /// - `data`: Request body data (optional).
  /// - `params`: Query parameters for the request (optional).
  /// - `receiveTimeout`: Duration for the receive timeout (optional).
  /// - `sendTimeout`: Duration for the send timeout (optional).
  /// - `headers`: Custom headers for the request (optional).
  ///
  /// Returns an [Either] containing a [Failure] on error and a [Response] on success.
  Future<Either<Failure, Response>> post({
    required String endpoint,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  });

  /// Sends a PUT request to the specified [endpoint].
  ///
  /// Parameters:
  ///
  /// - `endPoint`: URL endpoint of the API.
  /// - `receiveTimeout`: Duration for the receive timeout (optional).
  /// - `sendTimeout`: Duration for the send timeout (optional).
  /// - `headers`: Custom headers for the request (optional).
  ///
  /// Returns an [Either] containing a [Failure] on error and a [Response] on success.
  Future<Either<Failure, Response>> put({
    required String endpoint,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  });

  /// Sends a DELETE request to the specified [endpoint].
  ///
  /// Parameters:
  ///
  /// `endpoint`: URL endpoint of the API.
  /// `receiveTimeout`: Duration for the receive timeout (optional).
  /// `sendTimeout`: Duration for the send timeout (optional).
  /// `headers`: Custom headers for the request (optional).
  ///
  /// Returns an [Either] containing a [Failure] on error and a [Response] on success.
  Future<Either<Failure, Response>> delete({
    required String endpoint,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  });

  /// Sends a PATCH request to the specified [endpoint].
  ///
  /// Parameters:
  ///
  /// - `endPoint`: URL endpoint of the API.
  /// - `receiveTimeout`: Duration for the receive timeout (optional).
  /// - `sendTimeout`: Duration for the send timeout (optional).
  /// - `headers`: Custom headers for the request (optional).
  ///
  /// Returns an [Either] containing a [Failure] on error and a [Response] on success.
  Future<Either<Failure, Response>> patch({
    required String endpoint,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  });

  /// Sends a MULTIPART request to the specified [endpoint].
  ///
  /// Parameters:
  ///
  /// - `endPoint`: URL endpoint of the API.
  /// - `receiveTimeout`: Duration for the receive timeout (optional).
  /// - `sendTimeout`: Duration for the send timeout (optional).
  /// - `headers`: Custom headers for the request (optional).
  ///
  /// Returns an [Either] containing a [Failure] on error and a [Response] on success.
  Future<Either<Failure, Response>> patch({
    required String endpoint,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  });

  /// Method to cancel the ongoing request.
  ///
  /// [cancellationReason]: Optional parameter specifying the reason for cancellation.
  void cancelRequest({String cancellationReason = ''});
}

class ApiServicesImplementation implements ApiServices {
  late final Dio _dio; // Instance of Dio for making HTTP requests
  final NetworkInfo _networkInfo = NetworkInfo(); // Network information utility

  // Default headers for HTTP requests
  final Map<String, String> _defaultHeader = {contentType: applicationJson, accept: applicationJson, authorization: token};

  // Define a CancelToken instance
  CancelToken? _cancelToken;

  /// This is a private field that holds the singleton instance of the ApiServices class.
  static ApiServices? _instance;

  /// This getter provides access to the singleton instance of ApiServices.
  /// If the _instance field is null, it creates a new instance of ApiServices using the instanceFor factory method,
  /// and assigns it to the _instance field. It uses a Dio instance from DioFactory().getDio() to initialize the ApiServices instance.

  //coverage:ignore-start
  static ApiServices instance([Dio? dio]) {
    _instance ??= ApiServicesImplementation.instanceFor(dio: dio ?? DioFactory().getDio());
    return _instance!;
  }
  //coverage:ignore-end

  /// This is a private constructor for the ApiServices class.
  /// It accepts a required Dio instance and an optional CancelToken instance as parameters.
  /// It initializes the _dio and _cancelToken fields with the provided parameters.
  ApiServicesImplementation._({required Dio dio, CancelToken? cancelToken}) : _dio = dio, _cancelToken = cancelToken;

  /// This factory method creates an instance of ApiServices using the provided Dio and optional CancelToken instances.
  /// It calls the private constructor to create the new instance.
  factory ApiServicesImplementation.instanceFor({required Dio dio, CancelToken? cancelToken}) {
    return ApiServicesImplementation._(dio: dio, cancelToken: cancelToken);
  }

  /// Sends an HTTP request with the provided parameters.
  ///
  /// [method]: HTTP method (GET, POST, PUT, DELETE, PATCH).
  /// [endPoint]: URL endpoint of the API.
  /// [data]: Request body data.
  /// [params]: Query parameters for the request.
  /// [receiveTimeout]: Duration for the receive timeout.
  /// [sendTimeout]: Duration for the send timeout.
  /// [headers]: Custom headers for the request. If not provided, default headers will be used.
  ///
  /// Returns an [Either] containing a [Failure] on error and a [Response] on success.

  Future<Either<Failure, Response>> _sendRequest(
    HttpMethod method, {
    required String endpoint,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    // Check if the device is connected to the internet
    final isConnected = await _networkInfo.isConnected ?? false;
    if (isConnected) {
      try {
        _cancelToken = cancelToken ?? CancelToken();
        // Send the HTTP request using Dio
        final response = await _dio.request(
          endpoint,
          data: data,
          queryParameters: params,
          options: Options(
            method: method.value,
            receiveTimeout: receiveTimeout,
            sendTimeout: sendTimeout,
            headers: headers ?? _defaultHeader, // Use custom headers if provided, otherwise use default headers
          ),
          cancelToken: _cancelToken,
          onSendProgress: onSendProgress,
          onReceiveProgress: onReceiveProgress,
        );
        // coverage:ignore-start
        return right(response); // Return successful response
        // coverage:ignore-end
      } catch (e) {
        return left(ErrorHandler.handle(e).failure); // Return failure with error message
      }
    } else {
      // coverage:ignore-start
      return left(ErrorSource.no_internet_connection.getFailure()); // Return failure for no internet connection
      // coverage:ignore-end
    }
  }

  @override
  Future<Either<Failure, Response>> get({
    required String endpoint,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    // Delegate the request to the _sendRequest method with HTTP method GET

    return await _sendRequest(
      HttpMethod.get,
      endpoint: endpoint,
      data: data,
      params: params,
      receiveTimeout: receiveTimeout,
      sendTimeout: sendTimeout,
      headers: headers,
      onSendProgress: onSendProgress,
      onReceiveProgress: onReceiveProgress,
      cancelToken: cancelToken,
    );
  }

  @override
  Future<Either<Failure, Response>> post({
    required String endpoint,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    // Delegate the request to the _sendRequest method with HTTP method POST
    return await _sendRequest(
      HttpMethod.post,
      endpoint: endpoint,
      data: data,
      params: params,
      receiveTimeout: receiveTimeout,
      sendTimeout: sendTimeout,
      headers: headers,
      onSendProgress: onSendProgress,
      onReceiveProgress: onReceiveProgress,
      cancelToken: cancelToken,
    );
  }

  @override
  Future<Either<Failure, Response>> put({
    required String endpoint,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    // Delegate the request to the _sendRequest method with HTTP method PUT
    return await _sendRequest(
      HttpMethod.put,
      data: data,
      params: params,
      endpoint: endpoint,
      receiveTimeout: receiveTimeout,
      sendTimeout: sendTimeout,
      headers: headers,
      onSendProgress: onSendProgress,
      onReceiveProgress: onReceiveProgress,
      cancelToken: cancelToken,
    );
  }

  @override
  Future<Either<Failure, Response>> delete({
    required String endpoint,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    // Delegate the request to the _sendRequest method with HTTP method DELETE
    return await _sendRequest(
      HttpMethod.delete,
      data: data,
      params: params,
      endpoint: endpoint,
      receiveTimeout: receiveTimeout,
      sendTimeout: sendTimeout,
      headers: headers,
      onSendProgress: onSendProgress,
      onReceiveProgress: onReceiveProgress,
      cancelToken: cancelToken,
    );
  }

  @override
  Future<Either<Failure, Response>> patch({
    required String endpoint,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    // Delegate the request to the _sendRequest method with HTTP method PATCH
    return await _sendRequest(
      HttpMethod.patch,
      data: data,
      params: params,
      endpoint: endpoint,
      receiveTimeout: receiveTimeout,
      sendTimeout: sendTimeout,
      headers: headers,
      onSendProgress: onSendProgress,
      onReceiveProgress: onReceiveProgress,
      cancelToken: cancelToken,
    );
  }

  @override
Future<Either<Failure, Response>> postMultipart({
  required String endpoint,
  required Map<String, dynamic> data,
  Map<String, dynamic>? params,
  Duration? receiveTimeout,
  Duration? sendTimeout,
  Map<String, String>? headers,
  ProgressCallback? onSendProgress,
  ProgressCallback? onReceiveProgress,
  CancelToken? cancelToken,
}) async {
  final Map<String, dynamic> formDataMap = {};

  for (var entry in data.entries) {
    final value = entry.value;

    if (value == null) {
      formDataMap[entry.key] = "null";
    } 
    // Handle single File
    else if (value is File) {
      formDataMap[entry.key] = await _mapFileToMultipart(value);
    }
    // Handle List of Files (including RxList from GetX)
    else if (value is Iterable) {
      final List<MultipartFile> multipartFiles = [];
      for (var item in value) {
        if (item is File) {
          multipartFiles.add(await _mapFileToMultipart(item));
        }
      }
      formDataMap[entry.key] = multipartFiles;
    } 
    // Regular text fields
    else {
      formDataMap[entry.key] = value.toString();
    }
  }

  final formData = FormData.fromMap(formDataMap);

  return await _sendRequest(
    HttpMethod.post,
    endpoint: endpoint,
    data: formData,
    params: params,
    receiveTimeout: receiveTimeout,
    sendTimeout: sendTimeout,
    headers: headers,
    onSendProgress: onSendProgress,
    onReceiveProgress: onReceiveProgress,
    cancelToken: cancelToken,
  );
}

/// Helper method to convert a File to a Dio MultipartFile with correct MediaType
Future<MultipartFile> _mapFileToMultipart(File file) async {
  String fileName = file.path.split('/').last;
  String extension = fileName.split('.').last.toLowerCase();
  
  MediaType contentType;
  if (['mp4', 'mov', 'avi'].contains(extension)) {
    contentType = MediaType('video', extension);
  } else {
    contentType = MediaType('image', extension == 'png' ? 'png' : 'jpeg');
  }

  return await MultipartFile.fromFile(
    file.path,
    filename: fileName,
    contentType: contentType,
  );
}

  @override
  void cancelRequest({String cancellationReason = ''}) async {
    _cancelToken?.cancel(cancellationReason); // Provide a cancellation reason
  }
}
