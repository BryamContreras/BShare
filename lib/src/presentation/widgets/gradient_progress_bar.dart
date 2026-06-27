import 'package:flutter/material.dart';

class GradientProgressBar extends StatelessWidget {
  const GradientProgressBar({super.key, required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: 10,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.18),
            ),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: clamped,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFF1D7FC4).withValues(alpha: 0.88),
                      const Color(0xFF4DA9DC).withValues(alpha: 0.72),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
