import 'dart:convert';
import 'dart:typed_data';

import 'package:baaba_api_handler/ts_api_handler.dart';
import 'package:dio/dio.dart' show Headers, ResponseBody;
import 'package:flutter_test/flutter_test.dart';

/// A JWT with [claims], unpadded as JWTs are. The signature is not checked.
String _jwt(Object claims) {
  String part(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'HS256'})}.${part(claims)}.c2ln';
}

final _now = DateTime.utc(2026, 11, 17, 12);
int _seconds(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

void main() {
  group('jwtExpired', () {
    test('false for a token well within its lifetime', () {
      final token = _jwt({'exp': _seconds(_now.add(const Duration(hours: 1)))});
      expect(jwtExpired(token, now: _now), isFalse);
    });

    test('true for a token past its exp', () {
      final token = _jwt({
        'exp': _seconds(_now.subtract(const Duration(minutes: 1))),
      });
      expect(jwtExpired(token, now: _now), isTrue);
    });

    test('true within the skew, false outside it', () {
      final token = _jwt({
        'exp': _seconds(_now.add(const Duration(seconds: 20))),
      });
      expect(jwtExpired(token, now: _now), isTrue); // default 30s
      expect(
        jwtExpired(token, now: _now, skew: const Duration(seconds: 10)),
        isFalse,
      );
      expect(jwtExpired(token, now: _now, skew: Duration.zero), isFalse);
    });

    test('exactly at exp counts as expired', () {
      final token = _jwt({'exp': _seconds(_now)});
      expect(jwtExpired(token, now: _now, skew: Duration.zero), isTrue);
    });

    test('restores missing padding whatever the payload length', () {
      // Payload lengths that leave 0, 1 and 2 padding characters off.
      for (final pad in ['', 'a', 'ab', 'abc']) {
        final token = _jwt({
          'exp': _seconds(_now.add(const Duration(hours: 1))),
          'p': pad,
        });
        expect(jwtExpired(token, now: _now), isFalse, reason: 'pad "$pad"');
      }
    });

    test('decodes base64url, not base64', () {
      // `?>` and `??` encode to `-` and `_` in base64url.
      final token = _jwt({
        'exp': _seconds(_now.add(const Duration(hours: 1))),
        'x': '?>??>',
      });
      expect(token.split('.')[1], anyOf(contains('-'), contains('_')));
      expect(jwtExpired(token, now: _now), isFalse);
    });

    test('a fractional exp is fine', () {
      final token = _jwt({'exp': _seconds(_now) + 3600.5});
      expect(jwtExpired(token, now: _now), isFalse);
    });

    test('a far-future exp does not overflow into "expired"', () {
      expect(jwtExpired(_jwt({'exp': 1e15}), now: _now), isFalse);
    });

    test('a token without exp never expires', () {
      expect(jwtExpired(_jwt({'sub': '1'}), now: _now), isFalse);
    });

    test('malformed tokens count as expired', () {
      final malformed = [
        '',
        'not-a-jwt',
        'a.b',
        'a.b.c.d.e', // a JWE: the payload is encrypted
        'eyJhbGciOiJIUzI1NiJ9..sig',
        'eyJhbGciOiJIUzI1NiJ9.!!!.sig',
        'eyJhbGciOiJIUzI1NiJ9.${base64Url.encode(utf8.encode('not json'))}.s',
        _jwt([1, 2, 3]),
        _jwt({'exp': 'tomorrow'}),
        _jwt({'exp': null}),
      ];
      for (final token in malformed) {
        expect(jwtExpired(token, now: _now), isTrue, reason: token);
      }
    });
  });

  group('jwtExpiryCheck', () {
    test('reads the token and checks it', () async {
      String? token = _jwt({'exp': 0});
      final check = jwtExpiryCheck(() async => token);
      expect(await check(), isTrue);

      token = _jwt({
        'exp': _seconds(DateTime.now().add(const Duration(hours: 1))),
      });
      expect(await check(), isFalse);
    });

    test('no token is not expired', () async {
      expect(await jwtExpiryCheck(() async => null)(), isFalse);
      expect(await jwtExpiryCheck(() async => '')(), isFalse);
    });

    test('plugs into AuthConfig.isTokenExpired and refreshes first', () async {
      final expired = _jwt({'exp': 0});
      final fresh = _jwt({
        'exp': _seconds(DateTime.now().add(const Duration(hours: 1))),
      });
      var token = expired;
      var refreshes = 0;
      final sent = <String?>[];

      ApiServices.init(
        ApiConfig(
          baseUrl: 'https://api.test',
          bypassConnectivityCheck: true,
          logging: const ApiLogOptions(enabled: false),
          httpClientAdapter: _Adapter(sent),
          auth: AuthConfig(
            getToken: () async => token,
            isTokenExpired: jwtExpiryCheck(() async => token),
            onTokenRefresh: () async {
              refreshes++;
              token = fresh;
              return true;
            },
          ),
        ),
      );
      addTearDown(ApiServices.reset);

      await ApiServices.instance().get(endpoint: '/me');
      await ApiServices.instance().get(endpoint: '/me', dedupe: false);

      expect(refreshes, 1);
      expect(sent, ['Bearer $fresh', 'Bearer $fresh']);
    });
  });
}

class _Adapter implements HttpClientAdapter {
  final List<String?> sent;
  _Adapter(this.sent);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    sent.add(options.headers['authorization'] as String?);
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
