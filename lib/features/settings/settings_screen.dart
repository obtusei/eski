import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/theme.dart';
import '../../core/media/media_library.dart';
import '../../core/storage/app_state.dart';
import '../../core/storage/db.dart';
import '../../shared/widgets/common.dart';
import '../camera/camera_controller.dart';

final _storageProvider = FutureProvider.autoDispose<(int, int)>((ref) async {
  return (await Db.dirSize(Db.tempDir), await Db.dirSize(Db.supportDir));
});

String _mb(int bytes) => bytes < 1048576 ? '${(bytes / 1024).toStringAsFixed(0)} KB' : '${(bytes / 1048576).toStringAsFixed(1)} MB';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final set = ref.read(settingsProvider.notifier).set;
    final c = context.c;
    final cam = ref.watch(cameraProvider.select((x) => x.camera));
    final storage = ref.watch(_storageProvider).value;
    final lib = ref.watch(libraryProvider);
    final edits = ref.watch(editsProvider.select((m) => m.length));

    Widget head(String t) => Padding(
          padding: EdgeInsets.fromLTRB(22, 30, 22, 6),
          child: Text(t, style: context.display(22).copyWith(fontStyle: FontStyle.italic)),
        );
    Widget toggle(String title, bool value, String key) =>
        Row2(title, value: value ? 'on' : 'off', onTap: () => set(key, !value));
    Widget cycle<T>(String title, T value, List<T> options, String key, {String Function(T)? label}) => Row2(
          title,
          value: label?.call(value) ?? '$value',
          onTap: () => set(key, options[(options.indexOf(value) + 1) % options.length]),
        );

    final sizes = cam?.photoSizes ?? const <List<int>>[];
    final mp = sizes.isEmpty ? null : sizes[s.photoMp.clamp(0, sizes.length - 1)];
    final videoModes = cam?.videoSizes ?? const <List<int>>[];
    final heights = videoModes.isEmpty ? const [2160, 1080, 720] : [for (final m in videoModes) m[1]];
    final maxFps = videoModes.where((m) => m[1] == s.videoHeight).firstOrNull?[2] ?? 30;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          children: [
            Padding(padding: const EdgeInsets.fromLTRB(22, 14, 22, 0), child: Text('settings', style: context.display(40))),
            head('appearance'),
            cycle<int>('theme', s.themeMode.index, const [0, 1, 2], 'theme', label: (i) => const ['automatic', 'light', 'dark'][i]),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
              child: Row(
                children: [
                  Expanded(child: Text('accent', style: context.body())),
                  for (final e in accentChoices.entries)
                    GestureDetector(
                      onTap: () => set('accent', e.value.toARGB32()),
                      child: Semantics(
                        label: e.key,
                        button: true,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 10),
                          child: Container(
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              color: e.value,
                              shape: BoxShape.circle,
                              border: Border.all(color: s.accent == e.value ? c.text : Colors.transparent, width: 2),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            cycle<int>('density', s.density, const [0, 1, 2], 'density', label: (i) => const ['compact', 'regular', 'roomy'][i]),
            cycle<int>('library columns', s.columns, const [2, 3, 4, 5], 'columns'),
            cycle<int>('editor tools', s.toolStyle, const [0, 1], 'toolStyle', label: (i) => const ['minimal', 'chips'][i]),
            if (s.toolStyle == 1) toggle('tool icons', s.toolIcons, 'toolIcons'),

            head('camera'),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 8, 22, 2),
              child: Text('viewfinder controls', style: context.body()),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11),
              child: Wrap(
                children: [
                  for (final id in allCameraControls)
                    TextTab(id, active: s.controls.contains(id), onTap: () {
                      final list = [...s.controls];
                      list.contains(id) ? list.remove(id) : list.add(id);
                      set('controls', [for (final k in allCameraControls) if (list.contains(k)) k]);
                    }),
                ],
              ),
            ),
            toggle('mirror the front camera', s.mirrorFront, 'mirrorFront'),
            toggle('shutter haptics', s.haptics, 'haptics'),
            toggle('stabilization', s.stabilization, 'stabilization'),
            toggle('save a filtered copy for other apps', s.saveFiltered, 'saveFiltered'),
            if (mp != null && sizes.length > 1)
              Row2(
                'photo resolution',
                value: '${(mp[0] * mp[1] / 1e6).toStringAsFixed(1)} MP',
                onTap: () => set('photoMp', (s.photoMp + 1) % sizes.length),
              ),
            cycle<int>('video resolution', heights.contains(s.videoHeight) ? s.videoHeight : heights.first, heights, 'videoHeight', label: (h) => '${h}p'),
            cycle<int>(
              'video frame rate',
              s.videoFps.clamp(24, maxFps),
              [for (final f in const [24, 30, 60]) if (f <= maxFps) f],
              'videoFps',
              label: (f) => '$f fps',
            ),

            head('export'),
            cycle<String>('format', s.exportFormat, const ['jpeg', 'png'], 'exportFormat'),
            cycle<int>('jpeg quality', s.jpegQuality, const [85, 90, 95, 100], 'jpegQuality'),
            cycle<int>('long edge limit', s.maxEdge, const [2048, 4096, 8192], 'maxEdge', label: (v) => '$v px'),

            head('storage'),
            Row2('photographs in the library', value: lib.granted == true ? '${lib.total}' : '—'),
            Row2('edits kept', value: '$edits'),
            Row2('edit database', value: storage == null ? '…' : _mb(storage.$2)),
            Row2('working files', value: storage == null ? '…' : _mb(storage.$1)),
            Row2('clear working files', onTap: () async {
              await Db.clearTemp();
              ref.invalidate(_storageProvider);
              if (context.mounted) toast(context, 'working files cleared');
            }),

            head('about'),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 8, 22, 0),
              child: Text(
                'eski 1.0 — capture less ordinary moments.\n\nEverything stays on this device. No account, no cloud, no tracking. Originals are never changed; edits are kept beside them as recipes you can revisit.',
                style: context.body(c.dim),
              ),
            ),
            const SizedBox(height: 60),
          ],
        ),
      ),
    );
  }
}
