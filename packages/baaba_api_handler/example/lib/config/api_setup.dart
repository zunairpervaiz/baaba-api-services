import 'package:baaba_api_handler/baaba_api_handler.dart';
import 'package:flutter/foundation.dart';

import 'certs.dart';
import 'partner_env.dart';

/// Name of the second client, for the partner's GraphQL API.
const partnerClient = 'partner';

/// Configures both clients. Call once in `main()`, before anything resolves
/// `ApiServices.instance()` or `ApiServices.named(partnerClient)`.
void configureApi({required ApiObserver observer}) {
  // 1. The app's own API — the default client, as before. jsonplaceholder is
  //    a public test API, so the example has something real to show.
  ApiServices.init(
    ApiConfig(
      baseUrl: 'https://jsonplaceholder.typicode.com',
      connectTimeout: const Duration(seconds: 15),
      observer: observer,
      // A real app would add auth; with a JWT, the expiry check is one line:
      //
      // auth: AuthConfig(
      //   getToken: tokenStore.read,
      //   isTokenExpired: jwtExpiryCheck(tokenStore.read),
      //   onTokenRefresh: authRepository.refresh,
      // ),
    ),
  );

  // 2. A third-party GraphQL API on another host: its own CA, a proxy on
  //    staging, slower timeouts, and its own retry rules. A named client, so
  //    none of this leaks into the default one — and none of the default
  //    client's settings (or token) reach the partner. Host, timeout and
  //    proxy come from env/partner.env, generated into PartnerEnv.
  ApiServices.init(
    ApiConfig(
      baseUrl: PartnerEnv.baseUrl.toString(),
      connectTimeout: Duration(seconds: PartnerEnv.connectTimeoutSeconds),
      receiveTimeout: const Duration(seconds: 60),
      // The partner's health is not the device's: skip the internet probe
      // and let the request itself say whether the host is reachable.
      bypassConnectivityCheck: true,
      observer: observer,

      // Trust the partner's host only if its certificate chains to the
      // partner's CA, and refuse every other host outright: this client has
      // no business talking to anyone else. On web this is ignored.
      pinning: PinningConfig(
        rootsPemByHost: {
          PartnerEnv.baseUrl.host: [Certs.partnerRootCa],
        },
        unlistedHosts: UnlistedHostPolicy.refuse,
      ),

      // Where PROXY is set (staging: proxy.staging.example.com:3128), the
      // partner is reached through it; everything else goes direct. TLS is
      // tunnelled, so the pinned CA above is still what the certificate is
      // checked against.
      proxy: ProxyConfig(
        proxy: PartnerEnv.proxy,
        hosts: {PartnerEnv.baseUrl.host},
      ),

      // GraphQL sends every call as a POST, so by default none would be
      // retried on a timeout. Queries opt in per call with `retryable: true`;
      // here, only network-level failures are worth it, and never for the
      // one mutation that moves money.
      retry: RetryPolicy(
        maxRetries: 2,
        retryableStatusCodes: const {502, 503, 504},
        retryIf: (error, _) =>
            error.requestOptions.extra['operation'] != 'Transfer',
      ),

      logging: ApiLogOptions(
        // Headers are safe to print: tokens, cookies and API keys are masked.
        requestHeader: kDebugMode,
        redactHeaders: const {
          ...ApiLogOptions.defaultRedactHeaders,
          'x-partner-key',
        },
      ),
    ),
    name: partnerClient,
  );
}
