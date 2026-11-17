import 'dart:convert';

import 'package:baaba_api_handler/src/config/api_config.dart';
import 'package:baaba_api_handler/src/utils/api_log_options.dart';
import 'package:baaba_api_handler/src/utils/failure.dart';
import 'package:dio/dio.dart';

/// Masks secrets in what the logger prints and the observer receives.
///
/// Works on **copies**: the request that goes out, the response the caller
/// gets and the failure the caller gets are never touched. Copy-on-write
/// throughout — a body with nothing to mask comes back as the same instance,
/// so the common case allocates nothing.
class Redactor {
  final Set<String> _headers;
  final Set<String> _query;
  final Set<String> _fields;
  final int _keep;

  Redactor._(ApiLogOptions options)
    : _headers = {
        'authorization',
        for (final h in options.redactHeaders) h.toLowerCase(),
      },
      _query = {for (final q in options.redactQueryParams) q.toLowerCase()},
      _fields = {for (final f in options.redactBodyFields) f.toLowerCase()},
      _keep = options.redactKeepChars < 0 ? 0 : options.redactKeepChars;

  static final Expando<Redactor> _cache = Expando<Redactor>();

  /// The redactor for [options], or `null` when redaction is off. Built once
  /// per options object, since the observer asks on every call.
  static Redactor? of(ApiLogOptions options) =>
      options.redact ? (_cache[options] ??= Redactor._(options)) : null;

  /// The redactor for [config]'s observer, or `null` when redaction is off.
  static Redactor? forConfig(ApiConfig config) => of(config.logging);

  static const String _marker = '…[redacted]';

  /// `eyJhbGciOi...` → `eyJh…[redacted]`. A value no longer than twice what
  /// would be kept is masked entirely, so a short password or a PIN never
  /// shows even in part.
  ///
  /// With [header] set, an `Authorization`-style value keeps its scheme:
  /// `Bearer eyJh…[redacted]`. Only for headers — in a body, `correct horse
  /// battery` is a password, not a scheme and a credential.
  String mask(Object? value, {bool header = false}) {
    final text = value is List && value.length == 1
        ? '${value.first}'
        : '$value';
    if (header) {
      final match = _scheme.firstMatch(text);
      if (match != null) return '${match[1]} ${_maskPlain(match[2]!)}';
    }
    return _maskPlain(text);
  }

  static final RegExp _scheme = RegExp(
    r'^(Bearer|Basic|Digest|Token|Negotiate|NTLM|Hawk|AWS4-HMAC-SHA256|DPoP) '
    r'(\S.*)$',
    caseSensitive: false,
  );

  /// A body field's value. Only a field named like a token keeps
  /// `redactKeepChars` of its value — enough to tell two tokens apart, and
  /// harmless for a long random string. Anything else — a password, an OTP,
  /// an ID number — is masked entirely: its first characters are part of
  /// the secret.
  String _maskField(String name, Object? value) =>
      name.toLowerCase().contains('token') ? mask(value) : _marker;

  String _maskPlain(String text) => text.length <= _keep * 2
      ? _marker
      : '${text.substring(0, _keep)}$_marker';

  // ---------------------------------------------------------------------------
  // Request, response, error, failure
  // ---------------------------------------------------------------------------

  /// A copy of [options] with secret headers, query parameters and body
  /// fields masked, or [options] itself when there was nothing to mask.
  ///
  /// The copy shares [RequestOptions.extra] with the original: the logger
  /// stamps the request's start time there and reads it back off the
  /// response, which carries the original options.
  RequestOptions request(RequestOptions options) {
    final headers = _headerMap(options.headers);
    final query = _queryMap(options.queryParameters);
    final path = _pathQuery(options.path);
    final data = body(options.data);
    if (identical(headers, options.headers) &&
        identical(query, options.queryParameters) &&
        identical(path, options.path) &&
        identical(data, options.data)) {
      return options;
    }
    return options.copyWith(
      path: path,
      queryParameters: query,
      headers: headers,
      data: data,
      extra: options.extra,
    );
  }

