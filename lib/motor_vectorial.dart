// ============================================================================
//  MOTOR DE MAPAS VECTORIALES (Dart) — guardar como lib/motor_vectorial.dart
//  Lee MBTiles con teselas vectoriales (.pbf / MVT) y las dibuja sin internet.
// ============================================================================
import 'dart:async';
import 'dart:collection';
import 'dart:convert' show utf8;
import 'dart:io' show gzip, zlib;
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:sqflite/sqflite.dart';

class ProveedorVectorial extends TileProvider {
  final List<Database> bases;
  final MotorVectorial motor;

  ProveedorVectorial(this.bases,
      {int resolucion = 512, bool etiquetas = true, bool edificios = true})
      : motor = MotorVectorial(bases,
            resolucion: resolucion, etiquetas: etiquetas, edificios: edificios);

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      _ImagenVectorial(motor, coordinates.x, coordinates.y, coordinates.z);
}

class MotorVectorial {
  final List<Database> bases;
  final int resolucion;
  final bool etiquetas, edificios;
  MotorVectorial(this.bases,
      {this.resolucion = 512, this.etiquetas = true, this.edificios = true});

  static const int _maxSobreZoom = 6;
  static const int _capacidadCache = 48;

  final LinkedHashMap<String, _TeselaM> _cache = LinkedHashMap<String, _TeselaM>();
  final Map<String, Future<_TeselaM?>> _enCurso = <String, Future<_TeselaM?>>{};
  Future<int>? _zMax;

  Future<int> _zoomMaximoDatos() => _zMax ??= _consultarZMax();

  Future<int> _consultarZMax() async {
    var m = 0;
    for (final db in bases) {
      try {
        final r = await db.rawQuery('SELECT MAX(zoom_level) AS z FROM tiles');
        final v = r.isEmpty ? null : r.first['z'];
        if (v is int && v > m) m = v;
      } catch (_) {}
    }
    return m;
  }

  Future<ui.Image> imagen(int z, int x, int y) async {
    try {
      final zMax = await _zoomMaximoDatos();
      var zD = z, dz = 0;
      if (z > zMax) {
        dz = z - zMax;
        zD = zMax;
      }
      if (dz > _maxSobreZoom) return _imagenTransparente();
      final px = x >> dz, py = y >> dz;
      final t = await _preparada(zD, px, py, z, dz);
      if (t == null) return _imagenTransparente();
      final subX = x - (px << dz), subY = y - (py << dz);
      return await _pintar(t, dz, subX, subY);
    } catch (_) {
      return _imagenTransparente();
    }
  }

  Future<_TeselaM?> _preparada(int zD, int px, int py, int zEfectivo, int dz) {
    final clave = '$zD/$px/$py@$zEfectivo';
    final enCache = _cache.remove(clave);
    if (enCache != null) {
      _cache[clave] = enCache;
      return Future<_TeselaM?>.value(enCache);
    }
    return _enCurso[clave] ??=
        _cargar(zD, px, py, zEfectivo, dz, clave).whenComplete(() {
      _enCurso.remove(clave);
    });
  }

  Future<_TeselaM?> _cargar(
      int zD, int px, int py, int zEfectivo, int dz, String clave) async {
    final datos = await _leerDb(zD, px, py);
    if (datos == null) return null;
    final r =
        await _Pool.instancia.preparar(datos, zEfectivo, dz, etiquetas, edificios);
    if (r == null) return null;
    final t = _TeselaM.desde(r);
    _cache[clave] = t;
    while (_cache.length > _capacidadCache) {
      _cache.remove(_cache.keys.first);
    }
    return t;
  }

  Future<Uint8List?> _leerDb(int z, int x, int y) async {
    final fila = (1 << z) - 1 - y;
    for (final db in bases) {
      try {
        final r = await db.rawQuery(
            'SELECT tile_data FROM tiles WHERE zoom_level = ? AND tile_column = ? AND tile_row = ? LIMIT 1',
            [z, x, fila]);
        if (r.isNotEmpty) {
          final d = r.first['tile_data'];
          if (d is Uint8List && d.isNotEmpty) return d;
        }
      } catch (_) {}
    }
    return null;
  }

