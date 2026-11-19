// The round-trip tests decode with the same function generated code calls.
// ignore_for_file: invalid_use_of_internal_member
import 'package:baaba_api_handler/annotations.dart' show decodeObfuscated;
import 'package:test/test.dart';

import 'support.dart';

/// Masks the random key and data lists, which differ on every build.
/// The formatter's line-wrapping of the lists is collapsed with them.
String _masked(String output) => output
    .replaceAll(RegExp(r'const <int>\[[^\]]*\]'), 'const <int>[…]')
    .replaceAll(
      RegExp(
        r'decodeObfuscated\(\s*const <int>\[…\],\s*const <int>\[…\],?\s*\)',
      ),
      'decodeObfuscated(const <int>[…], const <int>[…])',
    );

/// Every value an obfuscated output stores, decoded, in order.
List<String> _decoded(String output) {
  final pair = RegExp(
    r'decodeObfuscated\(\s*const <int>\[([^\]]*)\],\s*const <int>\[([^\]]*)\],?\s*\)',
  );
  List<int> ints(String s) => [
    for (final part in s.split(','))
      if (part.trim().isNotEmpty) int.parse(part.trim()),
  ];
  return [
    for (final m in pair.allMatches(output))
      decodeObfuscated(ints(m[1]!), ints(m[2]!)),
  ];
}

const _endpointsTypedef = '''
@BaabaApiEndpoint(path: 'env/endpoints.env')
typedef Endpoints = _Endpoints;
''';

// Distinctive values, so a leak cannot hide behind a member name.
const _endpointsEnv = '''
# Auth
LOGIN=auth/session-start
UPDATE_ORDER_ATTACHMENT=orders/{orderId}/attachments/{attachmentId}

# Kept from envied, unchanged
LEGACY_STATEMENT="statements/{}/period/{}"
EMPTY=
''';

