import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:puffle/theme.dart';

void main() {
  test('colour tokens match the spec', () {
    expect(Tokens.background, const Color(0xFF080B14));
    expect(Tokens.primary, const Color(0xFF6C63FF));
    expect(Tokens.gold, const Color(0xFFFFC94D));
  });
}
