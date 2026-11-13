import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/presets/preset_library.dart';
import '../image_processing/adjustments.dart';
import '../image_processing/look_engine.dart';
import 'db.dart';

/// User preferences, stored as one JSON document.
class Settings {
  const Settings([this.m = const {}]);
  final Map<String, dynamic> m;

  T _g<T>(String k, T d) => m[k] is T ? m[k] as T : d;

  ThemeMode get themeMode => ThemeMode.values[_g('theme', 2)];
  Color get accent => Color(_g('accent', 0xFFF5C518));
  int get density => _g('density', 1);
  int get grid => _g('grid', 1);
  bool get level => _g('level', false);
  bool get histogram => _g('histogram', false);
  bool get haptics => _g('haptics', true);
  bool get mirrorFront => _g('mirrorFront', true);
  bool get saveFiltered => _g('saveFiltered', true);
  bool get stabilization => _g('stabilization', true);
  String get exportFormat => _g('exportFormat', 'jpeg');
  int get jpegQuality => _g('jpegQuality', 95);
  int get maxEdge => _g('maxEdge', 8192);
  int get galleryLayout => _g('galleryLayout', 0);
  int get columns => _g('columns', 3);
  int get videoHeight => _g('videoHeight', 1080);
  int get videoFps => _g('videoFps', 30);
  int get photoMp => _g('photoMp', 0);

  /// Editor tool bar: 0 minimal text tabs, 1 chips.
  int get toolStyle => _g('toolStyle', 1);
  bool get toolIcons => _g('toolIcons', true);

  /// Quick controls shown on the viewfinder's top bar.
  List<String> get controls =>
      (m['controls'] as List?)?.cast<String>() ?? const ['flash', 'timer', 'ratio', 'grid', 'histogram'];

  double get gap => const [1.0, 2.0, 6.0][density];
  double get pad => const [12.0, 18.0, 24.0][density];
}

const allCameraControls = ['flash', 'timer', 'ratio', 'grid', 'level', 'histogram', 'peaking'];

/// State loaded before the first frame so the app opens without flicker.
class Boot {
  static Settings settings = const Settings();
  static Map<String, EditState> edits = {};
  static Set<String> favorites = {}, exports = {}, presetFavs = {};
  static List<Preset> userPresets = [];
  static List<Album> albums = [];

  static Future<void> load() async {
    await Db.open();
    settings = Settings(((await Db.kv('settings')) as Map?)?.cast<String, dynamic>() ?? const {});
    edits = {
      for (final e in (await Db.edits()).entries) e.key: EditState.fromJson((jsonDecode(e.value) as Map).cast<String, dynamic>()),
    }..removeWhere((_, v) => v.isNeutral);
    favorites = await Db.ids('favorites');
    exports = await Db.ids('exports');
    presetFavs = ((await Db.kv('presetFavs')) as List?)?.cast<String>().toSet() ?? {};
    userPresets = [
      for (final j in (await Db.kv('userPresets')) as List? ?? []) Preset.fromJson((j as Map).cast<String, dynamic>()),
    ];
    final items = await Db.collectionItems();
    albums = [
      for (final c in await Db.collections())
        Album(c['id'] as int, c['name'] as String, {
          for (final i in items)
            if (i['cid'] == c['id']) i['aid'] as String,
        }),
    ];
    for (final p in [...builtInPresets, ...userPresets]) {
      LookEngine.presets[p.id] = p;
    }
  }
}

class SettingsNotifier extends Notifier<Settings> {
  @override
  Settings build() => Boot.settings;

