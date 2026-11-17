/// Annotations read by `baaba_api_generator`.
///
/// Pure Dart — no Flutter import anywhere below this file — because the
/// generator imports it, and a builder runs on the plain Dart VM.
library;

/// Generates typed endpoints from a `.env` file of `KEY=path` lines.
///
/// ```dart
/// part 'endpoints.g.dart';
///
/// @BaabaApiEndpoint(path: 'env/endpoints.env')
/// typedef Endpoints = _Endpoints;
/// ```
///
/// On a `typedef`, every key in the file becomes a member: a key without
/// placeholders a getter (`Endpoints.login`), a key with them a method whose
/// parameters fill them (`Endpoints.updateOrder(orderId)`).
///
/// On a class, only the static fields it declares are generated, each an
/// unfilled [ApiEndpoint] template — the shape an `envied` class already has,
/// so moving over is a change of annotation:
///
/// ```dart
/// @BaabaApiEndpoint(path: 'env/endpoints.env')
/// abstract final class Endpoints {
///   static final ApiEndpoint orderAttachment = _Endpoints.orderAttachment;
/// }
/// ```
///
/// [path] is relative to the package root and **must be listed in the app's
/// `build.yaml` sources** (`env/**`), or build_runner cannot see it.
class BaabaApiEndpoint {
  /// The `.env` file, relative to the package root, e.g. `env/endpoints.env`.
  final String path;

  /// Store values XOR-obfuscated rather than as plain strings. On by
  /// default: hiding the values is the point. See the README for what this
  /// does and does not protect against.
  final bool obfuscate;

  const BaabaApiEndpoint({required this.path, this.obfuscate = true});
}

/// Generates typed configuration values from a `.env` file.
///
/// ```dart
/// part 'stage_env.g.dart';
///
/// @BaabaApiEnvironment(path: 'env/stage.env')
/// abstract final class StageEnv {
///   static final Uri baseUrl = _StageEnv.baseUrl;          // BASE_URL
///   static final int timeoutSeconds = _StageEnv.timeoutSeconds;
///   @BaabaApiField(name: 'HUB')
///   static final String? hubUrl = _StageEnv.hubUrl;
/// }
/// ```
///
/// Each static field reads the key named by its [BaabaApiField], or else its name
/// in UPPER_SNAKE case (`baseUrl` → `BASE_URL`), falling back to the name as
/// written (`baseUrl`, as `envied` reads it). Supported types are `String`,
/// `int`, `bool` and `Uri`, checked at build time; a nullable field reads an
/// empty value as `null`.
///
/// On a `typedef`, every key in the file becomes a `String` getter.
class BaabaApiEnvironment {
  /// The `.env` file, relative to the package root, e.g. `env/stage.env`.
  final String path;

  /// Store values XOR-obfuscated. On by default — see [BaabaApiEndpoint.obfuscate].
  final bool obfuscate;

  const BaabaApiEnvironment({required this.path, this.obfuscate = true});
}

/// Names the `.env` key a field reads, instead of its UPPER_SNAKE name.
class BaabaApiField {
  /// The key in the `.env` file.
  final String name;

  const BaabaApiField({required this.name});
}
