import 'package:flutter_test/flutter_test.dart';
import 'package:puffle/services/google_auth_policy.dart';
void main() {
  test('guest sign-up and paid guest login link the same account', () {
    for (final flags in [[true,false,false],[false,true,false],[false,false,true]]) {
      expect(shouldLinkGoogleIdentity(anonymous:true,signup:flags[0],saveMode:flags[1],premium:flags[2]),isTrue);
    }
  });
  test('returning login uses sign-in, not a guest upgrade', () {
    expect(shouldLinkGoogleIdentity(anonymous:true,signup:false,saveMode:false,premium:false),isFalse);
    expect(shouldLinkGoogleIdentity(anonymous:false,signup:true,saveMode:true,premium:true),isFalse);
  });
}
