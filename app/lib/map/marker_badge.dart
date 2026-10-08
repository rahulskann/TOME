import 'dart:io';

import 'package:flutter/material.dart';

import '../pack/category_icons.dart';
import '../pack/pack.dart';

/// A round, colour-coded icon for a category. Used on the map and in lists.
/// [found] markers are dimmed and ticked.
class CategoryBadge extends StatelessWidget {
  const CategoryBadge({super.key, required this.category, this.size = 28, this.found = false});

  final MarkerCategory? category;
  final double size;
  final bool found;

  @override
  Widget build(BuildContext context) {
    final color = category?.color ?? Theme.of(context).colorScheme.primary;
    final onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
            ? Colors.white
            : Colors.black87;
    final badge = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: size / 14),
        boxShadow: found ? null : const [BoxShadow(blurRadius: 4, color: Colors.black54)],
      ),
      child: _symbol(onColor),
    );
    if (!found) return badge;
    return _withTick(badge);
  }

  /// The pack's own icon image if it has one, else the built-in icon.
  Widget _symbol(Color onColor) {
    final builtIn = Icon(categoryIcon(category?.icon), size: size * 0.55, color: onColor);
    final file = category?.iconFile;
    if (file == null) return builtIn;
    final px = size * 0.72;
    return Center(
      child: Image.file(
        File(file),
        width: px,
        height: px,
        fit: BoxFit.contain,
        cacheWidth: 128, // icons are at most 128px; don't decode more
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => builtIn,
      ),
    );
  }

  Widget _withTick(Widget badge) {
    final tick = size * 0.5;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Opacity(opacity: 0.4, child: badge),
          Positioned(
            right: -tick * 0.25,
            bottom: -tick * 0.25,
            child: Container(
              width: tick,
              height: tick,
              decoration: const BoxDecoration(color: Color(0xFF3DBE6B), shape: BoxShape.circle),
              child: Icon(Icons.check, size: tick * 0.8, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
