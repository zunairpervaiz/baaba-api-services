import 'package:baaba_api_handler/src/config/pinning_config.dart';
import 'package:baaba_api_handler/src/config/proxy_config.dart';
import 'package:dio/dio.dart';

/// Web: the browser owns TLS and proxying, so there is nothing to configure.
/// `null` keeps Dio's default adapter.
HttpClientAdapter? createTransportAdapter({
  PinningConfig? pinning,
  ProxyConfig? proxy,
}) => null;

/// Web: TLS failures never reach Dart as a distinct type.
bool isTlsError(Object? error) => false;