  Future<ui.Image> _pintar(_TeselaM t, int dz, int subX, int subY) async {
    final tam = resolucion.toDouble();
    final f = 1 << dz;
    final esc = tam * f / 4096.0;
    final k = tam / 256.0;
    final marco = ui.Rect.fromLTWH(0, 0, tam, tam);
    final rec = ui.PictureRecorder();
    final c = ui.Canvas(rec, marco);
    c.clipRect(marco);
    c.drawRect(marco, ui.Paint()..color = const ui.Color(0xFFF2EFE9));
    c.save();
    c.scale(esc);
    c.translate(-subX * 4096.0 / f, -subY * 4096.0 / f);
    for (final g in t.grupos) {
      final p = ui.Paint()
        ..isAntiAlias = true
        ..color = ui.Color(g.color);
      if (g.tipo == 0) {
        p.style = ui.PaintingStyle.fill;
      } else {
        p
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = g.ancho * k / esc
          ..strokeCap = ui.StrokeCap.round
          ..strokeJoin = ui.StrokeJoin.round;
      }
      c.drawPath(g.path, p);
    }
    c.restore();
    for (final e in t.etiquetas) {
      final x = (e.x - subX * 4096.0 / f) * esc;
      final y = (e.y - subY * 4096.0 / f) * esc;
      if (x < 12 || y < 12 || x > tam - 12 || y > tam - 12) continue;
      _dibujarTexto(c, e.texto, x, y, e.tam * k);
    }
    final pic = rec.endRecording();
    try {
      return await pic.toImage(resolucion, resolucion);
    } finally {
      pic.dispose();
    }
  }

  void _dibujarTexto(
      ui.Canvas c, String texto, double x, double y, double tam) {
    final ancho = tam * 9.0;
    final estilo = ui.ParagraphStyle(
        textAlign: ui.TextAlign.center,
        maxLines: 2,
        textDirection: ui.TextDirection.ltr);
    ui.Paragraph construir(ui.Paint paint) {
      final b = ui.ParagraphBuilder(estilo)
        ..pushStyle(ui.TextStyle(
            foreground: paint, fontSize: tam, fontWeight: ui.FontWeight.w600))
        ..addText(texto);
      return b.build()..layout(ui.ParagraphConstraints(width: ancho));
    }

    final halo = construir(ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = tam * 0.28
      ..strokeJoin = ui.StrokeJoin.round
      ..color = const ui.Color(0xF0FFFFFF));
    final relleno = construir(ui.Paint()..color = const ui.Color(0xFF3A3A3A));
    final pos = ui.Offset(x - ancho / 2, y - halo.height / 2);
    c.drawParagraph(halo, pos);
    c.drawParagraph(relleno, pos);
  }
}

Future<ui.Image> _imagenTransparente() {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec, const ui.Rect.fromLTWH(0, 0, 1, 1));
  final pic = rec.endRecording();
  return pic.toImage(1, 1).whenComplete(pic.dispose);
}

class _ImagenVectorial extends ImageProvider<_ImagenVectorial> {
  final MotorVectorial motor;
  final int x, y, z;
  const _ImagenVectorial(this.motor, this.x, this.y, this.z);

  @override
  Future<_ImagenVectorial> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_ImagenVectorial>(this);

  @override
  ImageStreamCompleter loadImage(
          _ImagenVectorial key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_info());

  Future<ImageInfo> _info() async {
    final img = await motor.imagen(z, x, y);
    return ImageInfo(
        image: img, scale: img.width <= 1 ? 1.0 : img.width / 256.0);
  }

  @override
  bool operator ==(Object other) =>
      other is _ImagenVectorial &&
      identical(other.motor, motor) &&
      other.x == x &&
      other.y == y &&
      other.z == z;

  @override
  int get hashCode => Object.hash(identityHashCode(motor), x, y, z);
}

class _GrupoM {
  final int orden, tipo, color;
  final double ancho;
  final Float32List pts;
  final Int32List cortes;
  ui.Path? _path;
  _GrupoM(
      this.orden, this.tipo, this.color, this.ancho, this.pts, this.cortes);

  ui.Path get path => _path ??= _construir();

  ui.Path _construir() {
    final p = ui.Path();
    var i = 0;
    for (final len in cortes) {
      p.moveTo(pts[i], pts[i + 1]);
      for (var j = i + 2; j < i + len; j += 2) {
        p.lineTo(pts[j], pts[j + 1]);
      }
      if (tipo == 0) p.close();
      i += len;
    }
    return p;
  }
}

