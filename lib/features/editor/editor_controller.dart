import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../core/image_processing/adjustments.dart';
import '../../core/media/media_library.dart';
import '../../core/storage/app_state.dart';
import '../../core/storage/db.dart';

const _u = Object();

class EditorState {
  const EditorState({
    this.asset,
    this.image,
    this.thumb,
    this.overlay,
    this.overlayId,
    this.edit = const EditState(),
    this.history = const [EditState()],
    this.index = 0,
    this.error,
  });

  final AssetEntity? asset;

  /// Working preview; exports re-render from the full-resolution original.
  final ui.Image? image;
  final ui.Image? thumb;

  /// Second frame of a double exposure at working resolution, and its asset.
  final ui.Image? overlay;
  final String? overlayId;
  final EditState edit;
  final List<EditState> history;
  final int index;
  final String? error;

  bool get canUndo => index > 0;
  bool get canRedo => index < history.length - 1;

  EditorState copyWith({
    ui.Image? image,
    ui.Image? thumb,
    Object? overlay = _u,
    Object? overlayId = _u,
    EditState? edit,
    List<EditState>? history,
    int? index,
    String? error,
  }) =>
      EditorState(
        asset: asset,
        image: image ?? this.image,
        thumb: thumb ?? this.thumb,
        overlay: overlay == _u ? this.overlay : overlay as ui.Image?,
        overlayId: overlayId == _u ? this.overlayId : overlayId as String?,
        edit: edit ?? this.edit,
        history: history ?? this.history,
        index: index ?? this.index,
        error: error ?? this.error,
      );
}

/// Holds one photograph's edit session. Every committed change is a step in
/// a persisted history, so edits can be revisited at any time.
class EditorController extends Notifier<EditorState> {
  static const _maxHistory = 40;

  @override
  EditorState build() {
    ref.onDispose(() {
      state.image?.dispose();
      state.overlay?.dispose();
    });
    return const EditorState();
  }

  Future<void> load(AssetEntity a) async {
    final saved = ref.read(editsProvider)[a.id] ?? const EditState();
    var history = [saved];
    var index = 0;
    try {
      final raw = await Db.history(a.id);
      if (raw != null) {
        final j = jsonDecode(raw) as Map;
        final list = [for (final e in j['h'] as List) EditState.fromJson((e as Map).cast<String, dynamic>())];
        if (list.isNotEmpty) {
          history = list;
          index = (j['i'] as int).clamp(0, list.length - 1);
        }
      }
    } catch (_) {}
    state = EditorState(asset: a, edit: saved, history: history, index: index, thumb: Thumbs.peek(a.id));
    _syncOverlay();
    try {
      final thumb = await Thumbs.get(a);
      if (thumb != null) state = state.copyWith(thumb: thumb);
      final img = await loadAssetImage(a, maxEdge: 2400);
      if (!ref.mounted) {
        img.dispose();
        return;
      }
      state = state.copyWith(image: img);
    } catch (e) {
      state = state.copyWith(error: 'This photograph could not be opened');
    }
  }

  /// Live update while a control is being dragged; not yet a history step.
  void update(EditState e) {
    state = state.copyWith(edit: e);
    _syncOverlay();
  }

  /// Keeps the loaded second frame in step with the recipe, including
  /// through undo and redo.
  Future<void> _syncOverlay() async {
    final id = state.edit.dx?.assetId;
    if (id == state.overlayId) return;
    final old = state.overlay;
    state = state.copyWith(overlay: null, overlayId: id);
    // Released once the canvas has repainted without it.
    if (old != null) SchedulerBinding.instance.addPostFrameCallback((_) => old.dispose());
    if (id == null) return;
    final img = await loadOverlayImage(state.edit.dx, maxEdge: 2400);
    if (!ref.mounted || state.overlayId != id) {
      img?.dispose();
      return;
    }
    if (img != null) state = state.copyWith(overlay: img);
  }

  /// Records the current edit as a history step and saves it.
  void commit() {
    final e = state.edit;
    if (jsonEncode(e.toJson()) == jsonEncode(state.history[state.index].toJson())) return;
    var h = [...state.history.sublist(0, state.index + 1), e];
    if (h.length > _maxHistory) h = h.sublist(h.length - _maxHistory);
    state = state.copyWith(history: h, index: h.length - 1);
    _persist();
  }

  void apply(EditState e) {
    update(e);
    commit();
  }

  void undo() => _jump(state.index - 1);
  void redo() => _jump(state.index + 1);

  void _jump(int i) {
    if (i < 0 || i >= state.history.length) return;
    state = state.copyWith(edit: state.history[i], index: i);
    _syncOverlay();
    _persist();
  }

  /// Removes every edit and its history; the original is untouched either way.
  void revert() {
    state = state.copyWith(edit: const EditState(), history: const [EditState()], index: 0);
    _syncOverlay();
    final id = state.asset?.id;
    if (id != null) ref.read(editsProvider.notifier).remove(id);
  }

  void _persist() {
    final id = state.asset?.id;
    if (id == null) return;
    ref.read(editsProvider.notifier).put(
          id,
          state.edit,
          history: jsonEncode({'h': [for (final e in state.history) e.toJson()], 'i': state.index}),
        );
  }
}

final editorProvider = NotifierProvider.autoDispose<EditorController, EditorState>(EditorController.new);