void main() {
  group('@BaabaApiEndpoint on a typedef', () {
    test('golden: named, positional, none, and empty', () async {
      final g = await generate(library(_endpointsTypedef), {
        'env/endpoints.env': _endpointsEnv,
      });

      expect(g.errors, isEmpty);
      expect(
        _masked(g.output!),
        contains('''
abstract final class _Endpoints {
  static final String _v0 = decodeObfuscated(const <int>[…], const <int>[…]);
  static final String _v1 = decodeObfuscated(const <int>[…], const <int>[…]);
  static final String _v2 = decodeObfuscated(const <int>[…], const <int>[…]);
  static final String _v3 = decodeObfuscated(const <int>[…], const <int>[…]);

  static ApiEndpoint get login => ApiEndpoint(_v0);
  static ApiEndpoint updateOrderAttachment(
    Object orderId,
    Object attachmentId,
  ) => ApiEndpoint(_v1).fill([orderId, attachmentId]);
  static ApiEndpoint legacyStatement(Object arg1, Object arg2) =>
      ApiEndpoint(_v2).fill([arg1, arg2]);
  static ApiEndpoint get empty => ApiEndpoint(_v3);
}'''),
      );
      expect(
        g.output,
        contains('// ignore_for_file: invalid_use_of_internal_member'),
      );
    });

    test('decoding gives back every value, placeholders as {}', () async {
      final g = await generate(library(_endpointsTypedef), {
        'env/endpoints.env': _endpointsEnv,
      });
      expect(_decoded(g.output!), [
        'auth/session-start',
        'orders/{}/attachments/{}',
        'statements/{}/period/{}',
        '',
      ]);
    });

    test('no plain value appears anywhere in the output', () async {
      final g = await generate(library(_endpointsTypedef), {
        'env/endpoints.env': _endpointsEnv,
      });
      final output = g.output!;
      for (final leak in [
        'auth/session-start',
        'session-start',
        'auth',
        'orders/{orderId}/attachments/{attachmentId}',
        'orders/{}/attachments/{}',
        'orders',
        'attachments',
        'statements/{}/period/{}',
        'statements',
        'period',
      ]) {
        expect(output, isNot(contains(leak)), reason: leak);
      }
      // Not even a comment: the only string-ish text is code.
      expect(output, isNot(contains("'")));
      expect(output, isNot(contains('"')));
    });

    test('every build writes different output for the same input', () async {
      final files = {'env/endpoints.env': _endpointsEnv};
      final first = await generate(library(_endpointsTypedef), files);
      final second = await generate(library(_endpointsTypedef), files);

      expect(first.output, isNot(second.output));
      expect(_masked(first.output!), _masked(second.output!));
      expect(_decoded(first.output!), _decoded(second.output!));
    });

    test('obfuscate: false writes plain literals', () async {
      final g = await generate(
        library('''
@BaabaApiEndpoint(path: 'env/endpoints.env', obfuscate: false)
typedef Endpoints = _Endpoints;
'''),
        {'env/endpoints.env': "LOGIN=auth/login\nQUOTE=it's/\$x"},
      );
      expect(g.output, contains("static const String _v0 = 'auth/login';"));
      expect(g.output, contains(r"static const String _v1 = 'it\'s/\$x';"));
      expect(g.output, isNot(contains('decodeObfuscated')));
    });
  });

  group('@BaabaApiEndpoint on a class (the envied shape)', () {
    test('generates only the declared fields, as templates', () async {
      final g = await generate(
        library('''
@BaabaApiEndpoint(path: 'env/endpoints.env')
abstract final class Endpoints {
  static final String legacyStatement = _Endpoints.legacyStatement;
  @BaabaApiField(name: 'UPDATE_ORDER_ATTACHMENT')
  static final ApiEndpoint attachment = _Endpoints.attachment;
}
'''),
        {'env/endpoints.env': _endpointsEnv},
      );

      expect(g.errors, isEmpty);
      expect(
        _masked(g.output!),
        contains('''
  static ApiEndpoint get legacyStatement => ApiEndpoint(_v0);
  static ApiEndpoint get attachment => ApiEndpoint(_v1);
}'''),
      );
      expect(_decoded(g.output!), [
        'statements/{}/period/{}',
        'orders/{}/attachments/{}',
      ]);
      expect(g.output, isNot(contains('login')));
    });

    test('reads a field named as envied would (no UPPER_SNAKE key)', () async {
      final g = await generate(
        library('''
@BaabaApiEndpoint(path: 'env/endpoints.env')
abstract final class Endpoints {
  static final String orderList = _Endpoints.orderList;
}
'''),
        {'env/endpoints.env': 'orderList=orders'},
      );
      expect(_decoded(g.output!), ['orders']);
    });

    test('a digit stays with its word: s3Bucket reads S3_BUCKET', () async {
      // The typedef form maps S3_BUCKET to s3Bucket, so the class form has
      // to map back to it — this read S_3_BUCKET and failed the build.
      final g = await generate(
        library('''
@BaabaApiEnvironment(path: 'env/app.env')
abstract final class Env {
  static final String s3Bucket = _Env.s3Bucket;
  static final String oauth2ClientId = _Env.oauth2ClientId;
  static final String baseURLPath = _Env.baseURLPath;
}
'''),
        {
          'env/app.env':
              'S3_BUCKET=media-store\nOAUTH2_CLIENT_ID=client-x\n'
              'BASE_URL_PATH=api',
        },
      );
      expect(g.errors, isEmpty);
      expect(_decoded(g.output!), ['media-store', 'client-x', 'api']);
    });

    test("1.0.0's split-digit key is still found", () async {
      final g = await generate(
        library('''
@BaabaApiEnvironment(path: 'env/app.env')
abstract final class Env {
  static final String s3Bucket = _Env.s3Bucket;
}
'''),
        {'env/app.env': 'S_3_BUCKET=media-store'},
      );
      expect(g.errors, isEmpty);
      expect(_decoded(g.output!), ['media-store']);
    });
  });

  group('@BaabaApiEnvironment', () {
    const stageEnv = '''
BASE_URL="https://api.example.com/v1"
TIMEOUT_SECONDS=45
VERBOSE=TRUE # case does not matter
PROXY=
HUB=wss://hub.example.com/ws
''';

    test('golden: typed fields, empty values, @BaabaApiField', () async {
      final g = await generate(
        library('''
@BaabaApiEnvironment(path: 'env/stage.env', obfuscate: false)
abstract final class StageEnv {
  static final Uri baseUrl = _StageEnv.baseUrl;
  static final int timeoutSeconds = _StageEnv.timeoutSeconds;
  static final bool verbose = _StageEnv.verbose;
  static final String proxy = _StageEnv.proxy;
  static final String? proxyOrNull = _StageEnv.proxyOrNull;
  @BaabaApiField(name: 'PROXY')
  static final int? proxyPort = _StageEnv.proxyPort;
  @BaabaApiField(name: 'HUB')
  static final Uri hubUrl = _StageEnv.hubUrl;
}
'''),
        {'env/stage.env': '$stageEnv\nPROXY_OR_NULL=\n'},
      );

      expect(g.errors, isEmpty);
      expect(
        g.output,
        contains('''
abstract final class _StageEnv {
  static const String _v0 = 'https://api.example.com/v1';
  static const String _v1 = '+0000000000000000045';
  static const String _v2 = '1';
  static const String _v3 = '';
  static const String _v4 = 'wss://hub.example.com/ws';

  static final Uri baseUrl = Uri.parse(_v0);
  static final int timeoutSeconds = int.parse(_v1);
  static final bool verbose = _v2.codeUnitAt(0) == 49;
  static String get proxy => _v3;
  static String? get proxyOrNull => null;
  static int? get proxyPort => null;
  static final Uri hubUrl = Uri.parse(_v4);
}'''),
      );
    });

    test('obfuscated, round-trips and leaks nothing', () async {
      final g = await generate(
        library('''
@BaabaApiEnvironment(path: 'env/stage.env')
abstract final class StageEnv {
  static final Uri baseUrl = _StageEnv.baseUrl;
  static final int timeoutSeconds = _StageEnv.timeoutSeconds;
  static final bool verbose = _StageEnv.verbose;
}
'''),
        {'env/stage.env': stageEnv},
      );
      expect(_decoded(g.output!), [
        'https://api.example.com/v1',
        '+0000000000000000045',
        '1',
      ]);
      // ('45' is not checked: digits appear in the random lists.)
      for (final leak in ['example.com', 'https', 'true']) {
        expect(g.output, isNot(contains(leak)), reason: leak);
      }
    });

    test('a bool or int does not show its value in its length', () async {
      Future<List<int>> lengths(String env) async {
        final g = await generate(
          library('''
@BaabaApiEnvironment(path: 'env/f.env')
abstract final class F {
  static final bool flag = _F.flag;
  static final int n = _F.n;
}
'''),
          {'env/f.env': env},
        );
        expect(g.errors, isEmpty);
        return [for (final v in _decoded(g.output!)) v.length];
      }

      expect(
        await lengths('FLAG=true\nN=7'),
        await lengths('FLAG=false\nN=-1234567'),
      );
    });

    test('const helper fields are left alone', () async {
      final g = await generate(
        library('''
@BaabaApiEnvironment(path: 'env/f.env', obfuscate: false)
abstract final class F {
  static const int version = 3;
  static final String host = _F.host;
}
'''),
        {'env/f.env': 'HOST=a'},
      );
      expect(g.errors, isEmpty);
      expect(g.output, isNot(contains('version')));
    });

    test('on a typedef, every key is a String', () async {
      final g = await generate(
        library('''
@BaabaApiEnvironment(path: 'env/stage.env', obfuscate: false)
typedef StageEnv = _StageEnv;
'''),
        {'env/stage.env': 'BASE_URL=https://api.example.com\nPROXY='},
      );
      expect(g.output, contains('static String get baseUrl => _v0;'));
      expect(g.output, contains('static String get proxy => _v1;'));
    });
  });

  group('build errors', () {
    Future<String> errorFor(
      String declaration,
      Map<String, String> files,
    ) async {
      final g = await generate(library(declaration), files);
      expect(g.output, isNull, reason: 'the build should have failed');
      expect(g.errors, isNotEmpty);
      return g.errors.join('\n');
    }

    test('a missing file says to add env/** to build.yaml', () async {
      final message = await errorFor(_endpointsTypedef, {});
      expect(message, contains('cannot read "env/endpoints.env"'));
      expect(message, contains('build.yaml'));
      expect(message, contains('- env/**'));
      expect(message, contains('- lib/**'));
    });

    test('a key named after an Object member is rejected', () async {
      final message = await errorFor(_endpointsTypedef, {
        'env/endpoints.env': 'LOGIN=a\nHASH_CODE=b',
      });
      expect(message, contains('env/endpoints.env:2: key HASH_CODE'));
    });

    test('a placeholder that would shadow ApiEndpoint is rejected', () async {
      final message = await errorFor(_endpointsTypedef, {
        'env/endpoints.env': 'ITEM=items/{ApiEndpoint}',
      });
      expect(message, contains('{ApiEndpoint}'));
    });

    test('an untyped class field says to declare its type', () async {
      final message = await errorFor(
        '''
@BaabaApiEndpoint(path: 'env/endpoints.env')
abstract final class Endpoints {
  static final login = _Endpoints.login;
}
''',
        {'env/endpoints.env': 'LOGIN=auth/login'},
      );
      expect(message, contains('Endpoints.login has no declared type'));
    });

    test('a class field named like generated storage is rejected', () async {
      final message = await errorFor(
        '''
@BaabaApiEnvironment(path: 'env/stage.env')
abstract final class StageEnv {
  static final String _v0 = _StageEnv._v0;
  static String get baseUrl => _v0;
}
''',
        {'env/stage.env': '_v0=https://api.example.com'},
      );
      expect(message, contains('StageEnv._v0 clashes with a name'));
    });

    test('a duplicate key, with both lines', () async {
      final message = await errorFor(_endpointsTypedef, {
        'env/endpoints.env': 'LOGIN=a\n\nLOGIN=b',
      });
      expect(
        message,
        contains(
          'env/endpoints.env:3: duplicate key LOGIN (first defined on line 1)',
        ),
      );
    });

    test('a malformed placeholder, with key and line', () async {
      final message = await errorFor(_endpointsTypedef, {
        'env/endpoints.env': 'LOGIN=a\nORDER=orders/{orderId',
      });
      expect(
        message,
        contains('env/endpoints.env:2: ORDER: malformed placeholder'),
      );
    });

    test('a key that is not a valid Dart identifier', () async {
      final message = await errorFor(_endpointsTypedef, {
        'env/endpoints.env': 'LOGIN=a\nCLASS=b',
      });
      expect(
        message,
        contains('env/endpoints.env:2: key CLASS gives the name "class"'),
      );
    });

    test('two keys generating the same name', () async {
      final message = await errorFor(_endpointsTypedef, {
        'env/endpoints.env': 'LOGIN=a\nlogin=b',
      });
      expect(
        message,
        contains('keys LOGIN (line 1) and login both generate "login"'),
      );
    });

    test('a malformed line', () async {
      final message = await errorFor(_endpointsTypedef, {
        'env/endpoints.env': 'LOGIN=a\n2FA=b',
      });
      expect(message, contains('env/endpoints.env:2: invalid key "2FA"'));
    });

    test('a key the class asks for but the file lacks', () async {
      final message = await errorFor(
        '''
@BaabaApiEnvironment(path: 'env/stage.env')
abstract final class StageEnv {
  static final Uri baseUrl = _StageEnv.baseUrl;
}
''',
        {'env/stage.env': 'TIMEOUT=1'},
      );
      expect(
        message,
        contains('env/stage.env has no key BASE_URL for StageEnv.baseUrl'),
      );
      expect(message, contains('@BaabaApiField(name: ...)'));
    });

    test('a value that does not parse as the field type', () async {
      Future<String> forType(String type, String value) => errorFor(
        '''
@BaabaApiEnvironment(path: 'env/stage.env')
abstract final class StageEnv {
  static final $type x = _StageEnv.x;
}
''',
        {'env/stage.env': 'OTHER=1\nX=$value'},
      );
      expect(
        await forType('int', 'forty'),
        contains(
          'env/stage.env:2: X must be an int for StageEnv.x, got "forty"',
        ),
      );
      expect(
        await forType('bool', 'yes'),
        contains('env/stage.env:2: X must be true or false'),
      );
      expect(
        await forType('Uri', 'http://[::1'),
        contains('env/stage.env:2: X must be a URI'),
      );
      expect(
        await forType('int', ''),
        contains('env/stage.env:2: X is empty, but StageEnv.x is int'),
      );
      expect(
        await forType('double', '1.5'),
        contains('supported types are String, int, bool and Uri'),
      );
    });

    test('an annotation on something other than a typedef or class', () async {
      final message = await errorFor(
        "@BaabaApiEndpoint(path: 'env/endpoints.env')\nvoid endpoints() {}",
        {'env/endpoints.env': 'LOGIN=a'},
      );
      expect(message, contains('goes on a typedef'));
    });
  });
}
