import 'package:baaba_api_handler/src/config/api_config.dart';
import 'package:baaba_api_handler/src/utils/failure.dart';

/// Applies `ApiConfig.mapFailure` to a failure about to be returned.
///
/// Shared by the real client and `FakeApiServices`, so a consumer's mapping
/// is exercised by their tests exactly as it runs in production.
Failure mapFailure(Failure failure, ApiConfig config) {
  final mapper = config.mapFailure;
  if (mapper == null) return failure;
  try {
    final mapped = mapper(failure);
    if (mapped == null) return failure;
    // A mapper building a fresh Failure rarely thinks to carry the request
    // over, and the observer and callers still want to know which call it was.
    return mapped.requestOptions == null
        ? mapped.withRequest(failure.requestOptions)
        : mapped;
  } catch (_) {
    // A broken mapper must not turn a failure into an exception.
    return failure;
  }
}