class _EtiquetaM {
  final String texto;
  final double x, y, tam;
  const _EtiquetaM(this.texto, this.x, this.y, this.tam);
}

class _TeselaM {
  final List<_GrupoM> grupos;
  final List<_EtiquetaM> etiquetas;
  const _TeselaM(this.grupos, this.etiquetas);

  factory _TeselaM.desde(List<Object?> r) {
    final grupos = <_GrupoM>[];
    for (final g in r[0] as List) {
      final l = g as List;
      grupos.add(_GrupoM(l[0] as int, l[1] as int, l[2] as int,
          (l[3] as num).toDouble(), l[4] as Float32List, l[5] as Int32List));
    }
    grupos.sort((a, b) => a.orden.compareTo(b.orden));
    final et = <_EtiquetaM>[];
    for (final e in r[1] as List) {
      final l = e as List;
      et.add(_EtiquetaM(l[0] as String, (l[1] as num).toDouble(),
          (l[2] as num).toDouble(), (l[3] as num).toDouble()));
    }
    return _TeselaM(grupos, et);
  }
}

class _Pool {
  static final _Pool instancia = _Pool._();
  _Pool._();

  final List<_Trabajador> _ts = <_Trabajador>[];
  int _turno = 0;
  Future<void>? _inicio;

  Future<void> _crear() async {
    for (var i = 0; i < 2; i++) {
      _ts.add(await _Trabajador.iniciar());
    }
  }

  Future<List<Object?>?> preparar(Uint8List datos, int z, int dz,
      bool etiquetas, bool edificios) async {
    try {
      await (_inicio ??= _crear());
      if (_ts.isEmpty) throw StateError('sin trabajadores');
      final t = _ts[_turno++ % _ts.length];
      return await t.enviar(datos, z, dz, etiquetas, edificios);
    } catch (_) {
      try {
        return _prepararTesela(datos, z, dz, etiquetas, edificios);
      } catch (_) {
        return null;
      }
    }
  }
}

class _Trabajador {
  final SendPort _puerto;
  final Map<int, Completer<List<Object?>?>> _pendientes =
      <int, Completer<List<Object?>?>>{};
  int _id = 0;
  _Trabajador._(this._puerto);

  static Future<_Trabajador> iniciar() async {
    final recibir = ReceivePort();
    await Isolate.spawn(_entradaTrabajador, recibir.sendPort);
    final listo = Completer<_Trabajador>();
    _Trabajador? t;
    recibir.listen((Object? m) {
      if (m is SendPort) {
        final nuevo = _Trabajador._(m);
        t = nuevo;
        listo.complete(nuevo);
      } else if (m is List) {
        final id = m[0] as int;
        final c = t?._pendientes.remove(id);
        if (c != null) {
          final r = m[1];
          c.complete(r is List ? r.cast<Object?>() : null);
        }
      }
    });
    return listo.future;
  }

  Future<List<Object?>?> enviar(
      Uint8List datos, int z, int dz, bool etiquetas, bool edificios) {
    final id = _id++;
    final c = Completer<List<Object?>?>();
    _pendientes[id] = c;
    _puerto.send(<Object>[
      id,
      TransferableTypedData.fromList(<Uint8List>[datos]),
      z,
      dz,
      etiquetas,
      edificios
    ]);
    return c.future;
  }
}

void _entradaTrabajador(SendPort principal) {
  final rp = ReceivePort();
  principal.send(rp.sendPort);
  rp.listen((Object? m) {
    final msg = m as List;
    final id = msg[0] as int;
    try {
      final bytes =
          (msg[1] as TransferableTypedData).materialize().asUint8List();
      final r = _prepararTesela(
          bytes, msg[2] as int, msg[3] as int, msg[4] as bool, msg[5] as bool);
      principal.send(<Object?>[id, r]);
    } catch (_) {
      principal.send(<Object?>[id, 'error']);
    }
  });
}

class _Lector {
  final Uint8List b;
  int p;
  final int fin;
  _Lector(this.b, [int ini = 0, int? fin])
      : p = ini,
        fin = fin ?? b.length;

  bool get hay => p < fin;

