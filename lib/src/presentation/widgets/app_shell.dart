import 'package:bshare/src/presentation/localization/app_localizations.dart';
import 'package:bshare/src/presentation/localization/camera_localizations.dart';
import 'package:bshare/src/presentation/navigation/app_navigation.dart';
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
    final platform = Theme.of(context).platform;
    final mobile =
        platform == TargetPlatform.android || platform == TargetPlatform.iOS;
    final showSideNavigation = !mobile || width >= 900;
    final compactSideNavigation = !mobile && width < 900;
    final appTitle = !mobile && (title == null || title == 'BShare')
        ? l10n.t('home')
        : title;
    final destinations = [
      _Destination(l10n.t('home'), Icons.home_rounded, '/'),
      _Destination(l10n.t('send'), Icons.send_rounded, '/send'),
      _Destination(l10n.t('receive'), Icons.download_rounded, '/receive'),
      _Destination(l10n.t('transfers'), Icons.swap_horiz_rounded, '/transfers'),
      if (!mobile)
        _Destination(
          l10n.t('shareScreen'),
          Icons.screen_share_rounded,
          '/screen',
        ),
      if (!mobile)
        _Destination(
          l10n.cameraText('deviceCamera'),
          Icons.videocam_rounded,
          '/camera',
        ),
      if (!mobile)
        _Destination(l10n.t('settings'), Icons.settings_rounded, '/settings'),
    ];
    final appActions = [
      ...?actions,
      if (mobile) ...[
        IconButton.filledTonal(
          tooltip: l10n.t('settings'),
          onPressed: () => context.go('/settings'),
          icon: const Icon(Icons.settings_rounded),
        ),
        const SizedBox(width: 8),
      ],
    ];
    final current = GoRouterState.of(context).uri.path;
    final navigation = AppNavigationScope.maybeOf(context);
    final canGoBack =
        navigation?.canGoBack == true ||
        GoRouter.of(context).canPop() ||
        current != '/';
    final selected = destinations
        .indexWhere(
          (item) =>
              current == item.path ||
              (item.path != '/' && current.startsWith(item.path)),
        )
        .clamp(0, destinations.length - 1);

    final content = Scaffold(
      appBar: AppBar(
        toolbarHeight: width >= 900 && !mobile ? 68 : null,
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
                        Expanded(
                          child: _AppTitle(
                            key: const ValueKey('app-bar-title'),
                            title: appTitle,
                          ),
                        ),
                        ...appActions,
                      ],
                    ),
                  ),
                ),
              )
            : _AppTitle(key: const ValueKey('app-bar-title'), title: appTitle),
      ),
      body: SafeArea(child: _ResponsiveContent(child: child)),
      floatingActionButton: scrollController == null
          ? null
          : _ScrollTopButton(controller: scrollController!),
      bottomNavigationBar: !showSideNavigation
          ? NavigationBarTheme(
              data: NavigationBarTheme.of(context).copyWith(
                labelTextStyle: width < 420
                    ? const WidgetStatePropertyAll(TextStyle(fontSize: 12))
                    : null,
              ),
              child: NavigationBar(
                selectedIndex: selected,
                onDestinationSelected: (index) =>
                    context.go(destinations[index].path),
                destinations: [
                  for (final item in destinations)
                    NavigationDestination(
                      icon: Icon(item.icon),
                      label: item.label,
                      tooltip: item.label,
                    ),
                ],
              ),
            )
          : null,
    );

    if (!showSideNavigation) {
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DesktopNavigation(
              key: const ValueKey('desktop-navigation'),
              destinations: destinations,
              selectedIndex: selected,
              showBrand: !mobile,
              compact: compactSideNavigation,
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
    AppNavigationScope.back(context, fallback: backPath);
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
  const _AppTitle({super.key, required this.title});

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
    if (!_visible) return const SizedBox.shrink();
    return FloatingActionButton.small(
      tooltip: context.l10n.t('scrollToTop'),
      onPressed: () {
        if (MediaQuery.disableAnimationsOf(context)) {
          widget.controller.jumpTo(0);
        } else {
          widget.controller.animateTo(
            0,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          );
        }
      },
      child: const Icon(Icons.keyboard_arrow_up_rounded),
    );
  }
}

class _ResponsiveContent extends StatelessWidget {
  const _ResponsiveContent({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 900;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: wide ? 1080 : double.infinity),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: wide ? 32 : 0),
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
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.showBrand,
    required this.compact,
  });

  final List<_Destination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final bool showBrand;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final background =
        theme.navigationRailTheme.backgroundColor ?? scheme.surfaceContainerLow;

    return Material(
      color: background,
      child: SizedBox(
        width: compact ? 80 : 280,
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 8 : 12,
              vertical: 16,
            ),
            child: SingleChildScrollView(
              primary: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (showBrand) ...[
                    _NavigationBrand(
                      key: const ValueKey('desktop-navigation-brand'),
                      compact: compact,
                    ),
                    const SizedBox(height: 20),
                  ],
                  for (var index = 0; index < destinations.length; index++) ...[
                    _DesktopNavigationItem(
                      destination: destinations[index],
                      selected: index == selectedIndex,
                      onTap: () => onDestinationSelected(index),
                      compact: compact,
                    ),
                    if (index != destinations.length - 1)
                      const SizedBox(height: 6),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavigationBrand extends StatelessWidget {
  const _NavigationBrand({super.key, required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final logo = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.asset(
        'assets/brand/app_icon.png',
        width: 36,
        height: 36,
        fit: BoxFit.cover,
        excludeFromSemantics: true,
      ),
    );
    final label = Text(
      'BShare',
      maxLines: 1,
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
        fontSize: compact ? 14 : 22,
        fontWeight: FontWeight.w800,
      ),
    );

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 16, vertical: 4),
      child: compact
          ? Column(
              children: [
                logo,
                const SizedBox(height: 8),
                FittedBox(fit: BoxFit.scaleDown, child: label),
              ],
            )
          : Row(
              children: [
                logo,
                const SizedBox(width: 12),
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FittedBox(fit: BoxFit.scaleDown, child: label),
                  ),
                ),
              ],
            ),
    );
  }
}

class _DesktopNavigationItem extends StatelessWidget {
  const _DesktopNavigationItem({
    required this.destination,
    required this.selected,
    required this.onTap,
    required this.compact,
  });

  final _Destination destination;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected
        ? scheme.onPrimaryContainer
        : scheme.onSurfaceVariant;

    final item = Semantics(
      button: true,
      selected: selected,
      label: destination.label,
      child: Material(
        color: selected ? scheme.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 54),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 0 : 16,
                vertical: 12,
              ),
              child: compact
                  ? Icon(destination.icon, size: 26, color: foreground)
                  : Row(
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
    return compact ? Tooltip(message: destination.label, child: item) : item;
  }
}
