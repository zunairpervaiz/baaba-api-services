/// Test doubles for consumers of this package.
///
/// Import this in your own tests to get a working [FakeApiServices] without
/// writing mocktail boilerplate against the [ApiServices] interface:
///
/// ```dart
/// import 'package:baaba_api_handler/testing.dart';
/// ```
///
/// Nothing here is imported by the package's production code, so it adds no
/// weight to your app.
library;

export 'src/testing/fake_api_services.dart' show FakeApiServices, RecordedCall;
export 'ts_api_handler.dart';
