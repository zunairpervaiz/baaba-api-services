import 'names.dart';

/// An endpoint template's placeholders, normalised for `ApiEndpoint.fill`.
class Template {
  /// The template with every placeholder written `{}`, the form
  /// `ApiEndpoint.fill` fills in order.
  final String positional;

  /// One parameter name per placeholder, in order: the names written in a
  /// named template, `arg1`, `arg2`, ... in a positional one.
  final List<String> parameters;

  const Template(this.positional, this.parameters);
}

/// Thrown for a template whose placeholders cannot be read.
class TemplateException implements Exception {
  final String message;
  const TemplateException(this.message);
  @override
  String toString() => message;
}

/// Reads the placeholders in [value]: `{}` (positional) or `{name}` (named),
/// not both in one template.
Template parseTemplate(String value) {
  final out = StringBuffer();
  final names = <String>[];
  var positional = 0;
  var named = 0;

  for (var i = 0; i < value.length; i++) {
    final c = value[i];
    if (c == '}') {
      throw TemplateException(
        'malformed placeholder: "}" at column ${i + 1} closes nothing',
      );
    }
    if (c != '{') {
      out.write(c);
      continue;
    }
    final close = value.indexOf('}', i + 1);
    if (close < 0) {
      throw TemplateException(
        'malformed placeholder: "{" at column ${i + 1} is never closed',
      );
    }
    final name = value.substring(i + 1, close);
    if (name.contains('{')) {
      throw TemplateException(
        'malformed placeholder: nested "{" at column ${i + 1}',
      );
    }
    if (name.isEmpty) {
      positional++;
      names.add('arg$positional');
    } else {
      if (!isValidParameterName(name)) {
        throw TemplateException(
          'malformed placeholder "{$name}": a name must be a valid Dart '
          'identifier, and not ApiEndpoint or Object, e.g. {orderId}',
        );
      }
      if (names.contains(name)) {
        throw TemplateException('placeholder "{$name}" appears twice');
      }
      named++;
      names.add(name);
    }
    out.write('{}');
    i = close;
  }

  if (positional > 0 && named > 0) {
    throw TemplateException(
      'mixes {} and named placeholders; use one style per key',
    );
  }
  return Template(out.toString(), names);
}
