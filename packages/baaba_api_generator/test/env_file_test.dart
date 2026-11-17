import 'package:baaba_api_generator/src/env_file.dart';
import 'package:test/test.dart';

Map<String, String> _values(String source) => {
  for (final e in parseEnv(source)) e.key: e.value,
};

Matcher _errorAt(int line, String message) => throwsA(
  isA<EnvFormatException>()
      .having((e) => e.line, 'line', line)
      .having((e) => e.message, 'message', contains(message)),
);

void main() {
  test('reads KEY=value lines, skipping comments and blank lines', () {
    final entries = parseEnv('''
# Endpoints
LOGIN=auth/login

  # indented comment
USERS = users
''');
    expect(
      [for (final e in entries) (e.key, e.value, e.line)],
      [('LOGIN', 'auth/login', 2), ('USERS', 'users', 5)],
    );
  });

  test('quotes are optional', () {
    expect(_values('A="x y"\nB=\'x y\'\nC=x y'), {
      'A': 'x y',
      'B': 'x y',
      'C': 'x y',
    });
  });

  test('double quotes understand escapes; single quotes are literal', () {
    expect(
      _values(
        r'A="a\"b\\c\nd"'
        '\n'
        r"B='a\nb'",
      ),
      {'A': 'a"b\\c\nd', 'B': r'a\nb'},
    );
  });

  test('a trailing comment needs whitespace before the #', () {
    expect(
      _values('A=https://x.example.com/#/home\nB=value # note\nC="a # b" # c'),
      {'A': 'https://x.example.com/#/home', 'B': 'value', 'C': 'a # b'},
    );
  });

  test('values may be empty', () {
    expect(_values('A=\nB=""\nC= # nothing'), {'A': '', 'B': '', 'C': ''});
    expect(_values('COLOR=#fff'), {'COLOR': '#fff'});
  });

  test('accepts export, CRLF line endings and a BOM', () {
    expect(_values('﻿export A=1\r\nB=2\r\n'), {'A': '1', 'B': '2'});
  });

  test('keeps an = inside the value', () {
    expect(_values('Q=a=b&c=d'), {'Q': 'a=b&c=d'});
  });

  group('errors', () {
    test('duplicate key, naming both lines', () {
      expect(
        () => parseEnv('A=1\nB=2\nA=3'),
        _errorAt(3, 'duplicate key A (first defined on line 1)'),
      );
    });

    test('a line without =', () {
      expect(
        () => parseEnv('A=1\nnonsense'),
        _errorAt(2, 'expected KEY=value'),
      );
    });

    test('an invalid key', () {
      expect(() => parseEnv('2FA=x'), _errorAt(1, 'invalid key "2FA"'));
      expect(() => parseEnv('A-B=x'), _errorAt(1, 'invalid key'));
    });

    test('an unterminated quote', () {
      expect(() => parseEnv('A="x'), _errorAt(1, 'unterminated'));
    });

    test('text after a closing quote', () {
      expect(() => parseEnv('A="x" y'), _errorAt(1, 'after the closing quote'));
    });
  });
}