  int varint() {
    var r = 0, s = 0;
    while (true) {
      final x = b[p++];
      r |= (x & 0x7F) << s;
      if (x < 0x80 || p >= fin) return r;
      s += 7;
    }
  }

  Uint8List bytes() {
    final n = varint();
    final v = Uint8List.sublistView(b, p, p + n);
    p += n;
    return v;
  }

  double fixed32f() {
    final v = ByteData.sublistView(b, p, p + 4).getFloat32(0, Endian.little);
    p += 4;
    return v;
  }

  double fixed64f() {
    final v = ByteData.sublistView(b, p, p + 8).getFloat64(0, Endian.little);
    p += 8;
    return v;
  }

  void saltar(int cable) {
    if (cable == 0) {
      varint();
    } else if (cable == 1) {
      p += 8;
    } else if (cable == 2) {
      final n = varint();
      p += n;
    } else if (cable == 5) {
      p += 4;
    } else {
      throw const FormatException('protobuf: tipo de campo no soportado');
    }
  }
}

int _zz(int v) => (v >>> 1) ^ -(v & 1);

Uint8List _descomprimir(Uint8List b) {
  if (b.length > 2 && b[0] == 0x1f && b[1] == 0x8b) {
    return Uint8List.fromList(gzip.decode(b));
  }
  if (b.length > 2 && b[0] == 0x78) return Uint8List.fromList(zlib.decode(b));
  return b;
}

const int _rAgua = 1,
    _rSuelo = 2,
    _rEdif = 3,
    _rVia = 4,
    _rLugar = 5,
    _rCurso = 6,
    _rLimite = 7,
    _rOsm = 8;
const int _rangoRiel = 10;

int _rolCapa(String n) {
  switch (n) {
    case 'water':
    case 'ocean':
    case 'water_polygon':
      return _rAgua;
    case 'waterway':
      return _rCurso;
    case 'landcover':
    case 'landuse':
    case 'park':
    case 'natural':
      return _rSuelo;
    case 'building':
    case 'buildings':
      return _rEdif;
    case 'transportation':
    case 'roads':
    case 'road':
      return _rVia;
    case 'place':
    case 'places':
      return _rLugar;
    case 'boundary':
    case 'boundaries':
      return _rLimite;
    case 'lines':
    case 'multipolygons':
    case 'points':
      return _rOsm;
    default:
      return 0;
  }
}

class _Ctx {
  final int z;
  final double eps2, minLado;
  final bool etiquetas, edificios;
  final Map<int, _GrupoW> grupos = <int, _GrupoW>{};
  final List<List<Object>> etiquetasOut = <List<Object>>[];
  _Ctx(this.z, double eps, this.minLado, this.etiquetas, this.edificios)
      : eps2 = eps * eps;

  _GrupoW grupo(int orden, int tipo, int color, double ancho) =>
      grupos.putIfAbsent((orden << 32) | (color & 0xFFFFFFFF),
          () => _GrupoW(orden, tipo, color, ancho));
}

class _BufF {
  Float32List d = Float32List(2048);
  int length = 0;
  void add(double v) {
    if (length == d.length) {
      final n = Float32List(d.length * 2)..setRange(0, length, d);
      d = n;
    }
    d[length++] = v;
  }

  Float32List recortar() => d.sublist(0, length);
}

class _BufI {
  Int32List d = Int32List(256);
  int length = 0;
  void add(int v) {
    if (length == d.length) {
      final n = Int32List(d.length * 2)..setRange(0, length, d);
      d = n;
    }
    d[length++] = v;
  }

  Int32List recortar() => d.sublist(0, length);
}

class _GrupoW {
  final int orden, tipo, color;
  final double ancho;
  final _BufF pts = _BufF();
  final _BufI cortes = _BufI();
  _GrupoW(this.orden, this.tipo, this.color, this.ancho);

  List<Object> empaquetar() =>
      <Object>[orden, tipo, color, ancho, pts.recortar(), cortes.recortar()];
}

class _Trazo {
  final int orden, tipo, color;
  final double ancho;
  const _Trazo(this.orden, this.tipo, this.color, this.ancho);
}

