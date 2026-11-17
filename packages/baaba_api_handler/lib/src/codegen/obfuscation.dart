import 'package:meta/meta.dart';

/// Decodes a value `baaba_api_generator` stored XOR-obfuscated.
///
/// Called only by generated code — hence `@internal`; the generated file
/// suppresses the warning that marker raises. Not a stable API.
///
/// [key] and [data] are UTF-16 code units: `data[i] ^ key[i]` is the
/// original code unit.
@internal
String decodeObfuscated(List<int> key, List<int> data) {
  if (key.length != data.length) {
    throw ArgumentError('Obfuscated value is corrupt: lengths differ.');
  }
  return String.fromCharCodes(
    List<int>.generate(data.length, (i) => data[i] ^ key[i], growable: false),
  );
}
