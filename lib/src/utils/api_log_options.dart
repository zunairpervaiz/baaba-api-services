/// Controls what the console logger prints for each request.
///
/// The logger is only attached in non-release builds — in release nothing is
/// logged regardless of what you set here.
///
/// Pass an instance to `ApiServices.init(ApiConfig(logging: ...))`. The
/// defaults match the package's previous behaviour: request line, request
/// body, response body, and errors.
///
/// **Example — quiet logs, headers only when debugging auth:**
///
/// ```dart
/// ApiServices.init(const ApiConfig(
///   logging: ApiLogOptions(
///     requestBody: false,   // don't print passwords / PII
///     requestHeader: true,  // but do show the Authorization header
///     responseBody: false,  // responses are large
///   ),
/// ));
/// ```
///
/// **Example — an API that returns base64 images inline:**
///
/// ```dart
/// ApiServices.init(const ApiConfig(
///   logging: ApiLogOptions(requestBody: false, trimBase64: true),
/// ));
/// ```
///
/// See [trimBase64]. [logPrint] is a sink rather than a switch — every line
/// passes through it before reaching the console — so you can also rewrite
/// the stream yourself instead of losing the body.
///
/// **Example — silence logging entirely:**
///
/// ```dart
/// ApiServices.init(const ApiConfig(logging: ApiLogOptions.disabled()));
/// ```
class ApiLogOptions {
  /// Master switch. When `false` no logger is attached at all and every other
  /// field is ignored.
  final bool enabled;

  /// Print the request line (method + URL).
  final bool request;

  /// Print request headers and query parameters.
  ///
  /// Includes the `Authorization` header — leave off unless you're debugging
  /// auth.
  final bool requestHeader;

  /// Print the request body.
  ///
  /// Turn off for apps that send credentials or PII in request bodies.
  /// Bodies are never printed for `GET` requests regardless of this flag.
  final bool requestBody;

  /// Print response headers.
  final bool responseHeader;

  /// Print the response body.
  final bool responseBody;

  /// Print errors (`DioException`s, including non-2xx responses).
  final bool error;

  /// Line width before the logger wraps. Defaults to 90 characters.
  final int maxWidth;

  /// Print JSON in compact form rather than one node per line.
  final bool compact;

  /// Collapse base64 blobs in the output instead of printing them in full.
  ///
  /// The logger wraps every value at [maxWidth] and emits one line per 78-odd
  /// characters, so a response carrying photographs or fingerprints as base64
  /// becomes tens of thousands of console lines and buries the request that
  /// caused it. With this on, a blob prints as a recognisable head plus a
  /// count:
  ///
  /// ```
  /// ║      "data": iVBORw0KGgoAAAANSUhEUg…
  /// ║      …[412903 base64 chars elided]
  /// ```
  ///
  /// Everything else passes through byte for byte — a `detail` string, a case
  /// number, a stack trace all read exactly as they did. Off by default,
  /// because it rewrites the log stream and that should be a choice.
  ///
  /// Composes with [logPrint]: the trimmer sits in front, so a custom sink
  /// receives lines that are already trimmed. For tuning, construct a
  /// [Base64LogTrimmer] and pass it as [logPrint] instead.
  final bool trimBase64;

  /// Where log lines go. Defaults to `print`.
  ///
  /// Use this to route logs somewhere other than the console — `debugPrint`
  /// to avoid Android's log truncation, or your own crash reporter / file sink:
  ///
  /// ```dart
  /// const ApiLogOptions(logPrint: debugPrint)   // note: takes String?, wrap it
  /// ApiLogOptions(logPrint: (o) => debugPrint(o.toString()))
  /// ```
  final void Function(Object object)? logPrint;

  const ApiLogOptions({
    this.enabled = true,
    this.request = true,
    this.requestHeader = false,
    this.requestBody = true,
    this.responseHeader = false,
    this.responseBody = true,
    this.error = true,
    this.maxWidth = 90,
    this.compact = true,
    this.trimBase64 = false,
    this.logPrint,
  });

  /// No logging at all, even in debug builds.
  const ApiLogOptions.disabled()
      : enabled = false,
        request = false,
        requestHeader = false,
        requestBody = false,
        responseHeader = false,
        responseBody = false,
        error = false,
        maxWidth = 90,
        compact = true,
        trimBase64 = false,
        logPrint = null;

  /// Returns a copy with the given fields replaced.
  ApiLogOptions copyWith({
    bool? enabled,
    bool? request,
    bool? requestHeader,
    bool? requestBody,
    bool? responseHeader,
    bool? responseBody,
    bool? error,
    int? maxWidth,
    bool? compact,
    bool? trimBase64,
    void Function(Object object)? logPrint,
  }) {
    return ApiLogOptions(
      enabled: enabled ?? this.enabled,
      request: request ?? this.request,
      requestHeader: requestHeader ?? this.requestHeader,
      requestBody: requestBody ?? this.requestBody,
      responseHeader: responseHeader ?? this.responseHeader,
      responseBody: responseBody ?? this.responseBody,
      error: error ?? this.error,
      maxWidth: maxWidth ?? this.maxWidth,
      compact: compact ?? this.compact,
      trimBase64: trimBase64 ?? this.trimBase64,
      logPrint: logPrint ?? this.logPrint,
    );
  }
}
