/// What a token refresh came to, for `AuthConfig.refreshSession`.
///
/// A `bool` cannot tell "the server refused the refresh token" from "the
/// refresh could not be tried". Only the first means the session is over;
/// treating the second the same signs a user out for losing signal in a lift.
enum RefreshOutcome {
  /// A new token is saved and available from `AuthConfig.getToken`. Waiting
  /// requests are replayed with it.
  refreshed,

  /// The refresh token is gone, expired, or refused. `onRefreshFailed` fires,
  /// and the waiting requests fail with their `401`.
  sessionExpired,

  /// The refresh could not be completed — offline, a timeout, a `5xx`. The
  /// session may well still be good, so `onRefreshFailed` does **not** fire;
  /// the waiting requests fail with their `401` and a later request tries
  /// again.
  failed,
}
