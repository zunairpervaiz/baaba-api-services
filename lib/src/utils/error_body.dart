import 'package:baaba_api_handler/src/utils/constants.dart';

/// Pulls a human-readable message out of an error response body.
///
/// Shared by two callers that must agree: the `DioException` path in
/// `ErrorHandler`, and the `ApiConfig.isSuccess` path, which rejects a `2xx`
/// whose body says otherwise. Both should surface the same message for the
/// same body.
///
/// Keys are tried in order — `message`, then `detail` (RFC 7807), then
/// `error` — and a nested object is followed one level, so all of these yield
/// `'Email already taken'`:
///
/// ```json
/// "Email already taken"
/// {"message": "Email already taken"}
/// {"detail":  "Email already taken"}
/// {"error": {"message": "Email already taken"}}
/// ```
///
/// Returns `''` when nothing usable is found — the caller then falls back to
/// the generic `ResponseStrings` text for the status code.
String extractErrorMessage(dynamic data, {int depth = 0}) {
  if (data is String) return data;
  if (data is! Map || depth > 2) return '';

  for (final key in const [messageKey, detailKey, errorKey]) {
    if (!data.containsKey(key)) continue;

    final value = data[key];
    if (value == null) continue;
    if (value is String) return value;

    // {"error": {"message": "..."}} — follow it rather than printing the map.
    if (value is Map) {
      final nested = extractErrorMessage(value, depth: depth + 1);
      if (nested.isNotEmpty) return nested;
      continue;
    }

    // {"detail": ["first problem", "second problem"]}
    if (value is List) {
      final parts = value.whereType<String>().where((s) => s.isNotEmpty);
      if (parts.isNotEmpty) return parts.join(' ');
      continue;
    }

    return value.toString();
  }

  return '';
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
      final messages =
          value.where((e) => e != null).map((e) => e.toString()).toList();
      if (messages.isNotEmpty) result[field] = messages;
    } else if (value != null) {
      result[field] = [value.toString()];
    }
  });

  return result;
}
