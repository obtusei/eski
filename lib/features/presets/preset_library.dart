import 'dart:ui';

import '../../core/image_processing/adjustments.dart';
import '../../core/image_processing/look_engine.dart';

// Original film-inspired looks. Each is a plain recipe for the look engine;
// to add one, append a `_p(...)` line to its collection below.

const _ex = Adj.exposure, _br = Adj.brightness, _ct = Adj.contrast, _hl = Adj.highlights, _sd = Adj.shadows;
const _wh = Adj.whites, _bk = Adj.blacks, _sa = Adj.saturation, _vi = Adj.vibrance, _tp = Adj.temperature;
const _tn = Adj.tint, _cl = Adj.clarity, _tx = Adj.texture, _dz = Adj.dehaze, _fd = Adj.fade, _gr = Adj.grain;
const _gs = Adj.grainSize, _vg = Adj.vignette, _bm = Adj.bloom, _gl = Adj.glow, _ha = Adj.halation;
const _sh = Adj.sharpness, _ca = Adj.chroma, _lk = Adj.leak, _ls = Adj.leakSeed, _ds = Adj.dust;
const _sH = Adj.shHue, _sS = Adj.shSat, _mH = Adj.midHue, _mS = Adj.midSat, _hH = Adj.hiHue, _hS = Adj.hiSat;
const _bal = Adj.balance;

// HSL band indices.
const _red = 0, _orange = 1, _yellow = 2, _green = 3, _aqua = 4, _blue = 5, _purple = 6, _magenta = 7;

List<Offset> _c(List<double> f) => [for (var i = 0; i + 1 < f.length; i += 2) Offset(f[i], f[i + 1])];

// Reusable tone curves.
const _soft = [0.0, 0.04, 0.25, 0.24, 0.75, 0.77, 1.0, 0.97];
const _film = [0.0, 0.03, 0.2, 0.17, 0.5, 0.5, 0.8, 0.84, 1.0, 0.98];
const _punch = [0.0, 0.0, 0.22, 0.15, 0.5, 0.5, 0.78, 0.87, 1.0, 1.0];
const _matte = [0.0, 0.1, 0.25, 0.26, 0.75, 0.76, 1.0, 0.94];
const _deep = [0.0, 0.0, 0.3, 0.2, 0.7, 0.74, 1.0, 0.98];
const _airy = [0.0, 0.07, 0.3, 0.36, 0.7, 0.78, 1.0, 1.0];

var _collection = '';

Preset _p(
  String name,
  Map<Adj, double> a, {
  List<double>? m,
  List<double>? r,
  List<double>? g,
  List<double>? b,
  Map<int, List<double>> hsl = const {},
}) {
  final h = List<double>.filled(24, 0);
  hsl.forEach((band, v) {
    h[band] = v[0];
    h[8 + band] = v[1];
    h[16 + band] = v[2];
  });
  return Preset(
    id: '${_collection.toLowerCase()}/${name.toLowerCase()}'.replaceAll(RegExp(r'[^a-z0-9/]+'), '-'),
    name: name,
    collection: _collection,
    adj: Adjustments(a, h),
    curves: CurveSet(
      master: m == null ? identityCurve : _c(m),
      r: r == null ? identityCurve : _c(r),
      g: g == null ? identityCurve : _c(g),
      b: b == null ? identityCurve : _c(b),
    ),
  );
}

List<Preset> _col(String name, List<Preset> Function() build) {
  _collection = name;
  return build();
}

