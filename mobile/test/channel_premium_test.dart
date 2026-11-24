import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:puffle/models/status.dart';
import 'package:puffle/screens/channels_screen.dart';
import 'package:puffle/services/app_scope.dart';
import 'package:puffle/services/app_state.dart';

// Channels now come from Flixvault, so Puffle users browse and join them but
// cannot create their own channels from the app.
void main() {
  for (final source in ['ads', 'organic']) {
    for (final premium in [true, false]) {
      testWidgets('$source user premium=$premium sees no Create channel button', (tester) async {
        final app = AppState()..status = AppStatus({
          'is_guest': false, 'source': source, 'is_premium': premium,
          'plans_visible': false, 'free_mode': false,
        });
        await tester.pumpWidget(AppScope(state: app, child: const MaterialApp(home: ChannelsScreen())));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(FloatingActionButton, 'Create'), findsNothing);
        expect(find.text('Create a channel'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        app.dispose();
      });
    }
  }
}
