import 'package:flutter_test/flutter_test.dart';
import 'package:puffle/services/flixvault.dart';

void main() {
  test('Flixvault errors carry the server reason', () {
    expect(FlixvaultError('premium_required').code, 'premium_required');
  });
}