final List<Preset> builtInPresets = [
  ..._col('Kodak Gold', () => [
        _p('Gold 200', {_tp: .2, _sa: .08, _ct: .1, _hH: .11, _hS: .35, _sH: .07, _sS: .15, _gr: .2, _gs: .3},
            m: _film, hsl: {_yellow: [0, .15, .05], _green: [-.15, -.1, 0], _blue: [.08, -.12, 0]}),
        _p('Gold 400', {_tp: .26, _sa: .1, _ct: .16, _hH: .1, _hS: .4, _fd: .1, _gr: .32, _gs: .45, _vg: .12},
            m: _film, hsl: {_orange: [0, .12, 0], _green: [-.18, -.12, -.05]}),
        _p('Golden Hour', {_tp: .34, _ex: .06, _hl: -.2, _sa: .12, _hH: .09, _hS: .5, _bm: .22, _ha: .2, _gr: .18},
            m: _soft, r: [0, 0, .5, .54, 1, 1], b: [0, .03, .5, .46, 1, .94]),
      ]),
  ..._col('Kodak Portra', () => [
        _p('Portra 160', {_ct: -.08, _sa: -.08, _tp: .08, _sd: .15, _hl: -.15, _hH: .1, _hS: .15, _gr: .12, _gs: .2},
            m: _soft, hsl: {_orange: [.03, -.05, .08], _green: [-.1, -.2, 0], _red: [.04, -.08, 0]}),
        _p('Portra 400', {_ct: -.02, _sa: -.04, _tp: .12, _sd: .2, _hl: -.2, _hH: .1, _hS: .22, _sH: .5, _sS: .08, _gr: .2, _gs: .3},
            m: _soft, hsl: {_orange: [.03, -.04, .1], _green: [-.14, -.22, .04], _blue: [-.06, -.15, .05]}),
        _p('Portra 800', {_ct: .06, _tp: .16, _sd: .14, _hH: .09, _hS: .28, _sH: .45, _sS: .12, _gr: .34, _gs: .5, _ha: .12},
            m: _film, hsl: {_orange: [.03, 0, .08], _green: [-.14, -.2, 0]}),
      ]),
  ..._col('Kodak Ektar', () => [
        _p('Ektar 100', {_ct: .22, _sa: .22, _vi: .15, _cl: .12, _gr: .08, _gs: .15, _sh: .2},
            m: _punch, hsl: {_red: [0, .15, 0], _blue: [-.05, .2, -.08], _green: [.05, .12, 0]}),
        _p('Ektar Vivid', {_ct: .3, _sa: .3, _vi: .2, _dz: .15, _bk: -.12, _gr: .1, _sh: .25},
            m: _punch, hsl: {_aqua: [0, .2, 0], _blue: [-.04, .25, -.1], _orange: [0, .1, 0]}),
        _p('Ektar Dusk', {_ct: .2, _sa: .18, _tp: -.08, _tn: .1, _sH: .66, _sS: .25, _hH: .08, _hS: .2, _gr: .12},
            m: _deep),
      ]),
  ..._col('Classic Chrome', () => [
        _p('Chrome', {_sa: -.22, _ct: .18, _sd: -.1, _hl: -.12, _sH: .55, _sS: .1, _gr: .1},
            m: _deep, hsl: {_blue: [.06, -.25, -.1], _red: [0, -.1, -.05], _green: [-.08, -.25, -.05]}),
        _p('Chrome Soft', {_sa: -.28, _ct: .06, _fd: .12, _sd: .1, _tp: .05, _gr: .14},
            m: _soft, hsl: {_blue: [.06, -.2, 0], _green: [-.08, -.2, 0]}),
        _p('Chrome Street', {_sa: -.3, _ct: .28, _cl: .2, _bk: -.15, _sH: .58, _sS: .14, _gr: .2, _gs: .3, _vg: .15},
            m: _deep, hsl: {_orange: [0, -.1, 0], _blue: [.05, -.3, -.12]}),
      ]),
  ..._col('Pro 400H', () => [
        _p('400H', {_ex: .1, _ct: -.1, _sa: -.06, _tp: -.05, _tn: -.12, _sd: .22, _sH: .45, _sS: .18, _gr: .14},
            m: _airy, hsl: {_green: [.12, -.1, .1], _aqua: [0, .1, .05], _orange: [.02, -.06, .08]}),
        _p('400H Overexposed', {_ex: .24, _ct: -.16, _sa: -.1, _tn: -.1, _hl: -.3, _sd: .3, _sH: .45, _sS: .2, _fd: .1, _gr: .12},
            m: _airy, hsl: {_green: [.14, -.12, .14]}),
        _p('Mint', {_ex: .08, _ct: -.06, _tp: -.1, _tn: -.18, _sH: .42, _sS: .25, _hH: .13, _hS: .1, _gr: .12},
            m: _soft, hsl: {_green: [.15, 0, .08], _blue: [-.08, -.1, .05]}),
      ]),
  ..._col('Superia', () => [
        _p('Superia 200', {_ct: .14, _sa: .1, _tn: -.1, _sH: .38, _sS: .18, _gr: .2, _gs: .3},
            m: _film, hsl: {_green: [.05, .18, -.05], _red: [-.03, .1, 0], _blue: [.04, .05, -.06]}),
        _p('Superia 400', {_ct: .18, _sa: .12, _tn: -.14, _tp: -.04, _sH: .4, _sS: .22, _gr: .3, _gs: .45, _vg: .1},
            m: _film, hsl: {_green: [.06, .2, -.08], _red: [-.03, .14, 0]}),
        _p('Superia 1600', {_ct: .24, _sa: .06, _tn: -.12, _sH: .42, _sS: .26, _fd: .12, _gr: .5, _gs: .65, _vg: .2, _ha: .1},
            m: _film, hsl: {_green: [.06, .15, -.1]}),
      ]),
  ..._col('Cine Tungsten', () => [
        _p('800T', {_tp: -.3, _ct: .14, _sa: .05, _ha: .6, _bm: .15, _sH: .55, _sS: .25, _hH: .05, _hS: .12, _gr: .3, _gs: .45},
            m: _film, hsl: {_red: [.03, .2, 0], _orange: [0, .12, 0], _aqua: [0, .15, 0]}),
        _p('50D', {_tp: .06, _ct: .12, _sa: .08, _ha: .3, _hH: .1, _hS: .18, _sH: .52, _sS: .12, _gr: .1},
            m: _soft, hsl: {_blue: [-.05, .1, 0]}),
        _p('Neon Rain', {_tp: -.36, _tn: .12, _ct: .22, _ha: .8, _bm: .3, _gl: .12, _sH: .6, _sS: .35, _gr: .36, _gs: .5, _vg: .2},
            m: _deep, hsl: {_red: [.04, .3, 0], _magenta: [0, .25, 0], _aqua: [0, .25, 0]}),
      ]),
  ..._col('Vintage Film', () => [
        _p('1974', {_tp: .24, _fd: .3, _sa: -.15, _ct: -.05, _hH: .12, _hS: .4, _sH: .08, _sS: .2, _gr: .36, _gs: .55, _vg: .25, _ds: .25},
            m: _matte, b: [0, .08, 1, .88]),
        _p('Expired', {_tn: .2, _fd: .25, _sa: -.1, _sH: .85, _sS: .28, _hH: .16, _hS: .3, _gr: .42, _gs: .6, _lk: .3, _ls: .2, _ds: .3},
            m: _matte, g: [0, .03, .5, .47, 1, .96]),
        _p('Shoebox', {_tp: .16, _fd: .2, _ct: .08, _sa: -.2, _hH: .1, _hS: .3, _gr: .3, _gs: .5, _vg: .3, _ds: .45, _ca: .25},
            m: _matte, r: [0, .04, 1, 1]),
      ]),
  ..._col('Analog', () => [
        _p('Analog 01', {_ct: .1, _fd: .12, _sa: -.05, _tp: .06, _gr: .24, _gs: .35, _vg: .1}, m: _film),
        _p('Analog 02', {_ct: .14, _fd: .08, _tn: -.08, _sH: .5, _sS: .15, _hH: .1, _hS: .2, _gr: .28, _gs: .4, _ha: .15}, m: _film),
        _p('Half Frame', {_ct: .18, _fd: .15, _sa: .05, _tp: .1, _gr: .4, _gs: .7, _vg: .28, _ca: .2, _lk: .18, _ls: .55}, m: _film),
      ]),
  ..._col('Warm & Creamy', () => [
        _p('Butter', {_tp: .2, _ex: .08, _ct: -.14, _hl: -.2, _sd: .2, _sa: -.08, _hH: .12, _hS: .3, _gl: .15, _gr: .08},
            m: _airy, hsl: {_orange: [.02, -.05, .08], _yellow: [-.05, -.1, .05]}),
        _p('Oat', {_tp: .14, _ct: -.1, _sa: -.2, _fd: .14, _hH: .1, _hS: .22, _sH: .09, _sS: .12, _gr: .1},
            m: _soft, hsl: {_green: [-.12, -.3, 0]}),
        _p('Honey', {_tp: .28, _ct: .04, _sa: .04, _hl: -.15, _hH: .1, _hS: .4, _sH: .06, _sS: .15, _bm: .15, _gr: .12}, m: _soft),
      ]),
  ..._col('Cool & Moody', () => [
        _p('Fjord', {_tp: -.2, _ct: .16, _sa: -.2, _ex: -.08, _sd: -.1, _sH: .58, _sS: .3, _hH: .5, _hS: .1, _vg: .22, _gr: .14},
            m: _deep, hsl: {_green: [.1, -.3, -.1], _orange: [0, -.1, 0]}),
        _p('Slate', {_tp: -.12, _ct: .22, _sa: -.35, _bk: -.1, _cl: .15, _sH: .6, _sS: .2, _vg: .2, _gr: .16}, m: _deep),
        _p('Evergreen', {_tp: -.08, _tn: -.1, _ct: .18, _sa: -.12, _ex: -.1, _sH: .45, _sS: .28, _vg: .25, _gr: .16},
            m: _deep, hsl: {_green: [.08, -.1, -.2], _yellow: [-.1, -.25, -.1]}),
      ]),
  ..._col('Dreamy', () => [
        _p('Haze', {_gl: .45, _bm: .3, _ct: -.18, _ex: .1, _fd: .15, _sa: -.05, _hH: .92, _hS: .12, _gr: .1}, m: _airy),
        _p('Reverie', {_gl: .35, _bm: .25, _ct: -.1, _tp: .1, _tn: .08, _hH: .08, _hS: .25, _sH: .75, _sS: .18, _ha: .2, _gr: .14}, m: _airy),
        _p('Lucid', {_gl: .3, _bm: .4, _ct: -.05, _tp: -.1, _sH: .62, _sS: .22, _hH: .9, _hS: .18, _ca: .2, _gr: .12}, m: _soft),
      ]),
  ..._col('Soft Pastel', () => [
        _p('Sorbet', {_ex: .14, _ct: -.22, _sa: -.12, _vi: .2, _fd: .18, _hH: .95, _hS: .14, _sH: .5, _sS: .12}, m: _airy),
        _p('Lilac', {_ex: .1, _ct: -.18, _sa: -.15, _tn: .12, _fd: .15, _sH: .75, _sS: .2, _hH: .1, _hS: .1},
            m: _airy, hsl: {_blue: [.1, -.1, .1]}),
        _p('Seafoam', {_ex: .1, _ct: -.2, _sa: -.14, _tn: -.12, _tp: -.05, _fd: .16, _sH: .45, _sS: .2},
            m: _airy, hsl: {_green: [.15, -.1, .12]}),
      ]),
  ..._col('Minimal', () => [
        _p('Clean', {_ct: .08, _sa: -.06, _hl: -.1, _sd: .1, _sh: .15}),
        _p('Paper', {_ex: .08, _ct: -.06, _sa: -.25, _hl: -.15, _tp: .04, _fd: .06}, m: _soft),
        _p('Quiet', {_ct: -.04, _sa: -.4, _sd: .12, _fd: .1, _sH: .58, _sS: .06}, m: _soft),
      ]),
  ..._col('Cinematic', () => [
        _p('Teal & Amber', {_ct: .2, _sa: .04, _sH: .52, _sS: .45, _hH: .08, _hS: .4, _bal: .1, _vg: .2, _gr: .14, _ha: .15},
            m: _deep, hsl: {_orange: [0, .12, 0], _green: [.2, -.25, -.1]}),
        _p('Bleach Bypass', {_ct: .36, _sa: -.5, _cl: .25, _bk: -.1, _sH: .58, _sS: .1, _gr: .24, _gs: .4, _vg: .2}, m: _punch),
        _p('Noir Color', {_ct: .26, _sa: -.25, _ex: -.12, _sd: -.15, _sH: .62, _sS: .3, _hH: .1, _hS: .18, _vg: .35, _gr: .2}, m: _deep),
      ]),
  ..._col('Black & White', () => [
        _p('Tri-Tone', {_sa: -1, _ct: .2, _cl: .12, _gr: .32, _gs: .45}, m: _film),
        _p('Silver', {_sa: -1, _ct: .06, _sd: .15, _hl: -.1, _gr: .16, _gs: .25, _sH: .6, _sS: .06}, m: _soft),
        _p('Ortho', {_sa: -1, _ct: .3, _tp: -.4, _bk: -.12, _cl: .2, _gr: .4, _gs: .55, _vg: .2}, m: _punch),
        _p('Sepia Print', {_sa: -1, _ct: .1, _fd: .15, _sH: .08, _sS: .45, _hH: .11, _hS: .35, _gr: .3, _gs: .5, _vg: .2}, m: _matte),
      ]),
  ..._col('High Contrast', () => [
        _p('Punch', {_ct: .4, _sa: .14, _cl: .2, _bk: -.15, _wh: .12, _sh: .2}, m: _punch),
        _p('Ink', {_sa: -1, _ct: .5, _bk: -.25, _wh: .15, _cl: .3, _gr: .3, _gs: .4}, m: _punch),
        _p('Solar', {_ct: .34, _sa: .2, _vi: .2, _dz: .25, _tp: .08, _sh: .2}, m: _punch),
      ]),
  ..._col('Faded', () => [
        _p('Faded 01', {_fd: .4, _ct: -.1, _sa: -.15, _gr: .16}, m: _matte),
        _p('Sunbleached', {_fd: .35, _ex: .1, _tp: .15, _sa: -.25, _hH: .12, _hS: .25, _gr: .2, _ds: .12}, m: _matte),
        _p('Dusty Blue', {_fd: .38, _tp: -.12, _sa: -.2, _sH: .6, _sS: .25, _gr: .18}, m: _matte),
      ]),
  ..._col('Night', () => [
        _p('Afterhours', {_sd: .3, _hl: -.3, _ct: .12, _tp: -.14, _ha: .5, _bm: .2, _sH: .62, _sS: .25, _gr: .3, _gs: .45},
            m: _film, hsl: {_orange: [0, .15, 0], _red: [.03, .2, 0]}),
        _p('Sodium', {_sd: .22, _hl: -.2, _tp: .2, _tn: -.08, _ct: .16, _ha: .3, _hH: .1, _hS: .3, _sH: .45, _sS: .2, _gr: .28}, m: _film),
        _p('Moonlit', {_sd: .25, _ct: .1, _tp: -.3, _sa: -.3, _sH: .62, _sS: .35, _hH: .58, _hS: .12, _gr: .26, _vg: .2}, m: _deep),
      ]),
  ..._col('Street', () => [
        _p('Pavement', {_ct: .26, _sa: -.15, _cl: .28, _tx: .15, _bk: -.1, _gr: .26, _gs: .4, _vg: .16}, m: _deep),
        _p('Kiosk', {_ct: .18, _sa: .06, _tp: .08, _cl: .15, _hH: .1, _hS: .15, _sH: .55, _sS: .15, _gr: .22, _gs: .35},
            m: _film, hsl: {_red: [0, .15, 0]}),
        _p('Tram', {_sa: -1, _ct: .34, _cl: .3, _tx: .2, _gr: .38, _gs: .5, _vg: .22}, m: _punch),
      ]),
  ..._col('Portrait', () => [
        _p('Skin', {_ct: -.06, _sd: .16, _hl: -.18, _tp: .06, _cl: -.12, _hH: .08, _hS: .12, _gr: .06},
            m: _soft, hsl: {_orange: [.02, -.06, .1], _red: [.03, -.08, .04]}),
        _p('Studio', {_ct: .12, _sa: -.08, _cl: -.06, _sh: .15, _vg: .18, _sH: .6, _sS: .06},
            m: _film, hsl: {_orange: [.01, -.04, .06]}),
        _p('Window Light', {_ex: .08, _ct: -.1, _sd: .22, _tp: .1, _gl: .18, _cl: -.15, _hH: .1, _hS: .2, _gr: .1},
            m: _airy, hsl: {_orange: [.02, -.05, .1]}),
      ]),
  ..._col('Landscape', () => [
        _p('Ridge', {_ct: .18, _vi: .25, _dz: .25, _cl: .2, _hl: -.2, _sd: .15, _sh: .2},
            m: _film, hsl: {_blue: [-.04, .15, -.12], _green: [.04, .1, -.04]}),
        _p('Meadow', {_ct: .1, _vi: .2, _tp: .08, _sd: .15, _sh: .15},
            m: _soft, hsl: {_green: [-.06, .15, .05], _yellow: [-.05, .1, .05], _blue: [0, .1, -.05]}),
        _p('Coast', {_ct: .14, _vi: .15, _tp: -.08, _dz: .15, _cl: .12, _sH: .55, _sS: .12, _sh: .15},
            m: _film, hsl: {_aqua: [0, .2, 0], _blue: [-.05, .15, -.08]}),
      ]),
  ..._col('Aesthetic', () => [
        _p('Feed', {_ex: .06, _ct: .08, _sa: -.1, _tp: .1, _fd: .1, _hH: .1, _hS: .18, _gr: .1},
            m: _soft, hsl: {_orange: [.02, .05, .05], _green: [-.1, -.3, 0], _blue: [.04, -.2, 0]}),
        _p('Cocoa', {_tp: .18, _ct: .14, _sa: -.25, _fd: .12, _sH: .07, _sS: .25, _hH: .1, _hS: .2, _gr: .14, _vg: .12},
            m: _matte, hsl: {_green: [-.15, -.4, -.05], _blue: [0, -.4, 0]}),
        _p('Peach', {_ex: .1, _tp: .12, _tn: .1, _ct: -.08, _fd: .12, _hH: .04, _hS: .25, _sH: .9, _sS: .1, _gl: .12}, m: _airy),
        _p('Disposable', {_ct: .22, _sa: .12, _tp: .1, _tn: -.06, _gr: .36, _gs: .55, _vg: .3, _ca: .3, _lk: .22, _ls: .8, _sh: .1}, m: _film),
      ]),
];

/// Collection names in display order.
final List<String> presetCollections = () {
  final seen = <String>[];
  for (final p in builtInPresets) {
    if (!seen.contains(p.collection)) seen.add(p.collection);
  }
  return seen;
}();

// Referenced so the unused shorthand constants stay available to new presets.
// ignore: unused_element
const _reserved = [_br, _purple, _mH, _mS];
