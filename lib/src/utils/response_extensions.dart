import 'package:baaba_api_handler/src/utils/constants.dart';
import 'package:dio/dio.dart';

extension CachedResponse on Response {
  /// Whether this response was rebuilt from the local cache rather than
  /// received over the network.
  ///
  /// Only ever `true` for a `get`/`getAs` call made with a [CachePolicy] other
  /// than `networkOnly`. Use it to tell the user what they are looking at:
  ///
  /// ```dart
  /// result.fold(
  ///   (failure) => showError(failure.message),
  ///   (response) {
  ///     if (response.isFromCache) showBanner('Offline — showing saved data');
  ///     render(response.data);
  ///   },
  /// );
  /// ```
  bool get isFromCache => extra[fromCacheKey] == true;
}
