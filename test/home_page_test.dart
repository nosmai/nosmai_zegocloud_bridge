import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nosmai_zegocloud_bridge/main.dart';
import 'package:nosmai_zegocloud_bridge/src/config.dart';

void main() {
  testWidgets('home shows both roles and flags missing ZEGOCLOUD settings', (tester) async {
    await tester.pumpWidget(const NosmaiZegoApp(config: AppConfig(roomId: 'room')));
    expect(find.text('Host (Nosmai filters → ZEGOCLOUD)'), findsOneWidget);
    expect(find.text('Viewer'), findsOneWidget);
    expect(find.textContaining('ZEGO_APP_ID is missing'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
  });

  testWidgets('accepts complete settings', (tester) async {
    await tester.pumpWidget(NosmaiZegoApp(config: AppConfig(zegoAppId: '117962517', zegoAppSign: 'ab' * 32)));
    expect(find.textContaining('missing'), findsNothing);
    expect(find.textContaining('AppID 117962517'), findsOneWidget);
  });

  test('user IDs are made safe for ZEGOCLOUD', () {
    expect(userIdFor('Ali Khan'), 'Ali_Khan');
    expect(userIdFor('  '), 'user');
    expect(userIdFor('a.b@c'), 'a_b_c');
  });
}
