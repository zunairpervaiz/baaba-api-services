import 'dart:async';

import 'package:baaba_api_handler/src/utils/network_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NetworkInfo connectivity caching', () {
    late DateTime now;
    late int probeCount;

    setUp(() {
      now = DateTime(2026, 1, 1, 12);
      probeCount = 0;
    });

    NetworkInfo build({
      required Future<bool> Function() probe,
      Duration ttl = const Duration(seconds: 5),
    }) {
      return NetworkInfo(cacheTtl: ttl, probe: probe, clock: () => now);
    }

    Future<bool> online() async {
      probeCount++;
      return true;
    }

    Future<bool> offline() async {
      probeCount++;
      return false;
    }

    test('probes once and reuses the result inside the TTL window', () async {
      final info = build(probe: online);

      expect(await info.isConnected, isTrue);
      expect(await info.isConnected, isTrue);
      now = now.add(const Duration(seconds: 4));
      expect(await info.isConnected, isTrue);

      expect(probeCount, 1);
    });

    test('probes again once the window expires', () async {
      final info = build(probe: online);

      await info.isConnected;
      now = now.add(const Duration(seconds: 6));
      await info.isConnected;

      expect(probeCount, 2);
    });

    test('never caches a negative result', () async {
      // A cached "offline" would keep failing for seconds after the
      // connection came back — exactly when the user is retrying.
      final info = build(probe: offline);

      expect(await info.isConnected, isFalse);
      expect(await info.isConnected, isFalse);
      expect(await info.isConnected, isFalse);

      expect(probeCount, 3);
    });

    test('recovers immediately when connectivity returns', () async {
      var connected = false;
      final info = build(probe: () async {
        probeCount++;
        return connected;
      });

      expect(await info.isConnected, isFalse);
      connected = true;
      expect(await info.isConnected, isTrue);
    });

    test('concurrent callers share one in-flight probe', () async {
      final gate = Completer<bool>();
      final info = build(probe: () {
        probeCount++;
        return gate.future;
      });

      final results = Future.wait([
        info.isConnected,
        info.isConnected,
        info.isConnected,
      ]);
      gate.complete(true);

      expect(await results, [true, true, true]);
      expect(probeCount, 1);
    });

    test('a probe that throws reads as offline rather than escaping', () async {
      final info = build(probe: () async {
        probeCount++;
        throw StateError('probe exploded');
      });

      expect(await info.isConnected, isFalse);
    });

    test('recovers from a probe that throws synchronously', () async {
      // A synchronous throw completes the probe before the in-flight slot is
      // even assigned. If the slot is not cleared afterwards, a stale
      // completed future reports offline for the rest of the session.
      var explode = true;
      final info = build(probe: () {
        probeCount++;
        if (explode) throw StateError('probe exploded synchronously');
        return Future.value(true);
      });

      expect(await info.isConnected, isFalse);

      explode = false;
      expect(await info.isConnected, isTrue);
      expect(probeCount, 2);
    });

    test('invalidate() forces the next call to re-probe', () async {
      final info = build(probe: online);

      await info.isConnected;
      info.invalidate();
      await info.isConnected;

      expect(probeCount, 2);
    });

    test('a zero TTL probes every time', () async {
      final info = build(probe: online, ttl: Duration.zero);

      await info.isConnected;
      await info.isConnected;

      expect(probeCount, 2);
    });
  });
}
