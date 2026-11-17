// decodeObfuscated is @internal: only generated code calls it. The tests
// here are its owner's.
import 'dart:math';

import 'package:baaba_api_handler/annotations.dart';
import 'package:flutter_test/flutter_test.dart';

/// Obfuscates [value] the way baaba_api_generator does.
(List<int>, List<int>) _obfuscate(String value, Random random) {
  final units = value.codeUnits;
  final key = [for (final _ in units) random.nextInt(0x7ffffffe) + 1];
  return (key, [for (var i = 0; i < units.length; i++) units[i] ^ key[i]]);
}

void main() {
  group('decodeObfuscated', () {
    test('round-trips any string, including non-ASCII and emoji', () {
      final random = Random(42);
      for (final value in [
        '',
        'auth/login',
        'orders/{}/attachments/{}',
        'https://api.example.com/v1?x=1#frag',
        'زبیر',
        'café 🚀',
      ]) {
        final (key, data) = _obfuscate(value, random);
        expect(decodeObfuscated(key, data), value);
      }
    });

    test('rejects lists of different lengths', () {
      expect(() => decodeObfuscated([1, 2], [3]), throwsArgumentError);
    });
  });

  test('obfuscation is on by default', () {
    expect(const BaabaApiEndpoint(path: 'env/endpoints.env').obfuscate, isTrue);
    expect(const BaabaApiEnvironment(path: 'env/stage.env').obfuscate, isTrue);
    expect(const BaabaApiField(name: 'BASE_URL').name, 'BASE_URL');
  });
}
