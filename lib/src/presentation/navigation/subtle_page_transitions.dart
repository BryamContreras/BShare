import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// Short fades keep navigation still and avoid stacking scale/slide effects.
/// iOS keeps its native transition and interactive back gesture.
const subtlePageTransitions = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: SubtlePageTransitionsBuilder(),
    TargetPlatform.fuchsia: SubtlePageTransitionsBuilder(),
    TargetPlatform.linux: SubtlePageTransitionsBuilder(),
    TargetPlatform.macOS: SubtlePageTransitionsBuilder(),
    TargetPlatform.windows: SubtlePageTransitionsBuilder(),
    TargetPlatform.iOS: _AccessibleCupertinoPageTransitionsBuilder(),
  },
);

class SubtlePageTransitionsBuilder extends PageTransitionsBuilder {
  const SubtlePageTransitionsBuilder();

  @override
  Duration get transitionDuration => const Duration(milliseconds: 140);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 110);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return FadeTransition(
      opacity: animation.drive(CurveTween(curve: Curves.easeOut)),
      child: child,
    );
  }
}

class _AccessibleCupertinoPageTransitionsBuilder
    extends CupertinoPageTransitionsBuilder {
  const _AccessibleCupertinoPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return super.buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
}
