import 'package:baaba_api_handler/ts_api_handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(ApiServices.reset);
  tearDown(ApiServices.reset);

  group('ApiServices.init', () {
    test('stores the config and builds a usable singleton', () {
      ApiServices.init(const ApiConfig(baseUrl: 'https://api.test'));

      expect(ApiServices.config.baseUrl, 'https://api.test');
      expect(ApiServices.instance(), isA<ApiServices>());
    });

    test('called twice, the second config wins', () {
      ApiServices.init(const ApiConfig(baseUrl: 'https://first.test'));
      final first = ApiServices.instance();

      ApiServices.init(const ApiConfig(baseUrl: 'https://second.test'));

      expect(ApiServices.config.baseUrl, 'https://second.test');
      expect(ApiServices.instance(), isNot(same(first)));
    });

    test('defaults are sane without any arguments', () {
      ApiServices.init(const ApiConfig());

      expect(ApiServices.config.connectTimeout, const Duration(seconds: 30));
      expect(ApiServices.config.bypassConnectivityCheck, isFalse);
      expect(ApiServices.config.retry.maxRetries, 3);
      expect(ApiServices.config.auth, isNull);
      expect(ApiServices.config.isSuccess, isNull);
    });
  });

  group('ApiServices.reset', () {
    test('clears the config and the singleton', () {
      ApiServices.init(const ApiConfig(baseUrl: 'https://api.test'));
      final before = ApiServices.instance();

      ApiServices.reset();

      expect(ApiServices.config.baseUrl, isNull);
      expect(ApiServices.instance(), isNot(same(before)));
    });

    test('clears the loader callbacks', () async {
      var shows = 0;
      ApiServices.configureLoader(onShow: () => shows++, onHide: () {});

      ApiServices.reset();

      // Nothing should be able to reach the old callbacks.
      ApiServices.init(const ApiConfig());
      expect(shows, 0);
    });
  });

  group('instance() without init()', () {
    test('builds a default client rather than failing', () {
      expect(ApiServices.instance(), isA<ApiServices>());
      expect(ApiServices.config.baseUrl, isNull);
    });

    test('is a singleton across calls', () {
      expect(ApiServices.instance(), same(ApiServices.instance()));
    });
  });

  group('deprecated forwarders', () {
    test('configure() produces an equivalent AuthConfig', () {
      // ignore: deprecated_member_use_from_same_package
      ApiServices.configure(
        getToken: () async => 'token',
        onTokenRefresh: () async => true,
        bypassConnectivityCheck: true,
        refreshTimeout: const Duration(seconds: 10),
      );

      final auth = ApiServices.config.auth;
      expect(auth, isNotNull);
      expect(auth!.refreshTimeout, const Duration(seconds: 10));
      expect(ApiServices.config.bypassConnectivityCheck, isTrue);
    });

    test('setConnectivityCheck() flips the bypass flag', () {
      // ignore: deprecated_member_use_from_same_package
      ApiServices.setConnectivityCheck(enabled: false);
      expect(ApiServices.config.bypassConnectivityCheck, isTrue);

      // ignore: deprecated_member_use_from_same_package
      ApiServices.setConnectivityCheck();
      expect(ApiServices.config.bypassConnectivityCheck, isFalse);
    });

    test('setLogging() replaces the log options', () {
      // ignore: deprecated_member_use_from_same_package
      ApiServices.setLogging(const ApiLogOptions.disabled());

      expect(ApiServices.config.logging.enabled, isFalse);
    });
  });

  group('ApiConfig.copyWith', () {
    test('replaces only what it is given', () {
      const base = ApiConfig(
        baseUrl: 'https://api.test',
        connectTimeout: Duration(seconds: 5),
        bypassConnectivityCheck: true,
      );

      final derived = base.copyWith(baseUrl: 'https://staging.test');

      expect(derived.baseUrl, 'https://staging.test');
      expect(derived.connectTimeout, const Duration(seconds: 5));
      expect(derived.bypassConnectivityCheck, isTrue);
    });

    test('can turn a boolean back off', () {
      const base = ApiConfig(bypassConnectivityCheck: true);

      expect(
        base.copyWith(bypassConnectivityCheck: false).bypassConnectivityCheck,
        isFalse,
      );
    });
  });
}
