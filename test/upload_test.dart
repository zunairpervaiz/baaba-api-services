import 'dart:io';

import 'package:baaba_api_handler/src/api_service.dart';
import 'package:baaba_api_handler/src/utils/constants.dart';
import 'package:baaba_api_handler/src/utils/network_info.dart';
import 'package:baaba_api_handler/ts_api_handler.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockDio extends Mock implements Dio {}

class MockNetworkInfo extends Mock implements NetworkInfo {}

void main() {
  late MockDio mockDio;
  late MockNetworkInfo mockNetworkInfo;
  late ApiServices api;
  late List<Invocation> calls;

  setUp(() {
    ApiServices.reset();
    calls = [];
    mockDio = MockDio();
    mockNetworkInfo = MockNetworkInfo();

    registerFallbackValue(RequestOptions(path: ''));
    registerFallbackValue(Options());
    when(() => mockNetworkInfo.isConnected).thenAnswer((_) async => true);

    when(() => mockDio.request<dynamic>(
          any(),
          data: any(named: 'data'),
          queryParameters: any(named: 'queryParameters'),
          options: any(named: 'options'),
          cancelToken: any(named: 'cancelToken'),
          onSendProgress: any(named: 'onSendProgress'),
          onReceiveProgress: any(named: 'onReceiveProgress'),
        )).thenAnswer((invocation) async {
      calls.add(invocation);
      return Response(
        requestOptions: RequestOptions(path: '/upload'),
        statusCode: 200,
        data: {'ok': true},
      );
    });

    api = ApiServicesImplementation.instanceFor(
      dio: mockDio,
      networkInfo: mockNetworkInfo,
    );
  });

  tearDown(ApiServices.reset);

  FormData sentFormData() => calls.single.namedArguments[#data] as FormData;

  Options sentOptions() => calls.single.namedArguments[#options] as Options;

  test('builds FormData from fields and in-memory files', () async {
    final result = await api.upload(
      endpoint: '/documents',
      fields: {'title': 'Q3 report', 'visibility': 'team'},
      files: [
        UploadFile.fromBytes(
          field: 'thumbnail',
          bytes: [1, 2, 3],
          filename: 'thumb.png',
          contentType: 'image/png',
        ),
      ],
    );

    expect(result.isRight(), isTrue);

    final form = sentFormData();
    // MapEntry has no value equality, so compare on the pairs themselves.
    expect(
      form.fields.map((e) => '${e.key}=${e.value}'),
      containsAll(['title=Q3 report', 'visibility=team']),
    );
    expect(form.files.single.key, 'thumbnail');
    expect(form.files.single.value.filename, 'thumb.png');
    expect(form.files.single.value.contentType.toString(), 'image/png');
  });

  test('strips a JSON content-type from caller-supplied headers too', () async {
    // An upload that also needs a tenant header should not have to know to
    // omit the content type; sending it would replace the multipart type Dio
    // generates, boundary included.
    await api.upload(
      endpoint: '/documents',
      headers: {'content-type': 'application/json', 'X-Tenant-Id': 'my-org'},
      files: [
        UploadFile.fromBytes(field: 'f', bytes: [1], filename: 'a.bin'),
      ],
    );

    final headers = sentOptions().headers!;
    expect(headers.containsKey('content-type'), isFalse);
    expect(headers['X-Tenant-Id'], 'my-org');
  });

  test('keeps an explicit multipart content-type', () async {
    await api.upload(
      endpoint: '/documents',
      headers: {'content-type': 'multipart/related; boundary=xyz'},
      files: [
        UploadFile.fromBytes(field: 'f', bytes: [1], filename: 'a.bin'),
      ],
    );

    expect(sentOptions().headers!['content-type'],
        'multipart/related; boundary=xyz');
  });

  test('leaves headers alone for a non-multipart body', () async {
    await api.post(
      endpoint: '/users',
      data: {'name': 'Ada'},
      headers: {'content-type': 'application/json'},
    );

    expect(sentOptions().headers!['content-type'], applicationJson);
  });

  test('does not send a JSON content-type with a multipart body', () async {
    // application/json here would replace the multipart type Dio generates,
    // boundary included, and the server would reject the upload.
    await api.upload(
      endpoint: '/documents',
      files: [
        UploadFile.fromBytes(field: 'f', bytes: [1], filename: 'a.bin'),
      ],
    );

    final headers = sentOptions().headers!;
    expect(headers.containsKey(contentType), isFalse);
    expect(headers[accept], applicationJson);
  });

  test('keeps content-type parameters instead of mangling the subtype',
      () async {
    await api.upload(
      endpoint: '/documents',
      files: [
        UploadFile.fromBytes(
          field: 'f',
          bytes: [1],
          filename: 'a.csv',
          contentType: 'text/csv; charset=utf-8',
        ),
      ],
    );

    final sent = sentFormData().files.single.value.contentType!;
    expect(sent.type, 'text');
    expect(sent.subtype, 'csv');
    expect(sent.parameters['charset'], 'utf-8');
  });

  test('an unparseable content-type falls back to inference', () async {
    await api.upload(
      endpoint: '/documents',
      files: [
        UploadFile.fromBytes(
          field: 'f',
          bytes: [1],
          filename: 'a.png',
          contentType: 'not a media type',
        ),
      ],
    );

    // Dio infers from the filename rather than the upload failing.
    expect(
        sentFormData().files.single.value.contentType?.mimeType, 'image/png');
  });

  test('defaults to POST and honours an explicit method', () async {
    await api.upload(endpoint: '/documents', fields: {'a': '1'});
    expect(sentOptions().method, 'POST');

    calls.clear();
    await api.upload(
      endpoint: '/documents',
      method: HttpMethod.put,
      fields: {'a': '1'},
    );
    expect(sentOptions().method, 'PUT');
  });

  test('forwards the progress callback', () async {
    void onProgress(int sent, int total) {}

    await api.upload(
      endpoint: '/documents',
      fields: {'a': '1'},
      onSendProgress: onProgress,
    );

    expect(calls.single.namedArguments[#onSendProgress], same(onProgress));
  });

  test('reads a file from disk', () async {
    final file = File('${Directory.systemTemp.path}/baaba_upload_test.txt');
    await file.writeAsString('hello');
    addTearDown(() => file.existsSync() ? file.deleteSync() : null);

    await api.upload(
      endpoint: '/documents',
      files: [UploadFile.fromPath(field: 'doc', path: file.path)],
    );

    final sent = sentFormData().files.single;
    expect(sent.key, 'doc');
    expect(sent.value.filename, 'baaba_upload_test.txt');
  });

  test('a missing file becomes a Failure, not an exception', () async {
    final result = await api.upload(
      endpoint: '/documents',
      files: [
        UploadFile.fromPath(field: 'doc', path: '/definitely/not/here.txt'),
      ],
    );

    expect(result.isLeft(), isTrue);
    expect(calls, isEmpty);
  });

  test('skips the request entirely when offline', () async {
    when(() => mockNetworkInfo.isConnected).thenAnswer((_) async => false);

    final result = await api.upload(
      endpoint: '/documents',
      fields: {'a': '1'},
    );

    result.fold(
      (failure) => expect(failure.errorType, ErrorSource.noInternetConnection),
      (_) => fail('Expected an offline failure'),
    );
    expect(calls, isEmpty);
  });

  test('shows the loader once across file reads and the request', () async {
    var shows = 0;
    var hides = 0;
    ApiServices.configureLoader(onShow: () => shows++, onHide: () => hides++);

    await api.upload(
      endpoint: '/documents',
      files: [
        UploadFile.fromBytes(field: 'f', bytes: [1], filename: 'a.bin'),
      ],
    );

    expect(shows, 1);
    expect(hides, 1);
  });
}
