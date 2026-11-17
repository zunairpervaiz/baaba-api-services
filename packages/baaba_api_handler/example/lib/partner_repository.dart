import 'package:baaba_api_handler/baaba_api_handler.dart';

import 'config/api_setup.dart';
import 'config/endpoints.dart';

/// Talks to the partner's GraphQL API through the named client.
///
/// `partner.example.net` is a placeholder, so in the example every call
/// fails — with `certificateRejected` or a connection failure, depending on
/// the network — which is what [describe] is for.
class PartnerRepository {
  final ApiServices _api;

  PartnerRepository([ApiServices? api])
    : _api = api ?? ApiServices.named(partnerClient);

  /// A GraphQL query: a POST that only reads, so marked safe to retry where
  /// it is made. A mutation would leave `retryable` unset.
  Future<Either<Failure, String>> balance(String account) {
    return _api.postAs<String>(
      endpoint: Endpoints.partnerGraphql,
      data: {
        'operationName': 'GetBalance',
        'query':
            r'query GetBalance($account: ID!) { balance(account: $account) }',
        'variables': {'account': account},
      },
      parser: (body) => '${((body as Map)['data'] as Map)['balance']}',
      retryable: true,
      extra: const {'operation': 'GetBalance'},
    );
  }

  /// Two dependent calls, written straight through: `orThrow()` stops at the
  /// first failure, and `guardApi` hands it back as a `Left`.
  Future<Either<Failure, String>> latestStatement(String account) {
    return guardApi(() async {
      final balance = await this.balance(account).orThrow();
      final statement = await _api
          .get(
            endpoint: Endpoints.partnerStatement(account, 'latest'),
            responseType: ResponseType.plain,
          )
          .orThrow();
      return 'Balance: $balance\n\n${statement.data}';
    });
  }

  /// Says what went wrong in terms a user can act on.
  static String describe(Failure failure) => switch (failure.errorType) {
    ErrorSource.certificateRejected =>
      'The partner presented a certificate we do not trust. '
          'This can mean the connection is being intercepted.',
    ErrorSource.noInternetConnection ||
    ErrorSource.connectionFailure ||
    ErrorSource.connectionTimeout => 'Could not reach the partner service.',
    _ => failure.message,
  };
}
