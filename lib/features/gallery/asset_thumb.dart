import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../app/theme/theme.dart';
import '../../core/media/media_library.dart';
import '../../core/storage/app_state.dart';
import '../../shared/widgets/common.dart';

/// An asset thumbnail that renders the asset's edit live, so the library
/// always shows photographs as they currently look.
class AssetThumb extends ConsumerStatefulWidget {
  const AssetThumb(this.asset, {super.key, this.size = 256, this.fit = BoxFit.cover, this.applyEdit = true});
  final AssetEntity asset;
  final int size;
  final BoxFit fit;
  final bool applyEdit;

  @override
  ConsumerState<AssetThumb> createState() => _AssetThumbState();
}

class _AssetThumbState extends ConsumerState<AssetThumb> {
  ui.Image? _img;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AssetThumb old) {
    super.didUpdateWidget(old);
    if (old.asset.id != widget.asset.id || old.size != widget.size) _load();
  }

  void _load() {
    _img = Thumbs.peek(widget.asset.id, widget.size);
    if (_img != null) return;
    final id = widget.asset.id;
    Thumbs.get(widget.asset, widget.size).then((img) {
      if (mounted && widget.asset.id == id && img != null) setState(() => _img = img);
    });
  }

  @override
  Widget build(BuildContext context) {
    final img = _img;
    if (img == null) return ColoredBox(color: context.c.surface);
    final edit = widget.applyEdit ? ref.watch(editsProvider.select((m) => m[widget.asset.id])) : null;
    if (edit == null) return RawImage(image: img, fit: widget.fit);
    return EditedImage(image: img, edit: edit, fit: widget.fit);
  }
}
