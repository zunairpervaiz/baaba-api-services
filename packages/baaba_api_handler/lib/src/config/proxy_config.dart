import 'package:baaba_api_handler/src/utils/host_pattern.dart';

/// Sends requests for selected hosts through an HTTP proxy, and everything
/// else direct.
///
/// ```dart
/// ApiServices.init(
///   ApiConfig(
///     baseUrl: 'https://partner.example.net',
///     proxy: ProxyConfig(
///       proxy: isStaging ? 'proxy.staging.example.com:3128' : null,
///       hosts: {'partner.example.net', '*.partner.example.net'},
///     ),
///   ),
///   name: 'partner',
/// );
/// ```
///
/// Applied through `HttpClient.findProxy`, so an `https` request to a listed
/// host is tunnelled with `CONNECT` and TLS runs end to end through the
/// tunnel: the proxy never sees the plaintext, and the certificate is still
/// verified — against the roots in `ApiConfig.pinning` when the host is
/// pinned. A proxy that terminates TLS itself will therefore be rejected by
/// a pinned client, as it should be.
///
/// [hosts] matches as `PinningConfig` does: exactly, or `*.example.com` for
/// any subdomain. Matching ignores case.
///
/// **Not on web.** The browser decides how to reach the network, so this
/// setting is ignored there.
class ProxyConfig {
  /// The proxy, as `host:port`. `null` sends everything direct — convenient
  /// for passing an environment's value straight through.
  final String? proxy;

  /// The hosts whose requests go through [proxy].
  final Set<String> hosts;

  const ProxyConfig({this.proxy, this.hosts = const {}});

  /// Whether requests to [host] go through the proxy.
  bool appliesTo(String host) {
    final through = proxy;
    if (through == null || through.isEmpty) return false;
    return hosts.any((pattern) => hostMatches(pattern, host));
  }

  /// Whether any request could go through the proxy at all.
  bool get isActive => (proxy?.isNotEmpty ?? false) && hosts.isNotEmpty;

  /// The `HttpClient.findProxy` answer for [uri]: `PROXY host:port` for a
  /// listed host, `DIRECT` for everything else.
  String findProxy(Uri uri) => appliesTo(uri.host) ? 'PROXY $proxy' : 'DIRECT';
}
