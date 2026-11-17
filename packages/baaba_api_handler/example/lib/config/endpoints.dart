import 'package:baaba_api_handler/baaba_api_handler.dart';

part 'endpoints.g.dart';

/// Every endpoint the app calls, generated from `env/endpoints.env` by
/// baaba_api_generator (`dart run build_runner build`).
///
/// Obfuscated by default: the compiled app holds the paths as XORed integer
/// lists, decoded on first use, so a strings search of the binary finds none
/// of them.
///
/// ```dart
/// Endpoints.postComments(7);          // posts/7/comments
/// Endpoints.userPost(1, 2);           // users/1/posts/2
/// Endpoints.partnerGraphql;           // graphql
/// ```
@BaabaApiEndpoint(path: 'env/endpoints.env')
typedef Endpoints = _Endpoints;
