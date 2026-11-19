import 'dart:typed_data';

import 'package:baaba_api_handler/src/utils/binary_log_summary.dart';
import 'package:baaba_api_handler/testing.dart';
import 'package:dio/dio.dart' show Headers, ResponseBody;
import 'package:flutter_test/flutter_test.dart';

/// A PNG's signature and some pixels: 1000 bytes.
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, //
  for (var i = 0; i < 996; i++) i % 256,
]);

class _BytesAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromBytes(
    _png,
    200,
    headers: {
      Headers.contentTypeHeader: ['image/png'],
    },
  );

  @override
  void close({bool force = false}) {}
}

void main() {
  tearDown(ApiServices.reset);

  group('logging a binary response', () {
    Future<(String, Object?)> fetchPhoto({bool redact = true}) async {
      final lines = <String>[];
      ApiServices.init(
        ApiConfig(
          baseUrl: 'https://api.test',
          bypassConnectivityCheck: true,
          httpClientAdapter: _BytesAdapter(),
          retry: const RetryPolicy.disabled(),
          logging: ApiLogOptions(
            redact: redact,
            logPrint: (o) => lines.add('$o'),
          ),
        ),
      );
      final result = await ApiServices.instance().get(
        endpoint: '/files/photo.png',
        responseType: ResponseType.bytes,
      );
      return (lines.join('\n'), result.getRight().toNullable()!.data);
    }

    test('prints its size and type instead of the bytes', () async {
      final (log, _) = await fetchPhoto();

      expect(log, contains('<1000 bytes, image/png>'));
      // The bytes would print as `137, 80, 78, 71, ...`.
      expect(log, isNot(contains('137, 80, 78, 71')));
    });

    test('does so with redaction off too', () async {
      final (log, _) = await fetchPhoto(redact: false);

      expect(log, contains('<1000 bytes, image/png>'));
      expect(log, isNot(contains('137, 80, 78, 71')));
    });

    test('still hands the caller every byte', () async {
      final (_, data) = await fetchPhoto();

      expect(data, _png);
    });
  });

  group('BinaryLogSummary', () {
    Response<dynamic> response(
      Object? data, {
      ResponseType type = ResponseType.json,
      String? contentType,
    }) => Response<dynamic>(
      data: data,
      requestOptions: RequestOptions(path: '/x', responseType: type),
      statusCode: 200,
      headers: Headers.fromMap({
        if (contentType != null) Headers.contentTypeHeader: [contentType],
      }),
    );

    test('summarizes a List<int> asked for as bytes', () {
      final summary = BinaryLogSummary.response(
        response([1, 2, 3], type: ResponseType.bytes),
      );

      expect(summary.data, '<3 bytes>');
    });

    test('summarizes typed data whatever the response type', () {
      final summary = BinaryLogSummary.response(
        response(Uint8List(5), contentType: 'application/pdf; charset=binary'),
      );

      expect(summary.data, '<5 bytes, application/pdf>');
    });

    test('leaves a JSON list of numbers alone', () {
      final original = response([1, 2, 3]);

      expect(BinaryLogSummary.response(original), same(original));
    });

    test('summarizes a typed-data request body but not a JSON list', () {
      final bytes = RequestOptions(
        path: '/x',
        data: Uint8List(8),
        contentType: 'application/octet-stream',
      );
      final json = RequestOptions(path: '/x', data: [1, 2, 3]);

      expect(
        BinaryLogSummary.request(bytes).data,
        '<8 bytes, application/octet-stream>',
      );
      expect(BinaryLogSummary.request(json), same(json));
    });

    test('keeps the request extra the logger reads its timing from', () {
      final options = RequestOptions(path: '/x', data: Uint8List(1));
      options.extra['start'] = 1;

      expect(BinaryLogSummary.request(options).extra, same(options.extra));
    });

    test('summarizes a binary body on an error response', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/x'),
        response: response(Uint8List(4), contentType: 'image/jpeg'),
      );

      expect(
        BinaryLogSummary.error(error).response!.data,
        '<4 bytes, image/jpeg>',
      );
    });
  });
}
