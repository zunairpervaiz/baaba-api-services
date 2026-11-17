import 'package:baaba_api_handler/src/utils/request_key.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('request keys', () {
    test('argument order does not change the key', () {
      expect(
        buildUrlKey(endpoint: '/p', params: {'a': 1, 'b': 2}),
        buildUrlKey(endpoint: '/p', params: {'b': 2, 'a': 1}),
      );
    });

    test('query parameters produce distinct keys', () {
      expect(
        buildUrlKey(endpoint: '/p', params: {'page': 1}),
        isNot(buildUrlKey(endpoint: '/p', params: {'page': 2})),
      );
    });

    test('a null value is a bare key, distinct from the string "null"', () {
      expect(
        buildUrlKey(endpoint: '/p', params: {'a': null}),
        isNot(buildUrlKey(endpoint: '/p', params: {'a': 'null'})),
      );
    });

    test('baseUrl is joined without doubling the slash', () {
      expect(
        buildUrlKey(baseUrl: 'https://api.test/', endpoint: '/users'),
        'https://api.test/users',
      );
      expect(
        buildUrlKey(baseUrl: 'https://api.test', endpoint: 'users'),
        'https://api.test/users',
      );
    });

    test('an absolute endpoint ignores baseUrl', () {
      expect(
        buildUrlKey(
          baseUrl: 'https://api.test',
          endpoint: 'https://cdn.other/thing',
        ),
        'https://cdn.other/thing',
      );
    });

    test('request keys separate methods and bodies', () {
      final get = buildRequestKey(method: 'GET', endpoint: '/a');
      final post = buildRequestKey(method: 'POST', endpoint: '/a');
      final postB = buildRequestKey(
        method: 'POST',
        endpoint: '/a',
        data: {'x': 1},
      );

      expect(get, isNot(post));
      expect(post, isNot(postB));
    });

    test('an unencodable body returns null, meaning "do not collapse"', () {
      expect(
        buildRequestKey(method: 'GET', endpoint: '/a', data: Object()),
        isNull,
      );
    });
  });
}
