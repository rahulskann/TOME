import 'package:flutter/material.dart';

import 'pack/packs_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final theme = await ThemeSetting.load();
  runApp(TomeApp(theme: theme));
}

class TomeApp extends StatelessWidget {
  const TomeApp({super.key, required this.theme});

  final ThemeSetting theme;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: theme,
      builder: (context, current, _) => MaterialApp(
        title: 'TOME',
        theme: current.data,
        home: PacksScreen(theme: theme),
      ),
    );
  }
}
