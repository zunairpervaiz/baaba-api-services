import 'package:baaba_api_generator/builder.dart';
import 'package:build/build.dart';
import 'package:build_test/build_test.dart';

/// What one generator run produced.
class Generated {
  /// The generated part, or `null` when the build failed.
  final String? output;

  /// The build's error messages.
  final List<String> errors;

  const Generated(this.output, this.errors);
}

TestReaderWriter? _shared;

/// Runs the builder over `lib/api.dart` = [library], with [files] (path →
/// contents, e.g. `env/endpoints.env`) alongside it in package `app`.
Future<Generated> generate(String library, Map<String, String> files) async {
  final readerWriter = TestReaderWriter(rootPackage: 'app');
  // Loading every package's sources is slow; copy them from one load.
  if (_shared == null) {
    _shared = TestReaderWriter(rootPackage: 'app');
    await _shared!.testing.loadIsolateSources();
  }
  for (final id in _shared!.testing.assets) {
    if (id.package == 'baaba_api_handler' || id.package == 'meta') {
      readerWriter.testing.writeBytes(id, _shared!.testing.readBytes(id));
    }
  }
  final errors = <String>[];
  final result = await testBuilder(
    baabaApiBuilder(BuilderOptions.empty),
    {
      'app|lib/api.dart': library,
      for (final MapEntry(:key, :value) in files.entries) 'app|$key': value,
    },
    rootPackage: 'app',
    readerWriter: readerWriter,
    onLog: (record) {
      if (record.level.value >= 1000) errors.add(record.message);
    },
  );
  // build_to: cache, so the part lands under .dart_tool.
  final id = AssetId(
    'app',
    '.dart_tool/build/generated/app/lib/api.baaba_api.g.part',
  );
  final output = result.readerWriter.testing.exists(id)
      ? result.readerWriter.testing.readString(id)
      : null;
  return Generated(output, [...errors, ...result.errors]);
}

/// A library with one annotated declaration.
String library(String declaration) =>
    '''
import 'package:baaba_api_handler/annotations.dart';

part 'api.g.dart';

$declaration
''';
