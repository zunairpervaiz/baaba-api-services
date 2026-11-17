import 'package:baaba_api_handler/src/utils/host_pattern.dart';

/// What a pinned client does with a host [PinningConfig] does not list.
enum UnlistedHostPolicy {
  /// Verify it against the platform's trust store, as an unpinned client
  /// would. The default: pinning your own API should not break the CDN, the
  /// maps tiles, or the crash reporter that share the client.
  system,

  /// Refuse it: the request fails with `ErrorSource.certificateRejected`
  /// without a connection being opened. For a client that must only ever
  /// talk to the hosts you pinned.
  refuse,
}

/// Certificate pinning by CA: each host is trusted only if its certificate
/// chains to one of the roots listed for it.
///
/// ```dart
/// ApiServices.init(ApiConfig(
///   baseUrl: 'https://api.example.com',
///   pinning: PinningConfig(
///     rootsPemByHost: {
///       'api.example.com': [Certs.internalRootCa],
///       '*.partner.example.net': [Certs.partnerRootCa, Certs.partnerNextCa],
///     },
///   ),
/// ));
/// ```
///
/// **The handshake itself fails.** Each set of roots gets its own
/// `HttpClient`, built on a `SecurityContext` that trusts those roots and
/// nothing else — no `badCertificateCallback` is involved, so there is no
/// callback to get wrong and no code path that can wave a certificate
/// through. A certificate that does not chain to the listed roots fails the
/// TLS handshake, and the request fails with
/// `ErrorSource.certificateRejected` — never `noInternetConnection` or
/// `connectionFailure`, so the app can tell an interception attempt from a
/// dropped connection.
///
/// **Pin roots, not leaves.** A root or intermediate CA outlives the server
/// certificates it issues, so a routine certificate renewal does not lock
/// every installed copy of the app out. List the next CA alongside the
/// current one before you rotate.
///
/// **Not on web.** A browser does its own TLS and offers no way to restrict
/// it, so on web this setting is ignored and requests use the default
/// adapter. Pinning there is the browser's job (and, for the server side,
/// HSTS and Certificate Transparency's).
///
/// Mutually exclusive with `ApiConfig.httpClientAdapter`, which replaces the
/// transport entirely.
class PinningConfig {
  /// PEM-encoded root (or intermediate) certificates, by host.
  ///
  /// A key is matched exactly, or — written `*.example.com` — as any
  /// subdomain of `example.com`; an exact key wins over a wildcard, and a
  /// longer wildcard over a shorter one. A wildcard does not cover the bare
  /// domain: list `example.com` too if you call it.
  ///
  /// Each value is one or more PEM strings, each holding one or more
  /// certificates. A PEM that does not parse fails closed: requests to that
  /// host fail with `ErrorSource.certificateRejected`.
  final Map<String, List<String>> rootsPemByHost;

  /// What to do with a host [rootsPemByHost] does not list. Defaults to
  /// [UnlistedHostPolicy.system].
  final UnlistedHostPolicy unlistedHosts;

  const PinningConfig({
    required this.rootsPemByHost,
    this.unlistedHosts = UnlistedHostPolicy.system,
  });

  /// The roots pinned for [host], or `null` when it is not listed.
  ///
  /// Also the way to reach the same roots outside Dio — see
  /// `package:baaba_api_handler/io.dart`:
  ///
  /// ```dart
  /// final client = pinnedHttpClient(pinning.rootsFor('hub.example.com')!);
  /// ```
  List<String>? rootsFor(String host) => lookupHost(rootsPemByHost, host);
}
