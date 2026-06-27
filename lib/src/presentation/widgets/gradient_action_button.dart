import 'package:flutter/material.dart';

class GradientActionButton extends StatelessWidget {
  const GradientActionButton({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
    this.expand = false,
    this.vertical = false,
    this.width,
    this.height,
  });

  final VoidCallback? onPressed;
  final IconData icon;
  final String label;
  final bool expand;
  final bool vertical;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final child = _GradientButtonSurface(
      onPressed: onPressed,
      minWidth: expand ? double.infinity : 0,
      width: width,
      height: height,
      child: vertical
          ? Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 21),
                const SizedBox(height: 5),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
              ],
            )
          : Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 20),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
    );
    return expand ? SizedBox(width: double.infinity, child: child) : child;
  }
}

class GradientIconButton extends StatelessWidget {
  const GradientIconButton({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.tooltip,
  });

  final VoidCallback? onPressed;
  final IconData icon;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: _GradientButtonSurface(
        onPressed: onPressed,
        width: 48,
        child: Icon(icon, size: 22),
      ),
    );
  }
}

class _GradientButtonSurface extends StatelessWidget {
  const _GradientButtonSurface({
    required this.onPressed,
    required this.child,
    this.width,
    this.height,
    this.minWidth = 0,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final double? width;
  final double? height;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final gradient = LinearGradient(
      colors: enabled
          ? [
              scheme.primaryContainer.withValues(alpha: 0.88),
              Color.lerp(
                scheme.primaryContainer,
                scheme.primary,
                0.18,
              )!.withValues(alpha: 0.9),
            ]
          : [
              scheme.surfaceContainerHighest.withValues(alpha: 0.84),
              scheme.surfaceContainerHigh.withValues(alpha: 0.74),
            ],
    );
    final foreground = enabled ? scheme.onPrimaryContainer : scheme.outline;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: minWidth),
        child: Ink(
          width: width,
          height: height ?? 48,
          decoration: BoxDecoration(
            gradient: gradient,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: enabled
                  ? scheme.primary.withValues(alpha: 0.22)
                  : scheme.outlineVariant,
            ),
          ),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: IconTheme.merge(
                data: IconThemeData(color: foreground),
                child: DefaultTextStyle.merge(
                  style: TextStyle(color: foreground),
                  child: Center(child: child),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
