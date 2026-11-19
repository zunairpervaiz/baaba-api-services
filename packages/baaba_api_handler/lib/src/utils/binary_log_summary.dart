import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Stands in for binary bodies in what the logger prints.
///
/// A photo or PDF fetched with `ResponseType.bytes` arrives as a `List<int>`,
/// which the logger would print number by number — hundreds of thousands of
/// console lines for one image, burying every request around it. The logger
/// gets `<48213 bytes, image/png>` instead.
///
/// Works on copies, like the redactor: the caller still gets the bytes.
abstract final class BinaryLogSummary {
  /// [options] with a binary body replaced by its summary, or [options]
  /// itself when the body is not binary.
  ///
  /// Only typed data (`Uint8List` and the like) counts as binary in a
  /// request: a plain `List<int>` may be a JSON array the caller sends.
  ///
  /// The copy shares [RequestOptions.extra] with the original: the logger
  /// stamps the request's start time there and reads it back off the
  /// response, which carries the original options.
  static RequestOptions request(RequestOptions options) {
    final data = options.data;
    if (data is! TypedData) return options;
    return options.copyWith(
      data: describe(data.lengthInBytes, options.contentType),
      extra: options.extra,
    );
  }

  /// [response] with a binary body replaced by its summary, and its
  /// request's too, or [response] itself when neither is binary.
  ///
  /// A response body is binary when it is typed data, or a `List<int>`
  /// asked for with `ResponseType.bytes`.
  static Response<dynamic> response(Response<dynamic> response) {
    final options = request(response.requestOptions);
    final data = response.data;
    final int? length = data is TypedData
        ? data.lengthInBytes
        : data is List<int> &&
              response.requestOptions.responseType == ResponseType.bytes
        ? data.length
        : null;
    if (length == null && identical(options, response.requestOptions)) {
      return response;
    }
    return Response<dynamic>(
      data: length == null
          ? data
          : describe(length, response.headers.value(Headers.contentTypeHeader)),
      requestOptions: options,
      statusCode: response.statusCode,
      statusMessage: response.statusMessage,
      isRedirect: response.isRedirect,
      redirects: response.redirects,
      extra: response.extra,
      headers: response.headers,
    );
  }

  /// [error] with binary bodies in its request and response summarized —
  /// a server that answers a failed download with bytes still logs briefly.
  static DioException error(DioException error) {
    final options = request(error.requestOptions);
    final original = error.response;
    final summarized = original == null ? null : response(original);
    if (identical(options, error.requestOptions) &&
        identical(summarized, original)) {
      return error;
    }
    return error.copyWith(requestOptions: options, response: summarized);
  }

  /// `<48213 bytes, image/png>`, or `<48213 bytes>` without a content type.
  static String describe(int length, String? contentType) {
    final type = contentType?.split(';').first.trim();
    return type == null || type.isEmpty
        ? '<$length bytes>'
        : '<$length bytes, $type>';
  }
}
