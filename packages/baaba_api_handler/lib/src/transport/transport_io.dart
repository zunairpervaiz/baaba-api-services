import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baaba_api_handler/src/config/pinning_config.dart';
import 'package:baaba_api_handler/src/config/proxy_config.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// The adapter for [pinning] and [proxy], or `null` when there is nothing to
/// configure and Dio's default adapter will do.
HttpClientAdapter? createTransportAdapter({
  PinningConfig? pinning,
  ProxyConfig? proxy,
}) {
  final activeProxy = proxy != null && proxy.isActive ? proxy : null;
  if (pinning == null && activeProxy == null) return null;
  return PinnedRoutingAdapter(pinning: pinning, proxy: activeProxy);
}

/// Whether [error] is a TLS failure — a handshake that failed verification,
/// most often. Dio's default adapter lets one escape as an `unknown` error.
bool isTlsError(Object? error) => error is TlsException;

/// A `SecurityContext` that trusts [rootsPem] and nothing else.
///
/// `withTrustedRoots: false` is the whole point: the platform's store is left
/// out, so a certificate from any other CA — a corporate MITM proxy, a
/// mis-issued certificate — fails the handshake.
///
/// Throws a `TlsException` if a PEM does not parse.
SecurityContext pinnedSecurityContext(List<String> rootsPem) {
  final context = SecurityContext(withTrustedRoots: false);
  for (final pem in rootsPem) {
    context.setTrustedCertificatesBytes(utf8.encode(pem));
  }
  return context;
}

/// An `HttpClient` trusting only [rootsPem], or the platform store when
/// [rootsPem] is `null`, and sending [proxy]'s hosts through it.
///
/// Deliberately sets no `badCertificateCallback`: with none, a certificate
/// that does not verify fails the handshake outright, and there is no
/// callback that could be written to wave it through. That holds through a
/// proxy too — `https` is tunnelled with `CONNECT`, and the handshake inside
/// the tunnel is verified against the same context.
HttpClient buildHttpClient({List<String>? rootsPem, ProxyConfig? proxy}) {
  final client = HttpClient(
    context: rootsPem == null ? null : pinnedSecurityContext(rootsPem),
  );
  if (proxy != null) client.findProxy = proxy.findProxy;
  return client;
}

/// Sends each request through the `HttpClient` for its host's pinned roots,
/// via [proxy] for the hosts it lists.
///
/// One `HttpClient` per distinct set of roots — a `SecurityContext` is fixed
/// when the client is built — created on first use and reused after, so
/// connections are pooled per set as they would be by a single client.
/// Hosts [PinningConfig] does not list go to a client on the platform's
/// trust store, or are refused, per [PinningConfig.unlistedHosts].
///
/// Any TLS failure — on a pinned host, an unlisted one, or an unparseable
/// PEM — is reported as a [DioExceptionType.badCertificate], which the
/// package maps to `ErrorSource.certificateRejected`.
class PinnedRoutingAdapter implements HttpClientAdapter {
  /// `null` for a client that only proxies: every host then uses the
  /// platform's trust store.
  final PinningConfig? pinning;

  /// Applied to every `HttpClient` this adapter builds, pinned or not.
  final ProxyConfig? proxy;

  /// Built on first use, keyed by the roots they trust.
  final Map<String, IOHttpClientAdapter> _pinned = {};
  IOHttpClientAdapter? _system;

  PinnedRoutingAdapter({this.pinning, this.proxy});

  /// Follows redirects itself when pinning, so that every hop is routed —
  /// and checked — by its own host. Left to `HttpClient`, a redirect is
  /// followed inside the first hop's client: an unlisted host could redirect
  /// to a pinned one and be verified against the platform store, or a pinned
  /// host to one the `refuse` policy should have blocked.
  ///
  /// Like `HttpClient`, only `GET` and `HEAD` are followed; any other method
  /// gets the 3xx back. `Authorization` and `Cookie` are dropped on a hop to
  /// another origin, as `HttpClient` does.
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final method = options.method.toUpperCase();
    if (pinning == null ||
        !options.followRedirects ||
        (method != 'GET' && method != 'HEAD')) {
      return _fetchHop(
        options.followRedirects && pinning != null
            ? options.copyWith(followRedirects: false)
            : options,
        requestStream,
        cancelFuture,
      );
    }

