import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'core/image_processing/look_engine.dart';
import 'core/storage/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // The look shader and saved state load before the first frame so the
  // camera opens directly, with no splash logic in between.
  await Future.wait([LookEngine.init(), Boot.load()]);
  runApp(const ProviderScope(child: EskiApp()));
}
