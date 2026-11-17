import 'dart:math';

import 'package:baaba_api_generator/src/emitter.dart';
import 'package:test/test.dart';

/// Returns [value] for every draw, clamped into range.
class _FixedRandom implements Random {
  final int value;
  _FixedRandom(this.value);
  @override
  int nextInt(int max) => min(value, max - 1);
  @override
  double nextDouble() => 0;
  @override
  bool nextBool() => false;
}

List<List<int>> _lists(String storage) => [
  for (final m in RegExp(r'<int>\[([^\]]*)\]').allMatches(storage))
    m[1]!.split(',').map((s) => int.parse(s.trim())).toList(),
];

void main() {
  test('every key leaves its code unit changed, even at the extremes', () {
    for (final r in [0, 0xffff, 0x7fffffff]) {
      final emitter = Emitter(obfuscate: true, random: _FixedRandom(r))
        ..store('AZaz09');
      final [key, data] = _lists(emitter.storage);
      for (var i = 0; i < key.length; i++) {
        expect(key[i] & 0xffff, isNot(0), reason: 'random=$r, unit $i');
        expect(key[i], lessThan(1 << 31));
        expect(data[i] & 0xffff, isNot('AZaz09'.codeUnitAt(i)));
      }
    }
  });
}
