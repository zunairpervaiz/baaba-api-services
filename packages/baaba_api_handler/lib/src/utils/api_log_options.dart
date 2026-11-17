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
///     requestHeader: true,  // headers too — tokens print masked
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
  /// Safe to turn on while debugging: with [redact] on (the default) the
  /// `Authorization` header and the others in [redactHeaders] print masked.
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

  /// Mask secrets in what is logged and in what `ApiConfig.observer`
  /// receives. On by default.
  ///
  /// Masked: the `Authorization` header (always, while this is on) and every
  /// header in [redactHeaders]; query parameters in [redactQueryParams],
  /// whether passed as `params` or written into the endpoint; and JSON body
  /// fields in [redactBodyFields], at any depth, in requests and responses
  /// alike. A masked token keeps its first [redactKeepChars] characters:
  ///
  /// ```
  /// authorization: Bearer eyJh…[redacted]
  /// ```
  ///
  /// Names match case-insensitively. Only the copies handed to the logger and
  /// the observer are masked — what is sent, and what the caller receives,
  /// is never touched.
  ///
  /// Applies even when logging is [ApiLogOptions.disabled], because the
  /// observer still runs; turn it off with `redact: false`.
  final bool redact;

  /// Headers whose values are masked, besides `Authorization`.
  final Set<String> redactHeaders;

  /// Query parameters whose values are masked. Includes `t`, which realtime
  /// hubs use to carry the access token (`/hub?t=...`).
  final Set<String> redactQueryParams;

  /// JSON body fields whose values are masked, in request and response
  /// bodies, at any depth. Replace the set to cover your API's own names:
  ///
  /// ```dart
  /// redactBodyFields: {...ApiLogOptions.defaultRedactBodyFields, 'nationalId', 'otp'},
  /// ```
  final Set<String> redactBodyFields;

  /// How many leading characters of a masked header, query parameter or
  /// token field (a body field named like `*token*`) stay visible — enough
  /// to tell two tokens apart. Values no longer than twice this are masked
  /// entirely, and so is every other body field: a password's first
  /// characters are part of the password.
  final int redactKeepChars;

  /// The default [redactHeaders].
  static const Set<String> defaultRedactHeaders = {
    'authorization',
    'proxy-authorization',
    'cookie',
    'set-cookie',
    'x-api-key',
  };

  /// The default [redactQueryParams].
  static const Set<String> defaultRedactQueryParams = {
    't',
    'token',
    'access_token',
    'refresh_token',
    'id_token',
    'api_key',
    'apikey',
  };

  /// The default [redactBodyFields].
  static const Set<String> defaultRedactBodyFields = {
    'password',
    'token',
    'accessToken',
    'refreshToken',
    'access_token',
    'refresh_token',
    'idToken',
    'id_token',
  };

  /// Where log lines go. Defaults to `debugPrint`.
  ///
  /// Use this to route logs somewhere other than the console — your own
  /// crash reporter or a file sink:
  ///
  /// ```dart
  /// ApiLogOptions(logPrint: (o) => crashReporter.log(o.toString()))
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
    this.redact = true,
    this.redactHeaders = defaultRedactHeaders,
    this.redactQueryParams = defaultRedactQueryParams,
    this.redactBodyFields = defaultRedactBodyFields,
    this.redactKeepChars = 4,
    this.logPrint,
  });

  /// No logging at all, even in debug builds.
  ///
  /// Redaction stays on with its defaults, since it also protects what the
  /// observer receives.
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
      redact = true,
      redactHeaders = defaultRedactHeaders,
      redactQueryParams = defaultRedactQueryParams,
      redactBodyFields = defaultRedactBodyFields,
      redactKeepChars = 4,
      logPrint = null;

  /// Returns a copy with the given fields replaced.
  ///
  /// Only replaces — passing `null` is indistinguishable from omitting the
  /// argument, so it cannot remove a [logPrint]. Build a fresh
  /// [ApiLogOptions] for that.
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
    bool? redact,
    Set<String>? redactHeaders,
    Set<String>? redactQueryParams,
    Set<String>? redactBodyFields,
    int? redactKeepChars,
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
      redact: redact ?? this.redact,
      redactHeaders: redactHeaders ?? this.redactHeaders,
      redactQueryParams: redactQueryParams ?? this.redactQueryParams,
      redactBodyFields: redactBodyFields ?? this.redactBodyFields,
      redactKeepChars: redactKeepChars ?? this.redactKeepChars,
      logPrint: logPrint ?? this.logPrint,
    );
  }
}