    final redirects = <RedirectRecord>[];
    var hop = options.copyWith(followRedirects: false);
    var stream = requestStream;
    while (true) {
      final body = await _fetchHop(hop, stream, cancelFuture);
      final location = body.headers['location']?.firstOrNull;
      if (!_redirectStatuses.contains(body.statusCode) ||
          location == null ||
          redirects.length >= options.maxRedirects) {
        if (redirects.isEmpty) return body;
        return ResponseBody(
          body.stream,
          body.statusCode,
          statusMessage: body.statusMessage,
          headers: body.headers,
          isRedirect: true,
          redirects: redirects,
        )..extra.addAll(body.extra);
      }
      // Nothing more is read from this hop; release its connection.
      await body.stream.drain<void>().catchError((_) {});

      final from = hop.uri;
      final to = from.resolve(location);
      redirects.add(RedirectRecord(body.statusCode, hop.method, to));
      final headers = Map<String, dynamic>.of(hop.headers);
      if (to.scheme != from.scheme ||
          to.host.toLowerCase() != from.host.toLowerCase() ||
          to.port != from.port) {
        headers.removeWhere((name, _) {
          final lower = name.toLowerCase();
          return lower == 'authorization' || lower == 'cookie';
        });
      }
      hop = hop.copyWith(
        path: to.toString(),
        queryParameters: const {},
        headers: headers,
      );
      stream = null; // GET and HEAD carry no body to resend.
    }
  }

  static const Set<int> _redirectStatuses = {301, 302, 303, 307, 308};

  Future<ResponseBody> _fetchHop(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    final host = uri.host;
    final pins = pinning;
    final roots = pins?.rootsFor(host);

    if (pins != null &&
        roots == null &&
        pins.unlistedHosts == UnlistedHostPolicy.refuse) {
      throw DioException.badCertificate(
        requestOptions: options,
        error: TlsException(
          'Refused: "$host" is not listed in PinningConfig and unlisted '
          'hosts are refused.',
        ),
      );
    }
    // Plain http to a pinned host would skip the handshake the pins check.
    if (roots != null && uri.scheme != 'https') {
      throw DioException.badCertificate(
        requestOptions: options,
        error: TlsException(
          'Refused: "$host" is pinned, but the request is ${uri.scheme}://, '
          'which has no certificate to check.',
        ),
      );
    }

    try {
      final adapter = roots == null ? _systemAdapter() : _adapterFor(roots);
      return await adapter.fetch(options, requestStream, cancelFuture);
    } on TlsException catch (e) {
      // HandshakeException, a bad PEM, a certificate past its date. Dio would
      // wrap these as `unknown`, indistinguishable from any other bug.
      throw DioException.badCertificate(requestOptions: options, error: e);
    } on DioException catch (e) {
      if (e.error is TlsException) {
        throw DioException.badCertificate(
          requestOptions: options,
          error: e.error,
        );
      }
      rethrow;
    }
  }

  IOHttpClientAdapter _adapterFor(List<String> roots) {
    final key = roots.join('\u0000');
    final existing = _pinned[key];
    if (existing != null) return existing;
    // Built eagerly here rather than inside createHttpClient, so a PEM that
    // does not parse throws now, inside fetch's catch, instead of on Dio's
    // side of the call.
    final client = buildHttpClient(rootsPem: roots, proxy: proxy);
    return _pinned[key] = IOHttpClientAdapter(createHttpClient: () => client);
  }

  IOHttpClientAdapter _systemAdapter() {
    return _system ??= IOHttpClientAdapter(
      createHttpClient: () => buildHttpClient(proxy: proxy),
    );
  }

  @override
  void close({bool force = false}) {
    for (final adapter in _pinned.values) {
      adapter.close(force: force);
    }
    _system?.close(force: force);
  }
}