  void set(String key, Object? value) {
    state = Settings({...state.m, key: value});
    Db.setKv('settings', state.m);
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, Settings>(SettingsNotifier.new);

/// Current edit recipe per asset id.
class EditsNotifier extends Notifier<Map<String, EditState>> {
  @override
  Map<String, EditState> build() => Boot.edits;

  void put(String id, EditState s, {String? history}) {
    if (s.isNeutral && history == null) {
      remove(id);
      return;
    }
    // A neutral edit with history keeps its history but is not "edited".
    state = s.isNeutral ? ({...state}..remove(id)) : {...state, id: s};
    Db.saveEdit(id, jsonEncode(s.toJson()), history);
  }

  void remove(String id) {
    state = {...state}..remove(id);
    Db.deleteEdit(id);
  }
}

final editsProvider = NotifierProvider<EditsNotifier, Map<String, EditState>>(EditsNotifier.new);

class IdSetNotifier extends Notifier<Set<String>> {
  IdSetNotifier(this.table, this.initial);
  final String table;
  final Set<String> initial;

  @override
  Set<String> build() => initial;

  void toggle(String id, [bool? on]) {
    final v = on ?? !state.contains(id);
    state = v ? {...state, id} : ({...state}..remove(id));
    Db.setMember(table, id, v);
  }
}

final favoritesProvider = NotifierProvider<IdSetNotifier, Set<String>>(() => IdSetNotifier('favorites', Boot.favorites));

/// Rendered copies eski saved to the device library; hidden from the main
/// grid because the original already shows its edit live.
final exportsProvider = NotifierProvider<IdSetNotifier, Set<String>>(() => IdSetNotifier('exports', Boot.exports));

class PresetFavs extends Notifier<Set<String>> {
  @override
  Set<String> build() => Boot.presetFavs;

  void toggle(String id) {
    state = state.contains(id) ? ({...state}..remove(id)) : {...state, id};
    Db.setKv('presetFavs', state.toList());
  }
}

final presetFavsProvider = NotifierProvider<PresetFavs, Set<String>>(PresetFavs.new);

class UserPresets extends Notifier<List<Preset>> {
  @override
  List<Preset> build() => Boot.userPresets;

  Preset add(String name, EditState s) {
    final base = LookEngine.preset(s.presetId);
    // Bake the active look into the new one so it stands alone.
    final scaled = base?.adj.scaled(s.intensity) ?? const Adjustments();
    final merged = <Adj, double>{...scaled.v};
    s.adj.v.forEach((k, v) => merged[k] = k.discrete ? v : (merged[k] ?? 0) + v);
    final p = Preset(
      id: 'user/${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      collection: 'My Looks',
      adj: Adjustments(merged, [for (var i = 0; i < 24; i++) scaled.hsl[i] + s.adj.hsl[i]]),
      curves: s.curves.isIdentity ? (base?.curves ?? const CurveSet()) : s.curves,
      user: true,
    );
    LookEngine.presets[p.id] = p;
    state = [...state, p];
    _save();
    return p;
  }

  void remove(String id) {
    state = [for (final p in state) if (p.id != id) p];
    LookEngine.presets.remove(id);
    _save();
  }

  void _save() => Db.setKv('userPresets', [for (final p in state) p.toJson()]);
}

final userPresetsProvider = NotifierProvider<UserPresets, List<Preset>>(UserPresets.new);

class Album {
  const Album(this.id, this.name, this.items);
  final int id;
  final String name;
  final Set<String> items;
}

class Albums extends Notifier<List<Album>> {
  @override
  List<Album> build() => Boot.albums;

  Future<void> create(String name, [Iterable<String> ids = const []]) async {
    final id = await Db.addCollection(name);
    for (final a in ids) {
      await Db.setCollectionItem(id, a, true);
    }
    state = [...state, Album(id, name, ids.toSet())];
  }

  void addTo(int id, Iterable<String> ids) {
    state = [for (final a in state) a.id == id ? Album(a.id, a.name, {...a.items, ...ids}) : a];
    for (final a in ids) {
      Db.setCollectionItem(id, a, true);
    }
  }

  void removeFrom(int id, Iterable<String> ids) {
    state = [for (final a in state) a.id == id ? Album(a.id, a.name, a.items.difference(ids.toSet())) : a];
    for (final a in ids) {
      Db.setCollectionItem(id, a, false);
    }
  }

  void delete(int id) {
    state = [for (final a in state) if (a.id != id) a];
    Db.removeCollection(id);
  }
}

final albumsProvider = NotifierProvider<Albums, List<Album>>(Albums.new);

/// Copied adjustments, for paste onto other photographs.
class Clipboard extends Notifier<EditState?> {
  @override
  EditState? build() => null;
  void copy(EditState s) => state = s;
}

final clipboardProvider = NotifierProvider<Clipboard, EditState?>(Clipboard.new);
