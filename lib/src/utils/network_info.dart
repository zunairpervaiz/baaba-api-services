import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';

/// Answers "is there internet right now?" for the pre-flight check every
/// request runs.
///
/// The underlying probe is a real network round-trip to external hosts. Doing
/// that before *every* API call roughly doubles the latency of a fast request,
/// so a positive result is reused for [cacheTtl].
///
/// **Negative results are never cached.** A cached `false` would keep telling
/// the caller "offline" for seconds after the connection came back — which is
/// exactly the moment the user is hammering a retry button. Only the fast path
/// is cached; every failure re-probes.
class NetworkInfo {
  /// How long a positive connectivity result stays good for.
  /// [Duration.zero] probes on every call.
  final Duration cacheTtl;

  final Future<bool> Function() _probe;
  final DateTime Function() _clock;

  DateTime? _connectedAt;

  /// The probe currently running, if any, so concurrent callers share one
  /// round-trip instead of each firing their own.
  Future<bool>? _inFlight;

  NetworkInfo({
    this.cacheTtl = const Duration(seconds: 5),
    Future<bool> Function()? probe,
    DateTime Function()? clock,
  })  : _probe = probe ?? _defaultProbe,
        _clock = clock ?? DateTime.now;

  static Future<bool> _defaultProbe() => InternetConnection().hasInternetAccess;

  Future<bool> get isConnected {
    final connectedAt = _connectedAt;
    if (connectedAt != null && _clock().difference(connectedAt) < cacheTtl) {
      return Future.value(true);
    }

    // The clear is attached with whenComplete rather than living in _runProbe's
    // finally. An async body runs synchronously up to its first await, so a
    // probe that throws synchronously would finish _runProbe — clearing
    // _inFlight — *before* the assignment below put anything there, stranding a
    // completed future that reports offline for the rest of the session.
    // whenComplete always defers to a microtask, so the assignment wins.
    return _inFlight ??= _runProbe().whenComplete(() => _inFlight = null);
  }

  Future<bool> _runProbe() async {
    try {
      final connected = await _probe();
      _connectedAt = connected ? _clock() : null;
      return connected;
    } catch (_) {
      // A probe that throws is indistinguishable from being offline as far as
      // the caller is concerned, and must never escape as an exception.
      _connectedAt = null;
      return false;
    }
  }

  /// Drops the cached result so the next call probes again.
  ///
  /// Call it when you know connectivity changed — e.g. from your own
  /// connectivity stream listener — instead of waiting out [cacheTtl].
  void invalidate() => _connectedAt = null;
}
