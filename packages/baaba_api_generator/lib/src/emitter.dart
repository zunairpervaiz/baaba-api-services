import 'dart:math';

/// Writes the private storage for generated values.
///
/// Obfuscated, each value becomes two `const` int lists — a fresh
/// `Random.secure` key as long as the value, and the value's UTF-16 code
/// units XORed with it — decoded on first use into a lazily initialised
/// `static final`. Ints in a `const` list compile to numbers, not text, so a
/// strings search of the binary finds nothing.
///
/// **The plain value is never written**, in code or in a comment. Not
/// obfuscated, each value is an ordinary string literal.
class Emitter {
  final bool obfuscate;
  final Random _random;
  final StringBuffer _storage = StringBuffer();
  int _count = 0;

  Emitter({required this.obfuscate, Random? random})
    : _random = random ?? Random.secure();

  /// Whether [name] has the shape of a storage member (`_v0`, `_v1`, ...),
  /// which a class-form field of the same name would collide with.
  static bool isStorageName(String name) => _storageName.hasMatch(name);

  static final RegExp _storageName = RegExp(r'^_v\d+$');

  /// The storage declarations written so far.
  String get storage => _storage.toString();

  /// Stores [value] and returns the name of a `String` that holds it at
  /// runtime.
  String store(String value) {
    final name = '_v${_count++}';
    if (!obfuscate) {
      _storage.writeln('static const String $name = ${dartString(value)};');
      return name;
    }
    final units = value.codeUnits;
    // The low 16 bits — the ones a code unit occupies — are never 0, or that
    // unit would be left in the clear. The high bits are random too, so the
    // stored ints do not show that they hide 16-bit units. Below 2^31, so
    // web's 32-bit bitwise ops are safe.
    final key = [
      for (final _ in units)
        (_random.nextInt(0x8000) << 16) | (_random.nextInt(0xffff) + 1),
    ];
    final data = [for (var i = 0; i < units.length; i++) units[i] ^ key[i]];
    _storage.writeln(
      'static final String $name = '
      'decodeObfuscated(const <int>$key, const <int>$data);',
    );
    return name;
  }
}

/// [value] as a single-quoted Dart string literal.
String dartString(String value) {
  final escaped = value
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('\t', r'\t');
  return "'$escaped'";
}