List<Object?> _prepararTesela(
    Uint8List crudo, int z, int dz, bool etiquetas, bool edificios) {
  final datos = _descomprimir(crudo);
  final f = 1 << dz;
  final ctx = _Ctx(z, 9.6 / f, 16.0 / f, etiquetas, edificios);
  final l = _Lector(datos);
  while (l.hay) {
    final t = l.varint();
    if ((t >> 3) == 3 && (t & 7) == 2) {
      final n = l.varint();
      _leerCapa(datos, l.p, l.p + n, ctx);
      l.p += n;
    } else {
      l.saltar(t & 7);
    }
  }
  final grupos = ctx.grupos.values.toList()
    ..sort((a, b) => a.orden.compareTo(b.orden));
  final salida = <List<Object>>[
    for (final g in grupos)
      if (g.cortes.length > 0) g.empaquetar(),
  ];
  return <Object?>[salida, ctx.etiquetasOut];
}

void _leerCapa(Uint8List b, int ini, int fin, _Ctx ctx) {
  final l = _Lector(b, ini, fin);
  var nombre = '';
  var extent = 4096;
  final claves = <String>[];
  final valores = <Object?>[];
  final rasgos = <int>[];
  while (l.hay) {
    final t = l.varint();
    final campo = t >> 3, cable = t & 7;
    if (campo == 1 && cable == 2) {
      nombre = utf8.decode(l.bytes(), allowMalformed: true);
    } else if (campo == 2 && cable == 2) {
      final n = l.varint();
      rasgos.add(l.p);
      rasgos.add(l.p + n);
      l.p += n;
    } else if (campo == 3 && cable == 2) {
      claves.add(utf8.decode(l.bytes(), allowMalformed: true));
    } else if (campo == 4 && cable == 2) {
      final n = l.varint();
      valores.add(_leerValor(b, l.p, l.p + n));
      l.p += n;
    } else if (campo == 5 && cable == 0) {
      extent = l.varint();
    } else {
      l.saltar(cable);
    }
  }
  final rol = _rolCapa(nombre);
  if (rol == 0 || rasgos.isEmpty || extent <= 0) return;
  final k = 4096.0 / extent;
  for (var i = 0; i + 1 < rasgos.length; i += 2) {
    _leerRasgo(b, rasgos[i], rasgos[i + 1], rol, claves, valores, k, ctx);
  }
}

Object? _leerValor(Uint8List b, int ini, int fin) {
  final l = _Lector(b, ini, fin);
  Object? r;
  while (l.hay) {
    final t = l.varint();
    final campo = t >> 3, cable = t & 7;
    if (campo == 1 && cable == 2) {
      r = utf8.decode(l.bytes(), allowMalformed: true);
    } else if (campo == 2 && cable == 5) {
      r = l.fixed32f();
    } else if (campo == 3 && cable == 1) {
      r = l.fixed64f();
    } else if ((campo == 4 || campo == 5) && cable == 0) {
      r = l.varint();
    } else if (campo == 6 && cable == 0) {
      r = _zz(l.varint());
    } else if (campo == 7 && cable == 0) {
      r = l.varint() != 0;
    } else {
      l.saltar(cable);
    }
  }
  return r;
}

void _leerRasgo(Uint8List b, int ini, int fin, int rol, List<String> claves,
    List<Object?> valores, double k, _Ctx ctx) {
  final l = _Lector(b, ini, fin);
  var tipo = 0, gIni = -1, gFin = -1;
  final tags = <int>[];
  while (l.hay) {
    final t = l.varint();
    final campo = t >> 3, cable = t & 7;
    if (campo == 2) {
      if (cable == 2) {
        final n = l.varint();
        final hasta = l.p + n;
        while (l.p < hasta) {
          tags.add(l.varint());
        }
      } else {
        tags.add(l.varint());
      }
    } else if (campo == 3 && cable == 0) {
      tipo = l.varint();
    } else if (campo == 4 && cable == 2) {
      final n = l.varint();
      gIni = l.p;
      gFin = l.p + n;
      l.p = gFin;
    } else {
      l.saltar(cable);
    }
  }
  if (gIni < 0 || tipo == 0) return;

  final props = <String, Object?>{};
  for (var i = 0; i + 1 < tags.length; i += 2) {
    final ki = tags[i], vi = tags[i + 1];
    if (ki < claves.length && vi < valores.length) props[claves[ki]] = valores[vi];
  }

  final r = _rolEfectivo(rol, tipo, props);
  if (r == 0) return;
  if (r == _rLugar) {
    _etiqueta(b, gIni, gFin, props, k, ctx);
    return;
  }
  final trazos = _trazos(r, props, ctx);
  if (trazos.isEmpty) return;
  final partes = _geometria(b, gIni, gFin, tipo);
  if (partes.isEmpty) return;
  for (final tr in trazos) {
    final g = ctx.grupo(tr.orden, tr.tipo, tr.color, tr.ancho);
    for (final p in partes) {
      _agregarParte(g, p, k, ctx.eps2, tr.tipo == 0, ctx.minLado);
    }
  }
}

