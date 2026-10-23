import 'package:flutter/material.dart';

class ActionCard extends StatelessWidget {
  const ActionCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
    this.compactTypography = false,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;
  final bool compactTypography;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 340;
          final iconExtent = compact ? 38.0 : 44.0;
          final textTheme = Theme.of(context).textTheme;
          final titleStyle =
              (compact ? textTheme.titleMedium : textTheme.titleLarge)
                  ?.copyWith(
                    fontSize: compactTypography ? (compact ? 15 : 20) : null,
                    fontWeight: FontWeight.w800,
                  );
          final subtitleStyle =
              (compact ? textTheme.bodySmall : textTheme.bodyMedium)?.copyWith(
                fontSize: compactTypography ? (compact ? 12 : 13) : null,
                color: scheme.onSurfaceVariant,
              );
          return Ink(
            padding: EdgeInsets.all(compact ? 12 : 14),
            decoration: BoxDecoration(
              color: Theme.of(context).cardTheme.color,
              borderRadius: BorderRadius.circular(8),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x1F1389D8),
                  blurRadius: 28,
                  offset: Offset(0, 12),
                ),
              ],
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: iconExtent,
                  height: iconExtent,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    icon,
                    color: scheme.primary,
                    size: compact ? 22 : 26,
                  ),
                ),
                SizedBox(width: compact ? 10 : 14),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: titleStyle,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        maxLines: compact ? 1 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: subtitleStyle,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
