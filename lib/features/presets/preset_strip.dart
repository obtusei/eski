import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/theme.dart';
import '../../core/image_processing/adjustments.dart';
import '../../core/image_processing/look_engine.dart';
import '../../core/storage/app_state.dart';
import '../../shared/widgets/common.dart';
import 'preset_library.dart';

/// Bundled sample photograph for look thumbnails when no photo is at hand.
final sampleSceneProvider = FutureProvider<ui.Image>((ref) async {
  try {
    final data = await rootBundle.load('assets/images/sample.jpg');
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final image = (await codec.getNextFrame()).image;
    codec.dispose();
    return image;
  } catch (_) {
    return buildSampleScene();
  }
});

/// Collection tabs over a strip of live look thumbnails. Tap to apply,
/// long-press to favourite.
class PresetStrip extends ConsumerStatefulWidget {
  const PresetStrip({super.key, required this.selected, required this.onSelect, this.thumb, this.onCreate});

  /// When set, a “new” tile is shown that saves the current edit as a look.
  final VoidCallback? onCreate;

  final String? selected;
  final ValueChanged<String?> onSelect;

  /// Image used for thumbnails; a built-in scene is used when null.
  final ui.Image? thumb;

  @override
  ConsumerState<PresetStrip> createState() => _PresetStripState();
}

class _PresetStripState extends ConsumerState<PresetStrip> {
  String _tab = 'all';
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Options for a look the user made.
  void _manage(Preset p) {
    showEskiSheet<void>(
      context,
      (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 18),
          Text(p.name.toLowerCase(), style: ctx.display(28)),
          const SizedBox(height: 8),
          Row2(ref.read(presetFavsProvider).contains(p.id) ? 'remove from favorites' : 'add to favorites', onTap: () {
            ref.read(presetFavsProvider.notifier).toggle(p.id);
            Navigator.pop(ctx);
          }),
          Row2('delete this look', danger: true, onTap: () {
            if (widget.selected == p.id) widget.onSelect(null);
            ref.read(userPresetsProvider.notifier).remove(p.id);
            Navigator.pop(ctx);
          }),
          const SizedBox(height: 14),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final favs = ref.watch(presetFavsProvider);
    final mine = ref.watch(userPresetsProvider);
    final all = [...mine, ...builtInPresets];
    final tabs = ['all', if (favs.isNotEmpty) 'favorites', if (mine.isNotEmpty) 'My Looks', ...presetCollections];
    if (!tabs.contains(_tab)) _tab = 'all';
    final list = switch (_tab) {
      'all' => all,
      'favorites' => [for (final p in all) if (favs.contains(p.id)) p],
      _ => [for (final p in all) if (p.collection == _tab) p],
    };
    final thumb = widget.thumb ?? ref.watch(sampleSceneProvider).value;
    final lead = widget.onCreate == null ? 1 : 2;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 30,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (final t in tabs)
                TextTab(
                  t.toLowerCase(),
                  active: t == _tab,
                  dot: false,
                  onTap: () {
                    setState(() => _tab = t);
                    if (_scroll.hasClients) _scroll.jumpTo(0);
                  },
                ),
            ],
          ),
        ),
        SizedBox(
          height: 100,
          child: ListView.builder(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            itemCount: list.length + lead,
            itemBuilder: (context, i) {
              if (i == 1 && lead == 2) {
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onCreate,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: SizedBox(
                      width: 58,
                      child: Column(
                        children: [
                          Container(
                            width: 58,
                            height: 68,
                            decoration: BoxDecoration(border: Border.all(color: c.line)),
                            child: Icon(Icons.add, size: 20, color: c.accentInk),
                          ),
                          const SizedBox(height: 5),
                          Text('new look', maxLines: 1, style: context.label(c.dim, 10.5)),
                        ],
                      ),
                    ),
                  ),
                );
              }
              final p = i == 0 ? null : list[i - lead];
              final on = widget.selected == p?.id;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  HapticFeedback.selectionClick();
                  widget.onSelect(p?.id);
                },
                onLongPress: p == null
                    ? null
                    : () {
                        HapticFeedback.mediumImpact();
                        if (p.user) {
                          _manage(p);
                        } else {
                          ref.read(presetFavsProvider.notifier).toggle(p.id);
                        }
                      },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: SizedBox(
                    width: 58,
                    child: Column(
                      children: [
                        Stack(
                          children: [
                            Container(
                              width: 58,
                              height: 68,
                              color: c.surface,
                              child: thumb == null
                                  ? null
                                  : EditedImage(image: thumb, edit: EditState(presetId: p?.id), fit: BoxFit.cover),
                            ),
                            if (p != null && favs.contains(p.id))
                              Positioned(
                                top: 5,
                                right: 5,
                                child: Container(
                                  width: 5,
                                  height: 5,
                                  decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
                                ),
                              ),
                            if (on)
                              Positioned(left: 0, right: 0, bottom: 0, child: Container(height: 2, color: c.accent)),
                          ],
                        ),
                        const SizedBox(height: 5),
                        Text(
                          (p?.name ?? 'none').toLowerCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.label(on ? c.text : c.dim, 10.5),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// All looks in strip order, for swipe-to-change in the viewfinder.
List<Preset> orderedPresets(WidgetRef ref) => [...ref.read(userPresetsProvider), ...builtInPresets];
