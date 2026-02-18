import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';

class NetworkInfo {
  final InternetConnection _internetConnection = InternetConnection();

  Future<bool>? get isConnected async => await _internetConnection.hasInternetAccess;
}
