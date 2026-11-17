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
/// `apiV2Url` → `API_V2_URL`.
String keyForMemberName(String name) {
  final buffer = StringBuffer();
  for (var i = 0; i < name.length; i++) {
    final c = name[i];
    final upper = c.toUpperCase() == c && c.toLowerCase() != c;
    final digit = RegExp(r'[0-9]').hasMatch(c);
    if (i > 0 && (upper || digit)) {
      final previous = name[i - 1];
      final previousIsLower =
          previous.toLowerCase() == previous &&
          previous.toUpperCase() != previous;
      final previousIsDigit = RegExp(r'[0-9]').hasMatch(previous);
      if (previousIsLower || (upper && previousIsDigit)) buffer.write('_');
    }
    buffer.write(c.toUpperCase());
  }
  return buffer.toString();
}
