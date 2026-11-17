/// Parses `.env` files: `KEY=value` lines.
///
/// - `#` at the start of a line makes it a comment; blank lines are ignored.
/// - An optional `export ` prefix is accepted, as dotenv files often have.
/// - A value may be wrapped in `"` or `'`. Unquoted, a `#` preceded by
///   whitespace starts a trailing comment (so `https://x/#/a` keeps its `#`).
///   Double-quoted values understand `\"`, `\\`, `\n`, `\r` and `\t`.
/// - A value may be empty.
/// - Keys are `[A-Za-z_][A-Za-z0-9_]*`; a duplicate key is an error.
///
/// Compatible with the files `envied` reads, so they move over unchanged.
library;

/// One `KEY=value` line.
class EnvEntry {
  final String key;
  final String value;

  /// 1-based.
  final int line;

  const EnvEntry(this.key, this.value, this.line);
}

/// A problem in an `.env` file, located by line.
class EnvFormatException implements Exception {
  final String message;
  final int line;

  const EnvFormatException(this.message, this.line);

  @override
  String toString() => 'line $line: $message';
}

final RegExp _key = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// The entries of [source], in file order. Throws [EnvFormatException].
List<EnvEntry> parseEnv(String source) {
  final text = source.startsWith('﻿') ? source.substring(1) : source;
  final lines = text.split(RegExp(r'\r?\n'));
  final entries = <EnvEntry>[];
  final seen = <String, int>{};

  for (var i = 0; i < lines.length; i++) {
    final number = i + 1;
    var line = lines[i].trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('export ')) line = line.substring(7).trimLeft();

    final eq = line.indexOf('=');
    if (eq < 0) {
      throw EnvFormatException('expected KEY=value, found "$line"', number);
    }
    final key = line.substring(0, eq).trim();
    if (!_key.hasMatch(key)) {
      throw EnvFormatException(
        'invalid key "$key": use letters, digits and underscores, not '
        'starting with a digit',
        number,
      );
    }
    final previous = seen[key];
    if (previous != null) {
      throw EnvFormatException(
        'duplicate key $key (first defined on line $previous)',
        number,
      );
    }
    seen[key] = number;
    entries.add(
      EnvEntry(key, _value(line.substring(eq + 1), key, number), number),
    );
  }
  return entries;
}

String _value(String raw, String key, int line) {
  final text = raw.trimLeft();
  if (text.isEmpty) return '';
  // `KEY= # note` is an empty value with a comment; `KEY=#fff` is a value.
  if (text.startsWith('#') && text.length != raw.length) return '';
  final quote = text[0];
  if (quote == '"' || quote == "'") {
    final buffer = StringBuffer();
    var i = 1;
    for (; i < text.length; i++) {
      final c = text[i];
      if (c == quote) break;
      if (quote == '"' && c == r'\' && i + 1 < text.length) {
        final next = text[++i];
        buffer.write(switch (next) {
          'n' => '\n',
          'r' => '\r',
          't' => '\t',
          _ => next,
        });
        continue;
      }
      buffer.write(c);
    }
    if (i >= text.length) {
      throw EnvFormatException('unterminated $quote quote in $key', line);
    }
    final rest = text.substring(i + 1).trim();
    if (rest.isNotEmpty && !rest.startsWith('#')) {
      throw EnvFormatException(
        'unexpected "$rest" after the closing quote of $key',
        line,
      );
    }
    return buffer.toString();
  }
  final comment = RegExp(r'\s#').firstMatch(text);
  return (comment == null ? text : text.substring(0, comment.start)).trim();
}
