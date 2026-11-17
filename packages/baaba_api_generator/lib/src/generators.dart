import 'dart:async';

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:baaba_api_handler/annotations.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import 'emitter.dart';
import 'env_file.dart';
import 'names.dart';
import 'placeholders.dart';

// decodeObfuscated is @internal by design; and the analyzer does not count
// uses that reach the private class through the public typedef, so every
// member of the typedef form would otherwise be reported unused.
const _ignore =
    '// ignore_for_file: invalid_use_of_internal_member, unused_element, '
    'unused_field, type=lint';

const _apiField = TypeChecker.typeNamed(
  BaabaApiField,
  inPackage: 'baaba_api_handler',
);

/// `@BaabaApiEndpoint`: typed endpoint templates.
class EndpointsGenerator extends GeneratorForAnnotation<BaabaApiEndpoint> {
  const EndpointsGenerator() : super(inPackage: 'baaba_api_handler');

  @override
  Future<String> generateForAnnotatedElement(
    Element element,
    ConstantReader annotation,
    BuildStep buildStep,
  ) async {
    final source = await _EnvSource.read(
      element,
      annotation,
      buildStep,
      'BaabaApiEndpoint',
    );
    final emitter = Emitter(obfuscate: source.obfuscate);
    final members = StringBuffer();

    Template template(EnvEntry entry) {
      try {
        return parseTemplate(entry.value);
      } on TemplateException catch (e) {
        throw source.error('${entry.key}: $e', entry.line);
      }
    }

    if (element is TypeAliasElement) {
      for (final (name, entry) in source.publicNames()) {
        final t = template(entry);
        final value = emitter.store(t.positional);
        if (t.parameters.isEmpty) {
          members.writeln(
            'static ApiEndpoint get $name => ApiEndpoint($value);',
          );
        } else {
          final params = t.parameters.map((p) => 'Object $p').join(', ');
          members.writeln(
            'static ApiEndpoint $name($params) => '
            'ApiEndpoint($value).fill([${t.parameters.join(', ')}]);',
          );
        }
      }
    } else {
      for (final field in source.fields()) {
        final type = field.type;
        _requireDeclaredType(source, field);
        if (!type.isDartCoreString && type.element?.name != 'ApiEndpoint') {
          throw source.fieldError(
            field,
            'is ${type.getDisplayString()}; an @BaabaApiEndpoint field must be '
            'ApiEndpoint or String',
          );
        }
        final entry = source.entryFor(field);
        final value = emitter.store(template(entry).positional);
        members.writeln(
          'static ApiEndpoint get ${field.name} => ApiEndpoint($value);',
        );
      }
    }
    return source.wrap(emitter, members);
  }
}

/// `@BaabaApiEnvironment`: typed configuration values.
class EnvironmentGenerator extends GeneratorForAnnotation<BaabaApiEnvironment> {
  const EnvironmentGenerator() : super(inPackage: 'baaba_api_handler');

