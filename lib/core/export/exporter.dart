import 'dart:io';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';

import '../camera/native_camera.dart';
import '../image_processing/adjustments.dart';
import '../image_processing/renderer.dart';
import '../media/media_library.dart';
import '../storage/app_state.dart';
import '../storage/db.dart';

/// Full-resolution rendering and saving. Files are written to a `.part` path
/// and renamed when complete, so an interrupted export never leaves a broken
/// image behind.
class Exporter {
  static String stamp() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${two(n.month)}${two(n.day)}_${two(n.hour)}${two(n.minute)}${two(n.second)}_${n.millisecond}';
  }

  /// Encodes [image] to a file in the temp directory and returns it.
  static Future<File> encode(ui.Image image, Settings s, {String? name}) async {
    final png = s.exportFormat == 'png';
    final path = p.join(Db.tempDir.path, '${name ?? 'eski_${stamp()}'}.${png ? 'png' : 'jpg'}');
    final part = '$path.part';
    if (png) {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(part).writeAsBytes(data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
    } else {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      await NativeCamera.encodeJpeg(
        data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        image.width,
        image.height,
        s.jpegQuality,
        part,
      );
    }
    return File(part).rename(path);
  }

  /// Renders an asset with its edit at full quality.
  static Future<File> render(AssetEntity a, EditState edit, Settings s) async {
    final src = await loadAssetImage(a, maxEdge: s.maxEdge);
    final over = await loadOverlayImage(edit.dx, maxEdge: s.maxEdge);
    try {
      final out = await renderEdit(src, edit, maxEdge: s.maxEdge, overlay: over);
      try {
        return await encode(out, s);
      } finally {
        out.dispose();
      }
    } finally {
      src.dispose();
      over?.dispose();
    }
  }

  /// Saves a rendered file to the device library as a new item; the original
  /// is never touched.
  static Future<AssetEntity> saveImage(File f) => PhotoManager.editor.saveImageWithPath(
        f.path,
        title: p.basename(f.path),
        relativePath: Platform.isAndroid ? 'Pictures/eski' : null,
      );

  /// Detects the person in an image file and keeps the matte in app storage.
  static Future<String?> detectSubject(String path) async {
    final dir = Directory(p.join(Db.supportDir.path, 'mattes'));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return NativeCamera.segmentSubject(path, p.join(dir.path, 'matte_${stamp()}.png'));
  }

  static Future<void> shareFiles(List<File> files) =>
      SharePlus.instance.share(ShareParams(files: [for (final f in files) XFile(f.path)]));

  /// Shares assets, rendering those that have edits.
  static Future<void> shareAssets(List<AssetEntity> items, Map<String, EditState> edits, Settings s) async {
    final files = <File>[];
    for (final a in items) {
      final e = edits[a.id];
      if (e != null && !e.isNeutral && !isVideo(a)) {
        files.add(await render(a, e, s));
      } else {
        final f = await a.originFile;
        if (f != null) files.add(f);
      }
    }
    if (files.isNotEmpty) await shareFiles(files);
  }
}
