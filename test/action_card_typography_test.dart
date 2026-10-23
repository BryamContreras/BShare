import 'package:bshare/src/presentation/widgets/action_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final mobile in [true, false]) {
    for (final width in [320.0, 390.0]) {
      testWidgets('home card typography mobile=$mobile width=$width', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                child: Center(
                  child: SizedBox(
                    width: width,
                    child: ActionCard(
                      title: 'Cámara del dispositivo',
                      subtitle: 'Comparte la cámara con una computadora.',
                      icon: Icons.videocam_rounded,
                      onTap: () {},
                      compactTypography: mobile,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final compact = width < 340;
        final title = find.text('Cámara del dispositivo');
        expect(
          tester.widget<Text>(title).style?.fontSize,
          mobile ? (compact ? 15 : 20) : (compact ? 16 : 22),
        );
        expect(
          tester
              .widget<Text>(
                find.text('Comparte la cámara con una computadora.'),
              )
              .style
              ?.fontSize,
          mobile ? (compact ? 12 : 13) : (compact ? 12 : 14),
        );
        expect(
          tester.renderObject<RenderParagraph>(title).textScaler.scale(10),
          20,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
