import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Remembers route origins without keeping previous screens, cameras or
/// renderers mounted. Repeated visits replace their older history entry.
class AppNavigation {
  AppNavigation(this.router) {
    router.routerDelegate.addListener(_recordLocation);
    _recordLocation();
  }

  final GoRouter router;
  final List<({String location, Object? extra})> _history = [];

  bool get canGoBack => _history.length > 1;

  void _recordLocation() {
    final configuration = router.routerDelegate.currentConfiguration;
    final location = configuration.uri.toString();
    if (configuration.isEmpty || location.isEmpty) return;
    if (_history.isNotEmpty && _history.last.location == location) return;
    if (configuration.uri.path == '/') _history.clear();
    _history.removeWhere((entry) => entry.location == location);
    _history.add((location: location, extra: configuration.extra));
    // Bound history even when future routes contain arbitrary query strings.
    if (_history.length > 32) _history.removeAt(1);
  }

  void back({String? fallback}) {
    if (canGoBack) {
      _history.removeLast();
      final previous = _history.last;
      router.go(previous.location, extra: previous.extra);
      return;
    }
    if (router.canPop()) {
      router.pop();
      return;
    }
    final current = router.routerDelegate.currentConfiguration.uri.path;
    final parent = fallback ?? (current.startsWith('/send/') ? '/send' : '/');
    if (parent != current) {
      _history.clear();
      _history.add((location: parent, extra: null));
      router.go(parent);
    }
  }

  void dispose() {
    router.routerDelegate.removeListener(_recordLocation);
  }
}

class AppNavigationScope extends InheritedWidget {
  const AppNavigationScope({
    super.key,
    required this.navigation,
    required super.child,
  });

  final AppNavigation navigation;

  @override
  bool updateShouldNotify(AppNavigationScope oldWidget) =>
      navigation != oldWidget.navigation;

  static AppNavigation? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AppNavigationScope>()
      ?.navigation;

  static void back(BuildContext context, {String? fallback}) {
    final navigation = maybeOf(context);
    if (navigation != null) {
      navigation.back(fallback: fallback);
    } else if (GoRouter.of(context).canPop()) {
      context.pop();
    } else {
      final path = GoRouterState.of(context).uri.path;
      context.go(fallback ?? (path.startsWith('/send/') ? '/send' : '/'));
    }
  }
}
