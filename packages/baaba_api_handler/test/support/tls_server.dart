import 'dart:io';

/// The test-only TLS material in `test/fixtures/tls` — see its README.
abstract final class TestCerts {
  static String _read(String name) =>
      File('test/fixtures/tls/$name').readAsStringSync();

  /// The CA that signed the server's certificate.
  static final String ca = _read('ca.pem');

  /// A CA with no relation to the server's certificate.
  static final String otherCa = _read('other_ca.pem');

  static SecurityContext serverContext() => SecurityContext()
    ..useCertificateChainBytes(
      File('test/fixtures/tls/server.pem').readAsBytesSync(),
    )
    ..usePrivateKeyBytes(
      File('test/fixtures/tls/server.key').readAsBytesSync(),
    );
}

/// An HTTPS server on 127.0.0.1 presenting a `localhost`/`127.0.0.1`
/// certificate signed by [TestCerts.ca]. Answers every request with
/// `{"ok": true}` — or, for `/redirect?to=<url>`, a 302 to that url — and
/// records the paths it served.
class TlsServer {
  final HttpServer _server;
  final List<String> paths = [];

  TlsServer._(this._server) {
    _server.listen((request) async {
      paths.add(request.uri.path);
      // `/redirect?to=<url>` answers 302 to that url.
      final to = request.uri.queryParameters['to'];
      if (request.uri.path == '/redirect' && to != null) {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, to);
        await request.response.close();
        return;
      }
      request.response
        ..headers.contentType = ContentType.json
        ..write('{"ok": true}');
      await request.response.close();
    }, onError: (_) {});
  }

  static Future<TlsServer> start() async => TlsServer._(
    await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      TestCerts.serverContext(),
    ),
  );

  int get port => _server.port;

  Future<void> close() => _server.close(force: true);
}
