import 'package:baaba_api_handler/baaba_api_handler.dart';

part 'partner_env.g.dart';

/// The partner client's settings, from `env/partner.env`, typed and checked
/// when the app is built: a `CONNECT_TIMEOUT_SECONDS` that is not a number
/// fails the build, not the app.
@BaabaApiEnvironment(path: 'env/partner.env')
abstract final class PartnerEnv {
  static final Uri baseUrl = _PartnerEnv.baseUrl; // BASE_URL
  static final int connectTimeoutSeconds = _PartnerEnv.connectTimeoutSeconds;

  /// `host:port`, or null when PROXY is empty.
  @BaabaApiField(name: 'PROXY')
  static final String? proxy = _PartnerEnv.proxy;
}