List<Int32List> _geometria(Uint8List b, int ini, int fin, int tipo) {
  final l = _Lector(b, ini, fin);
  final partes = <Int32List>[];
  var actual = <int>[];
  var x = 0, y = 0;
  final minimo = tipo == 3 ? 6 : 4;
  while (l.hay) {
    final cmd = l.varint();
    final id = cmd & 7;
    final n = cmd >> 3;
    if (id == 1) {
      for (var i = 0; i < n; i++) {
        x += _zz(l.varint());
        y += _zz(l.varint());
        if (tipo == 1) {
          partes.add(Int32List.fromList(<int>[x, y]));
        } else {
          if (actual.length >= minimo) partes.add(Int32List.fromList(actual));
          actual = <int>[x, y];
        }
      }
    } else if (id == 2) {
      for (var i = 0; i < n; i++) {
        x += _zz(l.varint());
        y += _zz(l.varint());
        actual.add(x);
        actual.add(y);
      }
    } else if (id == 7) {
      if (actual.length >= minimo) partes.add(Int32List.fromList(actual));
      actual = <int>[];
    } else {
      break;
    }
  }
  if (tipo != 1 && actual.length >= minimo) {
    partes.add(Int32List.fromList(actual));
  }
  return partes;
}

void _agregarParte(_GrupoW g, Int32List p, double k, double eps2,
    bool poligono, double minLado) {
  final n = p.length ~/ 2;
  if (n < 2) return;
  var minX = double.infinity,
      minY = double.infinity,
      maxX = -double.infinity,
      maxY = -double.infinity;
  for (var i = 0; i < n; i++) {
    final x = p[2 * i] * k, y = p[2 * i + 1] * k;
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }
  if (maxX - minX < minLado && maxY - minY < minLado) return;
  final inicio = g.pts.length;
  var ux = p[0] * k, uy = p[1] * k;
  g.pts.add(ux);
  g.pts.add(uy);
  for (var i = 1; i < n - 1; i++) {
    final x = p[2 * i] * k, y = p[2 * i + 1] * k;
    final dx = x - ux, dy = y - uy;
    if (dx * dx + dy * dy >= eps2) {
      g.pts.add(x);
      g.pts.add(y);
      ux = x;
      uy = y;
    }
  }
  g.pts.add(p[2 * (n - 1)] * k);
  g.pts.add(p[2 * (n - 1) + 1] * k);
  final cant = g.pts.length - inicio;
  if (cant < (poligono ? 6 : 4)) {
    g.pts.length = inicio;
    return;
  }
  g.cortes.add(cant);
}

String? _s(Map<String, Object?> p, String k) => p[k]?.toString();

int? _entero(Object? v) {
  if (v is int) return v;
  if (v is double) return v.round();
  return int.tryParse('$v');
}

bool _esAguaOsm(Map<String, Object?> p) =>
    _s(p, 'natural') == 'water' ||
    _s(p, 'natural') == 'bay' ||
    p['water'] != null ||
    _s(p, 'waterway') == 'riverbank' ||
    _s(p, 'landuse') == 'reservoir' ||
    _s(p, 'landuse') == 'basin';

int _rolEfectivo(int rol, int tipo, Map<String, Object?> p) {
  if (rol == _rOsm) {
    if (tipo == 1) return p.containsKey('place') ? _rLugar : 0;
    if (tipo == 3) {
      if (p['building'] != null) return _rEdif;
      if (_esAguaOsm(p)) return _rAgua;
      return _rSuelo;
    }
    if (tipo == 2) {
      if (p['highway'] != null || p['railway'] != null) return _rVia;
      if (p['waterway'] != null) return _rCurso;
      if (p['boundary'] != null) return _rLimite;
    }
    return 0;
  }
  switch (rol) {
    case _rAgua:
    case _rSuelo:
    case _rEdif:
      return tipo == 3 ? rol : 0;
    case _rCurso:
    case _rVia:
    case _rLimite:
      return tipo == 2 ? rol : 0;
    case _rLugar:
      return tipo == 1 ? rol : 0;
  }
  return 0;
}

