import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:puffle/screens/channels_screen.dart';

void main() {
  testWidgets('search includes only joined channels and matches names without case sensitivity', (t) async {
    final rows = <Map<String, dynamic>>[
      {'id': 'one', 'name': 'Power Tools'},
      {'id': 'two', 'name': 'Travel'},
      {'id': 'three', 'name': 'Unjoined Power'},
    ];
    await t.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(body: TextButton(
      onPressed: () => showSearch<Map<String, dynamic>?>(context: context, delegate: JoinedChannelSearch(rows: rows, joined: {'one', 'two'})),
      child: const Text('Search'),
    )))));
    await t.tap(find.text('Search')); await t.pumpAndSettle();
    expect(find.text('Power Tools'), findsOneWidget);
    expect(find.text('Travel'), findsOneWidget);
    expect(find.text('Unjoined Power'), findsNothing);
    await t.enterText(find.byType(TextField), 'POWER'); await t.pumpAndSettle();
    expect(find.text('Power Tools'), findsOneWidget); expect(find.text('Travel'), findsNothing);
    await t.enterText(find.byType(TextField), 'missing'); await t.pumpAndSettle();
    expect(find.text('No joined channels match your search.'), findsOneWidget);
    await t.tap(find.byTooltip('Clear search')); await t.pumpAndSettle();
    expect(find.text('Travel'), findsOneWidget);
  });
}

