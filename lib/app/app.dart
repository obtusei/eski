import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/storage/app_state.dart';
import 'router/router.dart';
import 'theme/theme.dart';

class EskiApp extends ConsumerWidget {
  const EskiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    return MaterialApp.router(
      title: 'eski',
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      themeMode: s.themeMode,
      theme: eskiTheme(Brightness.light, s.accent),
      darkTheme: eskiTheme(Brightness.dark, s.accent),
    );
  }
}
