import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baaba_api_handler/src/config/pinning_config.dart';
import 'package:baaba_api_handler/src/config/proxy_config.dart';
import 'package:baaba_api_handler/src/utils/token_headers.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// The adapter for [pinning] and [proxy], or `null` when there is nothing to
/// configure and Dio's default adapter will do.
///
/// [tokenInCustomHeader] — an `AuthConfig.headerBuilder` is set — also needs
/// this adapter: the token may travel in a header `HttpClient` keeps on a
/// cross-origin redirect, so redirects are followed here instead.
HttpClientAdapter? createTransportAdapter({
  PinningConfig? pinning,
  ProxyConfig? proxy,
  bool tokenInCustomHeader = false,
}) {
  final activeProxy = proxy != null && proxy.isActive ? proxy : null;
  if (pinning == null && activeProxy == null && !tokenInCustomHeader) {
    return null;
  }
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
  final client =
      HttpClient(
          context: rootsPem == null ? null : pinnedSecurityContext(rootsPem),
        )
        // Dio's default; a client handed to IOHttpClientAdapter keeps
        // HttpClient's 15s instead, holding idle sockets five times as long.
        ..idleTimeout = const Duration(seconds: 3);
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
  bool _closed = false;

  PinnedRoutingAdapter({this.pinning, this.proxy});

  /// Follows redirects itself when pinning, so that every hop is routed —
  /// and checked — by its own host. Left to `HttpClient`, a redirect is
  /// followed inside the first hop's client: an unlisted host could redirect
  /// to a pinned one and be verified against the platform store, or a pinned
  /// host to one the `refuse` policy should have blocked.
  ///
  /// Also follows them itself for a request carrying the token in a header
  /// `HttpClient` would keep on a hop to another origin (see
  /// `token_headers.dart`), so that header can be dropped.
  ///
  /// Follows what `HttpClient` follows, no more: any redirect status for
  /// `GET` and `HEAD`, and a `303` for `POST` — re-sent as a body-less `GET`,
  /// the post-redirect-get pattern. Anything else gets the 3xx back. On a hop
  /// to another origin the credential headers
  /// `HttpClient` drops are dropped too, and so is every header the token
  /// was put in.
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // Otherwise a fetch after close() would quietly build a fresh HttpClient
    // that nothing ever closes. IOHttpClientAdapter refuses the same way.
    if (_closed) {
      throw StateError('Cannot fetch after the adapter was closed.');
    }
    final method = options.method.toUpperCase();
    final ownRedirects =
        pinning != null || carriesUnstrippedTokenHeader(options);
    if (!ownRedirects ||
        !options.followRedirects ||
        !_followable.contains(method)) {
      return _fetchHop(
        options.followRedirects && ownRedirects
            ? options.copyWith(followRedirects: false)
            : options,
        requestStream,
        cancelFuture,
      );
    }

    final dropCrossOrigin = {
      ...redirectStrippedHeaders,
      ...tokenHeaderNames(options),
    };

    final redirects = <RedirectRecord>[];
    var hop = options.copyWith(followRedirects: false);
    var stream = requestStream;
    while (true) {
      final body = await _fetchHop(hop, stream, cancelFuture);
      final location = body.headers['location']?.firstOrNull;
      if (!_follows(hop.method, body.statusCode) ||
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
      // A 303 is answered with a GET whatever the method was, as HttpClient
      // does; the body, and the headers describing it, are not re-sent.
      final nextMethod = body.statusCode == 303 ? 'GET' : hop.method;
      redirects.add(RedirectRecord(body.statusCode, nextMethod, to));
      final headers = Map<String, dynamic>.of(hop.headers);
      if (nextMethod != hop.method.toUpperCase()) {
        headers.removeWhere((name, _) {
          final lower = name.toLowerCase();
          return lower == 'content-type' || lower == 'content-length';
        });
      }
      if (to.scheme != from.scheme ||
          to.host.toLowerCase() != from.host.toLowerCase() ||
          to.port != from.port) {
        headers.removeWhere(
          (name, _) => dropCrossOrigin.contains(name.toLowerCase()),
        );
      }
      hop = hop.copyWith(
        method: nextMethod,
        path: to.toString(),
        queryParameters: const {},
        headers: headers,
      );
      // Only GET and HEAD hops follow, and those carry no body to resend.
      stream = null;
    }
  }

  static const Set<int> _redirectStatuses = {301, 302, 303, 307, 308};

  /// Methods [fetch] follows redirects for — `HttpClient`'s set.
  static const Set<String> _followable = {'GET', 'HEAD', 'POST'};

  /// Whether `HttpClient` would follow [status] for [method].
  static bool _follows(String method, int status) =>
      switch (method.toUpperCase()) {
        'GET' || 'HEAD' => _redirectStatuses.contains(status),
        'POST' => status == 303,
        _ => false,
      };

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
    _closed = true;
    for (final adapter in _pinned.values) {
      adapter.close(force: force);
    }
    _system?.close(force: force);
  }
}
