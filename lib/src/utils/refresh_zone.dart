import 'dart:async';

/// Marks the async context of `AuthConfig.onTokenRefresh`.
///
/// The refresh callback commonly makes its own request through the same
/// client — `authRepository.refresh()` calling `ApiServices.instance().post`.
/// With `ApiConfig.maxConcurrentRequests` set, that request would queue behind
/// the very requests waiting on it: each `401`'d request holds its slot while
/// it awaits the refresh. A cap of one deadlocked outright; a cap of _n_ with
/// _n_ concurrent `401`s stalled until `refreshTimeout` and then failed them
/// all.
///
/// A zone value follows every async call the callback makes, without the
/// interceptor and the client having to know about each other, so the
/// concurrency gate can let the refresh through.
const Object _refreshZoneKey = #baabaTokenRefresh;

/// Runs [body] marked as part of a token refresh.
Future<T> runAsTokenRefresh<T>(Future<T> Function() body) =>
    runZoned(body, zoneValues: {_refreshZoneKey: true});

/// Whether the current code is running on behalf of a token refresh.
bool get isInsideTokenRefresh => Zone.current[_refreshZoneKey] == true;
