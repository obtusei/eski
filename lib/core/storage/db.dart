import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Local metadata store. Photographs themselves stay in the device library;
/// this only holds edit recipes, favourites, collections and preferences.
class Db {
  static late Database _db;
  static late Directory supportDir;
  static late Directory tempDir;

  static Future<void> open() async {
    supportDir = await getApplicationSupportDirectory();
    tempDir = await getTemporaryDirectory();
    _db = await openDatabase(
      p.join(supportDir.path, 'eski.db'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('CREATE TABLE kv(k TEXT PRIMARY KEY, v TEXT)');
        await db.execute('CREATE TABLE edits(id TEXT PRIMARY KEY, state TEXT, history TEXT, updated INTEGER)');
        await db.execute('CREATE TABLE favorites(id TEXT PRIMARY KEY)');
        await db.execute('CREATE TABLE exports(id TEXT PRIMARY KEY, source TEXT)');
        await db.execute('CREATE TABLE collections(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)');
        await db.execute('CREATE TABLE collection_items(cid INTEGER, aid TEXT, PRIMARY KEY(cid, aid))');
      },
    );
    // Remove partial files left by an interrupted export or capture.
    try {
      await for (final f in tempDir.list()) {
        if (f is File && f.path.endsWith('.part')) await f.delete();
      }
    } catch (_) {}
  }

  static Future<dynamic> kv(String k) async {
    final r = await _db.query('kv', where: 'k = ?', whereArgs: [k]);
    return r.isEmpty ? null : jsonDecode(r.first['v'] as String);
  }

  static Future<void> setKv(String k, Object? v) =>
      _db.insert('kv', {'k': k, 'v': jsonEncode(v)}, conflictAlgorithm: ConflictAlgorithm.replace);

  static Future<Map<String, String>> edits() async =>
      {for (final r in await _db.query('edits', columns: ['id', 'state'])) r['id'] as String: r['state'] as String};

  static Future<String?> history(String id) async {
    final r = await _db.query('edits', columns: ['history'], where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : r.first['history'] as String?;
  }

  static Future<void> saveEdit(String id, String state, String? history) => _db.insert(
        'edits',
        {'id': id, 'state': state, 'history': history, 'updated': DateTime.now().millisecondsSinceEpoch},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  static Future<void> deleteEdit(String id) => _db.delete('edits', where: 'id = ?', whereArgs: [id]);

  static Future<Set<String>> ids(String table) async =>
      {for (final r in await _db.query(table, columns: ['id'])) r['id'] as String};

  static Future<void> setMember(String table, String id, bool on, {String? source}) => on
      ? _db.insert(table, {'id': id, 'source': ?source}, conflictAlgorithm: ConflictAlgorithm.replace)
      : _db.delete(table, where: 'id = ?', whereArgs: [id]);

  static Future<List<Map<String, Object?>>> collections() => _db.query('collections', orderBy: 'id');
  static Future<List<Map<String, Object?>>> collectionItems() => _db.query('collection_items');
  static Future<int> addCollection(String name) => _db.insert('collections', {'name': name});
  static Future<void> removeCollection(int id) async {
    await _db.delete('collections', where: 'id = ?', whereArgs: [id]);
    await _db.delete('collection_items', where: 'cid = ?', whereArgs: [id]);
  }

  static Future<void> setCollectionItem(int cid, String aid, bool on) => on
      ? _db.insert('collection_items', {'cid': cid, 'aid': aid}, conflictAlgorithm: ConflictAlgorithm.ignore)
      : _db.delete('collection_items', where: 'cid = ? AND aid = ?', whereArgs: [cid, aid]);

  static Future<int> dirSize(Directory d) async {
    var total = 0;
    try {
      await for (final f in d.list(recursive: true, followLinks: false)) {
        if (f is File) total += await f.length();
      }
    } catch (_) {}
    return total;
  }

  static Future<void> clearTemp() async {
    try {
      await for (final f in tempDir.list()) {
        await f.delete(recursive: true);
      }
    } catch (_) {}
  }
}
