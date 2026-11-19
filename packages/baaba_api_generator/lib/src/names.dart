/// Dart naming rules for generated members.
library;

const Set<String> _reserved = {
  'assert', 'break', 'case', 'catch', 'class', 'const', 'continue', //
  'default', 'do', 'else', 'enum', 'extends', 'false', 'final', 'finally',
  'for', 'if', 'in', 'is', 'new', 'null', 'rethrow', 'return', 'super',
  'switch', 'this', 'throw', 'true', 'try', 'var', 'void', 'while', 'with',
};

// Object's members: a static member of the generated class cannot share a
// name with one (`conflicting_static_and_instance`).
const Set<String> _objectMembers = {
  'hashCode',
  'runtimeType',
  'toString',
  'noSuchMethod',
};

// Names the generated method body refers to; a parameter of the same name
// would shadow it there.
const Set<String> _usedInBody = {'ApiEndpoint', 'Object'};

final RegExp _identifier = RegExp(r'^[A-Za-z$][A-Za-z0-9_$]*$');

/// Whether [name] can be a public generated member.
bool isValidMemberName(String name) =>
    _identifier.hasMatch(name) &&
    !_reserved.contains(name) &&
    !_objectMembers.contains(name);

/// Whether [name] can be a generated method's parameter.
bool isValidParameterName(String name) =>
    _identifier.hasMatch(name) &&
    !_reserved.contains(name) &&
    !_usedInBody.contains(name);

/// The member name for an `.env` key: `UPDATE_ORDER` → `updateOrder`.
/// A key that is not all upper case (`updateOrder`, `login`) is used as
/// written.
String memberNameForKey(String key) {
  if (key != key.toUpperCase()) return key;
  final words = key.toLowerCase().split('_').where((w) => w.isNotEmpty);
  final buffer = StringBuffer();
  for (final word in words) {
    buffer.write(
      buffer.isEmpty ? word : '${word[0].toUpperCase()}${word.substring(1)}',
    );
  }
  return buffer.toString();
}

/// The default `.env` key for a field: `baseUrl` → `BASE_URL`,
/// `apiV2Url` → `API_V2_URL`, `s3Bucket` → `S3_BUCKET`, `baseURLPath` →
/// `BASE_URL_PATH`. A digit stays with the word before it.
String keyForMemberName(String name) => _upperSnake(name, legacy: false);

/// The keys a field without `@BaabaApiField` reads, in order: its
/// [keyForMemberName], then 1.0.0's spelling (which split a digit off a
/// lower-case letter, `s3Bucket` → `S_3_BUCKET`), then its name as written.
List<String> keysForMemberName(String name) =>
    {keyForMemberName(name), _upperSnake(name, legacy: true), name}.toList();

bool _isUpper(String c) => c.toUpperCase() == c && c.toLowerCase() != c;
bool _isLower(String c) => c.toLowerCase() == c && c.toUpperCase() != c;
bool _isDigit(String c) => '0123456789'.contains(c);

String _upperSnake(String name, {required bool legacy}) {
  final buffer = StringBuffer();
  for (var i = 0; i < name.length; i++) {
    final c = name[i];
    if (i > 0) {
      final previous = name[i - 1];
      final next = i + 1 < name.length ? name[i + 1] : '';
      final boundary = legacy
          ? (_isUpper(c) || _isDigit(c)) &&
                (_isLower(previous) || (_isUpper(c) && _isDigit(previous)))
          : _isUpper(c) &&
                (_isLower(previous) ||
                    _isDigit(previous) ||
                    (_isUpper(previous) && next.isNotEmpty && _isLower(next)));
      if (boundary) buffer.write('_');
    }
    buffer.write(c.toUpperCase());
  }
  return buffer.toString();
}
