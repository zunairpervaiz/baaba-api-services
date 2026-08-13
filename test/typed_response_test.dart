import 'package:baaba_api_handler/src/api_service.dart';
import 'package:baaba_api_handler/src/utils/network_info.dart';
import 'package:baaba_api_handler/ts_api_handler.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockDio extends Mock implements Dio {}

class MockNetworkInfo extends Mock implements NetworkInfo {}

class User {
  final int id;
  final String name;

  const User(this.id, this.name);

  factory User.fromJson(Map<String, dynamic> json) =>
      User(json['id'] as int, json['name'] as String);
}

void main() {
  late ApiServices api;
  late MockDio mockDio;
  late MockNetworkInfo mockNetworkInfo;

  void stubResponse(Object? body, {int statusCode = 200}) {
    when(() => mockDio.request<dynamic>(
          any(),
          data: any(named: 'data'),
          queryParameters: any(named: 'queryParameters'),
          options: any(named: 'options'),
          cancelToken: any(named: 'cancelToken'),
          onSendProgress: any(named: 'onSendProgress'),
          onReceiveProgress: any(named: 'onReceiveProgress'),
        )).thenAnswer((_) async => Response(
          requestOptions: RequestOptions(path: '/users'),
          statusCode: statusCode,
          data: body,
        ));
  }

  setUp(() {
    ApiServices.reset();
    mockDio = MockDio();
    mockNetworkInfo = MockNetworkInfo();

    registerFallbackValue(RequestOptions(path: ''));
    registerFallbackValue(Options());
    when(() => mockNetworkInfo.isConnected).thenAnswer((_) async => true);

    api = ApiServicesImplementation.instanceFor(
      dio: mockDio,
      networkInfo: mockNetworkInfo,
    );
  });

  tearDown(ApiServices.reset);

  group('getAs', () {
    test('deserializes the body into the requested type', () async {
      stubResponse({'id': 1, 'name': 'Ada'});

      final result = await api.getAs<User>(
        endpoint: '/users/1',
        parser: (data) => User.fromJson(data as Map<String, dynamic>),
      );

      expect(result.isRight(), isTrue);
      result.fold(
        (f) => fail('Expected a user, got $f'),
        (user) {
          expect(user.id, 1);
          expect(user.name, 'Ada');
        },
      );
    });

    test('a throwing parser becomes a Failure, never an exception', () async {
      stubResponse({'unexpected': 'shape'});

      final result = await api.getAs<User>(
        endpoint: '/users/1',
        parser: (data) => User.fromJson(data as Map<String, dynamic>),
      );

      expect(result.isLeft(), isTrue);
      result.fold(
        (failure) {
          expect(failure.errorType, ErrorSource.parseError);
          expect(failure.code, ResponseCode.parseError);
          // The raw body is kept so the caller can log what actually arrived.
          expect(failure.data, {'unexpected': 'shape'});
          expect(failure.statusCode, 200);
        },
        (_) => fail('Expected a parse failure'),
      );
    });

    test('propagates a network failure without invoking the parser', () async {
      var parserCalls = 0;
      when(() => mockNetworkInfo.isConnected).thenAnswer((_) async => false);

      final result = await api.getAs<User>(
        endpoint: '/users/1',
        parser: (data) {
          parserCalls++;
          return User.fromJson(data as Map<String, dynamic>);
        },
      );

      expect(parserCalls, 0);
      result.fold(
        (failure) =>
            expect(failure.errorType, ErrorSource.noInternetConnection),
        (_) => fail('Expected a failure'),
      );
    });
  });

  group('listParser', () {
    test('maps a bare JSON array', () async {
      stubResponse([
        {'id': 1, 'name': 'Ada'},
        {'id': 2, 'name': 'Grace'},
      ]);

      final result = await api.getAs<List<User>>(
        endpoint: '/users',
        parser: listParser(User.fromJson),
      );

      result.fold(
        (f) => fail('Expected users, got $f'),
        (users) {
          expect(users, hasLength(2));
          expect(users.last.name, 'Grace');
        },
      );
    });

    test('pulls the array out of a wrapper key', () async {
      stubResponse({
        'data': [
          {'id': 7, 'name': 'Alan'}
        ],
        'meta': {'total': 1},
      });

      final result = await api.getAs<List<User>>(
        endpoint: '/users',
        parser: listParser(User.fromJson, key: 'data'),
      );

      result.fold(
        (f) => fail('Expected users, got $f'),
        (users) => expect(users.single.name, 'Alan'),
      );
    });

    test('a wrong shape surfaces as parseError', () async {
      stubResponse({'not': 'a list'});

      final result = await api.getAs<List<User>>(
        endpoint: '/users',
        parser: listParser(User.fromJson),
      );

      result.fold(
        (failure) => expect(failure.errorType, ErrorSource.parseError),
        (_) => fail('Expected a parse failure'),
      );
    });
  });

  group('the other typed verbs', () {
    setUp(() => stubResponse({'id': 3, 'name': 'Linus'}));

    test('postAs / putAs / patchAs / deleteAs all deserialize', () async {
      User parse(dynamic d) => User.fromJson(d as Map<String, dynamic>);

      for (final result in [
        await api.postAs<User>(endpoint: '/users', parser: parse),
        await api.putAs<User>(endpoint: '/users/3', parser: parse),
        await api.patchAs<User>(endpoint: '/users/3', parser: parse),
        await api.deleteAs<User>(endpoint: '/users/3', parser: parse),
      ]) {
        result.fold(
          (f) => fail('Expected a user, got $f'),
          (user) => expect(user.name, 'Linus'),
        );
      }
    });
  });
}
