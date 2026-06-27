import 'package:flutter/material.dart';

class CompactTransferButton extends StatelessWidget {
  const CompactTransferButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.size = 34,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: SizedBox.square(
        dimension: size,
        child: Material(
          color: enabled
              ? colors.primaryContainer.withValues(alpha: 0.88)
              : colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Icon(
              icon,
              size: size <= 30 ? 16 : 18,
              color: enabled
                  ? colors.onPrimaryContainer
                  : colors.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