  /// A copy of [response] with its headers, body and request masked.
  Response<dynamic> response(Response<dynamic> response) {
    final options = request(response.requestOptions);
    final headers = _responseHeaders(response.headers);
    final data = body(response.data);
    final redirects = _redirects(response.redirects);
    if (identical(options, response.requestOptions) &&
        identical(headers, response.headers) &&
        identical(data, response.data) &&
        identical(redirects, response.redirects)) {
      return response;
    }
    return Response<dynamic>(
      data: data,
      requestOptions: options,
      statusCode: response.statusCode,
      statusMessage: response.statusMessage,
      isRedirect: response.isRedirect,
      redirects: redirects,
      extra: response.extra,
      headers: headers,
    );
  }

  /// [redirects] with secret query parameters masked in each location — an
  /// OAuth callback carries `?code=` or `?access_token=` — and so in the
  /// `realUri` the response derives from the last one.
  List<RedirectRecord> _redirects(List<RedirectRecord> redirects) {
    List<RedirectRecord>? copy;
    for (var i = 0; i < redirects.length; i++) {
      final record = redirects[i];
      final location = record.location.toString();
      final masked = _pathQuery(location);
      if (identical(masked, location)) continue;
      (copy ??= List.of(redirects))[i] = RedirectRecord(
        record.statusCode,
        record.method,
        Uri.parse(masked),
      );
    }
    return copy ?? redirects;
  }

  /// A copy of [error] with its request and response masked.
  DioException error(DioException error) {
    final options = request(error.requestOptions);
    final original = error.response;
    final masked = original == null ? null : response(original);
    if (identical(options, error.requestOptions) &&
        identical(masked, original)) {
      return error;
    }
    return error.copyWith(requestOptions: options, response: masked);
  }

  /// A copy of [failure] with its body and request masked.
  Failure failure(Failure failure) {
    final options = failure.requestOptions;
    final maskedOptions = options == null ? null : request(options);
    final data = body(failure.data);
    if (identical(maskedOptions, options) && identical(data, failure.data)) {
      return failure;
    }
    return Failure(
      failure.errorType,
      failure.code,
      failure.message,
      data: data,
      statusCode: failure.statusCode,
      requestOptions: maskedOptions,
    );
  }

  // ---------------------------------------------------------------------------
  // Parts
  // ---------------------------------------------------------------------------

  Map<String, dynamic> _headerMap(Map<String, dynamic> headers) {
    Map<String, dynamic>? copy;
    for (final MapEntry(:key, :value) in headers.entries) {
      if (value == null || !_headers.contains(key.toLowerCase())) continue;
      (copy ??= Map<String, dynamic>.of(headers))[key] = mask(
        value,
        header: true,
      );
    }
    return copy ?? headers;
  }

  Headers _responseHeaders(Headers headers) {
    Map<String, List<String>>? copy;
    headers.forEach((name, values) {
      if (!_headers.contains(name.toLowerCase())) return;
      copy ??= {
        for (final MapEntry(:key, :value) in headers.map.entries)
          key: List.of(value),
      };
      copy![name] = [for (final v in values) mask(v, header: true)];
    });
    return copy == null ? headers : Headers.fromMap(copy!);
  }

  Map<String, dynamic> _queryMap(Map<String, dynamic> query) {
    Map<String, dynamic>? copy;
    for (final MapEntry(:key, :value) in query.entries) {
      if (value == null || !_query.contains(key.toLowerCase())) continue;
      (copy ??= Map<String, dynamic>.of(query))[key] = value is Iterable
          ? [for (final v in value) mask(v)]
          : mask(value);
    }
    return copy ?? query;
  }

