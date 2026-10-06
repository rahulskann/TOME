import 'package:flutter/material.dart';

import 'pack/packs_screen.dart';

void main() => runApp(const TomeApp());

class TomeApp extends StatelessWidget {
  const TomeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TOME',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF7FB2F0), brightness: Brightness.dark),
      ),
      home: const PacksScreen(),
    );
  }
}