const List<double> _factorZoom = <double>[
  0.4, 0.4, 0.4, 0.4, 0.45, 0.45, 0.45, 0.5, 0.55, 0.6,
  0.65, 0.75, 0.85, 0.95, 1.0, 1.25, 1.7, 2.3, 3.1, 4.0
];
double _fz(int z) => _factorZoom[z < 0 ? 0 : (z > 19 ? 19 : z)];

const List<int> _minZVia = <int>[99, 14, 13, 14, 12, 10, 8, 6, 5, 4, 9];
const List<double> _anchoVia = <double>[
  0, 1.0, 1.2, 1.6, 2.4, 3.2, 3.8, 4.4, 5.0, 5.5, 1.0
];
const List<int> _colorVia = <int>[
  0, 0xFF8E8E8E, 0xFFB08D57, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF,
  0xFFFBEBA0, 0xFFFAD16A, 0xFFF4A95B, 0xFFE9906A, 0xFF8C8C8C
];
const List<int> _colorBorde = <int>[
  0, 0, 0, 0xFFC0C0C0, 0xFFB5B5B5, 0xFFAAAAAA,
  0xFFC2B26B, 0xFFC9A63F, 0xFFC8843F, 0xFFC0603A, 0
];

int _rangoVia(Map<String, Object?> p) {
  final hw = _s(p, 'highway');
  if (hw == null && p['railway'] != null) return _rangoRiel;
  final v = hw ?? _s(p, 'class') ?? _s(p, 'kind');
  switch (v) {
    case 'motorway':
    case 'motorway_link':
    case 'highway':
      return 9;
    case 'trunk':
    case 'trunk_link':
      return 8;
    case 'primary':
    case 'primary_link':
      return 7;
    case 'secondary':
    case 'secondary_link':
    case 'major_road':
      return 6;
    case 'tertiary':
    case 'tertiary_link':
    case 'medium_road':
      return 5;
    case 'unclassified':
    case 'residential':
    case 'living_street':
    case 'minor':
    case 'street':
    case 'minor_road':
    case 'road':
      return 4;
    case 'service':
      return 3;
    case 'track':
      return 2;
    case 'path':
    case 'footway':
    case 'pedestrian':
    case 'cycleway':
    case 'steps':
    case 'bridleway':
      return 1;
    case 'rail':
    case 'light_rail':
      return _rangoRiel;
    default:
      return -1;
  }
}

int? _colorSuelo(String c) {
  switch (c) {
    case 'wood':
    case 'forest':
      return 0xFFC5DFAE;
    case 'scrub':
    case 'heath':
    case 'grassland':
      return 0xFFD2E3B9;
    case 'wetland':
    case 'marsh':
      return 0xFFC8DDC5;
    case 'grass':
    case 'park':
    case 'garden':
    case 'meadow':
    case 'recreation_ground':
    case 'pitch':
    case 'village_green':
    case 'golf_course':
    case 'playground':
    case 'national_park':
    case 'nature_reserve':
    case 'protected_area':
      return 0xFFD3E8BF;
    case 'farmland':
    case 'farm':
    case 'farmyard':
    case 'orchard':
    case 'vineyard':
    case 'allotments':
    case 'plant_nursery':
      return 0xFFEFEBD3;
    case 'residential':
    case 'suburb':
    case 'neighbourhood':
      return 0xFFEAE5DE;
    case 'commercial':
    case 'retail':
      return 0xFFF0DCDC;
    case 'industrial':
    case 'quarry':
    case 'railway':
    case 'garages':
    case 'brownfield':
    case 'construction':
      return 0xFFE6E0EB;
    case 'cemetery':
    case 'grave_yard':
      return 0xFFC3DCC3;
    case 'sand':
    case 'beach':
      return 0xFFF3E6BF;
    case 'rock':
    case 'bare_rock':
    case 'scree':
      return 0xFFE0DCD6;
    case 'glacier':
    case 'ice':
      return 0xFFF2F8FC;
    case 'hospital':
    case 'school':
    case 'university':
    case 'college':
    case 'military':
      return 0xFFF0E8E4;
    default:
      return null;
  }
}

