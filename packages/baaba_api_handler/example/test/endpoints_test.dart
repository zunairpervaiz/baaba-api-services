// End to end: the code baaba_api_generator wrote for env/*.env compiles,
// decodes to the values in those files, and does not contain them.
import 'dart:io';

import 'package:baaba_api_handler_example/config/endpoints.dart';
import 'package:baaba_api_handler_example/config/partner_env.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generated endpoints decode and fill', () {
    expect(Endpoints.postComments(7), 'posts/7/comments');
    expect(Endpoints.userPost(1, 2), 'users/1/posts/2');
    expect(Endpoints.partnerGraphql, 'graphql');
    expect(
      Endpoints.partnerStatement('ACC 001', 'latest'),
      'accounts/ACC%20001/statements/latest',
    );
  });

  test('generated environment is typed', () {
    expect(PartnerEnv.baseUrl, Uri.parse('https://partner.example.net/api'));
    expect(PartnerEnv.connectTimeoutSeconds, 45);
    expect(PartnerEnv.proxy, isNull); // PROXY= is empty
  });

  test('no value from env/ appears in the generated files', () {
    final generated = [
      File('lib/config/endpoints.g.dart').readAsStringSync(),
      File('lib/config/partner_env.g.dart').readAsStringSync(),
    ].join();
    for (final leak in [
      'posts',
      'comments',
      'statements',
      'graphql',
      'partner.example.net',
      'https',
    ]) {
      expect(generated, isNot(contains(leak)), reason: leak);
    }
  });
}
