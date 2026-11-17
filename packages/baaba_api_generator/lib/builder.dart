/// The build_runner entry point. See the README for setup.
library;

import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import 'src/generators.dart';

/// Writes `*.g.dart` parts for `@BaabaApiEndpoint` and `@BaabaApiEnvironment`.
Builder baabaApiBuilder(BuilderOptions options) => SharedPartBuilder(const [
  EndpointsGenerator(),
  EnvironmentGenerator(),
], 'baaba_api');
