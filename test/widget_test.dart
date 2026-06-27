import 'package:bshare/src/presentation/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('BShare app renders', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: BShareApp()));
    expect(find.text('BShare'), findsWidgets);
  });

  for (final size in [
    const Size(320, 568),
    const Size(360, 780),
    const Size(393, 852),
    const Size(800, 600),
  ]) {
    testWidgets('Home and Send fit at ${size.width}x${size.height}', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(const ProviderScope(child: BShareApp()));
      await tester.pump(const Duration(milliseconds: 500));

      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Send').last);
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
    });
  }
}
