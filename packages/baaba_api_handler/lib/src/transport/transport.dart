/// Builds the HTTP adapter for `PinningConfig`, on platforms that can honour
/// it.
///
/// A conditional export, so the core package never imports `dart:io`: on web
/// the stub answers `null` and Dio keeps its default (browser) adapter.
library;

export 'transport_stub.dart' if (dart.library.io) 'transport_io.dart';