List<_Trazo> _trazos(int r, Map<String, Object?> p, _Ctx c) {
  switch (r) {
    case _rAgua:
      return const <_Trazo>[_Trazo(20, 0, 0xFFA8CFEF, 0)];
    case _rSuelo:
      {
        final clase = _s(p, 'class') ??
            _s(p, 'subclass') ??
            _s(p, 'landuse') ??
            _s(p, 'natural') ??
            _s(p, 'leisure') ??
            _s(p, 'landcover');
        final color = clase == null ? null : _colorSuelo(clase);
        if (color == null) return const <_Trazo>[];
        return <_Trazo>[_Trazo(10, 0, color, 0)];
      }
    case _rEdif:
      if (!c.edificios || c.z < 14) return const <_Trazo>[];
      return const <_Trazo>[_Trazo(40, 0, 0xFFD9D0C9, 0)];
    case _rCurso:
      {
        final clase = _s(p, 'class') ?? _s(p, 'waterway') ?? '';
        final grande = clase == 'river' || clase == 'canal';
        final minZ = clase == 'river' ? 7 : (clase == 'canal' ? 10 : 12);
        if (c.z < minZ) return const <_Trazo>[];
        final ancho = (grande ? 1.8 : 0.9) * _fz(c.z);
        return <_Trazo>[_Trazo(grande ? 31 : 30, 1, 0xFF94C4EA, ancho)];
      }
    case _rLimite:
      {
        final nivel = _entero(p['admin_level']) ?? 8;
        if (nivel > 4 && c.z < 8) return const <_Trazo>[];
        if (nivel > 6 && c.z < 11) return const <_Trazo>[];
        return <_Trazo>[
          _Trazo(60, 1, 0xFFB794C7, 1.1 * _fz(c.z).clamp(0.7, 1.6))
        ];
      }
    case _rVia:
      {
        final rango = _rangoVia(p);
        if (rango < 1 || c.z < _minZVia[rango]) return const <_Trazo>[];
        final ancho = _anchoVia[rango] * _fz(c.z);
        if (rango == _rangoRiel) {
          return <_Trazo>[_Trazo(150, 1, _colorVia[rango], ancho)];
        }
        if (rango >= 3 && c.z >= 12) {
          return <_Trazo>[
            _Trazo(100 + rango, 1, _colorBorde[rango], ancho + 1.4),
            _Trazo(200 + rango, 1, _colorVia[rango], ancho),
          ];
        }
        return <_Trazo>[_Trazo(200 + rango, 1, _colorVia[rango], ancho)];
      }
  }
  return const <_Trazo>[];
}

(int, int, double)? _configLugar(String clase) {
  switch (clase) {
    case 'country':
      return (2, 6, 19.0);
    case 'state':
    case 'province':
    case 'region':
      return (4, 8, 15.0);
    case 'city':
      return (4, 99, 17.0);
    case 'town':
      return (7, 99, 14.0);
    case 'village':
      return (10, 99, 12.5);
    case 'suburb':
    case 'quarter':
      return (12, 99, 11.0);
    case 'hamlet':
    case 'isolated_dwelling':
    case 'locality':
    case 'neighbourhood':
      return (12, 99, 10.5);
    default:
      return null;
  }
}

void _etiqueta(Uint8List b, int gIni, int gFin, Map<String, Object?> p,
    double k, _Ctx c) {
  if (!c.etiquetas || c.etiquetasOut.length >= 60) return;
  final nombre = _s(p, 'name:es') ?? _s(p, 'name_es') ?? _s(p, 'name');
  if (nombre == null || nombre.isEmpty) return;
  final clase = _s(p, 'class') ?? _s(p, 'place') ?? _s(p, 'kind') ?? '';
  final cfg = _configLugar(clase);
  if (cfg == null || c.z < cfg.$1 || c.z > cfg.$2) return;
  for (final pt in _geometria(b, gIni, gFin, 1)) {
    c.etiquetasOut.add(<Object>[nombre, pt[0] * k, pt[1] * k, cfg.$3]);
  }
}
