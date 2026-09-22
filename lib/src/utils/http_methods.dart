// ignore_for_file: constant_identifier_names

enum HttpMethod {
  get,
  post,
  put,
  delete,
  patch,

  /// Like [get], but the server returns headers only and no body. Idempotent,
  /// so it is covered by `RetryPolicy.idempotentMethods`.
  head,

  /// Asks the server which methods and CORS rules apply to a resource.
  /// Idempotent, so it is covered by `RetryPolicy.idempotentMethods`.
  options,
}

extension HttpMethodExtension on HttpMethod {
  // Retrieves the string value of the HTTP method.
  String get value {
    return name.toUpperCase();
  }
}
