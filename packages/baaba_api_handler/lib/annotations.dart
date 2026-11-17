/// What generated code and `baaba_api_generator` need, and nothing else.
///
/// Also exported from `package:baaba_api_handler/baaba_api_handler.dart`, so
/// an app imports that as usual. This library exists for the generator: it
/// is pure Dart, so a builder can import it without pulling in Flutter.
library;

export 'src/codegen/annotations.dart'
    show BaabaApiEndpoint, BaabaApiEnvironment, BaabaApiField;
// For generated code only. Exported so a generated part can reach it through
// the library's ordinary import; @internal keeps it out of everyone else's.
// ignore: invalid_export_of_internal_element
export 'src/codegen/obfuscation.dart' show decodeObfuscated;
export 'src/endpoint/api_endpoint.dart' show ApiEndpoint;
