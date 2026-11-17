import 'package:baaba_api_handler/src/utils/host_pattern.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a trailing dot does not step around a key', () {
    expect(lookupHost({'api.example.com': 1}, 'api.example.com.'), 1);
    expect(lookupHost({'*.example.com': 1}, 'API.example.com.'), 1);
    expect(hostMatches('api.example.com.', 'api.example.com'), isTrue);
  });

  test('an IPv6 key matches with or without brackets', () {
    // Uri.host gives IPv6 without brackets.
    final host = Uri.parse('https://[::1]:8443/').host;
    expect(lookupHost({'[::1]': 1}, host), 1);
    expect(lookupHost({'::1': 1}, host), 1);
  });

  test('wildcards still need a subdomain, and the longest wins', () {
    final keys = {'*.example.com': 1, '*.api.example.com': 2};
    expect(lookupHost(keys, 'example.com'), isNull);
    expect(lookupHost(keys, 'evilexample.com'), isNull);
    expect(lookupHost(keys, 'v2.api.example.com'), 2);
    expect(lookupHost(keys, 'cdn.example.com'), 1);
  });
}
