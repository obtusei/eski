import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../camera/native_camera.dart';
import '../image_processing/adjustments.dart';
import '../image_processing/renderer.dart';

bool isRaw(AssetEntity a) {
  final mime = (a.mimeType ?? '').toLowerCase();
  final name = (a.title ?? '').toLowerCase();
  return mime.contains('dng') ||
      mime.contains('raw') ||
      const ['.dng', '.arw', '.cr2', '.cr3', '.nef', '.raf', '.orf', '.rw2'].any(name.endsWith);
}

bool isVideo(AssetEntity a) => a.type == AssetType.video;

/// Decoded thumbnails, cached least-recently-used so large libraries stay light.
class Thumbs {
  static final _cache = LinkedHashMap<String, ui.Image>();
  static final _pending = <String, Future<ui.Image?>>{};
  static const _cap = 320;

  static ui.Image? peek(String id, [int size = 256]) => _cache['$id@$size'];

  static Future<ui.Image?> get(AssetEntity a, [int size = 256]) {
    final key = '${a.id}@$size';
    final hit = _cache.remove(key);
    if (hit != null) {
      _cache[key] = hit;
      return Future.value(hit);
    }
    return _pending[key] ??= () async {
      try {
        final bytes = await a.thumbnailDataWithSize(ThumbnailSize(size, size), quality: size > 400 ? 92 : 85);
        if (bytes == null) return null;
        final codec = await ui.instantiateImageCodec(bytes);
        final img = (await codec.getNextFrame()).image;
        codec.dispose();
        _cache[key] = img;
        // Large previews are few; small thumbs share the general budget.
        final large = _cache.keys.where((k) => !k.endsWith('@256')).toList();
        if (large.length > 8) _cache.remove(large.first);
        if (_cache.length > _cap) _cache.remove(_cache.keys.first);
        return img;
      } catch (_) {
        return null;
      } finally {
        _pending.remove(key);
      }
    }();
  }
}

/// Second frames of double exposures, at thumbnail resolution, for previews
/// that only have a thumbnail of the base. Painters listen to [ready].
class Overlays {
  static final ready = ValueNotifier<int>(0);
  static final _missing = <String>{};
  static final _loading = <String>{};

  static int _size(ui.Image base) => math.max(base.width, base.height) <= 400 ? 256 : 1800;

  /// The cached second frame for [dx], or null while it loads.
  static ui.Image? of(DoubleExposure? dx, ui.Image base) {
    if (dx == null || _missing.contains(dx.assetId)) return null;
    final size = _size(base);
    final hit = Thumbs.peek(dx.assetId, size);
    if (hit != null) return hit;
    final key = '${dx.assetId}@$size';
    if (_loading.add(key)) {
      load(dx, base).whenComplete(() {
        _loading.remove(key);
        ready.value++;
      });
    }
    return null;
  }

  static Future<ui.Image?> load(DoubleExposure? dx, ui.Image base) async {
    if (dx == null) return null;
    final a = await AssetEntity.fromId(dx.assetId);
    if (a == null) {
      _missing.add(dx.assetId);
      return null;
    }
    return Thumbs.get(a, _size(base));
  }
}

/// Loads the second frame of a double exposure, or null if it is gone.
Future<ui.Image?> loadOverlayImage(DoubleExposure? dx, {int? maxEdge}) async {
  if (dx == null) return null;
  try {
    final a = await AssetEntity.fromId(dx.assetId);
    return a == null ? null : await loadAssetImage(a, maxEdge: maxEdge);
  } catch (_) {
    return null;
  }
}

/// Loads an asset's pixels. RAW files the Flutter decoder cannot read are
/// developed by the platform RAW pipeline first.
Future<ui.Image> loadAssetImage(AssetEntity a, {int? maxEdge}) async {
  final file = await a.originFile;
  if (file == null) throw StateError('The original file is not available on this device');
  if (!isRaw(a)) {
    try {
      return await decodeImageFile(file.path, maxEdge: maxEdge);
    } catch (_) {}
  }
  try {
    final developed = await NativeCamera.developRaw(file.path);
    if (developed != null) return await decodeImageFile(developed, maxEdge: maxEdge);
  } catch (_) {}
  return decodeImageFile(file.path, maxEdge: maxEdge);
}