  @override
  Future<String> generateForAnnotatedElement(
    Element element,
    ConstantReader annotation,
    BuildStep buildStep,
  ) async {
    final source = await _EnvSource.read(
      element,
      annotation,
      buildStep,
      'BaabaApiEnvironment',
    );
    final emitter = Emitter(obfuscate: source.obfuscate);
    final members = StringBuffer();

    if (element is TypeAliasElement) {
      for (final (name, entry) in source.publicNames()) {
        members.writeln(
          'static String get $name => ${emitter.store(entry.value)};',
        );
      }
      return source.wrap(emitter, members);
    }

    for (final field in source.fields()) {
      _requireDeclaredType(source, field);
      final entry = source.entryFor(field);
      final type = field.type;
      final nullable = type.nullabilitySuffix == NullabilitySuffix.question;
      final name = field.name;
      final kind = _kind(type);
      if (kind == null) {
        throw source.fieldError(
          field,
          'is ${type.getDisplayString()}; supported types are String, int, '
          'bool and Uri (nullable or not)',
        );
      }
      final typeName = '$kind${nullable ? '?' : ''}';

      if (entry.value.isEmpty && kind != 'String') {
        if (!nullable) {
          throw source.error(
            '${entry.key} is empty, but ${source.owner}.$name is $kind. '
            'Give it a value, or declare the field $kind? to read empty as '
            'null',
            entry.line,
          );
        }
        members.writeln('static $typeName get $name => null;');
        continue;
      }
      if (entry.value.isEmpty && nullable) {
        members.writeln('static $typeName get $name => null;');
        continue;
      }

      switch (kind) {
        case 'String':
          members.writeln(
            'static $typeName get $name => ${emitter.store(entry.value)};',
          );
        case 'int':
          final parsed = int.tryParse(entry.value.trim());
          if (parsed == null) {
            throw source.error(
              '${entry.key} must be an int for ${source.owner}.$name, '
              'got "${entry.value}"',
              entry.line,
            );
          }
          // Signed and zero-padded to a fixed width, so the stored length
          // says nothing about the number (int.parse accepts both).
          final digits = '$parsed'.replaceFirst('-', '').padLeft(19, '0');
          final fixed = '${parsed < 0 ? '-' : '+'}$digits';
          members.writeln(
            'static final $typeName $name = '
            'int.parse(${emitter.store(fixed)});',
          );
        case 'bool':
          final lower = entry.value.trim().toLowerCase();
          if (lower != 'true' && lower != 'false') {
            throw source.error(
              '${entry.key} must be true or false for ${source.owner}.$name, '
              'got "${entry.value}"',
              entry.line,
            );
          }
          // Stored as one character, '1' or '0', so both values are the same
          // length, and compared by code unit (49 is '1') so no literal of
          // either is written.
          final stored = emitter.store(lower == 'true' ? '1' : '0');
          members.writeln(
            'static final $typeName $name = $stored.codeUnitAt(0) == 49;',
          );
        case 'Uri':
          if (Uri.tryParse(entry.value.trim()) == null) {
            throw source.error(
              '${entry.key} must be a URI for ${source.owner}.$name, '
              'got "${entry.value}"',
              entry.line,
            );
          }
          members.writeln(
            'static final $typeName $name = '
            'Uri.parse(${emitter.store(entry.value.trim())});',
          );
      }
    }
    return source.wrap(emitter, members);
  }

  static String? _kind(DartType type) {
    if (type.isDartCoreString) return 'String';
    if (type.isDartCoreInt) return 'int';
    if (type.isDartCoreBool) return 'bool';
    final element = type.element;
    if (element?.name == 'Uri' && element?.library?.isDartCore == true) {
      return 'Uri';
    }
    return null;
  }
}

/// A class-form field must spell out its type: inferred from
/// `_Owner.member`, it is unresolvable while the part is being generated.
void _requireDeclaredType(_EnvSource source, FieldElement field) {
  final type = field.type;
  if (type is InvalidType || type is DynamicType) {
    throw source.fieldError(
      field,
      'has no declared type. Write it out — the generated part it would be '
      'inferred from does not exist yet, e.g. static final String '
      '${field.name} = ...',
    );
  }
}

/// The annotated element, its `.env` file, and the shared error handling.
class _EnvSource {
  final Element element;
  final String owner;
  final String path;
  final bool obfuscate;
  final List<EnvEntry> entries;

  _EnvSource(this.element, this.owner, this.path, this.obfuscate, this.entries);

