/// Pinned clients for code that does not go through `ApiServices` — a
/// WebSocket, a SignalR hub, any library that takes its own `HttpClient` or
/// `package:http` client.
///
/// ```dart
/// import 'package:baaba_api_handler/io.dart';
/// ```
///
/// **Mobile and desktop only.** This library imports `dart:io`, which does
/// not exist on web — import it only from code that never compiles for web,
/// or behind your own conditional import. The core library,
/// `package:baaba_api_handler/baaba_api_handler.dart`, stays web-safe and
/// falls back to the browser's TLS there.
///
/// The clients trust the given roots and nothing else, exactly as
/// `ApiConfig.pinning` does: no `badCertificateCallback`, so a certificate
/// that does not chain to them fails the handshake. Reuse the roots you
/// already gave `ApiConfig` with `PinningConfig.rootsFor`:
///
/// ```dart
/// final roots = pinning.rootsFor('hub.example.com')!;
///
/// // web_socket_channel
/// final channel = IOWebSocketChannel.connect(
///   Uri.parse('wss://hub.example.com/ws'),
///   customClient: pinnedHttpClient(roots),
/// );
///
/// // signalr_netcore and others that take a package:http client
/// final hub = HubConnectionBuilder()
///     .withUrl(
///       'https://hub.example.com/hub',
///       options: HttpConnectionOptions(client: pinnedIoClient(roots)),
///     )
///     .build();
/// ```
library;

import 'dart:io';

import 'package:baaba_api_handler/src/config/proxy_config.dart';
import 'package:baaba_api_handler/src/transport/transport_io.dart';
import 'package:http/io_client.dart';

export 'package:http/io_client.dart' show IOClient;

export 'src/config/pinning_config.dart' show PinningConfig, UnlistedHostPolicy;
export 'src/config/proxy_config.dart' show ProxyConfig;

/// A `dart:io` [HttpClient] that trusts [rootsPem] and nothing else.
///
/// Each entry is a PEM string holding one or more root or intermediate CA
/// certificates. Throws a [TlsException] if one does not parse — at
/// construction, so a bad certificate bundle fails where it is wired up.
///
/// Pass [proxy] to send its hosts through an HTTP proxy, as
/// `ApiConfig.proxy` does; `https` is tunnelled, and still verified against
/// [rootsPem].
///
/// The client is yours: close it when you are done with it.
HttpClient pinnedHttpClient(List<String> rootsPem, {ProxyConfig? proxy}) =>
    buildHttpClient(rootsPem: rootsPem, proxy: proxy);

/// A `package:http` client that trusts [rootsPem] and nothing else — an
/// [IOClient] over [pinnedHttpClient].
///
/// For libraries that take a `package:http` `Client`, such as SignalR's
/// negotiate and long-polling transport. Throws a [TlsException] if a PEM
/// does not parse. Closing it closes the underlying `HttpClient`.
IOClient pinnedIoClient(List<String> rootsPem, {ProxyConfig? proxy}) =>
    IOClient(pinnedHttpClient(rootsPem, proxy: proxy));
