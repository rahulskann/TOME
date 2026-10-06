import 'package:flutter/material.dart';

/// Icons a pack can name in `categories[].icon`. Names are part of the pack
/// format (docs/pack-format.md), so only ever add to this map; never rename.
const Map<String, IconData> categoryIcons = {
  'circle': Icons.circle,
  'star': Icons.star,
  'heart': Icons.favorite,
  'chest': Icons.inventory_2,
  'key': Icons.vpn_key,
  'gem': Icons.diamond,
  'coin': Icons.paid,
  'shield': Icons.shield,
  'book': Icons.auto_stories,
  'scroll': Icons.description,
  'flag': Icons.flag,
  'door': Icons.door_front_door,
  'bench': Icons.chair,
  'bell': Icons.notifications,
  'boss': Icons.local_fire_department,
  'enemy': Icons.pest_control,
  'npc': Icons.person,
  'shop': Icons.storefront,
  'quest': Icons.priority_high,
  'secret': Icons.visibility_off,
  'puzzle': Icons.extension,
  'travel': Icons.alt_route,
  'save': Icons.bookmark,
  'tool': Icons.build,
  'skill': Icons.bolt,
  'upgrade': Icons.arrow_circle_up,
  'map': Icons.map,
  'music': Icons.music_note,
  'flower': Icons.local_florist,
  'fish': Icons.set_meal,
  'bug': Icons.bug_report,
  'water': Icons.water_drop,
  'note': Icons.sticky_note_2,
};

IconData categoryIcon(String? name) => categoryIcons[name] ?? Icons.circle;
