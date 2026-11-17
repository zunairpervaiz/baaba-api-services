/// The generators behind `baaba_api_generator`.
///
/// Apps do not import this: adding the package as a dev dependency is enough,
/// and build_runner finds the builder through `build.yaml`. It is here for
/// composing the generators into a builder of your own.
library;

export 'builder.dart' show baabaApiBuilder;
export 'src/generators.dart' show EndpointsGenerator, EnvironmentGenerator;
