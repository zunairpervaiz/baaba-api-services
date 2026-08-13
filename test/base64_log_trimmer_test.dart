import 'dart:typed_data';

import 'package:baaba_api_handler/src/dio_factory.dart';
import 'package:baaba_api_handler/ts_api_handler.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// A base64 run of the size a fingerprint or a photograph actually reaches.
String base64Blob([int chars = 4000]) =>
    ('iVBORw0KGgoAAAANSUhEUgAAAu4AAAK8CAYAAAA' * (chars ~/ 39 + 1))
        .substring(0, chars);

class _StubAdapter implements HttpClientAdapter {
  final String body;

  _StubAdapter(this.body);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      ResponseBody.fromString(body, 200, headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      });

  @override
  void close({bool force = false}) {}
}

void main() {
  late List<String> out;
  late Base64LogTrimmer trim;

  setUp(() {
    out = [];
    trim = Base64LogTrimmer(sink: (o) => out.add(o.toString()));
  });

  group('what passes through untouched', () {
    test('ordinary prose', () {
      trim('║ "detail": "The case could not be found."');

      expect(out, ['║ "detail": "The case could not be found."']);
    });

    test('identifiers and case numbers below the threshold', () {
      const line = '║ "caseNo": "FIR-2026-000148-ISB",';
      trim(line);

      expect(out, [line]);
    });

    test('a stack trace', () {
      const line =
          '║ #0      _MyHomePageState.build (package:app/main.dart:42:5)';
      trim(line);

      expect(out, [line]);
    });

    test('box drawing and empty lines', () {
      trim('╔ Body');
      trim('║');
      trim('╚══════════════════');

      expect(out, ['╔ Body', '║', '╚══════════════════']);
    });
  });

  group('what gets collapsed', () {
    test('keeps the key and a recognisable head of the value', () {
      trim('║      "data": ${base64Blob(400)}');

      expect(out.first, startsWith('║      "data": iVBORw0KGgoAAAANSUhEUg'));
      expect(out.first, endsWith('…'));
      expect(out.first.length, lessThan(60));
    });

    test('swallows continuation lines and reports the total', () {
      trim('║      "data": ${base64Blob(90)}');
      trim('║      ${base64Blob(90)}');
      trim('║      ${base64Blob(90)}');
      trim('║ "next": "field"');

      expect(out, hasLength(3));
      expect(out[0], startsWith('║      "data": iVBORw0KGgo'));
      expect(out[1], matches(RegExp(r'…\[\d+ base64 chars elided\]')));
      expect(out[2], '║ "next": "field"');
    });

    test('the reported count is the characters actually dropped', () {
      // 100 chars on the first line, of which 24 are kept -> 76 elided,
      // plus two full continuation lines of 100 -> 276 total.
      trim('║ "data": ${base64Blob(100)}');
      trim('║ ${base64Blob(100)}');
      trim('║ ${base64Blob(100)}');
      trim('║ "end": 1');

      expect(out[1], contains('[276 base64 chars elided]'));
    });

    test('a short base64-shaped value is left alone', () {
      // Below minRunLength — could be an id, so it must survive intact.
      const line = '║ "hash": "aVBORw0KGgoAAAANSUhE"';
      trim(line);

      expect(out, [line]);
    });

    test('handles several blobs in one body', () {
      trim('║ "photo": ${base64Blob(200)}');
      trim('║ "caption": "front view"');
      trim('║ "print": ${base64Blob(200)}');
      trim('║ "finger": "left index"');

      expect(out.where((l) => l.contains('elided')), hasLength(2));
      expect(out, contains('║ "caption": "front view"'));
      expect(out, contains('║ "finger": "left index"'));
    });
  });

  group('configuration', () {
    test('minRunLength keeps longer identifiers readable', () {
      final strict = Base64LogTrimmer(
        sink: (o) => out.add(o.toString()),
        minRunLength: 200,
      );
      final line = '║ "ref": ${base64Blob(100)}';

      strict(line);

      expect(out, [line]);
    });

    test('keptChars controls how much of the head survives', () {
      final terse = Base64LogTrimmer(
        sink: (o) => out.add(o.toString()),
        keptChars: 4,
      );

      terse('║ "data": ${base64Blob(400)}');

      expect(out.first, '║ "data": iVBO…');
    });
  });

  group('state isolation', () {
    test('two trimmers do not share the elided count', () {
      final otherOut = <String>[];
      final other = Base64LogTrimmer(sink: (o) => otherOut.add(o.toString()));

      trim('║ ${base64Blob(100)}');
      other('║ "unrelated": "value"');

      // `other` must not report the characters `trim` swallowed.
      expect(otherOut, ['║ "unrelated": "value"']);
    });
  });

  group('end to end through the real logger', () {
    test('a base64 response costs a few lines instead of hundreds', () async {
      final noisy = <String>[];
      final quiet = <String>[];

      Future<void> run(List<String> sink, {required bool trimBase64}) async {
        final dio = DioFactory().getDio(
          config: ApiConfig(
            baseUrl: 'https://example.com',
            logging: ApiLogOptions(
              trimBase64: trimBase64,
              logPrint: (o) => sink.add(o.toString()),
            ),
          ),
        );
        dio.httpClientAdapter = _StubAdapter(
          '{"caseNo":"FIR-2026-000148","photo":"${base64Blob(20000)}"}',
        );
        await dio.get('/records/1');
      }

      await run(noisy, trimBase64: false);
      await run(quiet, trimBase64: true);

      expect(noisy.length, greaterThan(200));
      expect(quiet.length, lessThan(20));

      // The fields you actually wanted are still there.
      expect(quiet.join('\n'), contains('FIR-2026-000148'));
      expect(quiet.join('\n'), contains('elided'));
    });

    test('a custom logPrint still receives the trimmed lines', () async {
      final sink = <String>[];
      final dio = DioFactory().getDio(
        config: ApiConfig(
          baseUrl: 'https://example.com',
          logging: ApiLogOptions(
            trimBase64: true,
            logPrint: (o) => sink.add(o.toString()),
          ),
        ),
      );
      dio.httpClientAdapter = _StubAdapter('{"photo":"${base64Blob(5000)}"}');

      await dio.get('/records/1');

      expect(sink, isNotEmpty);
      expect(sink.join('\n'), contains('elided'));
    });

    test('two clients each get their own trimmer', () {
      const config = ApiConfig(logging: ApiLogOptions(trimBase64: true));

      final first = DioFactory().getDio(config: config);
      final second = DioFactory().getDio(config: config);

      expect(first, isNot(same(second)));
    });

    test('off by default, so existing log output is unchanged', () async {
      final sink = <String>[];
      final dio = DioFactory().getDio(
        config: ApiConfig(
          baseUrl: 'https://example.com',
          logging: ApiLogOptions(logPrint: (o) => sink.add(o.toString())),
        ),
      );
      dio.httpClientAdapter = _StubAdapter('{"photo":"${base64Blob(4000)}"}');

      await dio.get('/records/1');

      expect(sink.join('\n'), isNot(contains('elided')));
    });
  });
}
