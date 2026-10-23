import 'package:bshare/src/presentation/navigation/subtle_page_transitions.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _openPageKey = ValueKey('open-page');
const _secondPageKey = ValueKey('second-page');

Future<MaterialPageRoute<void>> _openPage(
  WidgetTester tester,
  TargetPlatform platform,
) async {
  late MaterialPageRoute<void> route;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        platform: platform,
        pageTransitionsTheme: subtlePageTransitions,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            key: _openPageKey,
            onPressed: () {
              route = MaterialPageRoute<void>(
                builder: (_) => const Scaffold(
                  key: _secondPageKey,
                  body: Center(child: Text('Second page')),
                ),
              );
              Navigator.of(context).push(route);
            },
            child: const Text('Open page'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(_openPageKey));
  await tester.pump();
  return route;
}

void main() {
  test('Android and desktop use brief fades; iOS keeps Cupertino', () {
    expect(
      subtlePageTransitions.builders.keys,
      containsAll(TargetPlatform.values),
    );
    for (final platform in TargetPlatform.values) {
      final builder = subtlePageTransitions.builders[platform]!;
      if (platform == TargetPlatform.iOS) {
        expect(builder, isA<CupertinoPageTransitionsBuilder>());
        expect(builder.delegatedTransition, isNotNull);
      } else {
        expect(builder, isA<SubtlePageTransitionsBuilder>());
        expect(builder.transitionDuration, const Duration(milliseconds: 140));
        expect(
          builder.reverseTransitionDuration,
          const Duration(milliseconds: 110),
        );
      }
    }
  });

  testWidgets('navigation fades briefly without sliding or scaling the page', (
    tester,
  ) async {
    final route = await _openPage(tester, TargetPlatform.linux);
    expect(route.transitionDuration, const Duration(milliseconds: 140));
    expect(route.reverseTransitionDuration, const Duration(milliseconds: 110));
    await tester.pump(const Duration(milliseconds: 70));

    final page = find.byKey(_secondPageKey);
    final fades = find.ancestor(
      of: page,
      matching: find.byType(FadeTransition),
    );
    expect(fades, findsOneWidget);
    final fade = tester.widget<FadeTransition>(fades);
    expect(fade.opacity.value, greaterThan(0));
    expect(fade.opacity.value, lessThan(1));
    expect(
      find.ancestor(of: page, matching: find.byType(SlideTransition)),
      findsNothing,
    );
    expect(
      find.ancestor(of: page, matching: find.byType(ScaleTransition)),
      findsNothing,
    );

    await tester.pump(const Duration(milliseconds: 70));
    expect(fade.opacity.value, 1);
    route.navigator!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    await tester.pumpAndSettle();
    expect(find.byKey(_secondPageKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disableAnimations skips route effects on every platform', (
    tester,
  ) async {
    const child = SizedBox(width: 20, height: 20);
    for (final platform in TargetPlatform.values) {
      final route = MaterialPageRoute<void>(builder: (_) => child);
      addTearDown(route.dispose);
      Widget? transition;
      final transitionKey = ValueKey('transition-$platform');
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey(platform),
          theme: ThemeData(platform: platform),
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Builder(
              builder: (context) {
                transition = subtlePageTransitions.builders[platform]!
                    .buildTransitions<void>(
                      route,
                      context,
                      const AlwaysStoppedAnimation(0.5),
                      const AlwaysStoppedAnimation(0),
                      child,
                    );
                return KeyedSubtree(key: transitionKey, child: transition!);
              },
            ),
          ),
        ),
      );
      expect(transition, same(child), reason: '$platform');
      final subtree = find.byKey(transitionKey);
      for (final type in [FadeTransition, SlideTransition, ScaleTransition]) {
        expect(
          find.descendant(of: subtree, matching: find.byType(type)),
          findsNothing,
          reason: '$platform/$type',
        );
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('iOS still supports its interactive edge swipe to go back', (
    tester,
  ) async {
    final route = await _openPage(tester, TargetPlatform.iOS);
    await tester.pumpAndSettle();
    expect(find.byKey(_secondPageKey), findsOneWidget);
    expect(route.popGestureEnabled, isTrue);

    await tester.timedDragFrom(
      const Offset(1, 300),
      const Offset(600, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(_secondPageKey), findsNothing);
    expect(find.byKey(_openPageKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
