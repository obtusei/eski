import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../features/camera/camera_controller.dart';
import '../../features/camera/camera_screen.dart';
import '../../features/creative_studio/studio_model.dart';
import '../../features/creative_studio/studio_screen.dart';
import '../../features/editor/editor_screen.dart';
import '../../features/gallery/gallery_screen.dart';
import '../../features/gallery/viewer_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../theme/theme.dart';

final router = GoRouter(
  initialLocation: '/camera',
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => _Shell(shell),
      branches: [
        StatefulShellBranch(routes: [GoRoute(path: '/camera', builder: (_, _) => const CameraScreen())]),
        StatefulShellBranch(routes: [GoRoute(path: '/library', builder: (_, _) => const GalleryScreen())]),
        StatefulShellBranch(routes: [GoRoute(path: '/studio', builder: (_, _) => const StudioScreen())]),
        StatefulShellBranch(routes: [GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen())]),
      ],
    ),
    GoRoute(path: '/viewer', builder: (_, s) => ViewerScreen(s.extra! as ViewerArgs)),
    GoRoute(path: '/editor', builder: (_, s) => EditorScreen(s.extra! as AssetEntity)),
    GoRoute(path: '/studio/edit', builder: (_, s) => StudioEditor(s.extra! as Comp)),
  ],
);

const _tabs = ['camera', 'library', 'studio', 'settings'];

/// Bottom navigation: four quiet words.
class _Shell extends ConsumerWidget {
  const _Shell(this.shell);
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onCamera = shell.currentIndex == 0;
    final c = context.c;
    final fg = onCamera ? Colors.white : c.text;
    final dim = onCamera ? Colors.white54 : c.dim;
    return Scaffold(
      backgroundColor: onCamera ? Colors.black : c.bg,
      body: shell,
      bottomNavigationBar: ColoredBox(
        color: onCamera ? Colors.black : c.bg,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 46,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final (i, t) in _tabs.indexed)
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        if (i != shell.currentIndex) HapticFeedback.selectionClick();
                        ref.read(tabProvider.notifier).set(i);
                        shell.goBranch(i, initialLocation: i == shell.currentIndex);
                      },
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(t, style: context.label(i == shell.currentIndex ? fg : dim, 13)),
                            const SizedBox(height: 4),
                            Container(
                              width: 3,
                              height: 3,
                              decoration: BoxDecoration(
                                color: i == shell.currentIndex ? c.accent : Colors.transparent,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
