import 'dart:convert';

import 'package:baaba_api_handler/src/utils/constants.dart';

/// Pulls a human-readable message out of an error response body.
///
/// Shared by two callers that must agree: the `DioException` path in
/// `ErrorHandler`, and the `ApiConfig.isSuccess` path, which rejects a `2xx`
/// whose body says otherwise. Both should surface the same message for the
/// same body.
///
/// Keys are tried in order — `message`, then `detail` (RFC 7807), then
/// `error`, then `msg` — and nested objects are followed up to two levels, so
/// all of these yield `'Email already taken'`:
///
/// ```json
/// "Email already taken"
/// {"message": "Email already taken"}
/// {"detail":  "Email already taken"}
/// {"error": {"message": "Email already taken"}}
/// {"detail": [{"loc": ["body", "email"], "msg": "Email already taken"}]}
/// ```
///
/// The last is FastAPI/Pydantic's default `422` shape: a list of objects,
/// each read the same way.
///
/// When none of those keys has anything, the field messages under `errors`
/// are used, then `title`. That covers ASP.NET's automatic `400`, which has
/// neither `message` nor `detail`:
///
/// ```json
/// {"title": "One or more validation errors occurred.",
///  "errors": {"Email": ["The Email field is required."]}}
/// ```
///
/// yields `'The Email field is required.'` — what to fix, rather than only
/// that something is wrong.
///
/// A JSON body that arrives as a `String` — `responseType: plain`, or a
/// server labelling JSON as `text/plain` — is decoded and read as JSON rather
/// than shown to the user as raw `{"message": ...}` text.
///
/// Returns `''` when nothing usable is found — the caller then falls back to
/// the generic `ResponseStrings` text for the status code.
///
/// An HTML body yields `''` too. Gateways and proxies (nginx, Cloudflare,
/// a load balancer) answer a `502` or `504` with an error *page*, and that
/// markup is not something to put in front of a user.
String extractErrorMessage(dynamic data, {int depth = 0}) {
  if (data is String) {
    final text = data.trim();
    if (text.startsWith('<')) return '';
    if (depth == 0 && (text.startsWith('{') || text.startsWith('['))) {
      try {
        return extractErrorMessage(jsonDecode(text), depth: depth + 1);
      } on FormatException {
        // Not JSON after all — a message that happens to start with a brace.
      }
    }
    return text;
  }
  if (data is! Map || depth > 2) return '';

  for (final key in const [messageKey, detailKey, errorKey, msgKey]) {
    if (!data.containsKey(key)) continue;

    final value = data[key];
    // {"error": true} is a flag, not a message — showing the user "true"
    // helps no one, and a later key may still have something to say.
    if (value == null || value is bool) continue;
    if (value is String) {
      if (value.trim().isEmpty) continue;
      return value;
    }

    // {"error": {"message": "..."}} — follow it rather than printing the map.
    if (value is Map) {
      final nested = extractErrorMessage(value, depth: depth + 1);
      if (nested.isNotEmpty) return nested;
      continue;
    }

    // {"detail": ["first problem", "second problem"]}, or a list of objects
    // such as FastAPI's [{"loc": [...], "msg": "field required"}].
    if (value is List) {
      final parts = [
        for (final item in value)
          if (item is String)
            item.trim()
          else if (item is Map)
            extractErrorMessage(item, depth: depth + 1),
      ].where((s) => s.isNotEmpty);
      if (parts.isNotEmpty) return parts.join(' ');
      continue;
    }

    return value.toString();
  }

  final fieldErrors = _flattenErrors(data[errorsKey], depth);
  if (fieldErrors.isNotEmpty) return fieldErrors;

  final title = data[titleKey];
  if (title is String && title.trim().isNotEmpty) return title.trim();

  return '';
}

/// Joins the messages in an `errors` value — a `{field: [messages]}` map, or
/// a plain list — into one line, in the order the server gave them.
String _flattenErrors(Object? errors, int depth) {
  final Iterable<Object?> entries;
  if (errors is Map) {
    entries = errors.values;
  } else if (errors is List) {
    entries = errors;
  } else {
    return '';
  }

  final parts = <String>[];
  void add(Object? item) {
    if (item is String) {
      parts.add(item.trim());
    } else if (item is Map) {
      parts.add(extractErrorMessage(item, depth: depth + 1));
    }
  }

  for (final entry in entries) {
    if (entry is List) {
      entry.forEach(add);
    } else {
      add(entry);
    }
  }
  return parts.where((s) => s.isNotEmpty).join(' ');
}

/// Pulls a machine-readable error code out of a body — `code` or
/// `errorCode`, at the top level or inside an `error` object:
///
/// ```json
/// {"success": false, "code": "ACCOUNT_LOCKED", "message": "..."}
/// {"error": {"code": "INSUFFICIENT_FUNDS", "message": "..."}}
/// ```
///
/// A numeric code is returned as its string. `null` when there is none.
String? extractErrorCode(dynamic data) {
  if (data is String) {
    final text = data.trim();
    if (!text.startsWith('{')) return null;
    try {
      data = jsonDecode(text);
    } on FormatException {
      return null;
    }
  }
  if (data is! Map) return null;

  for (final key in const [codeKey, errorCodeKey]) {
    final value = data[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    if (value is num) return value.toString();
  }

  final nested = data[errorKey];
  return nested is Map ? extractErrorCode(nested) : null;
}

/// Pulls per-field validation errors out of a body, for driving form field
/// errors instead of showing one flat string.
///
/// Recognises the widespread `errors` shape, with values as either a list of
/// messages or a single message:
///
/// ```json
/// {"errors": {"email": ["already taken"], "name": "is required"}}
/// ```
///
/// Returns `null` when the body has no `errors` object, so callers can cleanly
/// distinguish "no field errors" from "an empty set of field errors".
Map<String, List<String>>? extractValidationErrors(dynamic data) {
  if (data is! Map) return null;

  final raw = data[errorsKey];
  if (raw is! Map) return null;

  final result = <String, List<String>>{};
  raw.forEach((key, value) {
    final field = key.toString();
    if (value is String) {
      result[field] = [value];
    } else if (value is List) {
      final messages = value
          .where((e) => e != null)
          .map((e) => e.toString())
          .toList();
      if (messages.isNotEmpty) result[field] = messages;
    } else if (value != null) {
      result[field] = [value.toString()];
    }
  });

  return result;
}
