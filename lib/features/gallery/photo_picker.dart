import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/theme.dart';
import '../../core/media/media_library.dart';
import '../../core/storage/app_state.dart';
import '../../shared/widgets/common.dart';
import 'asset_thumb.dart';

/// Sheet for choosing a photograph from the library.
class PhotoPicker extends ConsumerStatefulWidget {
  const PhotoPicker({super.key, this.title = 'choose a photograph', this.exclude});
  final String title;

  /// An asset id left out of the grid, such as the photograph being edited.
  final String? exclude;

  @override
  ConsumerState<PhotoPicker> createState() => _PhotoPickerState();
}

class _PhotoPickerState extends ConsumerState<PhotoPicker> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(libraryProvider.notifier).init());
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 600) ref.read(libraryProvider.notifier).loadMore();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(libraryProvider);
    final exports = ref.watch(exportsProvider);
    final photos = [for (final a in lib.assets) if (!isVideo(a) && !exports.contains(a.id) && a.id != widget.exclude) a];
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: Column(
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(22, 18, 22, 12), child: Row(children: [Text(widget.title, style: context.display(26))])),
          Expanded(
            child: photos.isEmpty && !lib.hasMore
                ? Center(
                    child: Text(
                      lib.granted == false ? 'eski has no access to your library' : 'no photographs yet',
                      style: context.body(context.c.dim),
                    ),
                  )
                : GridView.builder(
                    controller: _scroll,
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, mainAxisSpacing: 2, crossAxisSpacing: 2),
                    itemCount: photos.length + (lib.hasMore ? 1 : 0),
                    itemBuilder: (context, i) => i == photos.length
                        ? LoadMore(active: true, onLoad: ref.read(libraryProvider.notifier).loadMore)
                        : GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        Navigator.pop(context, photos[i]);
                      },
                      child: AssetThumb(photos[i], key: ValueKey(photos[i].id)),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