class LibraryState {
  const LibraryState({this.granted, this.assets = const [], this.loading = false, this.hasMore = true, this.total = 0});

  /// null until the permission question has been answered.
  final bool? granted;
  final List<AssetEntity> assets;
  final bool loading, hasMore;
  final int total;

  LibraryState copyWith({bool? granted, List<AssetEntity>? assets, bool? loading, bool? hasMore, int? total}) =>
      LibraryState(
        granted: granted ?? this.granted,
        assets: assets ?? this.assets,
        loading: loading ?? this.loading,
        hasMore: hasMore ?? this.hasMore,
        total: total ?? this.total,
      );
}

/// The device photo library, paged so tens of thousands of items stay cheap.
class Library extends Notifier<LibraryState> {
  static const _pageSize = 80;
  AssetPathEntity? _all;
  int _page = 0;
  Timer? _debounce;
  bool _watching = false;

  @override
  LibraryState build() => const LibraryState();

  Future<void> init() async {
    if (state.granted == true || state.loading) return;
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.hasAccess) {
      state = state.copyWith(granted: false);
      return;
    }
    state = state.copyWith(granted: true);
    if (!_watching) {
      _watching = true;
      PhotoManager.addChangeCallback((_) {
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 900), refresh);
      });
      PhotoManager.startChangeNotify();
    }
    await refresh();
  }

  Future<void> refresh() async {
    if (state.granted != true) return;
    state = state.copyWith(loading: true);
    try {
      final paths = await PhotoManager.getAssetPathList(
        onlyAll: true,
        type: RequestType.common,
        filterOption: FilterOptionGroup(orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)]),
      );
      if (paths.isEmpty) {
        state = state.copyWith(assets: [], loading: false, hasMore: false, total: 0);
        return;
      }
      _all = paths.first;
      final total = await _all!.assetCountAsync;
      // Reload as many pages as were already on screen.
      final count = ((_page + 1) * _pageSize).clamp(_pageSize, 1 << 30);
      final list = await _all!.getAssetListRange(start: 0, end: count);
      state = state.copyWith(assets: list, loading: false, hasMore: list.length < total, total: total);
    } catch (_) {
      state = state.copyWith(loading: false);
    }
  }

  Future<void> loadMore() async {
    if (state.loading || !state.hasMore || _all == null) return;
    state = state.copyWith(loading: true);
    try {
      final start = state.assets.length;
      final list = await _all!.getAssetListRange(start: start, end: start + _pageSize);
      _page = (start + list.length) ~/ _pageSize;
      final seen = {for (final a in state.assets) a.id};
      final merged = [...state.assets, ...list.where((a) => !seen.contains(a.id))];
      state = state.copyWith(assets: merged, loading: false, hasMore: list.isNotEmpty && merged.length < state.total);
    } catch (_) {
      state = state.copyWith(loading: false);
    }
  }

  void prepend(AssetEntity a) {
    if (state.assets.any((e) => e.id == a.id)) return;
    state = state.copyWith(assets: [a, ...state.assets], total: state.total + 1);
  }

  /// Deletes originals from the device. Callers must confirm with the user.
  Future<List<String>> delete(List<AssetEntity> items) async {
    final gone = await PhotoManager.editor.deleteWithIds([for (final a in items) a.id]);
    final set = gone.toSet();
    state = state.copyWith(
      assets: [for (final a in state.assets) if (!set.contains(a.id)) a],
      total: state.total - set.length,
    );
    return gone;
  }
}

final libraryProvider = NotifierProvider<Library, LibraryState>(Library.new);

/// Device albums, for browsing by folder.
final deviceAlbumsProvider = FutureProvider<List<AssetPathEntity>>((ref) async {
  if (ref.watch(libraryProvider.select((s) => s.granted)) != true) return [];
  return PhotoManager.getAssetPathList(type: RequestType.common, hasAll: false);
});
