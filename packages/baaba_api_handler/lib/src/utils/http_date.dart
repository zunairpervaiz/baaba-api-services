/// Minimal HTTP-date parser for the `Retry-After` header.
///
/// `dart:io`'s `HttpDate` would do this, but importing `dart:io` would make
/// the package unusable on web. Only the RFC 1123 form
/// (`Wed, 21 Oct 2015 07:28:00 GMT`) is needed — it is what servers actually
/// send — with the leading day-of-week optional.
abstract final class HttpDate {
  static const _months = [
    'jan', 'feb', 'mar', 'apr', 'may', 'jun', //
    'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
  ];

  /// Parses an HTTP date into a UTC [DateTime].
  ///
  /// Throws [FormatException] on anything it does not recognise, so callers
  /// can fall back rather than trusting a half-parsed value.
  static DateTime parse(String value) {
    // Drop the leading day-of-week; it carries no information.
    final cleaned = value.replaceFirst(RegExp(r'^[A-Za-z]+,?\s+'), '').trim();
    final parts = cleaned.split(RegExp(r'[\s:]+'));
    if (parts.length < 6) throw FormatException('Invalid HTTP date', value);

    final day = int.tryParse(parts[0]);
    final month = _months.indexOf(parts[1].toLowerCase()) + 1;
    final year = int.tryParse(parts[2]);
    final hour = int.tryParse(parts[3]);
    final minute = int.tryParse(parts[4]);
    final second = int.tryParse(parts[5]);

    if (day == null ||
        month == 0 ||
        year == null ||
        hour == null ||
        minute == null ||
        second == null) {
      throw FormatException('Invalid HTTP date', value);
    }

    return DateTime.utc(year, month, day, hour, minute, second);
  }
}
