import 'package:dio/dio.dart';

/// Makes [options] safe to send a second time.
///
/// A multipart body is a stream, and Dio reads it exactly once —
/// `FormData.finalize()` throws `StateError` on the second call:
///
/// > The FormData has already been finalized. This typically means you are
/// > using the same FormData in repeated requests.
///
/// Both replay paths hit this: `NetworkRetryInterceptor` retrying a `429`
/// (which bypasses the idempotency check, because the server said it did not
/// process the request) and `TokenRefreshInterceptor` replaying after a `401`,
/// which is a likely outcome for an upload large enough to outlive the token.
///
/// `FormData.clone()` rebuilds from the same stream *factory*, so a file part
/// re-opens from disk and a byte part re-emits its bytes. Dio provides it for
/// exactly this purpose.
///
/// Call immediately before `dio.fetch(options)`. Cloning only when the body
/// has actually been consumed keeps a request that failed before sending
/// untouched.
void prepareForReplay(RequestOptions options) {
  final data = options.data;
  if (data is FormData && data.isFinalized) {
    options.data = data.clone();
  }
}