  /// Masks secret parameters in a query written into the path itself —
  /// `/hub?t=<token>`, as realtime hubs are called.
  String _pathQuery(String path) {
    final start = path.indexOf('?');
    if (start < 0 || _query.isEmpty) return path;
    final end = path.indexOf('#', start);
    final query = path.substring(start + 1, end < 0 ? null : end);
    final masked = _maskPairs(query, _query, (_, value) => mask(value));
    if (masked == null) return path;
    return '${path.substring(0, start + 1)}$masked'
        '${end < 0 ? '' : path.substring(end)}';
  }

  /// [pairs] — `a=1&b=2`, as in a query or a form-urlencoded body — with the
  /// values of [names] masked by [masker], or `null` when none was.
  String? _maskPairs(
    String pairs,
    Set<String> names,
    String Function(String name, String value) masker,
  ) {
    var changed = false;
    final out = [
      for (final pair in pairs.split('&'))
        () {
          final eq = pair.indexOf('=');
          if (eq < 0) return pair;
          final String name;
          try {
            name = Uri.decodeQueryComponent(pair.substring(0, eq));
          } catch (_) {
            return pair;
          }
          if (!names.contains(name.toLowerCase())) return pair;
          changed = true;
          final value = pair.substring(eq + 1);
          return '${pair.substring(0, eq)}=${masker(name, value)}';
        }(),
    ];
    return changed ? out.join('&') : null;
  }

  /// [data] with secret fields masked, at any depth.
  ///
  /// Handles decoded JSON (maps and lists), a JSON string, a form-urlencoded
  /// string (`grant_type=password&password=...`), and `FormData`'s fields.
  /// Anything else — bytes, a stream, XML — passes through untouched.
  Object? body(Object? data) {
    if (_fields.isEmpty) return data;
    if (data is Map || data is List) return _json(data);
    if (data is String) return _jsonString(data);
    if (data is FormData) return _formData(data);
    return data;
  }

  Object? _json(Object? node) {
    if (node is Map) {
      Map<dynamic, dynamic>? copy;
      for (final MapEntry(:key, :value) in node.entries) {
        final Object? replaced;
        if (key is String && _fields.contains(key.toLowerCase())) {
          replaced = value == null
              ? null
              : (value is Map || value is List)
              ? _marker
              : _maskField(key, value);
        } else {
          replaced = _json(value);
        }
        if (!identical(replaced, value)) {
          (copy ??= Map<dynamic, dynamic>.of(node))[key] = replaced;
        }
      }
      if (copy == null) return node;
      // Keep the map's declared type where it is the usual one, so a reader
      // casting `data as Map<String, dynamic>` still can.
      return node is Map<String, dynamic>
          ? Map<String, dynamic>.from(copy)
          : copy;
    }
    if (node is List) {
      List<dynamic>? copy;
      for (var i = 0; i < node.length; i++) {
        final value = node[i];
        final replaced = _json(value);
        if (!identical(replaced, value)) {
          (copy ??= List<dynamic>.of(node))[i] = replaced;
        }
      }
      return copy ?? node;
    }
    return node;
  }

  // `a=1&b=2`: a form-urlencoded body, as an OAuth password grant sends.
  static final RegExp _formEncoded = RegExp(
    r'^[^\s=&]+=[^\s&]*(&[^\s=&]+=[^\s&]*)*$',
  );

  String _jsonString(String text) {
    final trimmed = text.trimLeft();
    if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) {
      if (!_formEncoded.hasMatch(text)) return text;
      return _maskPairs(text, _fields, _maskField) ?? text;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return text;
    }
    final masked = _json(decoded);
    return identical(masked, decoded) ? text : jsonEncode(masked);
  }

  FormData _formData(FormData form) {
    var changed = false;
    final fields = [
      for (final field in form.fields)
        if (_fields.contains(field.key.toLowerCase()))
          () {
            changed = true;
            return MapEntry(field.key, _maskField(field.key, field.value));
          }()
        else
          field,
    ];
    if (!changed) return form;
    // Only ever printed, never sent, so sharing the file entries is safe —
    // nothing finalizes this copy.
    return FormData()
      ..fields.addAll(fields)
      ..files.addAll(form.files);
  }
}
