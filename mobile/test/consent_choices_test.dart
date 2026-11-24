import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:puffle/screens/consent_gate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  for (final allow in [true, false]) {
    testWidgets('single consent saves all measurement choices as $allow', (t) async {
      SharedPreferences.setMockInitialValues({});
      final choices = <bool>[];
      await t.pumpWidget(MaterialApp(home: ConsentGate(
        requestNotifications: () async {},
        saveMeasurementChoice: (v) async { choices.add(v); },
        child: const Text('Home'),
      )));
      await t.pumpAndSettle();
      final button = find.text(allow ? 'Agree and continue' : 'Continue without optional sharing');
      await t.ensureVisible(button);
      await t.tap(button);
      await t.pumpAndSettle();
      expect(choices, [allow]);
      expect(find.byType(ConsentDialog), findsNothing);
      expect(find.text('Measurement preferences'), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(consentPrefKey), true);
      expect(prefs.getString('consent_notice_version'), isNotNull);
    });
  }
  testWidgets('first-run agreement is stored even before a session exists', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'https://example.test', anonKey: 'test-key',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    expect(Supabase.instance.client.auth.currentSession, isNull);
    await tester.pumpWidget(MaterialApp(home: ConsentGate(
      requestNotifications: () async {},
      child: const Text('Home'),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agree and continue'));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(consentPrefKey), true);
    expect(prefs.getString('pending_onboarding_measurement'), contains('"allow":true'));
    expect(find.byType(ConsentDialog), findsNothing);
  });

  testWidgets('failed consent save stays open and can retry', (t) async {
    SharedPreferences.setMockInitialValues({});
    var tries = 0;
    await t.pumpWidget(MaterialApp(home: ConsentGate(
      requestNotifications: () async {},
      saveMeasurementChoice: (_) async { if (++tries == 1) throw StateError('offline'); },
      child: const Text('Home'),
    )));
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('Agree and continue'));
    await t.tap(find.text('Agree and continue'));
    await t.pumpAndSettle();
    expect(find.byType(ConsentDialog), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getBool(consentPrefKey), isNot(true));
    expect(find.textContaining('Could not save'), findsOneWidget);
    await t.ensureVisible(find.text('Agree and continue'));
    await t.tap(find.text('Agree and continue'));
    await t.pumpAndSettle();
    expect(tries, 2);
    expect(find.byType(ConsentDialog), findsNothing);
  });
}
