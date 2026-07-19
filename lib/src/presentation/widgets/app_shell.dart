import 'dart:io';

import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.child,
    this.title,
    this.actions,
    this.scrollController,
    this.backPath,
  });

  final Widget child;
  final String? title;
  final List<Widget>? actions;
  final ScrollController? scrollController;
  final String? backPath;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final l10n = context.l10n;
    final destinations = [
      _Destination(l10n.t('home'), Icons.home_rounded, '/'),
      _Destination(l10n.t('send'), Icons.send_rounded, '/send'),
      _Destination(l10n.t('receive'), Icons.download_rounded, '/receive'),
      _Destination(l10n.t('transfers'), Icons.swap_horiz_rounded, '/transfers'),
      if (!Platform.isAndroid)
        _Destination(l10n.t('screen'), Icons.screen_share_rounded, '/screen'),
      if (!Platform.isAndroid)
        _Destination(l10n.t('settings'), Icons.settings_rounded, '/settings'),
    ];
    final appActions = [
      ...?actions,
      if (Platform.isAndroid) ...[
        IconButton.filledTonal(
          tooltip: l10n.t('settings'),
          onPressed: () => context.go('/settings'),
          icon: const Icon(Icons.settings_rounded),
        ),
        const SizedBox(width: 8),
      ],
    ];
    final current = GoRouterState.of(context).uri.path;
    final canGoBack = ModalRoute.of(context)?.canPop == true || current != '/';
    final selected = destinations
        .indexWhere(
          (item) =>
              current == item.path ||
              (item.path != '/' && current.startsWith(item.path)),
        )
        .clamp(0, destinations.length - 1);

    final content = Scaffold(
      appBar: AppBar(
        toolbarHeight: width >= 900 && !Platform.isAndroid ? 68 : null,
        leading: canGoBack
            ? IconButton(
                tooltip: l10n.t('back'),
                onPressed: () => _goBack(context),
                icon: const Icon(Icons.arrow_back_rounded),
              )
            : null,
        titleSpacing: width >= 900 ? 0 : null,
        actions: width >= 900 ? null : appActions,
        title: width >= 900
            ? Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1080),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        Expanded(child: _AppTitle(title: title)),
                        ...appActions,
                      ],
                    ),
                  ),
                ),
              )
            : _AppTitle(title: title),
      ),
      body: SafeArea(child: _ResponsiveContent(child: child)),
      floatingActionButton: scrollController == null
          ? null
          : _ScrollTopButton(controller: scrollController!),
      bottomNavigationBar: width < 900
          ? NavigationBar(
              selectedIndex: selected,
              onDestinationSelected: (index) =>
                  context.go(destinations[index].path),
              destinations: [
                for (final item in destinations)
                  NavigationDestination(
                    icon: Icon(item.icon),
                    label: item.label,
                  ),
              ],
            )
          : null,
    );

    if (width < 900) {
      return _BackHandler(
        current: current,
        onBack: () => _goBack(context),
        child: content,
      );
    }
    return _BackHandler(
      current: current,
      onBack: () => _goBack(context),
      child: Scaffold(
        body: Row(
          children: [
            _DesktopNavigation(
              destinations: destinations,
              selectedIndex: selected,
              onDestinationSelected: (index) =>
                  context.go(destinations[index].path),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: content),
          ],
        ),
      ),
    );
  }

  void _goBack(BuildContext context) {
    if (backPath != null) {
      context.go(backPath!);
      return;
    }
    if (ModalRoute.of(context)?.canPop == true) {
      context.pop();
    } else {
      context.go('/');
    }
  }
}

class _BackHandler extends StatelessWidget {
  const _BackHandler({
    required this.current,
    required this.onBack,
    required this.child,
  });

  final String current;
  final VoidCallback onBack;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: current == '/',
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || current == '/') return;
        onBack();
      },
      child: child,
    );
  }
}

class _AppTitle extends StatelessWidget {
  const _AppTitle({required this.title});

  final String? title;

  @override
  Widget build(BuildContext context) {
    final showLogo = title == null;
    return Row(
      children: [
        if (showLogo) ...[
          SizedBox(
            width: 36,
            height: 36,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/brand/app_icon.png',
                fit: BoxFit.cover,
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Text(
            title ?? 'BShare',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }
}

class _ScrollTopButton extends StatefulWidget {
  const _ScrollTopButton({required this.controller});

  final ScrollController controller;

  @override
  State<_ScrollTopButton> createState() => _ScrollTopButtonState();
}

class _ScrollTopButtonState extends State<_ScrollTopButton> {
  var _visible = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_update);
  }

  @override
  void didUpdateWidget(covariant _ScrollTopButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_update);
      widget.controller.addListener(_update);
      _update();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_update);
    super.dispose();
  }

  void _update() {
    final visible =
        widget.controller.hasClients && widget.controller.offset > 260;
    if (visible != _visible) setState(() => _visible = visible);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _visible ? 1 : 0,
      duration: const Duration(milliseconds: 160),
      child: FloatingActionButton.small(
        tooltip: context.l10n.t('scrollToTop'),
        onPressed: () => widget.controller.animateTo(
          0,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        ),
        child: const Icon(Icons.keyboard_arrow_up_rounded),
      ),
    );
  }
}

class _ResponsiveContent extends StatelessWidget {
  const _ResponsiveContent({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width < 900) return child;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1080),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: child,
        ),
      ),
    );
  }
}

class _Destination {
  const _Destination(this.label, this.icon, this.path);
  final String label;
  final IconData icon;
  final String path;
}

class _DesktopNavigation extends StatelessWidget {
  const _DesktopNavigation({
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final List<_Destination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final background =
        theme.navigationRailTheme.backgroundColor ?? scheme.surfaceContainerLow;

    return Material(
      color: background,
      child: SizedBox(
        width: 280,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            child: Column(
              children: [
                for (var index = 0; index < destinations.length; index++) ...[
                  _DesktopNavigationItem(
                    destination: destinations[index],
                    selected: index == selectedIndex,
                    onTap: () => onDestinationSelected(index),
                  ),
                  if (index != destinations.length - 1)
                    const SizedBox(height: 6),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopNavigationItem extends StatelessWidget {
  const _DesktopNavigationItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final _Destination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected
        ? scheme.onPrimaryContainer
        : scheme.onSurfaceVariant;

    return Semantics(
      button: true,
      selected: selected,
      label: destination.label,
      child: Material(
        color: selected ? scheme.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: SizedBox(
            height: 54,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(destination.icon, size: 26, color: foreground),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      destination.label,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 16,
                        fontWeight: selected
                            ? FontWeight.w800
                            : FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
