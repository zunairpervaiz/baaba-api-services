// ignore_for_file: constant_identifier_names

enum HttpMethod {
  get,
  post,
  put,
  delete,
  patch,
}

extension HttpMethodExtension on HttpMethod {
  // Retrieves the string value of the HTTP method.
  String get value {
    return name.toUpperCase();
  }
}