  static Future<_EnvSource> read(
    Element element,
    ConstantReader annotation,
    BuildStep buildStep,
    String annotationName,
  ) async {
    final owner = element.name ?? '?';
    if (element is! TypeAliasElement && element is! ClassElement) {
      throw InvalidGenerationSourceError(
        '@$annotationName goes on a typedef (typedef $owner = _$owner;) or '
        'a class with static fields.',
        element: element,
      );
    }
    final path = annotation.read('path').stringValue;
    final obfuscate = annotation.read('obfuscate').boolValue;

    final AssetId id;
    try {
      id = AssetId(buildStep.inputId.package, path);
    } catch (e) {
      throw InvalidGenerationSourceError(
        '@$annotationName(path: \'$path\') is not a valid path: $e',
        element: element,
      );
    }
    if (!await buildStep.canRead(id)) {
      throw InvalidGenerationSourceError(
        '@$annotationName on $owner: cannot read "$path".\n'
        'Either the file does not exist, or build_runner cannot see it. '
        'build_runner only reads files listed in the "sources" of your app\'s '
        'build.yaml, and the defaults do not include env/. Add it — note that '
        'listing sources replaces the defaults, so keep lib/** and the rest:\n'
        '\n'
        'targets:\n'
        '  \$default:\n'
        '    sources:\n'
        '      - \$package\$\n'
        '      - lib/**\n'
        '      - env/**\n'
        '      - pubspec.yaml\n',
        element: element,
      );
    }

    final List<EnvEntry> entries;
    try {
      entries = parseEnv(await buildStep.readAsString(id));
    } on EnvFormatException catch (e) {
      throw InvalidGenerationSourceError(
        '$path:${e.line}: ${e.message}',
        element: element,
      );
    }
    return _EnvSource(element, owner, path, obfuscate, entries);
  }

  /// The generated class: `_Endpoints` for `Endpoints`.
  String get generatedName => owner.startsWith('_') ? '_\$$owner' : '_$owner';

  InvalidGenerationSourceError error(String message, int line) =>
      InvalidGenerationSourceError('$path:$line: $message', element: element);

  InvalidGenerationSourceError fieldError(FieldElement field, String message) =>
      InvalidGenerationSourceError(
        '$owner.${field.name} $message.',
        element: field,
      );

  /// Every key, with the member name it generates — for the typedef form.
  Iterable<(String, EnvEntry)> publicNames() {
    final taken = <String, EnvEntry>{};
    final result = <(String, EnvEntry)>[];
    for (final entry in entries) {
      final name = memberNameForKey(entry.key);
      if (entry.key.startsWith('_') || !isValidMemberName(name)) {
        throw error(
          'key ${entry.key} gives the name "$name", which is not a valid '
          'Dart identifier for a public member. Rename the key',
          entry.line,
        );
      }
      final clash = taken[name];
      if (clash != null) {
        throw error(
          'keys ${clash.key} (line ${clash.line}) and ${entry.key} both '
          'generate "$name". Rename one',
          entry.line,
        );
      }
      taken[name] = entry;
      result.add((name, entry));
    }
    return result;
  }

  /// The static fields of the annotated class — for the class form. A
  /// `const` field is skipped: a generated value is decoded at runtime, so a
  /// `const` can never be reading one, and is the class's own helper.
  Iterable<FieldElement> fields() => (element as ClassElement).fields.where(
    (f) => f.isStatic && f.isOriginDeclaration && !f.isConst,
  );

  /// The entry [field] reads: its `@BaabaApiField` name, else its UPPER_SNAKE
  /// name, else its name as written (how `envied` reads it).
  EnvEntry entryFor(FieldElement field) {
    final name = field.name ?? '';
    final override = _apiField
        .firstAnnotationOf(field)
        ?.getField('name')
        ?.toStringValue();
    final candidates = override != null
        ? [override]
        : {keyForMemberName(name), name}.toList();
    for (final key in candidates) {
      for (final entry in entries) {
        if (entry.key == key) return entry;
      }
    }
    throw InvalidGenerationSourceError(
      '$path has no key ${candidates.first} for $owner.$name. '
      'Add "${candidates.first}=..." to the file, or name the key the field '
      'reads with @BaabaApiField(name: ...).',
      element: field,
    );
  }

  String wrap(Emitter emitter, StringBuffer members) =>
      '$_ignore\n\n'
      'abstract final class $generatedName {\n'
      '${emitter.storage}\n'
      '$members'
      '}';
}
