import 'package:baaba_api_generator/src/names.dart';
import 'package:baaba_api_generator/src/placeholders.dart';
import 'package:test/test.dart';

void main() {
  test('UPPER_SNAKE keys become camelCase members', () {
    expect(memberNameForKey('LOGIN'), 'login');
    expect(
      memberNameForKey('UPDATE_ORDER_ATTACHMENT'),
      'updateOrderAttachment',
    );
    expect(memberNameForKey('API_V2_URL'), 'apiV2Url');
    expect(memberNameForKey('updateOrder'), 'updateOrder');
  });

  test('field names map to UPPER_SNAKE keys', () {
    expect(keyForMemberName('baseUrl'), 'BASE_URL');
    expect(keyForMemberName('apiV2Url'), 'API_V2_URL');
    expect(keyForMemberName('timeout'), 'TIMEOUT');
    expect(keyForMemberName('hubURL'), 'HUB_URL');
  });

  test('member names must be public, non-reserved identifiers', () {
    expect(isValidMemberName('login'), isTrue);
    expect(isValidMemberName('class'), isFalse);
    expect(isValidMemberName('1x'), isFalse);
    expect(isValidMemberName(''), isFalse);
  });

  group('templates', () {
    test('named placeholders keep their names, in order', () {
      final t = parseTemplate('orders/{orderId}/attachments/{attachmentId}');
      expect(t.positional, 'orders/{}/attachments/{}');
      expect(t.parameters, ['orderId', 'attachmentId']);
    });

    test('positional placeholders become arg1, arg2, ...', () {
      final t = parseTemplate('a/{}/b/{}');
      expect(t.positional, 'a/{}/b/{}');
      expect(t.parameters, ['arg1', 'arg2']);
    });

    test('no placeholders', () {
      expect(parseTemplate('auth/login').parameters, isEmpty);
    });

    for (final (template, message) in [
      ('a/{id', 'never closed'),
      ('a/id}', 'closes nothing'),
      ('a/{1x}', 'valid Dart identifier'),
      ('a/{ id }', 'valid Dart identifier'),
      ('a/{class}', 'valid Dart identifier'),
      ('a/{{id}}', 'nested'),
      ('a/{id}/b/{id}', 'appears twice'),
      ('a/{}/b/{id}', 'mixes'),
    ]) {
      test('rejects "$template"', () {
        expect(
          () => parseTemplate(template),
          throwsA(
            isA<TemplateException>().having(
              (e) => e.message,
              'message',
              contains(message),
            ),
          ),
        );
      });
    }
  });
}
