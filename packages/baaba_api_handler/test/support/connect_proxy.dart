import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A minimal HTTP proxy that only understands `CONNECT`, which is all an
/// `https` request through a proxy uses. Records each tunnel's target and
/// always dials 127.0.0.1 on the requested port, so `localhost` resolving to
/// `::1` first cannot send it elsewhere.
class ConnectProxy {
  final ServerSocket _server;

  /// `host:port` of every tunnel requested, in order.
  final List<String> targets = [];

  ConnectProxy._(this._server) {
    _server.listen(_handle);
  }

  static Future<ConnectProxy> start() async =>
      ConnectProxy._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  /// `host:port`, as `ProxyConfig.proxy` takes it.
  String get address => '127.0.0.1:${_server.port}';

  Future<void> close() => _server.close();

  void _handle(Socket client) {
    final buffer = BytesBuilder();
    late StreamSubscription<Uint8List> sub;
    sub = client.listen((chunk) async {
      buffer.add(chunk);
      final bytes = buffer.toBytes();
      final text = latin1.decode(bytes);
      final end = text.indexOf('\r\n\r\n');
      if (end < 0) return;
      sub.pause();

      final requestLine = text.substring(0, text.indexOf('\r\n'));
      final parts = requestLine.split(' ');
      if (parts.length < 2 || parts[0] != 'CONNECT') {
        client.write('HTTP/1.1 405 Method Not Allowed\r\n\r\n');
        await client.close();
        return;
      }
      final target = parts[1];
      targets.add(target);
      final port = int.parse(target.split(':').last);

      final Socket upstream;
      try {
        upstream = await Socket.connect(InternetAddress.loopbackIPv4, port);
      } catch (_) {
        client.write('HTTP/1.1 502 Bad Gateway\r\n\r\n');
        await client.close();
        return;
      }
      client.write('HTTP/1.1 200 Connection established\r\n\r\n');
      final rest = bytes.sublist(end + 4);
      if (rest.isNotEmpty) upstream.add(rest);

      sub.onData(upstream.add);
      sub.onDone(() => upstream.destroy());
      sub.onError((_) => upstream.destroy());
      upstream.listen(
        client.add,
        onDone: client.destroy,
        onError: (_) => client.destroy(),
      );
      sub.resume();
    }, onError: (_) => client.destroy());
  }
}
