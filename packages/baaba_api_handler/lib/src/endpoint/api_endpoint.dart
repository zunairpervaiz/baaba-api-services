/// An endpoint path, optionally with `{}` placeholders filled in order.
///
/// Apps often keep endpoint paths out of the code — in `.env` files read
/// through `envied`, say, where the generated class decodes obfuscated values
/// at runtime. A path with parameters then has to be a template, and every
/// app ends up hand-writing a wrapper per endpoint to fill it. Wrap the value
/// once instead:
///
/// ```dart
/// // In the .env file:  ORDER_ATTACHMENT=orders/{}/attachments/{}
/// abstract final class Endpoints {
///   static final orderAttachment = ApiEndpoint(Env.orderAttachment);
/// }
///
/// await api.get(endpoint: Endpoints.orderAttachment.fill([orderId, fileId]));
/// ```
///
/// An extension type over `String`, so it costs nothing at runtime and goes
/// anywhere a `String` endpoint does — no method had to change to accept it.
///
/// Joining with `ApiConfig.baseUrl` neither doubles nor drops a slash, and an
/// absolute endpoint (`https://...`) bypasses `baseUrl` entirely, as any
/// absolute endpoint does.
extension type const ApiEndpoint(String path) implements String {
  static const String _placeholder = '{}';

  /// How many `{}` placeholders [path] has.
  int get placeholderCount => _placeholder.allMatches(path).length;

  /// Returns the endpoint with each `{}` replaced by the next of [args], in
  /// order.
  ///
  /// Every argument is URL-encoded as a single path segment, so a `/`, `?` or
  /// `#` inside an id stays part of that id rather than reshaping the URL:
  ///
  /// ```dart
  /// const ApiEndpoint('files/{}').fill(['a/b c']); // files/a%2Fb%20c
  /// ```
  ///
  /// Throws an [ArgumentError] when the number of [args] differs from
  /// [placeholderCount], or when an argument would not survive as a segment:
  /// an empty string (its slashes would be collapsed, silently addressing a
  /// different resource) or `.`/`..` (resolved away as a relative path).
  ApiEndpoint fill(List<Object> args) {
    final expected = placeholderCount;
    if (args.length != expected) {
      throw ArgumentError.value(
        args,
        'args',
        '"$path" has $expected placeholder${expected == 1 ? '' : 's'}, '
            'but ${args.length} argument${args.length == 1 ? ' was' : 's were'} '
            'given',
      );
    }
    if (expected == 0) return this;

    var index = 0;
    return ApiEndpoint(
      path.replaceAllMapped(_placeholder, (_) => _segment(args[index++])),
    );
  }

  static String _segment(Object arg) {
    final raw = arg.toString();
    // A dot segment survives percent-encoding — `%2E` is an unreserved
    // character, which URI normalisation decodes back — and is then resolved
    // away: `orders/../attachments`.
    if (raw.isEmpty || raw == '.' || raw == '..') {
      throw ArgumentError.value(
        arg,
        'args',
        'cannot be used as a path segment',
      );
    }
    return Uri.encodeComponent(raw);
  }
}
