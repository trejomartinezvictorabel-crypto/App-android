// ============================================================================
//  NAVEGACIÓN MULTIMODAL OFFLINE — MÉXICO (Flutter, un solo main.dart)
//  GPS en tiempo real · mapas MBTiles locales · enrutamiento A* sobre GeoJSON
//  Voz (TTS/STT) manos libres · SQLite local (POIs, rutas frecuentes, historial)
//  Navega SIN internet; internet solo se usa al descargar mapas / red vial (Ajustes).
//  Requiere Dart >= 3.0.
// ============================================================================
// ----------------------------------------------------------------------------
//  CONFIGURACIÓN COMPLETA (Flutter exige que viva fuera de este archivo;
//  se deja aquí copiada para tener todo en una sola pieza)
//
//  A) PERMISOS  →  android/app/src/main/AndroidManifest.xml
//     (NO van en pubspec.yaml). Entre <manifest> y <application>:
//
//     <uses-permission android:name="android.permission.INTERNET"/>   ← NUEVO: necesario para las descargas
//     <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
//     <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
//     <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
//     <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION"/>
//     <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
//     <uses-permission android:name="android.permission.WAKE_LOCK"/>
//     <uses-permission android:name="android.permission.RECORD_AUDIO"/>
//     <uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE"/>
//     <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>
//     <queries>
//         <intent><action android:name="android.intent.action.TTS_SERVICE"/></intent>
//     </queries>
//
//  B) PAQUETES  →  pubspec.yaml, sección dependencies: (solo paquetes, nunca permisos)
//
//     flutter_map: ^6.2.1
//     latlong2: ^0.9.1
//     geolocator: ^12.0.0
//     flutter_tts: ^4.0.2
//     vosk_flutter: ^0.3.48
//     sqflite: ^2.3.3+1
//     path: ^1.9.0
//     path_provider: ^2.1.4
//     file_picker: ^8.1.2
//     permission_handler: ^11.3.1
//     wakelock_plus: ^1.2.8
//     flutter_compass: ^0.8.1
//
//     (Las descargas NO agregan paquetes nuevos: usan dart:io, sqflite y path_provider, que ya están.)
//
//  C) MODELO DE VOZ OFFLINE (Vosk)  →  pubspec.yaml, sección flutter: (el .zip va SIN descomprimir)
//
//     flutter:
//       assets:
//         - assets/models/vosk-model-small-es-0.42.zip
//
//  D) En tiempo de ejecución la app pide los permisos sola (ubicación, notificaciones,
//     micrófono y acceso a Descargas): ver Controlador.pedirPermisos().
// ----------------------------------------------------------------------------
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as ruta_p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vosk_flutter/vosk_flutter.dart' as vosk;
import 'package:sqflite/sqflite.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ============================================================================
// 1. MODOS DE TRANSPORTE
// ============================================================================

/// Clase de vía normalizada desde la etiqueta "highway" de OpenStreetMap.
enum ClaseVia { autopista, troncal, primaria, secundaria, terciaria, local, servicio, terraceria, peatonal, ciclovia }

ClaseVia? claseDesdeOsm(String? t) {
  switch (t) {
    case 'motorway':
    case 'motorway_link':
      return ClaseVia.autopista;
    case 'trunk':
    case 'trunk_link':
      return ClaseVia.troncal;
    case 'primary':
    case 'primary_link':
      return ClaseVia.primaria;
    case 'secondary':
    case 'secondary_link':
      return ClaseVia.secundaria;
    case 'tertiary':
    case 'tertiary_link':
      return ClaseVia.terciaria;
    case 'unclassified':
    case 'residential':
    case 'living_street':
      return ClaseVia.local;
    case 'service':
      return ClaseVia.servicio;
    case 'track':
      return ClaseVia.terraceria;
    case 'footway':
    case 'pedestrian':
    case 'steps':
    case 'path':
    case 'bridleway':
      return ClaseVia.peatonal;
    case 'cycleway':
      return ClaseVia.ciclovia;
    default:
      return null;
  }
}

/// Modos multimodales: velocidades por tipo de vía (0 = prohibido), umbrales y avisos de voz.
enum Modo {
  auto('Auto', '🚗', 'automóvil', 45, 110, 1, 40, 25, [400, 150, 30], false),
  moto('Moto', '🏍️', 'motocicleta', 45, 100, 1, 35, 20, [300, 120, 30], false),
  bici('Bici', '🚲', 'bicicleta', 15, 40, 2, 25, 12, [150, 60, 20], true),
  transporte('Transp.', '🚌', 'transporte público', 25, 80, 2, 45, 30, [300, 120, 30], false),
  pie('A pie', '🚶', 'a pie', 5, 7, 2, 20, 10, [60, 25, 8], true);

  const Modo(this.etiqueta, this.emoji, this.vozNombre, this.velProm, this.velMax, this.intervaloS,
      this.umbralDesvio, this.umbralLlegada, this.avisos, this.ignoraSentido);

  final String etiqueta;
  final String emoji;
  final String vozNombre;
  final double velProm; // km/h
  final double velMax; // km/h (heurística admisible de A*)
  final int intervaloS; // intervalo de GPS (más espaciado = menos batería)
  final double umbralDesvio; // m
  final double umbralLlegada; // m
  final List<int> avisos; // distancias de aviso de voz (m)
  final bool ignoraSentido; // bici / a pie pueden ir contra sentido único

  // Orden = ClaseVia: autopista, troncal, primaria, secundaria, terciaria, local, servicio, terracería, peatonal, ciclovía
  static const List<double> _motor = [100, 80, 60, 50, 40, 30, 15, 20, 0, 0];
  static const List<double> _bici = [0, 14, 15, 16, 16, 16, 14, 10, 6, 18];
  static const List<double> _transp = [70, 60, 40, 35, 30, 20, 0, 0, 0, 0];
  static const List<double> _pie = [0, 5, 5, 5, 5, 5, 5, 4.5, 5, 5];

  double velEnVia(ClaseVia c) {
    switch (this) {
      case Modo.auto:
      case Modo.moto:
        return _motor[c.index];
      case Modo.bici:
        return _bici[c.index];
      case Modo.transporte:
        return _transp[c.index];
      case Modo.pie:
        return _pie[c.index];
    }
  }
}

// ============================================================================
// 2. UTILIDADES GEODÉSICAS Y DE TEXTO
// ============================================================================

class Geo {
  static const double _radioTierra = 6371000.0;
  static double _rad(double g) => g * math.pi / 180.0;
  static double _deg(double r) => r * 180.0 / math.pi;

  /// Distancia en metros (Haversine).
  static double dist(double lat1, double lon1, double lat2, double lon2) {
    final dLat = _rad(lat2 - lat1);
    final dLon = _rad(lon2 - lon1);
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(_rad(lat1)) * math.cos(_rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
    return 2 * _radioTierra * math.asin(math.min(1.0, math.sqrt(a)));
  }

  static double distLL(LatLng a, LatLng b) => dist(a.latitude, a.longitude, b.latitude, b.longitude);

  /// Rumbo 0..360 (0 = norte) de a hacia b.
  static double rumbo(LatLng a, LatLng b) {
    final lat1 = _rad(a.latitude), lat2 = _rad(b.latitude);
    final dLon = _rad(b.longitude - a.longitude);
    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    return (_deg(math.atan2(y, x)) + 360.0) % 360.0;
  }

  /// Diferencia angular en (-180, 180]; positivo = giro a la derecha.
  static double difAng(double desde, double hasta) {
    var d = (hasta - desde) % 360.0;
    if (d > 180.0) d -= 360.0;
    if (d <= -180.0) d += 360.0;
    return d;
  }

  static String cardinal(double r) {
    const n = ['norte', 'noreste', 'este', 'sureste', 'sur', 'suroeste', 'oeste', 'noroeste'];
    return n[((r + 22.5) / 45.0).floor() % 8];
  }

  /// Distancia y fracción de [p] sobre el segmento a-b (plano local).
  static (double, double) _segmento(LatLng p, LatLng a, LatLng b) {
    final kx = 111320.0 * math.cos(_rad(a.latitude));
    const ky = 110540.0;
    final bx = (b.longitude - a.longitude) * kx, by = (b.latitude - a.latitude) * ky;
    final px = (p.longitude - a.longitude) * kx, py = (p.latitude - a.latitude) * ky;
    final l2 = bx * bx + by * by;
    final t = l2 <= 1e-9 ? 0.0 : ((px * bx + py * by) / l2).clamp(0.0, 1.0);
    final dx = px - t * bx, dy = py - t * by;
    return (math.sqrt(dx * dx + dy * dy), t);
  }

  /// Proyecta [p] sobre la ruta empezando en [desde] y mirando [ventana] metros hacia adelante.
  static ({int seg, double dist, double prog}) proyectar(
      LatLng p, List<LatLng> pts, List<double> acum, int desde,
      {double ventana = 600}) {
    final ini = desde.clamp(0, pts.length - 2);
    var mejorD = double.maxFinite, mejorS = ini, mejorP = acum[ini];
    for (var i = ini; i < pts.length - 1; i++) {
      if (i > ini && acum[i] - acum[ini] > ventana) break;
      final (d, t) = _segmento(p, pts[i], pts[i + 1]);
      if (d < mejorD) {
        mejorD = d;
        mejorS = i;
        mejorP = acum[i] + t * (acum[i + 1] - acum[i]);
      }
    }
    return (seg: mejorS, dist: mejorD, prog: mejorP);
  }
}

class Fmt {
  static String dist(double m) => m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(1)} km';

  static String distVoz(double m) {
    if (m >= 1000) return '${(m / 1000).toStringAsFixed(1)} kilómetros';
    final r = m >= 100 ? (m / 50).round() * 50 : (m / 10).round() * 10;
    return '$r metros';
  }

  static String dur(int s) {
    final min = (s + 30) ~/ 60;
    return min < 60 ? '$min min' : '${min ~/ 60} h ${min % 60} min';
  }

  static String durVoz(int s) {
    final min = (s + 30) ~/ 60;
    if (min < 1) return 'menos de un minuto';
    if (min < 60) return min == 1 ? '1 minuto' : '$min minutos';
    final h = min ~/ 60, r = min % 60;
    final hs = h == 1 ? '1 hora' : '$h horas';
    return r == 0 ? hs : '$hs $r minutos';
  }

  static String _dos(int n) => n.toString().padLeft(2, '0');

  static String hora(DateTime d) => '${_dos(d.hour)}:${_dos(d.minute)}';

  static String fechaHora(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${_dos(d.day)}/${_dos(d.month)}/${d.year % 100} ${hora(d)}';
  }

  /// Minúsculas y sin acentos, para comparar nombres dictados por voz.
  static String normalizar(String t) {
    const con = 'áàäâéèëêíìïîóòöôúùüûñ';
    const sin = 'aaaaeeeeiiiioooouuuun';
    final b = StringBuffer();
    for (final c in t.toLowerCase().split('')) {
      final i = con.indexOf(c);
      b.write(i >= 0 ? sin[i] : c);
    }
    return b.toString().trim();
  }
}

// ============================================================================
// 3. MODELOS DE RUTA Y MANIOBRAS
// ============================================================================

enum TipoGiro {
  salida('⬆'),
  ligeroDer('↗'),
  der('➡'),
  cerradoDer('↘'),
  ligeroIzq('↖'),
  izq('⬅'),
  cerradoIzq('↙'),
  vueltaU('↩'),
  llegada('🏁');

  const TipoGiro(this.flecha);
  final String flecha;
}

class Maniobra {
  final int idx;
  final LatLng punto;
  final TipoGiro tipo;
  final String texto;
  final double acumM; // metros desde el inicio de la ruta
  const Maniobra(this.idx, this.punto, this.tipo, this.texto, this.acumM);
}

class Ruta {
  final List<LatLng> puntos;
  final List<double> acum;
  final double total;
  final double duracionS;
  final List<Maniobra> maniobras;
  final bool aproximada; // true = línea recta (sin red vial o sin camino)
  final Modo modo;
  const Ruta(this.puntos, this.acum, this.total, this.duracionS, this.maniobras, this.aproximada, this.modo);
}

/// Convierte la polilínea en instrucciones de giro en español.
List<Maniobra> generarManiobras(List<LatLng> pts, List<double> acum) {
  const distRef = 12.0, angMin = 30.0, sepMin = 25.0;
  final res = <Maniobra>[];
  if (pts.length < 2) return res;
  res.add(Maniobra(0, pts[0], TipoGiro.salida, 'Dirígete al ${Geo.cardinal(Geo.rumbo(pts[0], pts[1]))}', 0));
  var ultima = -sepMin;
  for (var i = 1; i < pts.length - 1; i++) {
    var j = i - 1;
    while (j > 0 && acum[i] - acum[j] < distRef) {
      j--;
    }
    var k = i + 1;
    while (k < pts.length - 1 && acum[k] - acum[i] < distRef) {
      k++;
    }
    final delta = Geo.difAng(Geo.rumbo(pts[j], pts[i]), Geo.rumbo(pts[i], pts[k]));
    if (delta.abs() < angMin || acum[i] - ultima < sepMin) continue;
    final der = delta > 0;
    final a = delta.abs();
    late TipoGiro tipo;
    late String texto;
    if (a >= 165) {
      tipo = TipoGiro.vueltaU;
      texto = 'Da vuelta en U';
    } else if (a >= 120) {
      tipo = der ? TipoGiro.cerradoDer : TipoGiro.cerradoIzq;
      texto = der ? 'Gira cerrado a la derecha' : 'Gira cerrado a la izquierda';
    } else if (a >= 60) {
      tipo = der ? TipoGiro.der : TipoGiro.izq;
      texto = der ? 'Gira a la derecha' : 'Gira a la izquierda';
    } else {
      tipo = der ? TipoGiro.ligeroDer : TipoGiro.ligeroIzq;
      texto = der ? 'Gira ligeramente a la derecha' : 'Gira ligeramente a la izquierda';
    }
    res.add(Maniobra(i, pts[i], tipo, texto, acum[i]));
    ultima = acum[i];
  }
  final u = pts.length - 1;
  res.add(Maniobra(u, pts[u], TipoGiro.llegada, 'Has llegado a tu destino', acum[u]));
  return res;
}

// ============================================================================
// 4. RED VIAL (GRAFO CSR) + A*
// ============================================================================

/// Grafo en formato CSR con arreglos tipados (poca memoria en equipos de 4 GB).
class RedVial {
  final Float64List lats, lons;
  final Int32List offs, dest;
  final Float32List dist;
  final Uint8List clase, contra;
  const RedVial(this.lats, this.lons, this.offs, this.dest, this.dist, this.clase, this.contra);

  int get nodos => lats.length;

  bool _tieneSalida(int i, Modo m) {
    for (var e = offs[i]; e < offs[i + 1]; e++) {
      if (m.velEnVia(ClaseVia.values[clase[e]]) > 0 && (contra[e] == 0 || m.ignoraSentido)) return true;
    }
    return false;
  }

  /// Nodo transitable más cercano a [c], o -1 si está a más de [maxM].
  int nodoCercano(LatLng c, Modo m, double maxM) {
    final kx = 111320.0 * math.cos(c.latitude * math.pi / 180.0);
    const ky = 110540.0;
    var mejor = -1;
    var mejorD2 = double.maxFinite;
    for (var i = 0; i < lats.length; i++) {
      final dx = (lons[i] - c.longitude) * kx, dy = (lats[i] - c.latitude) * ky;
      final d2 = dx * dx + dy * dy;
      if (d2 < mejorD2 && _tieneSalida(i, m)) {
        mejorD2 = d2;
        mejor = i;
      }
    }
    return (mejor >= 0 && math.sqrt(mejorD2) <= maxM) ? mejor : -1;
  }

  /// A* con costo en segundos y heurística = distancia / velocidad máxima del modo.
  ({List<int> nodos, double seg})? aStar(int origen, int destino, Modo modo) {
    if (origen == destino) return (nodos: [origen], seg: 0.0);
    final n = lats.length;
    final g = Float64List(n)..fillRange(0, n, double.infinity);
    final previo = Int32List(n)..fillRange(0, n, -1);
    final cerrado = Uint8List(n);
    final vMax = modo.velMax / 3.6;
    final latD = lats[destino], lonD = lons[destino];
    double h(int i) => Geo.dist(lats[i], lons[i], latD, lonD) / vMax;
    final clases = ClaseVia.values;

    final cola = _MonticuloMin();
    g[origen] = 0;
    cola.agregar(h(origen), origen);
    while (!cola.vacio) {
      final u = cola.sacar();
      if (cerrado[u] == 1) continue;
      if (u == destino) {
        final camino = <int>[];
        for (var c = destino; c != -1; c = previo[c]) {
          camino.add(c);
        }
        return (nodos: camino.reversed.toList(), seg: g[destino]);
      }
      cerrado[u] = 1;
      for (var e = offs[u]; e < offs[u + 1]; e++) {
        final v = dest[e];
        if (cerrado[v] == 1) continue;
        if (contra[e] == 1 && !modo.ignoraSentido) continue;
        final vel = modo.velEnVia(clases[clase[e]]);
        if (vel <= 0) continue;
        final nuevo = g[u] + dist[e] / (vel / 3.6);
        if (nuevo < g[v]) {
          g[v] = nuevo;
          previo[v] = u;
          cola.agregar(nuevo + h(v), v);
        }
      }
    }
    return null;
  }
}

/// Montículo binario mínimo (cola de prioridad) para A*.
class _MonticuloMin {
  final List<double> _f = [];
  final List<int> _v = [];
  bool get vacio => _f.isEmpty;

  void _swap(int a, int b) {
    final tf = _f[a];
    _f[a] = _f[b];
    _f[b] = tf;
    final tv = _v[a];
    _v[a] = _v[b];
    _v[b] = tv;
  }

  void agregar(double f, int v) {
    _f.add(f);
    _v.add(v);
    var i = _f.length - 1;
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (_f[p] <= _f[i]) break;
      _swap(i, p);
      i = p;
    }
  }

  int sacar() {
    final tope = _v[0];
    final lf = _f.removeLast();
    final lv = _v.removeLast();
    if (_f.isNotEmpty) {
      _f[0] = lf;
      _v[0] = lv;
      var i = 0;
      final n = _f.length;
      while (true) {
        final l = 2 * i + 1, r = l + 1;
        var m = i;
        if (l < n && _f[l] < _f[m]) m = l;
        if (r < n && _f[r] < _f[m]) m = r;
        if (m == i) break;
        _swap(i, m);
        i = m;
      }
    }
    return tope;
  }
}

void _recorrerLineas(dynamic c, void Function(List<dynamic>) alLinea) {
  if (c is! List || c.isEmpty) return;
  final primero = c.first;
  if (primero is List && primero.isNotEmpty && primero.first is num) {
    alLinea(c); // LineString
  } else {
    for (final e in c) {
      _recorrerLineas(e, alLinea); // MultiLineString
    }
  }
}

// Listas crecientes sobre arreglos tipados: ocupan ~4 veces menos memoria que List<double>/List<int>
// (importante para redes viales de un estado completo en equipos de 4 GB).
class _ListaI32 {
  Int32List _d = Int32List(4096);
  int length = 0;
  void add(int v) {
    if (length == _d.length) {
      final n = Int32List(_d.length * 2)..setRange(0, length, _d);
      _d = n;
    }
    _d[length++] = v;
  }

  int operator [](int i) => _d[i];
}

class _ListaU8 {
  Uint8List _d = Uint8List(4096);
  int length = 0;
  void add(int v) {
    if (length == _d.length) {
      final n = Uint8List(_d.length * 2)..setRange(0, length, _d);
      _d = n;
    }
    _d[length++] = v;
  }

  int operator [](int i) => _d[i];
}

class _ListaF32 {
  Float32List _d = Float32List(4096);
  int length = 0;
  void add(double v) {
    if (length == _d.length) {
      final n = Float32List(_d.length * 2)..setRange(0, length, _d);
      _d = n;
    }
    _d[length++] = v;
  }

  double operator [](int i) => _d[i];
}

class _ListaF64 {
  Float64List _d = Float64List(4096);
  int length = 0;
  void add(double v) {
    if (length == _d.length) {
      final n = Float64List(_d.length * 2)..setRange(0, length, _d);
      _d = n;
    }
    _d[length++] = v;
  }

  Float64List recortar() => _d.sublist(0, length);
}

/// ¿El archivo lo generó esta app (una vía por línea)? Entonces se puede leer en flujo.
Future<bool> _esGeoJsonPorLineas(File f) async {
  final raf = await f.open();
  try {
    final b = await raf.read(_cabeceraGeoJson.length + 1);
    return String.fromCharCodes(b) == '$_cabeceraGeoJson\n';
  } finally {
    await raf.close();
  }
}

/// Construye el grafo desde uno o varios GeoJSON de OSM. Se ejecuta en un isolate (no congela la UI).
/// Los archivos descargados por la app se leen línea por línea (poca memoria); cualquier otro
/// GeoJSON (p. ej. importado a mano) se carga completo, como antes.
Future<RedVial> construirRed(List<String> rutas) async {
  final claveANodo = <int, int>{};
  final lats = _ListaF64(), lons = _ListaF64();
  final ef = _ListaI32(), et = _ListaI32();
  final ec = _ListaU8(), ek = _ListaU8();
  final ed = _ListaF32();

  int nodo(double lat, double lon) {
    final k = ((lat * 1e6).round() + 90000000) * 400000000 + ((lon * 1e6).round() + 180000000);
    final e = claveANodo[k];
    if (e != null) return e;
    final n = lats.length;
    lats.add(lat);
    lons.add(lon);
    claveANodo[k] = n;
    return n;
  }

  void arista(int a, int b, double d, int clase, bool contra) {
    ef.add(a);
    et.add(b);
    ed.add(d);
    ec.add(clase);
    ek.add(contra ? 1 : 0);
  }

  void procesar(dynamic f) {
    if (f is! Map) return;
    final props = f['properties'];
    final geom = f['geometry'];
    if (props is! Map || geom is! Map) return;
    final claseVia = claseDesdeOsm(props['highway']?.toString());
    if (claseVia == null) return;
    final ow = props['oneway']?.toString();
    final junc = props['junction']?.toString();
    // 0 = ambos sentidos, 1 = adelante, 2 = atrás
    final int sentido = (ow == 'yes' || ow == 'true' || ow == '1' || (ow == null && junc == 'roundabout'))
        ? 1
        : (ow == '-1' || ow == 'reverse')
            ? 2
            : 0;
    _recorrerLineas(geom['coordinates'], (linea) {
      for (var i = 0; i < linea.length - 1; i++) {
        final a = linea[i], b = linea[i + 1];
        if (a is! List || b is! List || a.length < 2 || b.length < 2) continue;
        final lonA = (a[0] as num).toDouble(), latA = (a[1] as num).toDouble();
        final lonB = (b[0] as num).toDouble(), latB = (b[1] as num).toDouble();
        final ia = nodo(latA, lonA), ib = nodo(latB, lonB);
        if (ia == ib) continue;
        final d = Geo.dist(latA, lonA, latB, lonB);
        final ci = claseVia.index;
        if (sentido == 0) {
          arista(ia, ib, d, ci, false);
          arista(ib, ia, d, ci, false);
        } else if (sentido == 1) {
          arista(ia, ib, d, ci, false);
          arista(ib, ia, d, ci, true);
        } else {
          arista(ib, ia, d, ci, false);
          arista(ia, ib, d, ci, true);
        }
      }
    });
  }

  for (final ruta in rutas) {
    final archivo = File(ruta);
    if (await _esGeoJsonPorLineas(archivo)) {
      final lineas = archivo.openRead().transform(utf8.decoder).transform(const LineSplitter());
      await for (final linea in lineas) {
        var t = linea.trim();
        if (t.startsWith(',')) t = t.substring(1);
        if (!t.startsWith('{"type":"Feature"')) continue;
        try {
          procesar(jsonDecode(t));
        } on FormatException {
          continue;
        }
      }
    } else {
      final datos = jsonDecode(await archivo.readAsString());
      final features = datos is Map ? datos['features'] : datos;
      if (features is List) {
        for (final f in features) {
          procesar(f);
        }
      }
    }
  }
  if (ef.length == 0) {
    throw Exception("El archivo no contiene vías (LineString con propiedad 'highway').");
  }

  // Compactar a CSR
  final n = lats.length, m = ef.length;
  final offs = Int32List(n + 1);
  for (var e = 0; e < m; e++) {
    offs[ef[e] + 1]++;
  }
  for (var i = 0; i < n; i++) {
    offs[i + 1] += offs[i];
  }
  final pos = Int32List.fromList(offs.sublist(0, n));
  final dest = Int32List(m);
  final dist = Float32List(m);
  final clase = Uint8List(m);
  final contra = Uint8List(m);
  for (var e = 0; e < m; e++) {
    final q = pos[ef[e]]++;
    dest[q] = et[e];
    dist[q] = ed[e];
    clase[q] = ec[e];
    contra[q] = ek[e];
  }
  return RedVial(lats.recortar(), lons.recortar(), offs, dest, dist, clase, contra);
}

/// Motor de enrutamiento local: A* con red vial cargada; línea recta como respaldo.
class MotorRutas {
  RedVial? red;
  static const double _maxAjusteM = 3000;

  Future<int> cargar(List<String> rutas) async {
    final nueva = await Isolate.run(() => construirRed(rutas));
    red = nueva;
    return nueva.nodos;
  }

  Future<Ruta> calcular(LatLng o, LatLng d, Modo modo) async {
    await Future<void>.delayed(Duration.zero); // deja pintar el indicador de "calculando"
    final r = red;
    if (r != null) {
      final no = r.nodoCercano(o, modo, _maxAjusteM);
      final nd = r.nodoCercano(d, modo, _maxAjusteM);
      if (no >= 0 && nd >= 0) {
        final camino = r.aStar(no, nd, modo);
        if (camino != null) {
          final pts = <LatLng>[o];
          for (final n in camino.nodos) {
            final c = LatLng(r.lats[n], r.lons[n]);
            if (Geo.distLL(pts.last, c) > 0.5) pts.add(c);
          }
          if (Geo.distLL(pts.last, d) > 0.5) pts.add(d);
          final vProm = modo.velProm / 3.6;
          final extra = (Geo.distLL(o, LatLng(r.lats[camino.nodos.first], r.lons[camino.nodos.first])) +
                  Geo.distLL(LatLng(r.lats[camino.nodos.last], r.lons[camino.nodos.last]), d)) /
              vProm;
          return _armar(pts, camino.seg + extra, false, modo);
        }
      }
    }
    final dist = Geo.distLL(o, d);
    return _armar([o, d], dist / (modo.velProm / 3.6), true, modo);
  }

  Ruta _armar(List<LatLng> entrada, double seg, bool aprox, Modo modo) {
    final pts = entrada.length < 2 ? [entrada[0], entrada[0]] : entrada;
    final acum = List<double>.filled(pts.length, 0);
    for (var i = 1; i < pts.length; i++) {
      acum[i] = acum[i - 1] + Geo.distLL(pts[i - 1], pts[i]);
    }
    return Ruta(pts, acum, acum.last, seg, generarManiobras(pts, acum), aprox, modo);
  }
}

// ============================================================================
// 5. BASE DE DATOS LOCAL (SQLite)
// ============================================================================

class Poi {
  final int? id;
  final String nombre, categoria;
  final double lat, lon;
  final int creadoMs;
  const Poi({this.id, required this.nombre, required this.categoria, required this.lat, required this.lon, required this.creadoMs});
  Map<String, Object?> toMap() =>
      {'id': id, 'nombre': nombre, 'categoria': categoria, 'lat': lat, 'lon': lon, 'creadoMs': creadoMs};
  factory Poi.deMap(Map<String, Object?> m) => Poi(
      id: m['id'] as int?,
      nombre: m['nombre'] as String,
      categoria: m['categoria'] as String,
      lat: (m['lat'] as num).toDouble(),
      lon: (m['lon'] as num).toDouble(),
      creadoMs: m['creadoMs'] as int);
}

class RutaFrec {
  final int? id;
  final String nombre, destinoNombre, modo;
  final double lat, lon;
  final int veces, ultimoUsoMs;
  const RutaFrec(
      {this.id,
      required this.nombre,
      required this.destinoNombre,
      required this.lat,
      required this.lon,
      required this.modo,
      this.veces = 0,
      this.ultimoUsoMs = 0});
  Map<String, Object?> toMap() => {
        'id': id,
        'nombre': nombre,
        'destinoNombre': destinoNombre,
        'lat': lat,
        'lon': lon,
        'modo': modo,
        'veces': veces,
        'ultimoUsoMs': ultimoUsoMs
      };
  factory RutaFrec.deMap(Map<String, Object?> m) => RutaFrec(
      id: m['id'] as int?,
      nombre: m['nombre'] as String,
      destinoNombre: m['destinoNombre'] as String,
      lat: (m['lat'] as num).toDouble(),
      lon: (m['lon'] as num).toDouble(),
      modo: m['modo'] as String,
      veces: m['veces'] as int,
      ultimoUsoMs: m['ultimoUsoMs'] as int);
}

class Hist {
  final int id;
  final int inicioMs;
  final int? finMs;
  final String destinoNombre, modo;
  final double plan, recorrido;
  final bool completada;
  const Hist(this.id, this.inicioMs, this.finMs, this.destinoNombre, this.modo, this.plan, this.recorrido, this.completada);
  factory Hist.deMap(Map<String, Object?> m) => Hist(
      m['id'] as int,
      m['inicioMs'] as int,
      m['finMs'] as int?,
      m['destinoNombre'] as String,
      m['modo'] as String,
      (m['planM'] as num).toDouble(),
      (m['recorridoM'] as num).toDouble(),
      (m['completada'] as int) == 1);
}

class Datos {
  late Database db;

  Future<void> abrir() async {
    final ruta = ruta_p.join(await getDatabasesPath(), 'navegacion_offline.db');
    db = await openDatabase(ruta, version: 1, onCreate: (d, v) async {
      await d.execute('CREATE TABLE puntos_interes(id INTEGER PRIMARY KEY AUTOINCREMENT, nombre TEXT NOT NULL, '
          'categoria TEXT NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL, creadoMs INTEGER NOT NULL)');
      await d.execute('CREATE TABLE rutas_frecuentes(id INTEGER PRIMARY KEY AUTOINCREMENT, nombre TEXT NOT NULL, '
          'destinoNombre TEXT NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL, modo TEXT NOT NULL, '
          'veces INTEGER NOT NULL DEFAULT 0, ultimoUsoMs INTEGER NOT NULL DEFAULT 0)');
      await d.execute('CREATE TABLE historial(id INTEGER PRIMARY KEY AUTOINCREMENT, inicioMs INTEGER NOT NULL, '
          'finMs INTEGER, destinoNombre TEXT NOT NULL, modo TEXT NOT NULL, planM REAL NOT NULL, '
          'recorridoM REAL NOT NULL DEFAULT 0, completada INTEGER NOT NULL DEFAULT 0)');
    });
  }

  Future<List<Poi>> pois() async =>
      (await db.query('puntos_interes', orderBy: 'creadoMs DESC')).map(Poi.deMap).toList();
  Future<void> insertarPoi(Poi p) async => db.insert('puntos_interes', p.toMap()..remove('id'));
  Future<void> eliminarPoi(int id) async => db.delete('puntos_interes', where: 'id = ?', whereArgs: [id]);

  Future<List<RutaFrec>> rutas() async =>
      (await db.query('rutas_frecuentes', orderBy: 'veces DESC, ultimoUsoMs DESC')).map(RutaFrec.deMap).toList();
  Future<void> insertarRuta(RutaFrec r) async => db.insert('rutas_frecuentes', r.toMap()..remove('id'));
  Future<void> eliminarRuta(int id) async => db.delete('rutas_frecuentes', where: 'id = ?', whereArgs: [id]);
  Future<void> usoRuta(int id) async => db.rawUpdate(
      'UPDATE rutas_frecuentes SET veces = veces + 1, ultimoUsoMs = ? WHERE id = ?',
      [DateTime.now().millisecondsSinceEpoch, id]);

  Future<List<Hist>> historial() async =>
      (await db.query('historial', orderBy: 'inicioMs DESC', limit: 100)).map(Hist.deMap).toList();
  Future<int> iniciarHistorial(String destino, String modo, double planM) => db.insert('historial', {
        'inicioMs': DateTime.now().millisecondsSinceEpoch,
        'destinoNombre': destino,
        'modo': modo,
        'planM': planM
      });
  Future<void> finalizarHistorial(int id, double recorridoM, bool ok) async => db.update(
      'historial', {'finMs': DateTime.now().millisecondsSinceEpoch, 'recorridoM': recorridoM, 'completada': ok ? 1 : 0},
      where: 'id = ?', whereArgs: [id]);
  Future<void> podarHistorial() async => db.rawDelete(
      'DELETE FROM historial WHERE id NOT IN (SELECT id FROM historial ORDER BY inicioMs DESC LIMIT 500)');
  Future<void> borrarHistorial() async => db.delete('historial');
}

// ============================================================================
// 6. VOZ: TEXT-TO-SPEECH CON AUDIO FOCUS Y SPEECH-TO-TEXT
// ============================================================================

/// Guía por voz. flutter_tts pide el foco de audio de Android (focus: true) al hablar y lo libera al
/// terminar: la música baja/pausa durante la instrucción y se reanuda después; no habla sobre una llamada.
class GuiaVoz {
  final FlutterTts _tts = FlutterTts();
  bool habilitado = true;
  void Function(String)? alError;
  Future<void> _cola = Future<void>.value();
  int _gen = 0;

  Future<void> iniciar() async {
    try {
      try {
        await _tts.setEngine('com.google.android.tts'); // solo el sintetizador de voz de Google
      } catch (_) {}
      final okMx = await _tts.isLanguageAvailable('es-MX');
      if (okMx == true || okMx == 1) {
        await _tts.setLanguage('es-MX');
      } else {
        final okEs = await _tts.isLanguageAvailable('es-ES');
        if (okEs == true || okEs == 1) {
          await _tts.setLanguage('es-ES');
        } else {
          alError?.call('Falta la voz en español. Instálala en Ajustes > Salida de texto a voz.');
        }
      }
      await _tts.setSpeechRate(0.5);
      await _tts.awaitSpeakCompletion(true);
      await _tts.setAudioAttributesForNavigation(); // USAGE_ASSISTANCE_NAVIGATION_GUIDANCE
    } catch (e) {
      alError?.call('No se pudo iniciar la voz: $e');
    }
  }

  /// Dicta [texto]; con [urgente] interrumpe lo anterior (p. ej. "recalculando").
  void hablar(String texto, {bool urgente = false}) {
    if (!habilitado || texto.trim().isEmpty) return;
    if (urgente) {
      _gen++;
      _tts.stop();
    }
    final gen = _gen;
    _cola = _cola.then((_) async {
      if (gen != _gen) return;
      try {
        await _tts.speak(texto, focus: true);
      } catch (_) {}
    });
  }

  Future<void> silenciar() async {
    _gen++;
    await _tts.stop();
  }
}

/// Reconocimiento de voz 100 % SIN INTERNET con Vosk (paquete vosk_flutter).
/// El modelo en español viaja dentro de los assets de la app (assets/models/...zip): no depende de
/// Google, no pide descargar idiomas y no necesita red ni servicios del sistema.
class Escucha {
  static const String _modeloNombre = 'vosk-model-small-es-0.42';
  static const String _modeloAsset = 'assets/models/$_modeloNombre.zip';
  static const int _frecuencia = 16000;
  static const Duration _tiempoMax = Duration(seconds: 8);

  final vosk.VoskFlutterPlugin _vosk = vosk.VoskFlutterPlugin.instance();
  vosk.Model? _modelo;
  vosk.Recognizer? _reconocedor;
  vosk.SpeechService? _servicio;
  StreamSubscription<String>? _subResultado;
  Timer? _limite;
  Future<void>? _carga;
  bool voskListo = false;
  bool _activo = false;
  String estadoModelo = 'Cargando modelo de voz…';

  /// Carga el modelo una sola vez (la primera vez descomprime el .zip, tarda unos segundos).
  /// Si falla, la siguiente llamada vuelve a intentarlo.
  Future<void> cargarModelo() {
    final actual = _carga;
    if (actual != null) return actual;
    final nueva = _cargar();
    _carga = nueva;
    return nueva;
  }

  /// Busca el modelo ya descomprimido (carpeta con subcarpeta "am") en Descargas o en la app.
  /// Sirve de respaldo cuando el .zip no viaja dentro de los assets del APK.
  Future<String?> _buscarModeloLocal() async {
    final candidatas = <String>['/storage/emulated/0/Download/$_modeloNombre'];
    try {
      candidatas.add(ruta_p.join((await getApplicationSupportDirectory()).path, _modeloNombre));
      candidatas.add(ruta_p.join((await getApplicationDocumentsDirectory()).path, _modeloNombre));
    } catch (_) {}
    for (final c in candidatas) {
      try {
        if (Directory(ruta_p.join(c, 'am')).existsSync()) return c;
      } catch (_) {}
    }
    return null;
  }

  Future<void> _cargar() async {
    String? ruta;
    Object? errorAsset;
    try {
      // 1) Modelo empaquetado en la app (assets/models/vosk-model-small-es-0.42.zip)
      ruta = await vosk.ModelLoader().loadFromAssets(_modeloAsset);
    } catch (e) {
      errorAsset = e;
      // 2) Respaldo: carpeta ya descomprimida en Descargas o en el almacenamiento de la app
      ruta = await _buscarModeloLocal();
    }
    if (ruta == null) {
      voskListo = false;
      _carga = null; // permite reintentar
      estadoModelo = 'Falta el modelo de voz: agrega $_modeloAsset a la app '
          '(o copia la carpeta $_modeloNombre a Descargas). Detalle: $errorAsset';
      return;
    }
    try {
      final modelo = await _vosk.createModel(ruta);
      _modelo = modelo;
      _reconocedor = await _vosk.createRecognizer(model: modelo, sampleRate: _frecuencia);
      voskListo = true;
      estadoModelo = 'Vosk español (sin conexión) listo';
    } catch (e) {
      voskListo = false;
      _carga = null; // permite reintentar
      estadoModelo = 'No se pudo iniciar el modelo de voz: $e';
    }
  }

  String _texto(String json) {
    try {
      final m = jsonDecode(json);
      return m is Map ? '${m['text'] ?? ''}'.trim() : '';
    } catch (_) {
      return '';
    }
  }

  Future<void> _terminar(void Function(bool) alEstado) async {
    _limite?.cancel();
    _limite = null;
    _activo = false;
    alEstado(false);
    try {
      await _servicio?.stop();
    } catch (_) {}
  }

  Future<void> escuchar({
    required void Function(String) alResultado,
    required void Function(String) alError,
    required void Function(bool) alEstado,
  }) async {
    await cargarModelo();
    final reconocedor = _reconocedor;
    if (!voskListo || reconocedor == null) {
      alError('Falta el modelo de voz sin conexión. Mira Ajustes › Reconocimiento de voz.');
      return;
    }
    try {
      final servicio = _servicio ??= await _vosk.initSpeechService(reconocedor);
      await _subResultado?.cancel();
      var entregado = false;
      _subResultado = servicio.onResult().listen((r) {
        if (entregado) return;
        final t = _texto(r);
        if (t.isEmpty) return;
        entregado = true;
        _terminar(alEstado);
        alResultado(t);
      });
      alEstado(true);
      _activo = true;
      await servicio.start();
      _limite?.cancel();
      _limite = Timer(_tiempoMax, () {
        if (entregado) return;
        entregado = true;
        _terminar(alEstado);
        alError('No te escuché, intenta de nuevo.');
      });
    } catch (e) {
      await _terminar(alEstado);
      alError('Voz: $e');
    }
  }

  Future<void> cancelar() async {
    _limite?.cancel();
    _limite = null;
    await _subResultado?.cancel();
    _subResultado = null;
    if (_activo) {
      _activo = false;
      try {
        await _servicio?.stop();
      } catch (_) {}
    }
  }
}

// ---- Comandos de voz ----
sealed class Cmd {
  const Cmd();
}

class CmdIniciar extends Cmd {
  const CmdIniciar();
}

class CmdCancelar extends Cmd {
  const CmdCancelar();
}

class CmdModo extends Cmd {
  final Modo modo;
  const CmdModo(this.modo);
}

class CmdEstado extends Cmd {
  const CmdEstado();
}

class CmdRepetir extends Cmd {
  const CmdRepetir();
}

class CmdGuardarAqui extends Cmd {
  const CmdGuardarAqui();
}

class CmdIrA extends Cmd {
  final String nombre;
  const CmdIrA(this.nombre);
}

class CmdSilenciar extends Cmd {
  const CmdSilenciar();
}

class CmdActivarVoz extends Cmd {
  const CmdActivarVoz();
}

class CmdDesconocido extends Cmd {
  final String texto;
  const CmdDesconocido(this.texto);
}

Cmd interpretarComando(String original) {
  final t = Fmt.normalizar(original);
  bool tiene(List<String> claves) => claves.any(t.contains);
  final irA = RegExp(r'(?:llevame|navega|navegar|ruta|ir|vamos|dirigete)\s+(?:a|al|hacia)\s+(?:la\s+|el\s+|los\s+|las\s+)?(.+)')
      .firstMatch(t);

  if (tiene(['cancelar', 'detener nav', 'terminar nav', 'parar nav', 'finalizar'])) return const CmdCancelar();
  if (tiene(['modo', 'cambia', 'voy en', 'voy a pie'])) {
    Modo? m;
    if (tiene(['transporte', 'camion', 'autobus', 'publico'])) {
      m = Modo.transporte;
    } else if (t.contains('bici')) {
      m = Modo.bici;
    } else if (t.contains('moto')) {
      m = Modo.moto;
    } else if (tiene(['camin', 'pie', 'peaton'])) {
      m = Modo.pie;
    } else if (tiene(['auto', 'carro', 'coche'])) {
      m = Modo.auto;
    }
    return m != null ? CmdModo(m) : CmdDesconocido(original);
  }
  if (irA != null) {
    final nombre = (irA.group(1) ?? '').trim();
    return nombre.isNotEmpty ? CmdIrA(nombre) : CmdDesconocido(original);
  }
  if (tiene(['guardar', 'guarda', 'marca']) && tiene(['punto', 'lugar', 'aqui', 'ubicacion'])) {
    return const CmdGuardarAqui();
  }
  if (tiene(['iniciar', 'comenzar', 'empezar', 'arrancar'])) return const CmdIniciar();
  if (tiene(['cuanto falta', 'cuanta distancia', 'distancia', 'tiempo', 'llegada'])) return const CmdEstado();
  if (tiene(['repite', 'repetir', 'otra vez'])) return const CmdRepetir();
  if (tiene(['silencia', 'callate', 'sin voz', 'apaga voz'])) return const CmdSilenciar();
  if (tiene(['activa voz', 'enciende voz', 'con voz', 'activar voz'])) return const CmdActivarVoz();
  return CmdDesconocido(original);
}

// ============================================================================
// 7. MAPA OFFLINE: PROVEEDOR DE TESELAS MBTILES (RASTER)
// ============================================================================
//
//  CAUSA DEL FONDO MORADO: antes, cuando una tesela no existía, se devolvía un PNG de 1x1 que en
//  realidad era un píxel AZUL semitransparente. Al estirarse a toda la pantalla sobre el fondo gris
//  daba exactamente ese morado. Ahora la tesela vacía es un píxel 100 % TRANSPARENTE (se ve el
//  fondo gris) y nunca se lanza una excepción que rompa el renderizado.

/// Tesela sin datos: 1x1 RGBA totalmente transparente (píxeles crudos, sin PNG de por medio).
Future<ui.Codec> _codecTransparente() async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(Uint8List(4)); // R,G,B,A = 0
  final descriptor = ui.ImageDescriptor.raw(buffer, width: 1, height: 1, pixelFormat: ui.PixelFormat.rgba8888);
  return descriptor.instantiateCodec();
}

class _ImagenMbTile extends ImageProvider<_ImagenMbTile> {
  final List<Database> bases;
  final int x, y, z;
  const _ImagenMbTile(this.bases, this.x, this.y, this.z);

  /// Lee la tesela de la tabla `tiles` (zoom_level, tile_column, tile_row, tile_data).
  Future<Uint8List?> _leer() async {
    // MBTiles usa esquema TMS (Y invertida); flutter_map usa XYZ  →  y_tms = (1 << z) - 1 - y
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
    return null; // no existe en la base offline
  }

  Future<ui.Codec> _decodificar(ImageDecoderCallback decode) async {
    try {
      final datos = await _leer();
      if (datos == null) return _codecTransparente();
      final buffer = await ui.ImmutableBuffer.fromUint8List(datos);
      return await decode(buffer); // el await permite atrapar datos corruptos
    } catch (_) {
      return _codecTransparente();
    }
  }

  @override
  Future<_ImagenMbTile> obtainKey(ImageConfiguration configuration) => SynchronousFuture<_ImagenMbTile>(this);

  @override
  ImageStreamCompleter loadImage(_ImagenMbTile key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _decodificar(decode), scale: 1.0);

  @override
  bool operator ==(Object other) =>
      other is _ImagenMbTile && other.x == x && other.y == y && other.z == z && identical(other.bases, bases);

  @override
  int get hashCode => Object.hash(x, y, z, identityHashCode(bases));
}

class ProveedorMbTiles extends TileProvider {
  final List<Database> bases;
  ProveedorMbTiles(this.bases);

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      _ImagenMbTile(bases, coordinates.x, coordinates.y, coordinates.z);
}

// ============================================================================
// 7B. DESCARGA DE MAPAS Y RED VIAL (Overpass · Nominatim · servidor de teselas)
// ============================================================================
//
//  Fuentes PÚBLICAS (la app solo necesita internet mientras descarga):
//   · Red vial ....... Overpass API (datos de OpenStreetMap, licencia ODbL).
//   · Municipios ..... Nominatim (buscador de OpenStreetMap).
//   · Mapas raster ... el servidor de teselas XYZ que el usuario indique (ver panel de Ajustes).
//  Todo se guarda en el almacenamiento de la app y después funciona SIN internet.

const String _agenteHttp = 'NavegacionOfflineMX/1.0 (app de campo; descarga bajo demanda)';

/// Primera línea de los GeoJSON que genera la app (una vía por línea → lectura en flujo).
const String _cabeceraGeoJson = '{"type":"FeatureCollection","features":[';

class ErrorDescarga implements Exception {
  final String mensaje;
  const ErrorDescarga(this.mensaje);
  @override
  String toString() => mensaje;
}

class _ErrorHttp implements Exception {
  final int codigo;
  const _ErrorHttp(this.codigo);
}

// ---------------------------------------------------------------- catálogo
class EstadoMx {
  final String nombre, iso;
  const EstadoMx(this.nombre, this.iso);
}

/// Los 32 estados con su código ISO 3166-2 (así se identifican en OpenStreetMap).
const List<EstadoMx> estadosMx = [
  EstadoMx('Aguascalientes', 'MX-AGU'),
  EstadoMx('Baja California', 'MX-BCN'),
  EstadoMx('Baja California Sur', 'MX-BCS'),
  EstadoMx('Campeche', 'MX-CAM'),
  EstadoMx('Chiapas', 'MX-CHP'),
  EstadoMx('Chihuahua', 'MX-CHH'),
  EstadoMx('Ciudad de México', 'MX-CMX'),
  EstadoMx('Coahuila', 'MX-COA'),
  EstadoMx('Colima', 'MX-COL'),
  EstadoMx('Durango', 'MX-DUR'),
  EstadoMx('Guanajuato', 'MX-GUA'),
  EstadoMx('Guerrero', 'MX-GRO'),
  EstadoMx('Hidalgo', 'MX-HID'),
  EstadoMx('Jalisco', 'MX-JAL'),
  EstadoMx('México (Edo. de)', 'MX-MEX'),
  EstadoMx('Michoacán', 'MX-MIC'),
  EstadoMx('Morelos', 'MX-MOR'),
  EstadoMx('Nayarit', 'MX-NAY'),
  EstadoMx('Nuevo León', 'MX-NLE'),
  EstadoMx('Oaxaca', 'MX-OAX'),
  EstadoMx('Puebla', 'MX-PUE'),
  EstadoMx('Querétaro', 'MX-QUE'),
  EstadoMx('Quintana Roo', 'MX-ROO'),
  EstadoMx('San Luis Potosí', 'MX-SLP'),
  EstadoMx('Sinaloa', 'MX-SIN'),
  EstadoMx('Sonora', 'MX-SON'),
  EstadoMx('Tabasco', 'MX-TAB'),
  EstadoMx('Tamaulipas', 'MX-TAM'),
  EstadoMx('Tlaxcala', 'MX-TLA'),
  EstadoMx('Veracruz', 'MX-VER'),
  EstadoMx('Yucatán', 'MX-YUC'),
  EstadoMx('Zacatecas', 'MX-ZAC'),
];

enum Alcance { pais, estado, municipio }

/// Cuánto detalle vial se descarga (a más detalle, archivo más grande).
enum Detalle {
  troncal('Solo carreteras principales',
      'motorway|motorway_link|trunk|trunk_link|primary|primary_link'),
  principal('Principal (+ secundarias y terciarias)',
      'motorway|motorway_link|trunk|trunk_link|primary|primary_link|secondary|secondary_link|tertiary|tertiary_link'),
  estandar('Estándar (+ calles, brechas y terracerías)',
      'motorway|motorway_link|trunk|trunk_link|primary|primary_link|secondary|secondary_link|tertiary|tertiary_link|'
          'unclassified|residential|living_street|track'),
  completo('Completo (+ servicio, veredas, ciclovías y peatonal)',
      'motorway|motorway_link|trunk|trunk_link|primary|primary_link|secondary|secondary_link|tertiary|tertiary_link|'
          'unclassified|residential|living_street|track|service|footway|pedestrian|steps|path|cycleway|bridleway');

  const Detalle(this.etiqueta, this.filtro);
  final String etiqueta;
  final String filtro; // valores de la etiqueta "highway" de OSM
}

/// Zona geográfica: relación administrativa de OSM + su rectángulo envolvente.
class Zona {
  final String nombre;
  final int relId;
  final double sur, oeste, norte, este;
  const Zona(this.nombre, this.relId, this.sur, this.oeste, this.norte, this.este);
  int get areaId => 3600000000 + relId; // id de "área" en Overpass
}

/// Rectángulo aproximado de México (solo para teselas; no se usa en consultas Overpass).
const Zona zonaMexico = Zona('México', 114686, 14.3, -118.7, 32.8, -86.6);

// ---------------------------------------------------------------- HTTP
class ClienteHttp {
  static final HttpClient _cliente = HttpClient()
    ..userAgent = _agenteHttp
    ..connectionTimeout = const Duration(seconds: 20);

  /// Descarga el cuerpo completo. Con [cuerpo] hace POST de formulario; sin él, GET.
  static Future<Uint8List> bytes(Uri url, {String? cuerpo, Duration limite = const Duration(seconds: 240)}) async {
    final req = await (cuerpo == null ? _cliente.getUrl(url) : _cliente.postUrl(url)).timeout(const Duration(seconds: 30));
    req.headers.set(HttpHeaders.acceptLanguageHeader, 'es');
    if (cuerpo != null) {
      req.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      final cb = utf8.encode(cuerpo);
      req.contentLength = cb.length;
      req.add(cb);
    }
    final resp = await req.close().timeout(limite);
    if (resp.statusCode != 200) {
      await resp.drain<void>();
      throw _ErrorHttp(resp.statusCode);
    }
    final acumulado = BytesBuilder(copy: false);
    await for (final parte in resp.timeout(limite)) {
      acumulado.add(parte);
    }
    return acumulado.takeBytes();
  }
}

// ---------------------------------------------------------------- Overpass
class Overpass {
  static const List<String> _servidores = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
    'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
  ];
  int _turno = 0;

  /// Ejecuta una consulta Overpass QL. Reintenta y rota de servidor si hay saturación o fallas.
  Future<Map<String, dynamic>> consultar(String ql, bool Function() cancelado) async {
    String ultimo = 'sin detalle';
    for (var intento = 0; intento < 6; intento++) {
      if (cancelado()) throw const ErrorDescarga('Descarga cancelada.');
      final url = Uri.parse(_servidores[_turno % _servidores.length]);
      try {
        final datos = await ClienteHttp.bytes(url, cuerpo: 'data=${Uri.encodeQueryComponent(ql)}');
        final j = jsonDecode(utf8.decode(datos));
        if (j is Map<String, dynamic>) {
          final remark = '${j['remark'] ?? ''}';
          if (remark.contains('runtime error') || remark.contains('out of memory')) {
            throw const _ErrorHttp(504); // el servidor cortó la consulta: se trata como saturación
          }
          return j;
        }
        ultimo = 'respuesta inesperada';
      } on _ErrorHttp catch (e) {
        if (e.codigo == 400) throw const ErrorDescarga('Overpass rechazó la consulta (error 400).');
        ultimo = 'HTTP ${e.codigo}';
      } on TimeoutException {
        ultimo = 'tiempo agotado';
      } on SocketException {
        ultimo = 'sin conexión a internet';
      } on HandshakeException {
        ultimo = 'error de conexión segura';
      } on HttpException catch (e) {
        ultimo = e.message;
      } on FormatException {
        ultimo = 'respuesta incompleta';
      }
      _turno++;
      await Future<void>.delayed(Duration(seconds: 4 * (intento + 1)));
    }
    throw ErrorDescarga('Overpass no respondió ($ultimo). Revisa tu internet e inténtalo de nuevo.');
  }
}

// ---------------------------------------------------------------- zonas
class Catalogo {
  final Overpass _op;
  Catalogo(this._op);

  /// Un estado (o los 32 si [uno] es null) con su rectángulo envolvente, desde OpenStreetMap.
  Future<List<Zona>> estados({EstadoMx? uno, required bool Function() cancelado}) async {
    final filtro = uno == null ? '["ISO3166-2"~"^MX-"]' : '["ISO3166-2"="${uno.iso}"]';
    final j = await _op.consultar(
        '[out:json][timeout:90];rel$filtro["boundary"="administrative"]["admin_level"="4"];out bb;', cancelado);
    final r = <Zona>[];
    final els = j['elements'];
    if (els is List) {
      for (final e in els) {
        if (e is! Map || e['type'] != 'relation') continue;
        final b = e['bounds'];
        if (b is! Map) continue;
        final tags = e['tags'];
        final nombre = tags is Map ? '${tags['name'] ?? tags['ISO3166-2'] ?? e['id']}' : '${e['id']}';
        r.add(Zona(nombre, (e['id'] as num).toInt(), (b['minlat'] as num).toDouble(), (b['minlon'] as num).toDouble(),
            (b['maxlat'] as num).toDouble(), (b['maxlon'] as num).toDouble()));
      }
    }
    if (r.isEmpty) {
      throw ErrorDescarga(uno == null
          ? 'No pude obtener la lista de estados desde OpenStreetMap.'
          : 'No encontré ${uno.nombre} en OpenStreetMap.');
    }
    return r;
  }

  /// Busca municipios por nombre dentro de un estado (Nominatim, máx. 1 consulta por pulsación).
  Future<List<Zona>> buscarMunicipios(String texto, EstadoMx estado) async {
    final url = Uri.https('nominatim.openstreetmap.org', '/search', {
      'q': '${texto.trim()}, ${estado.nombre}, México',
      'format': 'jsonv2',
      'countrycodes': 'mx',
      'limit': '10',
      'accept-language': 'es',
    });
    try {
      final datos = await ClienteHttp.bytes(url, limite: const Duration(seconds: 30));
      final lista = jsonDecode(utf8.decode(datos));
      final r = <Zona>[];
      if (lista is List) {
        for (final e in lista) {
          if (e is! Map || e['osm_type'] != 'relation') continue;
          final bb = e['boundingbox'];
          if (bb is! List || bb.length < 4) continue;
          final s = double.tryParse('${bb[0]}'), n = double.tryParse('${bb[1]}');
          final w = double.tryParse('${bb[2]}'), o = double.tryParse('${bb[3]}');
          final id = e['osm_id'];
          if (s == null || n == null || w == null || o == null || id is! num) continue;
          final nombre = '${e['display_name'] ?? e['name'] ?? id}'.split(',').take(2).join(',').trim();
          r.add(Zona(nombre, id.toInt(), s, w, n, o));
        }
      }
      return r;
    } on _ErrorHttp catch (e) {
      throw ErrorDescarga(e.codigo == 429
          ? 'El buscador pide esperar un momento. Intenta de nuevo en unos segundos.'
          : 'El buscador de lugares respondió ${e.codigo}.');
    } on TimeoutException {
      throw const ErrorDescarga('El buscador de lugares tardó demasiado. Revisa tu internet.');
    } on IOException {
      throw const ErrorDescarga('Sin conexión a internet.');
    } on FormatException {
      throw const ErrorDescarga('Respuesta inválida del buscador de lugares.');
    }
  }
}

// ---------------------------------------------------------------- red vial
class _Celda {
  final Zona zona;
  final double s, w, n, e;
  const _Celda(this.zona, this.s, this.w, this.n, this.e);
  double get lado => math.max(n - s, e - w);
}

/// Descarga las vías de OSM por bloques y las guarda como GeoJSON con UNA VÍA POR LÍNEA.
/// Si un bloque trae demasiadas vías (ciudad densa) lo divide en 4 y vuelve a pedirlo,
/// así ningún bloque llega a ser tan grande como para agotar la memoria del teléfono.
class DescargadorRed {
  static const int _maxViasPorBloque = 6000;
  final Overpass _op;
  DescargadorRed(this._op);

  static List<_Celda> bloquesIniciales(List<Zona> zonas) {
    const paso = 1.0;
    final r = <_Celda>[];
    for (final z in zonas) {
      for (var s = z.sur; s < z.norte; s += paso) {
        for (var w = z.oeste; w < z.este; w += paso) {
          r.add(_Celda(z, s, w, math.min(s + paso, z.norte), math.min(w + paso, z.este)));
        }
      }
      if (r.isEmpty || !identical(r.last.zona, z)) {
        r.add(_Celda(z, z.sur, z.oeste, z.norte + 0.01, z.este + 0.01)); // zona diminuta
      }
    }
    return r;
  }

  String _consulta(_Celda c, Detalle d) {
    final caja = '${c.s.toStringAsFixed(5)},${c.w.toStringAsFixed(5)},${c.n.toStringAsFixed(5)},${c.e.toStringAsFixed(5)}';
    return '[out:json][timeout:180];area(${c.zona.areaId})->.a;'
        'way(area.a)["highway"~"^(${d.filtro})\$"]($caja);out geom qt $_maxViasPorBloque;';
  }

  /// Devuelve cuántas vías se guardaron.
  Future<int> descargar({
    required List<Zona> zonas,
    required Detalle detalle,
    required File salida,
    required void Function(double, String) progreso,
    required bool Function() cancelado,
  }) async {
    final cola = bloquesIniciales(zonas);
    final vistos = <int>{};
    var i = 0, vias = 0, primero = true;
    final sink = salida.openWrite();
    try {
      sink.write('$_cabeceraGeoJson\n');
      while (i < cola.length) {
        if (cancelado()) throw const ErrorDescarga('Descarga cancelada.');
        final c = cola[i++];
        final j = await _op.consultar(_consulta(c, detalle), cancelado);
        final els = j['elements'];
        final List lista = els is List ? els : <dynamic>[];
        if (lista.length >= _maxViasPorBloque && c.lado > 0.01) {
          final mf = (c.s + c.n) / 2, mw = (c.w + c.e) / 2;
          cola.add(_Celda(c.zona, c.s, c.w, mf, mw));
          cola.add(_Celda(c.zona, c.s, mw, mf, c.e));
          cola.add(_Celda(c.zona, mf, c.w, c.n, mw));
          cola.add(_Celda(c.zona, mf, mw, c.n, c.e));
        } else {
          for (final e in lista) {
            if (e is! Map || e['type'] != 'way') continue;
            final id = e['id'];
            if (id is! int || vistos.contains(id)) continue;
            final tags = e['tags'];
            final geom = e['geometry'];
            if (tags is! Map || geom is! List) continue;
            final hw = '${tags['highway']}';
            if (claseDesdeOsm(hw) == null) continue;
            final coords = StringBuffer();
            var k = 0;
            for (final p in geom) {
              if (p is! Map) continue;
              final lat = p['lat'], lon = p['lon'];
              if (lat is! num || lon is! num) continue;
              if (k++ > 0) coords.write(',');
              coords.write('[${lon.toStringAsFixed(6)},${lat.toStringAsFixed(6)}]');
            }
            if (k < 2) continue;
            vistos.add(id);
            final linea = StringBuffer(primero ? '' : ',');
            primero = false;
            linea.write('{"type":"Feature","properties":{"highway":"$hw"');
            final ow = tags['oneway'];
            if (ow != null) linea.write(',"oneway":${jsonEncode('$ow')}');
            final jn = tags['junction'];
            if (jn != null) linea.write(',"junction":${jsonEncode('$jn')}');
            linea.write('},"geometry":{"type":"LineString","coordinates":[$coords]}}');
            sink.writeln(linea.toString());
            vias++;
          }
          await sink.flush();
        }
        progreso(i / cola.length, 'Red vial: ${c.zona.nombre} · bloque $i de ${cola.length} · $vias vías');
        await Future<void>.delayed(const Duration(milliseconds: 500)); // cortesía con el servidor público
      }
      sink.write(']}\n');
    } finally {
      await sink.close();
    }
    if (vias == 0) {
      throw const ErrorDescarga('OpenStreetMap no tiene vías con ese nivel de detalle en la zona elegida.');
    }
    return vias;
  }
}

// ---------------------------------------------------------------- mapas (MBTiles)
class Teselas {
  static int x(double lon, int z) {
    final n = 1 << z;
    return math.max(0, math.min(n - 1, ((lon + 180.0) / 360.0 * n).floor()));
  }

  static int y(double lat, int z) {
    final n = 1 << z;
    final la = math.max(-85.0511, math.min(85.0511, lat)) * math.pi / 180.0;
    final v = ((1 - math.log(math.tan(la) + 1 / math.cos(la)) / math.pi) / 2 * n).floor();
    return math.max(0, math.min(n - 1, v));
  }

  /// Cuántas teselas cubren la zona entre [zMin] y [zMax].
  static int contar(Zona zona, int zMin, int zMax) {
    var t = 0;
    for (var z = zMin; z <= zMax; z++) {
      t += (x(zona.este, z) - x(zona.oeste, z) + 1) * (y(zona.sur, z) - y(zona.norte, z) + 1);
    }
    return t;
  }
}

String? _formatoImagen(Uint8List b) {
  if (b.length < 12) return null;
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return 'png';
  if (b[0] == 0xFF && b[1] == 0xD8) return 'jpg';
  if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && b[8] == 0x57 && b[9] == 0x45) return 'webp';
  return null;
}

/// Recorre todas las teselas (z, x, y) de la zona sin guardar la lista completa en memoria.
class _CursorTeselas {
  final Zona zona;
  final int zMax;
  int z;
  int _x = 0, _x1 = 0, _y = 0, _yIni = 0, _y1 = 0;

  _CursorTeselas(this.zona, int zMin, this.zMax) : z = zMin {
    _preparar();
  }

  void _preparar() {
    _x = Teselas.x(zona.oeste, z);
    _x1 = Teselas.x(zona.este, z);
    _yIni = Teselas.y(zona.norte, z);
    _y1 = Teselas.y(zona.sur, z);
    _y = _yIni;
  }

  ({int z, int x, int y})? siguiente() {
    if (z > zMax) return null;
    final r = (z: z, x: _x, y: _y);
    _y++;
    if (_y > _y1) {
      _x++;
      _y = _yIni;
      if (_x > _x1) {
        z++;
        if (z <= zMax) _preparar();
      }
    }
    return r;
  }
}

/// Descarga teselas raster de un servidor XYZ y las empaqueta en un archivo .mbtiles
/// (esquema TMS, igual que lee ProveedorMbTiles).
class DescargadorMapa {
  static const int _tamLote = 150;

  Future<int> descargar({
    required Zona zona,
    required String plantilla, // https://servidor/{z}/{x}/{y}.png
    required int zMin,
    required int zMax,
    required File salida,
    required void Function(double, String) progreso,
    required bool Function() cancelado,
    int simultaneas = 4,
  }) async {
    if (await salida.exists()) await salida.delete();
    final db = await openDatabase(salida.path, version: 1, onCreate: (d, v) async {
      await d.execute('CREATE TABLE metadata (name TEXT, value TEXT)');
      await d.execute('CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB)');
      await d.execute('CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row)');
    });
    try {
      final cursor = _CursorTeselas(zona, zMin, zMax);
      final total = Teselas.contar(zona, zMin, zMax);
      var hechas = 0, guardadas = 0, fallosSeguidos = 0;
      String? formato;
      ErrorDescarga? fatal;
      final lote = <Map<String, Object?>>[];
      Future<void> escritura = Future<void>.value();

      Future<void> volcar() {
        if (lote.isEmpty) return escritura;
        final copia = List<Map<String, Object?>>.of(lote);
        lote.clear();
        escritura = escritura.then((_) async {
          final b = db.batch();
          for (final fila in copia) {
            b.insert('tiles', fila, conflictAlgorithm: ConflictAlgorithm.replace);
          }
          await b.commit(noResult: true);
        });
        return escritura;
      }

      Future<void> trabajador() async {
        while (fatal == null && !cancelado()) {
          final t = cursor.siguiente();
          if (t == null) return;
          final url = plantilla
              .replaceAll('{z}', '${t.z}')
              .replaceAll('{x}', '${t.x}')
              .replaceAll('{y}', '${t.y}');
          Uint8List? datos;
          var inexistente = false;
          for (var intento = 0; intento < 3 && datos == null && !inexistente && fatal == null; intento++) {
            try {
              datos = await ClienteHttp.bytes(Uri.parse(url), limite: const Duration(seconds: 30));
            } on _ErrorHttp catch (e) {
              if (e.codigo == 404 || e.codigo == 204) {
                inexistente = true;
              } else if (e.codigo == 401 || e.codigo == 403 || e.codigo == 429) {
                fatal = ErrorDescarga('El servidor de teselas respondió ${e.codigo} (acceso denegado o límite alcanzado). '
                    'Revisa la URL y los términos del servicio, o baja el zoom máximo.');
              } else {
                await Future<void>.delayed(Duration(milliseconds: 500 * (intento + 1)));
              }
            } on TimeoutException {
              await Future<void>.delayed(Duration(milliseconds: 500 * (intento + 1)));
            } on IOException {
              await Future<void>.delayed(Duration(milliseconds: 500 * (intento + 1)));
            }
          }
          if (datos != null && datos.isNotEmpty) {
            final f = _formatoImagen(datos);
            if (f == null) {
              fatal = const ErrorDescarga('El servidor no devolvió imágenes PNG/JPG/WEBP. '
                  'Revisa la URL: debe ser de teselas raster, no vectoriales.');
            } else {
              formato ??= f;
              lote.add({
                'zoom_level': t.z,
                'tile_column': t.x,
                'tile_row': (1 << t.z) - 1 - t.y, // XYZ → TMS
                'tile_data': datos,
              });
              guardadas++;
              fallosSeguidos = 0;
              if (lote.length >= _tamLote) await volcar();
            }
          } else if (!inexistente && fatal == null) {
            fallosSeguidos++;
            if (fallosSeguidos >= 40) {
              fatal = const ErrorDescarga('Demasiados errores seguidos: revisa tu internet o la URL del servidor.');
            }
          }
          hechas++;
          if (hechas % 20 == 0) progreso(hechas / total, 'Mapa: $hechas de $total teselas');
        }
      }

      await Future.wait(List<Future<void>>.generate(simultaneas, (_) => trabajador()));
      await volcar();
      await escritura;
      if (cancelado()) throw const ErrorDescarga('Descarga cancelada.');
      final fallo = fatal;
      if (fallo != null) throw fallo;
      if (guardadas == 0) {
        throw const ErrorDescarga('El servidor no tiene teselas para esa zona y esos niveles de zoom.');
      }
      final meta = <String, String>{
        'name': zona.nombre,
        'format': formato ?? 'png',
        'bounds': '${zona.oeste},${zona.sur},${zona.este},${zona.norte}',
        'minzoom': '$zMin',
        'maxzoom': '$zMax',
        'type': 'baselayer',
        'version': '1',
        'description': 'Descargado por la app para ${zona.nombre}',
      };
      final loteMeta = db.batch();
      meta.forEach((k, v) => loteMeta.insert('metadata', {'name': k, 'value': v}));
      await loteMeta.commit(noResult: true);
      await db.close();
      return guardadas;
    } catch (_) {
      try {
        await db.close();
      } catch (_) {}
      try {
        if (await salida.exists()) await salida.delete();
      } catch (_) {}
      rethrow;
    }
  }
}

// ============================================================================
// 8. CONTROLADOR (equivalente al ViewModel): estado + lógica de navegación
// ============================================================================

/// Mapa .mbtiles disponible: en el almacenamiento propio de la app o en la carpeta pública Descargas.
class MapaLocal {
  final String nombre;
  final String ruta;
  final bool enDescargas;
  const MapaLocal(this.nombre, this.ruta, this.enDescargas);
}

enum Fase { inactiva, navegando, llegada }

class Controlador extends ChangeNotifier {
  final Datos datos = Datos();
  final GuiaVoz voz = GuiaVoz();
  final Escucha stt = Escucha();
  final MotorRutas motor = MotorRutas();

  // --- Estado observable por la UI ---
  Modo modo = Modo.auto;
  Fase fase = Fase.inactiva;
  Position? ubic;
  double velKmh = 0;
  bool permisoOk = false;
  bool permisosCompletos = true; // false = falta algún permiso (se muestra el aviso «Conceder»)
  bool gpsActivo = true;
  LatLng? destino;
  String destinoNombre = '';
  Ruta? ruta;
  bool calculando = false;
  double restanteM = 0;
  int? etaS;
  Maniobra? proxima;
  double distProxima = 0;
  bool vozActiva = true;
  bool escuchando = false;
  bool redCargada = false;
  String redEstado = 'Sin red vial: se usa ruta en línea recta';
  List<MapaLocal> mapas = [];
  // Rango de zoom real de los .mbtiles cargados y área que cubren (metadata "bounds")
  int zoomMinTiles = 0, zoomMaxTiles = 19;
  LatLngBounds? limitesMapa;
  // Brújula: ValueNotifier aparte para redibujar SOLO el widget de la brújula (no toda la pantalla)
  final ValueNotifier<double?> brujula = ValueNotifier<double?>(null);
  bool brujulaDisponible = true;
  bool rumboArriba = false; // true = el mapa gira para que "arriba" sea hacia donde apunta el teléfono
  int versionMapas = 0;
  String? mensaje;
  List<Poi> pois = [];
  List<RutaFrec> rutasFrec = [];
  List<Hist> historial = [];
  TileProvider proveedorTiles = ProveedorMbTiles(const []);

  /// true si hay mapas cargados con área conocida y el usuario está fuera de ella.
  bool get fueraDeMapa {
    final b = limitesMapa, u = ubic;
    if (b == null || u == null || mapas.isEmpty) return false;
    return !b.contains(LatLng(u.latitude, u.longitude));
  }

  // --- Estado interno ---
  StreamSubscription<Position>? _sub;
  final List<Database> _basesMb = [];
  int _idxSeg = 0, _desvios = 0, _ultimoRecalculo = 0;
  final Set<int> _anunciadas = {};
  double _velSuave = 0, _recorridoM = 0;
  int? _histId;
  String? _ultimaInstr;
  bool _gpsConNotificacion = false;
  StreamSubscription<CompassEvent>? _subBrujula;
  double? _rumboSuave;

  void _msg(String t) {
    mensaje = t;
    notifyListeners();
  }

  Future<void> iniciar() async {
    voz.alError = _msg;
    await datos.abrir();
    await _leerAjustesDescarga();
    await _recargar();
    await voz.iniciar();
    unawaited(stt.cargarModelo().then((_) => notifyListeners())); // modelo de voz en segundo plano
    await _abrirMapas();
    await _cargarRedGuardada();
    await iniciarGps(); // ubicación (diálogo del sistema)
    _iniciarBrujula();
    await pedirPermisos();
    await revisarPermisos();
  }

  /// Pide el resto de permisos de una vez. Solo pregunta por lo que aún no está concedido.
  Future<void> pedirPermisos() async {
    if (await Permission.notification.isDenied) await Permission.notification.request();
    if (await Permission.microphone.isDenied) await Permission.microphone.request();
    // Descargas: solo si no hay mapas cargados (en Android 11+ abre «Acceso a todos los archivos»)
    if (mapas.isEmpty && !await _tienePermisoDescargas()) {
      await _pedirPermisoDescargas();
      await _abrirMapas();
    }
  }

  /// Comprueba si están todos los permisos. El de archivos solo cuenta si aún no hay mapas cargados
  /// (con «Elegir y copiar un .mbtiles…» el mapa vive en la carpeta de la app y no lo necesita).
  Future<bool> revisarPermisos() async {
    final ok = await Permission.locationWhenInUse.isGranted &&
        await Permission.microphone.isGranted &&
        await Permission.notification.isGranted &&
        (mapas.isNotEmpty || await _tienePermisoDescargas());
    if (ok != permisosCompletos) {
      permisosCompletos = ok;
      notifyListeners();
    }
    return ok;
  }

  /// Un solo toque: pide ubicación, micrófono, notificaciones y archivos (Descargas).
  /// Internet no se pide en ejecución: basta con declararlo en el AndroidManifest.
  Future<void> pedirTodosPermisos() async {
    final estados = await [
      Permission.locationWhenInUse,
      Permission.microphone,
      Permission.notification,
    ].request();
    await _pedirPermisoDescargas(); // Android 11+: abre «Acceso a todos los archivos»
    final bloqueado = estados.values.any((e) => e.isPermanentlyDenied) ||
        await Permission.manageExternalStorage.isPermanentlyDenied;
    await iniciarGps(reiniciar: true);
    await _abrirMapas();
    final ok = await revisarPermisos();
    if (ok) {
      _msg('Todos los permisos concedidos.');
    } else if (bloqueado) {
      _msg('Activa los permisos que faltan en Ajustes de la app.');
      await openAppSettings();
    } else {
      _msg('Aún faltan algunos permisos.');
    }
  }

  Future<void> _recargar() async {
    pois = await datos.pois();
    rutasFrec = await datos.rutas();
    historial = await datos.historial();
    notifyListeners();
  }

  // ------------------------------------------------------------------ GPS
  Future<void> alMostrar() async {
    await iniciarGps();
    _iniciarBrujula();
    // Si no había mapas, se vuelve a buscar (quizá acabas de copiar el .mbtiles a Descargas
    // o de conceder «Acceso a todos los archivos»).
    if (mapas.isEmpty) await _abrirMapas();
    await revisarPermisos();
  }

  Future<void> alOcultar() async {
    _detenerBrujula(); // el sensor magnético solo se usa con la app visible (ahorra batería)
    await stt.cancelar();
    escuchando = false;
    if (fase != Fase.navegando) await _detenerGps();
  }

  LocationSettings _ajustes(bool conNotificacion) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
        intervalDuration: Duration(seconds: modo.intervaloS),
        foregroundNotificationConfig: conNotificacion
            ? const ForegroundNotificationConfig(
                notificationTitle: 'Navegación en curso',
                notificationText: 'Toca para volver al mapa',
                enableWakeLock: true,
              )
            : null,
      );
    }
    return const LocationSettings(accuracy: LocationAccuracy.best);
  }

  Future<void> iniciarGps({bool reiniciar = false}) async {
    if (_sub != null && !reiniciar) return;
    await _sub?.cancel();
    _sub = null;
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    permisoOk = p == LocationPermission.always || p == LocationPermission.whileInUse;
    if (!permisoOk) {
      _msg('Concede el permiso de ubicación para navegar.');
      return;
    }
    gpsActivo = await Geolocator.isLocationServiceEnabled();
    final ultima = await Geolocator.getLastKnownPosition();
    if (ultima != null && ubic == null) _procesar(ultima);
    _gpsConNotificacion = fase == Fase.navegando;
    _sub = Geolocator.getPositionStream(locationSettings: _ajustes(_gpsConNotificacion))
        .listen(_procesar, onError: (Object e) => _msg('GPS: $e'));
    notifyListeners();
  }

  Future<void> _detenerGps() async {
    await _sub?.cancel();
    _sub = null;
  }

  double _estimarVel(Position? previa, Position u) {
    if (previa == null) return 0;
    final dt = u.timestamp.difference(previa.timestamp).inMilliseconds / 1000.0;
    if (dt <= 0) return 0;
    return Geo.dist(previa.latitude, previa.longitude, u.latitude, u.longitude) / dt;
  }

  void _procesar(Position u) {
    final previa = ubic;
    final medida = u.speed >= 0 ? u.speed : _estimarVel(previa, u);
    _velSuave = 0.7 * _velSuave + 0.3 * (medida < 0.5 ? 0.0 : medida);
    ubic = u;
    velKmh = _velSuave * 3.6;
    gpsActivo = true;
    if (fase == Fase.navegando) {
      _progreso(u, previa);
    } else if (destino != null && ruta == null && !calculando) {
      _calcularRuta();
    }
    notifyListeners();
  }

  // ---------------------------------------------------- modo, destino y ruta
  Future<void> seleccionarModo(Modo m) async {
    if (modo == m) return;
    modo = m;
    notifyListeners();
    if (_sub != null) await iniciarGps(reiniciar: true); // el intervalo de GPS depende del modo
    if (destino != null) await _calcularRuta(recalculo: fase == Fase.navegando);
    if (fase == Fase.navegando) voz.hablar('Modo ${m.vozNombre}', urgente: true);
  }

  Future<void> establecerDestino(LatLng ll, String nombre) async {
    if (fase == Fase.navegando) await _finalizar(false);
    destino = ll;
    destinoNombre = nombre;
    ruta = null;
    fase = Fase.inactiva;
    calculando = false;
    restanteM = 0;
    etaS = null;
    proxima = null;
    notifyListeners();
    await _calcularRuta();
  }

  Future<void> limpiarDestino() async {
    if (fase == Fase.navegando) await _finalizar(false);
    destino = null;
    ruta = null;
    fase = Fase.inactiva;
    calculando = false;
    etaS = null;
    proxima = null;
    WakelockPlus.disable();
    notifyListeners();
  }

  Future<void> _calcularRuta({bool recalculo = false, bool iniciar = false}) async {
    final d = destino, u = ubic;
    if (d == null) return;
    if (u == null) {
      _msg('Esperando señal GPS para calcular la ruta…');
      return;
    }
    calculando = true;
    notifyListeners();
    try {
      final r = await motor.calcular(LatLng(u.latitude, u.longitude), d, modo);
      _idxSeg = 0;
      _desvios = 0;
      _anunciadas.clear();
      ruta = r;
      calculando = false;
      restanteM = r.total;
      etaS = r.duracionS.round();
      proxima = r.maniobras.where((m) => m.tipo != TipoGiro.salida).firstOrNull;
      distProxima = proxima?.acumM ?? r.total;
      notifyListeners();
      if (r.aproximada) _msg('Ruta en línea recta (sin red vial cargada o sin camino).');
      if (iniciar) {
        await _comenzar(r);
      } else if (recalculo) {
        voz.hablar('Ruta recalculada', urgente: true);
      }
    } catch (e) {
      calculando = false;
      _msg('No se pudo calcular la ruta: $e');
    }
  }

  // ---------------------------------------------------- navegación activa
  Future<void> iniciarNavegacion() async {
    if (destino == null) return _msg('Elige un destino primero.');
    if (ubic == null) return _msg('Esperando señal GPS…');
    await _calcularRuta(iniciar: true); // recalcula desde la posición actual
  }

  Future<void> _comenzar(Ruta r) async {
    _recorridoM = 0;
    fase = Fase.navegando;
    WakelockPlus.enable(); // pantalla encendida mientras se navega
    if (await Permission.notification.isDenied) await Permission.notification.request();
    await iniciarGps(reiniciar: true); // reinicia el GPS con notificación de primer plano
    notifyListeners();
    _histId = await datos.iniciarHistorial(destinoNombre, modo.name, r.total);
    await datos.podarHistorial();
    final primera = r.maniobras.first.texto;
    _ultimaInstr = primera;
    final b = StringBuffer('Iniciando navegación en modo ${modo.vozNombre}. ');
    if (r.aproximada) b.write('No hay red vial cargada, seguiré una línea recta. ');
    b.write('Distancia ${Fmt.distVoz(r.total)}. $primera');
    voz.hablar(b.toString(), urgente: true);
  }

  Future<void> cancelarNavegacion() async {
    if (fase == Fase.navegando) {
      voz.hablar('Navegación cancelada', urgente: true);
      await _finalizar(false);
    } else {
      await limpiarDestino();
    }
  }

  void _progreso(Position u, Position? previa) {
    final r = ruta, dest = destino;
    if (r == null || dest == null) return;

    if (previa != null && u.accuracy <= 50 && previa.accuracy <= 50) {
      final d = Geo.dist(previa.latitude, previa.longitude, u.latitude, u.longitude);
      if (d >= 3 && d < 500) _recorridoM += d; // filtra ruido de GPS detenido
    }
    if (u.accuracy > 80) return; // posición poco confiable

    final pos = LatLng(u.latitude, u.longitude);
    double restante;
    Maniobra? prox;
    double dProx;

    if (r.aproximada) {
      restante = Geo.distLL(pos, dest);
      prox = r.maniobras.last;
      dProx = restante;
    } else {
      final pr = Geo.proyectar(pos, r.puntos, r.acum, _idxSeg);
      _idxSeg = pr.seg;
      final umbral = math.max(modo.umbralDesvio, u.accuracy * 1.5);
      if (pr.dist > umbral) {
        _desvios++;
      } else {
        _desvios = 0;
      }
      final ahora = DateTime.now().millisecondsSinceEpoch;
      if (_desvios >= 3 && !calculando && ahora - _ultimoRecalculo > 10000) {
        _ultimoRecalculo = ahora;
        _desvios = 0;
        voz.hablar('Recalculando ruta', urgente: true);
        _calcularRuta(recalculo: true);
        return;
      }
      restante = math.max(0.0, r.total - pr.prog);
      prox = r.maniobras.where((m) => m.acumM > pr.prog + 1).firstOrNull;
      dProx = prox != null ? math.max(0.0, prox.acumM - pr.prog) : restante;
    }

    restanteM = restante;
    proxima = prox;
    distProxima = dProx;
    // ETA: en movimiento usa la velocidad real suavizada; detenido usa el ritmo previsto de la ruta
    double seg;
    if (_velSuave >= 2.0) {
      seg = restante / math.min(_velSuave, modo.velMax / 3.6);
    } else if (r.total > 1) {
      seg = restante * (r.duracionS / r.total);
    } else {
      seg = restante / (modo.velProm / 3.6);
    }
    etaS = seg.round();

    if (restante <= modo.umbralLlegada) {
      voz.hablar('Has llegado a tu destino', urgente: true);
      _finalizar(true);
      return;
    }
    if (prox != null && prox.tipo != TipoGiro.salida) _anunciar(prox, dProx);
  }

  /// Avisos a las distancias del modo; cada aviso se dice una sola vez.
  void _anunciar(Maniobra m, double d) {
    final av = modo.avisos;
    var nivel = -1;
    for (var i = 0; i < av.length; i++) {
      if (d <= av[i]) nivel = i;
    }
    if (nivel < 0 || _anunciadas.contains(m.idx * 10 + nivel)) return;
    for (var k = 0; k <= nivel; k++) {
      _anunciadas.add(m.idx * 10 + k);
    }
    final accion = m.texto.isEmpty ? m.texto : m.texto[0].toLowerCase() + m.texto.substring(1);
    final texto = nivel == av.length - 1 ? m.texto : 'En ${Fmt.distVoz(d)}, $accion';
    _ultimaInstr = texto;
    voz.hablar(texto);
  }

  Future<void> _finalizar(bool completada) async {
    final id = _histId;
    _histId = null;
    if (id != null) await datos.finalizarHistorial(id, _recorridoM, completada);
    WakelockPlus.disable();
    fase = completada ? Fase.llegada : Fase.inactiva;
    proxima = null;
    etaS = null;
    if (!completada) ruta = null;
    notifyListeners();
    if (_gpsConNotificacion) await iniciarGps(reiniciar: true); // quita la notificación de primer plano
    await _recargar();
  }

  Future<void> confirmarLlegada() => limpiarDestino();

  // ---------------------------------------------------- base de datos
  Future<void> guardarPunto(String nombre, String categoria, bool usarDestino) async {
    double? lat, lon;
    if (usarDestino && destino != null) {
      lat = destino!.latitude;
      lon = destino!.longitude;
    } else if (ubic != null) {
      lat = ubic!.latitude;
      lon = ubic!.longitude;
    }
    if (lat == null || lon == null) return _msg('Todavía no hay ubicación GPS.');
    final ahora = DateTime.now().millisecondsSinceEpoch;
    await datos.insertarPoi(Poi(
        nombre: nombre.trim().isEmpty ? 'Punto ${Fmt.fechaHora(ahora)}' : nombre.trim(),
        categoria: categoria,
        lat: lat,
        lon: lon,
        creadoMs: ahora));
    await _recargar();
    _msg('Punto guardado.');
  }

  Future<void> eliminarPoi(Poi p) async {
    await datos.eliminarPoi(p.id!);
    await _recargar();
  }

  Future<void> irAPoi(Poi p) => establecerDestino(LatLng(p.lat, p.lon), p.nombre);

  Future<void> guardarRutaFrecuente(String nombre) async {
    final d = destino;
    if (d == null) return _msg('Elige un destino para guardar la ruta.');
    await datos.insertarRuta(RutaFrec(
        nombre: nombre.trim().isEmpty ? destinoNombre : nombre.trim(),
        destinoNombre: destinoNombre,
        lat: d.latitude,
        lon: d.longitude,
        modo: modo.name));
    await _recargar();
    _msg('Ruta frecuente guardada.');
  }

  Future<void> usarRutaFrecuente(RutaFrec r) async {
    modo = Modo.values.firstWhere((m) => m.name == r.modo, orElse: () => Modo.auto);
    if (_sub != null) await iniciarGps(reiniciar: true);
    await establecerDestino(LatLng(r.lat, r.lon), r.destinoNombre);
    await datos.usoRuta(r.id!);
    await _recargar();
  }

  Future<void> eliminarRutaFrecuente(RutaFrec r) async {
    await datos.eliminarRuta(r.id!);
    await _recargar();
  }

  Future<void> borrarHistorial() async {
    await datos.borrarHistorial();
    await _recargar();
  }

  // ---------------------------------------------------- voz
  void establecerVoz(bool activa) {
    voz.habilitado = activa;
    vozActiva = activa;
    if (!activa) voz.silenciar();
    notifyListeners();
  }

  Future<void> alternarEscucha() async {
    if (escuchando) {
      await stt.cancelar();
      escuchando = false;
      notifyListeners();
      return;
    }
    // Permiso de micrófono ANTES de escuchar
    if (!await Permission.microphone.isGranted) {
      final r = await Permission.microphone.request();
      if (!r.isGranted) return _msg('Concede el permiso de micrófono para usar comandos de voz.');
    }
    await voz.silenciar(); // evita que el micrófono capte la guía
    await stt.escuchar(
      alEstado: (a) {
        escuchando = a;
        notifyListeners();
      },
      alResultado: (t) => _ejecutar(interpretarComando(t)),
      alError: _msg,
    );
  }

  void _ejecutar(Cmd c) {
    switch (c) {
      case CmdIniciar():
        iniciarNavegacion();
      case CmdCancelar():
        cancelarNavegacion();
      case CmdModo(:final modo):
        seleccionarModo(modo);
      case CmdEstado():
        final eta = etaS;
        voz.hablar(
            fase == Fase.navegando && eta != null
                ? 'Faltan ${Fmt.distVoz(restanteM)}. Llegada estimada en ${Fmt.durVoz(eta)}.'
                : 'No hay una navegación activa.',
            urgente: true);
      case CmdRepetir():
        voz.hablar(_ultimaInstr ?? 'No tengo instrucciones para repetir.', urgente: true);
      case CmdGuardarAqui():
        guardarPunto('', 'Campo', false);
        voz.hablar('Punto guardado');
      case CmdIrA(:final nombre):
        final buscado = Fmt.normalizar(nombre);
        final poi = pois.where((p) => Fmt.normalizar(p.nombre).contains(buscado)).firstOrNull;
        if (poi == null) {
          voz.hablar('No encontré un lugar llamado $nombre');
        } else {
          irAPoi(poi);
          voz.hablar('Destino ${poi.nombre}. Di iniciar navegación para comenzar.');
        }
      case CmdSilenciar():
        establecerVoz(false);
      case CmdActivarVoz():
        establecerVoz(true);
        voz.hablar('Voz activada');
      case CmdDesconocido(:final texto):
        voz.hablar('No entendí el comando: $texto');
    }
  }

  // ---------------------------------------------------- brújula
  void _iniciarBrujula() {
    if (_subBrujula != null) return;
    final flujo = FlutterCompass.events; // null si el teléfono no tiene magnetómetro
    if (flujo == null) {
      brujulaDisponible = false;
      notifyListeners();
      return;
    }
    brujulaDisponible = true;
    _subBrujula = flujo.listen((e) {
      final h = e.heading;
      if (h == null) return;
      final nuevo = (h + 360.0) % 360.0;
      final previo = _rumboSuave;
      if (previo == null) {
        _rumboSuave = nuevo;
        brujula.value = nuevo;
        return;
      }
      final d = ((nuevo - previo + 540.0) % 360.0) - 180.0; // diferencia con el salto 359°→0° resuelto
      if (d.abs() < 1.0) return; // ignora el ruido del sensor
      final suave = (previo + d * 0.3 + 360.0) % 360.0; // filtro pasa-bajas: aguja estable
      _rumboSuave = suave;
      brujula.value = suave;
    }, onError: (Object _) {});
  }

  void _detenerBrujula() {
    _subBrujula?.cancel();
    _subBrujula = null;
  }

  void alternarRumboArriba() {
    rumboArriba = !rumboArriba;
    _msg(rumboArriba ? 'Mapa con rumbo arriba (gira con la brújula).' : 'Mapa con el norte arriba.');
  }

  // ---------------------------------------------------- mapas y red vial
  Future<Directory> _carpeta(String nombre) async {
    final base = await getApplicationDocumentsDirectory();
    return Directory(ruta_p.join(base.path, nombre)).create(recursive: true);
  }

  // ---- Carpeta pública Descargas ----
  /// Rutas candidatas de Descargas (la física se llama «Download» aunque el teléfono esté en español).
  Future<List<String>> _carpetasDescargas() async {
    final r = <String>['/storage/emulated/0/Download'];
    try {
      final ext = await getExternalStorageDirectory(); // .../Android/data/<paquete>/files
      if (ext != null) {
        final i = ext.path.indexOf('/Android');
        if (i > 0) r.insert(0, '${ext.path.substring(0, i)}/Download');
      }
    } catch (_) {}
    return r.toSet().toList();
  }

  /// En Android 11+ leer archivos que no son de la app exige «Acceso a todos los archivos»
  /// (MANAGE_EXTERNAL_STORAGE); en Android 10 o menor basta el permiso de almacenamiento.
  Future<bool> _tienePermisoDescargas() async =>
      await Permission.manageExternalStorage.isGranted || await Permission.storage.isGranted;

  Future<bool> _pedirPermisoDescargas() async {
    if (await _tienePermisoDescargas()) return true;
    // Android 11+: abre la pantalla de Ajustes «Acceso a todos los archivos» para esta app
    if ((await Permission.manageExternalStorage.request()).isGranted) return true;
    // Android 10 o menor: diálogo normal de almacenamiento
    return (await Permission.storage.request()).isGranted;
  }

  Future<List<File>> _mbtilesEnDescargas() async {
    for (final ruta in await _carpetasDescargas()) {
      final dir = Directory(ruta);
      try {
        if (!await dir.exists()) continue;
        final archivos = <File>[];
        await for (final e in dir.list(followLinks: false)) {
          if (e is File && e.path.toLowerCase().endsWith('.mbtiles')) archivos.add(e);
        }
        return archivos;
      } on FileSystemException {
        continue; // sin permiso sobre esta ruta
      }
    }
    return <File>[];
  }

  /// Formato declarado en la tabla metadata del MBTiles ("png", "jpg", "pbf"...).
  Future<String> _formatoMb(Database db) async {
    try {
      final r = await db.rawQuery("SELECT value FROM metadata WHERE name = 'format'");
      return r.isEmpty ? '' : '${r.first['value']}'.toLowerCase().trim();
    } catch (_) {
      return '';
    }
  }

  /// Área del mapa según metadata "bounds" = "oeste,sur,este,norte".
  Future<LatLngBounds?> _limitesMb(Database db) async {
    try {
      final r = await db.rawQuery("SELECT value FROM metadata WHERE name = 'bounds'");
      if (r.isEmpty) return null;
      final p = '${r.first['value']}'.split(',').map((e) => double.tryParse(e.trim())).toList();
      if (p.length != 4 || p.any((e) => e == null)) return null;
      return LatLngBounds(LatLng(p[1]!, p[0]!), LatLng(p[3]!, p[2]!));
    } catch (_) {
      return null;
    }
  }

  /// Abre los .mbtiles de Descargas (si hay permiso) y los importados al almacenamiento propio.
  /// Los de Descargas se leen EN SITIO: no se copian ni se duplica el espacio.
  Future<void> _abrirMapas() async {
    for (final d in _basesMb) {
      await d.close();
    }
    _basesMb.clear();

    final candidatos = <MapaLocal>[];
    final propia = await _carpeta('mapas');
    for (final f in propia.listSync().whereType<File>()) {
      if (f.path.toLowerCase().endsWith('.mbtiles')) {
        candidatos.add(MapaLocal(ruta_p.basename(f.path), f.path, false));
      }
    }
    if (await _tienePermisoDescargas()) {
      try {
        for (final f in await _mbtilesEnDescargas()) {
          candidatos.add(MapaLocal(ruta_p.basename(f.path), f.path, true));
        }
      } catch (_) {}
    }
    candidatos.sort((a, b) => a.nombre.compareTo(b.nombre));

    final validos = <MapaLocal>[];
    final invalidos = <String>[];
    final vectoriales = <String>[];
    final vistos = <String>{};
    var zMin = 99, zMax = -1;
    LatLngBounds? unionBounds;
    for (final m in candidatos) {
      if (!vistos.add(m.nombre)) continue; // mismo nombre en Descargas y en la app: se usa uno
      Database? db;
      try {
        db = await openDatabase(m.ruta, readOnly: true, singleInstance: false);
        await db.rawQuery('SELECT 1 FROM tiles LIMIT 1'); // comprueba que sea un MBTiles real
        final fmt = await _formatoMb(db);
        if (fmt == 'pbf' || fmt == 'mvt') {
          await db.close(); // teselas vectoriales: flutter_map raster no las puede dibujar
          vectoriales.add(m.nombre);
          continue;
        }
        final zr = await db.rawQuery('SELECT MIN(zoom_level) AS a, MAX(zoom_level) AS b FROM tiles');
        final a = zr.first['a'], b = zr.first['b'];
        if (a is int) zMin = math.min(zMin, a);
        if (b is int) zMax = math.max(zMax, b);
        final lim = await _limitesMb(db);
        if (lim != null) {
          if (unionBounds == null) {
            unionBounds = lim;
          } else {
            unionBounds.extend(lim.northEast);
            unionBounds.extend(lim.southWest);
          }
        }
        _basesMb.add(db);
        validos.add(m);
      } catch (_) {
        await db?.close();
        invalidos.add(m.nombre);
      }
    }
    mapas = validos;
    zoomMinTiles = zMax >= 0 ? zMin : 0;
    zoomMaxTiles = zMax >= 0 ? zMax : 19;
    limitesMapa = unionBounds;
    proveedorTiles = ProveedorMbTiles(List<Database>.of(_basesMb));
    versionMapas++;
    notifyListeners();
    if (vectoriales.isNotEmpty) {
      _msg('${vectoriales.join(', ')} es VECTORIAL (pbf). Esta app necesita un .mbtiles raster (png/jpg).');
    } else if (invalidos.isNotEmpty) {
      _msg('No se pudo abrir como MBTiles: ${invalidos.join(', ')}');
    }
  }

  /// Botón «Buscar en Descargas»: pide el permiso si falta y vuelve a leer la carpeta.
  Future<void> buscarEnDescargas() async {
    if (!await _pedirPermisoDescargas()) {
      _msg('Sin el permiso «Acceso a todos los archivos» no puedo leer la carpeta Descargas.');
      return;
    }
    await _abrirMapas();
    if (mapas.any((m) => m.enDescargas)) {
      _msg('Mapas cargados desde Descargas.');
    } else {
      _msg('No encontré archivos .mbtiles en la carpeta Descargas.');
    }
  }

  Future<void> importarMapa() async {
    final sel = await FilePicker.platform.pickFiles(type: FileType.any);
    final origen = sel?.files.single.path;
    if (origen == null) return;
    if (!origen.toLowerCase().endsWith('.mbtiles')) {
      return _msg('Formato no soportado: usa un archivo .mbtiles de teselas raster (PNG/JPG).');
    }
    _msg('Importando mapa… los archivos grandes pueden tardar.');
    try {
      final carpeta = await _carpeta('mapas');
      await File(origen).copy(ruta_p.join(carpeta.path, ruta_p.basename(origen).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')));
      await _abrirMapas();
      if (mapas.isNotEmpty) _msg('Mapa importado.');
    } catch (e) {
      _msg('No se pudo importar el mapa: $e');
    }
  }

  Future<void> eliminarMapa(MapaLocal m) async {
    if (m.enDescargas) {
      return _msg('Ese mapa está en Descargas: bórralo desde tu administrador de archivos.');
    }
    for (final d in _basesMb) {
      await d.close();
    }
    _basesMb.clear();
    final f = File(m.ruta);
    if (await f.exists()) await f.delete();
    await _abrirMapas();
  }

  Future<void> importarRedVial() async {
    final sel = await FilePicker.platform.pickFiles(type: FileType.any);
    final origen = sel?.files.single.path;
    if (origen == null) return;
    redEstado = 'Importando red vial…';
    notifyListeners();
    try {
      final carpeta = await _carpeta('red');
      await File(origen).copy(ruta_p.join(carpeta.path, 'red_vial.geojson'));
      await _cargarRedGuardada();
    } catch (e) {
      redEstado = 'Error al importar la red vial';
      _msg('No se pudo importar la red vial: $e');
    }
  }

  // ---- Regiones de red vial guardadas (varios .geojson en la carpeta «red») ----
  Future<List<File>> _archivosRed() async {
    final dir = await _carpeta('red');
    final r = dir.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.geojson')).toList();
    r.sort((a, b) => a.path.compareTo(b.path));
    return r;
  }

  /// Carga TODAS las regiones guardadas en un solo grafo (se unen por coordenadas).
  Future<void> _cargarRedGuardada() async {
    final archivos = await _archivosRed();
    regionesRed = archivos;
    if (archivos.isEmpty) {
      motor.red = null;
      redCargada = false;
      redEstado = 'Sin red vial: se usa ruta en línea recta';
      notifyListeners();
      return;
    }
    redEstado = 'Cargando red vial…';
    notifyListeners();
    try {
      final n = await motor.cargar(archivos.map((f) => f.path).toList());
      redCargada = true;
      redEstado = 'Red vial cargada ($n nodos, ${archivos.length} ${archivos.length == 1 ? 'región' : 'regiones'})';
      notifyListeners();
      if (destino != null && fase != Fase.navegando) _calcularRuta();
    } catch (e) {
      redCargada = false;
      redEstado = 'Red vial inválida o demasiado grande para este equipo: $e';
      notifyListeners();
    }
  }

  Future<void> eliminarRegionRed(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (e) {
      _msg('No se pudo borrar la región: $e');
    }
    await _cargarRedGuardada();
  }

  Future<void> quitarRedVial() async {
    for (final f in await _archivosRed()) {
      try {
        await f.delete();
      } catch (_) {}
    }
    await _cargarRedGuardada();
  }

  // ---------------------------------------------------- descarga de mapas y red vial
  bool descargando = false;
  bool descargaEsMapa = false;
  double progresoDescarga = 0;
  String textoDescarga = '';
  String plantillaTeselas = '';
  List<File> regionesRed = [];
  bool _cancelarDescarga = false;
  final Overpass _overpass = Overpass();
  late final Catalogo catalogo = Catalogo(_overpass);

  Future<File> _archivoAjustesDescarga() async =>
      File(ruta_p.join((await getApplicationDocumentsDirectory()).path, 'ajustes_descarga.json'));

  Future<void> _leerAjustesDescarga() async {
    try {
      final f = await _archivoAjustesDescarga();
      if (await f.exists()) {
        final m = jsonDecode(await f.readAsString());
        if (m is Map) plantillaTeselas = '${m['plantilla'] ?? ''}';
      }
    } catch (_) {}
  }

  Future<void> _guardarPlantilla(String p) async {
    plantillaTeselas = p;
    try {
      await (await _archivoAjustesDescarga()).writeAsString(jsonEncode({'plantilla': p}));
    } catch (_) {}
  }

  void _iniciarDescarga(bool esMapa, String texto) {
    descargando = true;
    descargaEsMapa = esMapa;
    _cancelarDescarga = false;
    progresoDescarga = 0;
    textoDescarga = texto;
    WakelockPlus.enable(); // la pantalla no se apaga mientras se descarga
    notifyListeners();
  }

  void _terminarDescarga() {
    descargando = false;
    progresoDescarga = 0;
    textoDescarga = '';
    if (fase != Fase.navegando) WakelockPlus.disable();
    notifyListeners();
  }

  void _progresoDescarga(double p, String texto) {
    progresoDescarga = p.clamp(0.0, 1.0).toDouble();
    textoDescarga = texto;
    notifyListeners();
  }

  void cancelarDescarga() {
    if (!descargando) return;
    _cancelarDescarga = true;
    textoDescarga = 'Cancelando…';
    notifyListeners();
  }

  Future<List<Zona>> buscarMunicipios(String texto, EstadoMx estado) async {
    try {
      final r = await catalogo.buscarMunicipios(texto, estado);
      if (r.isEmpty) _msg('No encontré ese municipio en ${estado.nombre}.');
      return r;
    } on ErrorDescarga catch (e) {
      _msg(e.mensaje);
      return <Zona>[];
    }
  }

  static String _slug(String t) => Fmt.normalizar(t).replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');

  /// Descarga la red vial de OpenStreetMap (Overpass) del país, un estado o un municipio.
  Future<void> descargarRedVial({
    required Alcance alcance,
    EstadoMx? estado,
    Zona? municipio,
    required Detalle detalle,
    required Future<bool> Function(String) confirmar,
  }) async {
    if (descargando) return;
    if (alcance != Alcance.pais && estado == null) return _msg('Elige un estado.');
    if (alcance == Alcance.municipio && municipio == null) return _msg('Busca y elige un municipio.');
    final det = alcance == Alcance.pais ? Detalle.troncal : detalle;
    final dir = await _carpeta('red');
    late final String nombreArchivo;
    if (alcance == Alcance.pais) {
      nombreArchivo = 'red_mexico.geojson';
    } else if (alcance == Alcance.estado) {
      nombreArchivo = 'red_${estado!.iso.substring(3).toLowerCase()}.geojson';
    } else {
      nombreArchivo = 'red_mun_${municipio!.relId}_${_slug(municipio.nombre)}.geojson';
    }
    final destinoArchivo = File(ruta_p.join(dir.path, nombreArchivo));
    final parcial = File('${destinoArchivo.path}.part');

    final lugar = alcance == Alcance.pais ? 'todo México' : (alcance == Alcance.estado ? estado!.nombre : municipio!.nombre);
    final aviso = StringBuffer('Red vial de $lugar\nDetalle: ${det.etiqueta}\n\n')
      ..write('Fuente: OpenStreetMap (Overpass API). Puede tardar varios minutos')
      ..write(alcance == Alcance.pais ? ' (30 o más para todo el país)' : '')
      ..write(' y pesar de decenas a cientos de MB. Mantén la app abierta; la pantalla no se apagará.');
    if (alcance == Alcance.estado && det == Detalle.completo) {
      aviso.write('\n\nOJO: el detalle «Completo» de un estado entero es muy pesado y en un equipo de 4 GB puede no cargar. '
          'Recomendado: Estándar.');
    }
    if (!await confirmar(aviso.toString())) return;

    _iniciarDescarga(false, 'Buscando la zona en OpenStreetMap…');
    try {
      final List<Zona> zonas;
      if (alcance == Alcance.pais) {
        zonas = await catalogo.estados(cancelado: () => _cancelarDescarga);
      } else if (alcance == Alcance.estado) {
        zonas = await catalogo.estados(uno: estado, cancelado: () => _cancelarDescarga);
      } else {
        zonas = <Zona>[municipio!];
      }
      final vias = await DescargadorRed(_overpass).descargar(
        zonas: zonas,
        detalle: det,
        salida: parcial,
        progreso: _progresoDescarga,
        cancelado: () => _cancelarDescarga,
      );
      await parcial.rename(destinoArchivo.path);
      _progresoDescarga(1, 'Cargando la red vial en memoria…');
      await _cargarRedGuardada();
      _msg('Red vial de $lugar lista ($vias vías).');
    } on ErrorDescarga catch (e) {
      await _borrarSilencioso(parcial);
      _msg(e.mensaje);
    } catch (e) {
      await _borrarSilencioso(parcial);
      _msg('Falló la descarga de la red vial: $e');
    } finally {
      _terminarDescarga();
    }
  }

  Future<void> _borrarSilencioso(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Descarga teselas raster del país, un estado o un municipio y las guarda como .mbtiles.
  Future<void> descargarMapa({
    required Alcance alcance,
    EstadoMx? estado,
    Zona? municipio,
    required int zMin,
    required int zMax,
    required String plantilla,
    required Future<bool> Function(String) confirmar,
  }) async {
    if (descargando) return;
    if (alcance != Alcance.pais && estado == null) return _msg('Elige un estado.');
    if (alcance == Alcance.municipio && municipio == null) return _msg('Busca y elige un municipio.');
    final url = plantilla.trim();
    if (!url.contains('{z}') || !url.contains('{x}') || !url.contains('{y}')) {
      return _msg('La URL del servidor debe incluir {z}, {x} y {y}. Ej.: https://servidor/{z}/{x}/{y}.png');
    }
    final uri = Uri.tryParse(url.replaceAll('{z}', '0').replaceAll('{x}', '0').replaceAll('{y}', '0'));
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      return _msg('Usa una URL segura que empiece con https://');
    }
    if (zMax < zMin) return _msg('El zoom máximo debe ser mayor o igual al mínimo ($zMin).');
    await _guardarPlantilla(url);

    _iniciarDescarga(true, 'Buscando la zona…');
    try {
      final Zona zona;
      if (alcance == Alcance.pais) {
        zona = zonaMexico;
      } else if (alcance == Alcance.estado) {
        zona = (await catalogo.estados(uno: estado, cancelado: () => _cancelarDescarga)).first;
      } else {
        zona = municipio!;
      }
      final total = Teselas.contar(zona, zMin, zMax);
      if (total > 400000) {
        _msg('Son $total teselas: demasiadas para un teléfono. Baja el zoom máximo.');
        return;
      }
      final mb = (total * 0.02).round(); // ~20 KB por tesela, solo como referencia
      _progresoDescarga(0, 'Esperando confirmación…');
      final ok = await confirmar('Mapa de ${zona.nombre}\nZoom $zMin a $zMax\n\n'
          '$total teselas (~$mb MB, es un cálculo aproximado)\nServidor: ${uri.host}\n\n'
          'Asegúrate de que ese servidor permita descargar teselas para uso sin conexión. '
          'Mantén la app abierta; la pantalla no se apagará.');
      if (!ok) return;

      final dir = await _carpeta('mapas');
      final nombre = 'mapa_${_slug(zona.nombre)}_z$zMin-$zMax.mbtiles';
      final parcial = File(ruta_p.join(dir.path, '$nombre.part'));
      final destinoArchivo = File(ruta_p.join(dir.path, nombre));
      try {
        final n = await DescargadorMapa().descargar(
          zona: zona,
          plantilla: url,
          zMin: zMin,
          zMax: zMax,
          salida: parcial,
          progreso: _progresoDescarga,
          cancelado: () => _cancelarDescarga,
        );
        if (await destinoArchivo.exists()) await destinoArchivo.delete();
        await parcial.rename(destinoArchivo.path);
        _msg('Mapa de ${zona.nombre} listo ($n teselas).');
      } finally {
        await _borrarSilencioso(parcial);
        await _abrirMapas();
      }
    } on ErrorDescarga catch (e) {
      _msg(e.mensaje);
    } catch (e) {
      _msg('Falló la descarga del mapa: $e');
    } finally {
      _terminarDescarga();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _subBrujula?.cancel();
    brujula.dispose();
    stt.cancelar();
    WakelockPlus.disable();
    super.dispose();
  }
}

// ============================================================================
// 9. INTERFAZ (Material 3)
// ============================================================================

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Vertical fija: la brújula del sensor está calibrada para el teléfono en vertical
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final c = Controlador();
  runApp(AppNavegacion(c));
  c.iniciar(); // abre BD, voz, mapas, red vial y GPS sin bloquear el primer frame
}

class AppNavegacion extends StatelessWidget {
  final Controlador c;
  const AppNavegacion(this.c, {super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Navegación Offline MX',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF1565C0)),
        darkTheme: ThemeData(
            useMaterial3: true, colorSchemeSeed: const Color(0xFF1565C0), brightness: Brightness.dark),
        home: PantallaPrincipal(c),
      );
}

const List<String> _categorias = ['Campo', 'Obra', 'Cultivo', 'Agua', 'Peligro', 'Acceso'];

class PantallaPrincipal extends StatefulWidget {
  final Controlador c;
  const PantallaPrincipal(this.c, {super.key});

  @override
  State<PantallaPrincipal> createState() => _EstadoPantalla();
}

class _EstadoPantalla extends State<PantallaPrincipal> with WidgetsBindingObserver {
  final MapController _mapa = MapController();
  bool _listo = false, _seguir = true, _centrado = false;
  Ruta? _rutaVista;
  Fase _faseVista = Fase.inactiva;

  Controlador get c => widget.c;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(_alCambiar);
    c.brujula.addListener(_alBrujula);
  }

  @override
  void dispose() {
    c.removeListener(_alCambiar);
    c.brujula.removeListener(_alBrujula);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Segundo plano sin navegar: apaga el GPS (ahorro de batería). Al volver, lo reactiva.
  @override
  void didChangeAppLifecycleState(AppLifecycleState estado) {
    if (estado == AppLifecycleState.resumed) {
      c.alMostrar();
    } else if (estado == AppLifecycleState.paused) {
      c.alOcultar();
    }
  }

  int _ultimoGiroMs = 0;
  double _ultimoGiro = 0;

  /// Modo «rumbo arriba»: gira el mapa con la brújula (máx. ~10 veces/s y solo si cambia >2°).
  void _alBrujula() {
    if (!mounted || !c.rumboArriba || !_listo) return;
    final h = c.brujula.value;
    if (h == null) return;
    final ahora = DateTime.now().millisecondsSinceEpoch;
    if (ahora - _ultimoGiroMs < 100 || Geo.difAng(_ultimoGiro, h).abs() < 2.0) return;
    _ultimoGiroMs = ahora;
    _ultimoGiro = h;
    _mapa.rotate(-h);
  }

  void _alPulsarBrujula() {
    c.alternarRumboArriba();
    if (!_listo) return;
    final h = c.brujula.value;
    if (c.rumboArriba && h != null) {
      _ultimoGiro = h;
      _mapa.rotate(-h);
    } else {
      _mapa.rotate(0);
    }
  }

  /// Encuadra el área que cubren los .mbtiles cargados (por si estás fuera de ella).
  Future<void> _irAlAreaMapa() async {
    final b = c.limitesMapa;
    if (b == null || !_listo) return;
    setState(() => _seguir = false);
    try {
      _mapa.fitCamera(CameraFit.bounds(bounds: b, padding: const EdgeInsets.all(24)));
    } catch (_) {}
  }

  void _alCambiar() {
    if (!mounted) return;
    final m = c.mensaje;
    if (m != null) {
      c.mensaje = null;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(m)));
    }
    final u = c.ubic;
    if (_listo && u != null) {
      final p = LatLng(u.latitude, u.longitude);
      if (!_centrado) {
        _centrado = true;
        _mapa.move(p, 16);
      } else if (_seguir) {
        _mapa.move(p, _mapa.camera.zoom);
      }
    }
    if (c.fase == Fase.navegando && _faseVista != Fase.navegando) {
      _seguir = true;
      if (_listo && u != null) _mapa.move(LatLng(u.latitude, u.longitude), 17.5);
    }
    _faseVista = c.fase;
    final r = c.ruta;
    if (r == null) {
      _rutaVista = null;
    } else if (!identical(r, _rutaVista)) {
      _rutaVista = r;
      if (c.fase != Fase.navegando && _listo && r.puntos.length >= 2) {
        _seguir = false;
        try {
          _mapa.fitCamera(CameraFit.bounds(
              bounds: LatLngBounds.fromPoints(r.puntos), padding: const EdgeInsets.fromLTRB(40, 160, 40, 340)));
        } catch (_) {}
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final esc = Theme.of(context).colorScheme;
        return Scaffold(
          body: Stack(children: [
            Positioned.fill(child: _widgetMapa()),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(children: [
                  _chipGps(),
                  if (!c.permisoOk)
                    _aviso('Falta el permiso de ubicación.', 'Conceder', () async {
                      await c.iniciarGps(reiniciar: true);
                      if (!c.permisoOk) await Geolocator.openAppSettings();
                    }),
                  if (!c.permisosCompletos)
                    _aviso('Faltan permisos: ubicación, micrófono, notificaciones o archivos.', 'Conceder',
                        c.pedirTodosPermisos),
                  if (c.permisoOk && !c.gpsActivo)
                    _aviso('El GPS está apagado.', 'Activar', Geolocator.openLocationSettings),
                  if (c.mapas.isEmpty)
                    _aviso('Sin mapas offline. Copia tu .mbtiles a la carpeta Descargas.', 'Buscar', c.buscarEnDescargas),
                  if (c.mapas.isNotEmpty && c.fueraDeMapa)
                    _aviso('Estás fuera del área de tu mapa descargado.', 'Ver mapa', _irAlAreaMapa),
                  if (c.fase == Fase.navegando) _banner(esc),
                ]),
              ),
            ),
            Positioned(
              right: 8,
              top: MediaQuery.of(context).size.height * 0.26,
              child: Column(children: [
                Brujula(
                  rumbo: c.brujula,
                  disponible: c.brujulaDisponible,
                  rumboArriba: c.rumboArriba,
                  alPulsar: _alPulsarBrujula,
                ),
                const SizedBox(height: 8),
                _botonRedondo(Icons.my_location, _seguir, () {
                  setState(() => _seguir = !_seguir);
                  final u = c.ubic;
                  if (_seguir && _listo && u != null) _mapa.move(LatLng(u.latitude, u.longitude), _mapa.camera.zoom);
                }),
                const SizedBox(height: 8),
                _botonRedondo(c.escuchando ? Icons.mic : Icons.mic_none, c.escuchando, c.alternarEscucha),
                const SizedBox(height: 8),
                _botonRedondo(c.vozActiva ? Icons.volume_up : Icons.volume_off, false,
                    () => c.establecerVoz(!c.vozActiva)),
              ]),
            ),
            Align(alignment: Alignment.bottomCenter, child: SafeArea(child: _panelInferior(context))),
          ]),
        );
      },
    );
  }

  // ----------------------------------------------------------------- mapa
  Widget _widgetMapa() {
    final u = c.ubic;
    final r = c.ruta;
    final d = c.destino;
    return FlutterMap(
      mapController: _mapa,
      options: MapOptions(
        initialCenter: const LatLng(23.6345, -102.5528), // México; se recentra con el primer fix GPS
        initialZoom: 5,
        minZoom: 3,
        maxZoom: 19,
        backgroundColor: const Color(0xFFE0E0E0),
        onMapReady: () => _listo = true,
        onLongPress: (_, ll) => c.establecerDestino(ll, 'Punto del mapa'),
        onPositionChanged: (pos, hayGesto) {
          if (hayGesto && _seguir) setState(() => _seguir = false); // el usuario movió el mapa
        },
      ),
      children: [
        TileLayer(
          key: ValueKey<int>(c.versionMapas),
          tileProvider: c.proveedorTiles,
          // Rango real de zoom del .mbtiles: más allá, flutter_map amplía las teselas en vez de dejar blanco
          minNativeZoom: c.zoomMinTiles,
          maxNativeZoom: c.zoomMaxTiles,
          maxZoom: 19,
          errorTileCallback: (tile, error, stack) {},
        ),
        if (r != null)
          PolylineLayer(polylines: [Polyline(points: r.puntos, strokeWidth: 6, color: Colors.blue.shade700)]),
        MarkerLayer(rotate: true, markers: [ // rotate: los pines no se giran con el mapa
          for (final p in c.pois)
            Marker(
              point: LatLng(p.lat, p.lon),
              width: 40,
              height: 40,
              alignment: Alignment.topCenter,
              child: GestureDetector(
                onTap: () => c.irAPoi(p),
                child: const Icon(Icons.flag, color: Colors.orange, size: 36),
              ),
            ),
          if (d != null)
            Marker(
              point: d,
              width: 44,
              height: 44,
              alignment: Alignment.topCenter,
              child: const Icon(Icons.location_on, color: Colors.red, size: 44),
            ),
          if (u != null)
            Marker(
              point: LatLng(u.latitude, u.longitude),
              width: 26,
              height: 26,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1565C0),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                ),
              ),
            ),
        ]),
      ],
    );
  }

  // ------------------------------------------------------------ superposiciones
  Widget _chipGps() {
    final u = c.ubic;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          u == null ? 'Buscando señal GPS…' : 'GPS ±${u.accuracy.round()} m · ${c.velKmh.round()} km/h',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _aviso(String texto, String accion, Future<void> Function() alAccion) => Card(
        color: Colors.amber.shade100,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(children: [
            Expanded(child: Text(texto, style: const TextStyle(color: Colors.black87))),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.indigo.shade900),
              onPressed: alAccion,
              child: Text(accion, style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ]),
        ),
      );

  Widget _banner(ColorScheme esc) {
    final m = c.proxima;
    if (m == null) return const SizedBox.shrink();
    return Card(
      color: esc.primary,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Text(m.tipo.flecha, style: const TextStyle(fontSize: 34)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(Fmt.dist(c.distProxima),
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: esc.onPrimary)),
              Text(m.texto, style: TextStyle(fontSize: 16, color: esc.onPrimary)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _botonRedondo(IconData icono, bool activo, VoidCallback alPulsar) {
    final esc = Theme.of(context).colorScheme;
    return Material(
      elevation: 4,
      shape: const CircleBorder(),
      color: activo ? esc.primary : esc.surface,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: alPulsar,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(icono, color: activo ? esc.onPrimary : esc.onSurface),
        ),
      ),
    );
  }

  // --------------------------------------------------------------- panel inferior
  Widget _panelInferior(BuildContext context) {
    final esc = Theme.of(context).colorScheme;
    final eta = c.etaS;
    return Card(
      margin: const EdgeInsets.all(8),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(10),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (c.fase == Fase.llegada)
              Row(children: [
                Expanded(
                  child: Text('🏁 Has llegado a ${c.destinoNombre}',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
                FilledButton(onPressed: c.confirmarLlegada, child: const Text('Aceptar')),
              ])
            else ...[
              Row(children: [
                for (final m in Modo.values)
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => c.seleccionarModo(m),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        decoration: BoxDecoration(
                          color: c.modo == m ? esc.primaryContainer : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(children: [
                          Text(m.emoji, style: const TextStyle(fontSize: 22)),
                          Text(m.etiqueta,
                              maxLines: 1,
                              style: TextStyle(
                                  fontSize: 10, fontWeight: c.modo == m ? FontWeight.bold : FontWeight.normal)),
                        ]),
                      ),
                    ),
                  ),
              ]),
              const SizedBox(height: 8),
              if (c.destino == null)
                const Text(
                    'Mantén presionado el mapa para elegir un destino, o abre Lugares / Rutas.',
                    style: TextStyle(fontSize: 13))
              else ...[
                Text('Destino: ${c.destinoNombre}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(child: _stat('Distancia', Fmt.dist(c.restanteM))),
                  Expanded(child: _stat('Velocidad', '${c.velKmh.round()} km/h')),
                  Expanded(
                    child: _stat(
                        'ETA',
                        eta == null
                            ? '—'
                            : '${Fmt.dur(eta)} · ${Fmt.hora(DateTime.now().add(Duration(seconds: eta)))}'),
                  ),
                ]),
                if (c.calculando) const Padding(padding: EdgeInsets.only(top: 6), child: LinearProgressIndicator()),
                const SizedBox(height: 6),
                Row(children: [
                  if (c.fase == Fase.navegando)
                    Expanded(
                      child: FilledButton.tonal(onPressed: c.cancelarNavegacion, child: const Text('Detener')),
                    )
                  else
                    Expanded(
                      child: FilledButton(
                          onPressed: c.ruta != null && !c.calculando ? c.iniciarNavegacion : null,
                          child: const Text('Iniciar')),
                    ),
                  const SizedBox(width: 8),
                  OutlinedButton(onPressed: () => dialogoRuta(context, c), child: const Text('Guardar ruta')),
                  if (c.fase != Fase.navegando) TextButton(onPressed: c.limpiarDestino, child: const Text('Quitar')),
                ]),
              ],
              const SizedBox(height: 4),
              Row(children: [
                _menu('➕ Punto', () => dialogoPunto(context, c)),
                _menu('📍 Lugares', () => _abrirMenu(0)),
                _menu('🔁 Rutas', () => _abrirMenu(1)),
                _menu('🕘 Historial', () => _abrirMenu(2)),
                _menu('⚙️ Ajustes', () => _abrirMenu(3)),
              ]),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _stat(String titulo, String valor) => Column(children: [
        Text(titulo, style: const TextStyle(fontSize: 11)),
        Text(valor,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
      ]);

  Widget _menu(String texto, VoidCallback alPulsar) => Expanded(
        child: TextButton(
          style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 2)),
          onPressed: alPulsar,
          child: FittedBox(child: Text(texto, style: const TextStyle(fontSize: 12))),
        ),
      );

  void _abrirMenu(int pestana) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => PantallaMenu(c, pestana)));
}

// ============================================================================
// 10. MENÚ: LUGARES, RUTAS, HISTORIAL Y AJUSTES
// ============================================================================

class PantallaMenu extends StatelessWidget {
  final Controlador c;
  final int inicial;
  const PantallaMenu(this.c, this.inicial, {super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      initialIndex: inicial,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Menú'),
          bottom: const TabBar(tabs: [
            Tab(text: 'Lugares'),
            Tab(text: 'Rutas'),
            Tab(text: 'Historial'),
            Tab(text: 'Ajustes'),
          ]),
        ),
        body: ListenableBuilder(
          listenable: c,
          builder: (ctx, _) => TabBarView(children: [
            _lugares(ctx),
            _rutas(ctx),
            _historial(ctx),
            _ajustes(ctx),
          ]),
        ),
      ),
    );
  }

  Widget _vacio(String t) => Padding(padding: const EdgeInsets.all(16), child: Text(t));

  Widget _lugares(BuildContext ctx) {
    if (c.pois.isEmpty) return _vacio('Aún no hay lugares guardados. Usa «➕ Punto» en la pantalla principal.');
    return ListView.separated(
      itemCount: c.pois.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final p = c.pois[i];
        return ListTile(
          title: Text(p.nombre),
          subtitle: Text('${p.categoria} · ${p.lat.toStringAsFixed(5)}, ${p.lon.toStringAsFixed(5)}'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            FilledButton(
                onPressed: () {
                  c.irAPoi(p);
                  Navigator.pop(ctx);
                },
                child: const Text('Ir')),
            IconButton(onPressed: () => c.eliminarPoi(p), icon: const Icon(Icons.delete_outline)),
          ]),
        );
      },
    );
  }

  Widget _rutas(BuildContext ctx) {
    if (c.rutasFrec.isEmpty) return _vacio('Aún no hay rutas frecuentes. Elige un destino y pulsa «Guardar ruta».');
    return ListView.separated(
      itemCount: c.rutasFrec.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final r = c.rutasFrec[i];
        final modo = Modo.values.firstWhere((m) => m.name == r.modo, orElse: () => Modo.auto);
        return ListTile(
          title: Text('${modo.emoji} ${r.nombre}'),
          subtitle: Text('Destino: ${r.destinoNombre} · usada ${r.veces} veces'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            FilledButton(
                onPressed: () {
                  c.usarRutaFrecuente(r);
                  Navigator.pop(ctx);
                },
                child: const Text('Ir')),
            IconButton(onPressed: () => c.eliminarRutaFrecuente(r), icon: const Icon(Icons.delete_outline)),
          ]),
        );
      },
    );
  }

  Widget _historial(BuildContext ctx) {
    if (c.historial.isEmpty) return _vacio('Todavía no hay navegaciones registradas.');
    return Column(children: [
      Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: OutlinedButton(onPressed: c.borrarHistorial, child: const Text('Borrar historial')),
        ),
      ),
      Expanded(
        child: ListView.separated(
          itemCount: c.historial.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final h = c.historial[i];
            final modo = Modo.values.firstWhere((m) => m.name == h.modo, orElse: () => Modo.auto);
            final dur = h.finMs == null ? '—' : Fmt.dur((h.finMs! - h.inicioMs) ~/ 1000);
            return ListTile(
              title: Text('${h.completada ? '✅' : '⛔'} ${modo.emoji} ${h.destinoNombre}'),
              subtitle: Text('${Fmt.fechaHora(h.inicioMs)} · ${Fmt.dist(h.recorrido)} · $dur'),
            );
          },
        ),
      ),
    ]);
  }

  static String _tamanoArchivo(File f) {
    try {
      return '${(f.lengthSync() / 1048576).toStringAsFixed(1)} MB';
    } catch (_) {
      return '';
    }
  }

  Widget _ajustes(BuildContext ctx) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Guía por voz'),
        value: c.vozActiva,
        onChanged: c.establecerVoz,
      ),
      Text('Reconocimiento de voz: ${c.stt.estadoModelo}', style: const TextStyle(fontSize: 12)),
      const Divider(),
      const Text('Permisos', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      FilledButton(onPressed: c.pedirTodosPermisos, child: const Text('Conceder permisos')),
      const SizedBox(height: 8),
      OutlinedButton(onPressed: openAppSettings, child: const Text('Abrir ajustes de la app')),
      const Divider(),
      const Text('Mapas offline (.mbtiles raster)', style: TextStyle(fontWeight: FontWeight.bold)),
      if (c.mapas.isEmpty) const Text('No hay mapas. Copia el .mbtiles a la carpeta Descargas y pulsa «Buscar en Descargas».'),
      for (final m in c.mapas)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(m.enDescargas ? Icons.download_done : Icons.folder),
          title: Text(m.nombre, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${m.enDescargas ? 'Leído desde Descargas' : 'Importado a la app'} · zoom ${c.zoomMinTiles}–${c.zoomMaxTiles}'),
          trailing: m.enDescargas
              ? null
              : IconButton(onPressed: () => c.eliminarMapa(m), icon: const Icon(Icons.delete_outline)),
        ),
      FilledButton(onPressed: c.buscarEnDescargas, child: const Text('Buscar en Descargas')),
      const SizedBox(height: 8),
      OutlinedButton(onPressed: c.importarMapa, child: const Text('Elegir y copiar un .mbtiles…')),
      const Divider(),
      const Text('Red vial para enrutamiento', style: TextStyle(fontWeight: FontWeight.bold)),
      Text(c.redEstado),
      for (final f in c.regionesRed)
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: const Icon(Icons.alt_route),
          title: Text(ruta_p.basename(f.path), maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(_tamanoArchivo(f)),
          trailing: IconButton(onPressed: () => c.eliminarRegionRed(f), icon: const Icon(Icons.delete_outline)),
        ),
      const SizedBox(height: 8),
      FilledButton(onPressed: c.importarRedVial, child: const Text('Importar red vial (GeoJSON)')),
      if (c.redCargada)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: OutlinedButton(onPressed: c.quitarRedVial, child: const Text('Quitar toda la red vial')),
        ),
      const Divider(),
      // ---- Descargas desde repositorios públicos (se despliegan al tocarlas) ----
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        leading: const Icon(Icons.map_outlined),
        title: const Text('Descargar mapas MBTiles'),
        subtitle: const Text('País, estado o municipio'),
        children: [PanelDescarga(c, esMapa: true)],
      ),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        leading: const Icon(Icons.alt_route),
        title: const Text('Descargar red vial para enrutamiento'),
        subtitle: const Text('País, estado o municipio'),
        children: [PanelDescarga(c, esMapa: false)],
      ),
      const SizedBox(height: 24),
    ]);
  }
}

// ============================================================================
// 10B. PANEL DE DESCARGA (mapas MBTiles / red vial) — se despliega desde Ajustes
// ============================================================================

class PanelDescarga extends StatefulWidget {
  final Controlador c;
  final bool esMapa; // true = mapas MBTiles, false = red vial
  const PanelDescarga(this.c, {required this.esMapa, super.key});

  @override
  State<PanelDescarga> createState() => _EstadoPanelDescarga();
}

class _EstadoPanelDescarga extends State<PanelDescarga> {
  Alcance _alcance = Alcance.estado;
  EstadoMx _estado = estadosMx.firstWhere((e) => e.iso == 'MX-JAL');
  final TextEditingController _txtMunicipio = TextEditingController();
  late final TextEditingController _txtUrl;
  List<Zona> _resultados = <Zona>[];
  Zona? _municipio;
  bool _buscando = false;
  Detalle _detalle = Detalle.estandar;
  int _zMax = 12;

  static int _zMinPara(Alcance a) => a == Alcance.pais ? 4 : (a == Alcance.estado ? 6 : 10);
  static int _zMaxPara(Alcance a) => a == Alcance.pais ? 8 : (a == Alcance.estado ? 12 : 15);

  @override
  void initState() {
    super.initState();
    _txtUrl = TextEditingController(text: widget.c.plantillaTeselas);
  }

  @override
  void dispose() {
    _txtMunicipio.dispose();
    _txtUrl.dispose();
    super.dispose();
  }

  Future<void> _buscarMunicipio() async {
    final t = _txtMunicipio.text.trim();
    if (t.isEmpty) return;
    setState(() {
      _buscando = true;
      _resultados = <Zona>[];
      _municipio = null;
    });
    final r = await widget.c.buscarMunicipios(t, _estado);
    if (!mounted) return;
    setState(() {
      _buscando = false;
      _resultados = r;
      if (r.length == 1) _municipio = r.first;
    });
  }

  Future<bool> _confirmar(String texto) async {
    if (!mounted) return false;
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmar descarga'),
        content: SingleChildScrollView(child: Text(texto)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Descargar')),
        ],
      ),
    );
    return r ?? false;
  }

  Future<void> _descargar() async {
    final c = widget.c;
    if (widget.esMapa) {
      await c.descargarMapa(
        alcance: _alcance,
        estado: _estado,
        municipio: _municipio,
        zMin: _zMinPara(_alcance),
        zMax: _zMax,
        plantilla: _txtUrl.text,
        confirmar: _confirmar,
      );
    } else {
      await c.descargarRedVial(
        alcance: _alcance,
        estado: _estado,
        municipio: _municipio,
        detalle: _detalle,
        confirmar: _confirmar,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return ListenableBuilder(
      listenable: c,
      builder: (ctx, _) {
        final ocupado = c.descargando;
        final miDescarga = ocupado && c.descargaEsMapa == widget.esMapa;
        return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('¿Qué zona necesitas?'),
          const SizedBox(height: 8),
          SegmentedButton<Alcance>(
            segments: const <ButtonSegment<Alcance>>[
              ButtonSegment<Alcance>(value: Alcance.pais, label: Text('País')),
              ButtonSegment<Alcance>(value: Alcance.estado, label: Text('Estado')),
              ButtonSegment<Alcance>(value: Alcance.municipio, label: Text('Municipio')),
            ],
            selected: <Alcance>{_alcance},
            onSelectionChanged: ocupado
                ? null
                : (s) => setState(() {
                      _alcance = s.first;
                      _zMax = _zMaxPara(_alcance);
                    }),
          ),
          if (_alcance != Alcance.pais) ...[
            const SizedBox(height: 12),
            DropdownButton<EstadoMx>(
              isExpanded: true,
              value: _estado,
              items: [
                for (final e in estadosMx) DropdownMenuItem<EstadoMx>(value: e, child: Text(e.nombre)),
              ],
              onChanged: ocupado
                  ? null
                  : (e) => setState(() {
                        if (e != null) {
                          _estado = e;
                          _municipio = null;
                          _resultados = <Zona>[];
                        }
                      }),
            ),
          ],
          if (_alcance == Alcance.municipio) ...[
            TextField(
              controller: _txtMunicipio,
              enabled: !ocupado,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: 'Municipio de ${_estado.nombre} (ej. Zapopan)',
                suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: ocupado ? null : _buscarMunicipio),
              ),
              onSubmitted: (_) => _buscarMunicipio(),
            ),
            if (_buscando) const LinearProgressIndicator(),
            for (final z in _resultados)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                selected: identical(z, _municipio),
                leading: Icon(identical(z, _municipio) ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                title: Text(z.nombre, maxLines: 2, overflow: TextOverflow.ellipsis),
                onTap: ocupado ? null : () => setState(() => _municipio = z),
              ),
          ],
          const SizedBox(height: 12),
          if (widget.esMapa) ...[
            TextField(
              controller: _txtUrl,
              enabled: !ocupado,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Servidor de teselas raster (XYZ)',
                hintText: 'https://tu-servidor/{z}/{x}/{y}.png',
                helperMaxLines: 6,
                helperText: 'La app no trae un servidor fijo: usa uno propio o de un proveedor cuya licencia permita '
                    'descargar para uso sin conexión. El servidor público de OpenStreetMap '
                    '(tile.openstreetmap.org) lo prohíbe.',
              ),
            ),
            Row(children: [
              Text('Zoom: ${_zMinPara(_alcance)} a '),
              DropdownButton<int>(
                value: _zMax,
                items: [for (var z = 8; z <= 17; z++) DropdownMenuItem<int>(value: z, child: Text('$z'))],
                onChanged: ocupado ? null : (v) => setState(() => _zMax = v ?? _zMax),
              ),
              const SizedBox(width: 8),
              const Expanded(child: Text('Más zoom = más detalle y mucho más peso.', style: TextStyle(fontSize: 12))),
            ]),
          ] else ...[
            if (_alcance == Alcance.pais)
              const Text('Para todo el país se descargan solo las carreteras principales '
                  '(autopistas, troncales y primarias).')
            else
              DropdownButton<Detalle>(
                isExpanded: true,
                value: _detalle,
                items: [
                  for (final d in Detalle.values)
                    if (d != Detalle.troncal)
                      DropdownMenuItem<Detalle>(value: d, child: Text(d.etiqueta, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: ocupado ? null : (v) => setState(() => _detalle = v ?? _detalle),
              ),
            const SizedBox(height: 4),
            const Text(
              'Se guarda en la app y se une con las regiones que ya tengas (las rutas pueden cruzar de una a otra).',
              style: TextStyle(fontSize: 12),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: ocupado ? null : _descargar,
            icon: const Icon(Icons.download),
            label: Text(widget.esMapa ? 'Descargar mapa' : 'Descargar red vial'),
          ),
          if (miDescarga) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: c.progresoDescarga > 0 ? c.progresoDescarga : null),
            const SizedBox(height: 4),
            Text(c.textoDescarga, style: const TextStyle(fontSize: 12)),
            TextButton(onPressed: c.cancelarDescarga, child: const Text('Cancelar descarga')),
          ],
        ]),
      );
      },
    );
  }
}

// ============================================================================
// 11. DIÁLOGOS
// ============================================================================

Future<void> dialogoPunto(BuildContext context, Controlador c) async {
  final nombre = TextEditingController();
  var cat = _categorias.first;
  var usarDestino = false;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: const Text('Guardar punto de interés'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(controller: nombre, decoration: const InputDecoration(labelText: 'Nombre')),
            const SizedBox(height: 8),
            Wrap(spacing: 6, children: [
              for (final k in _categorias)
                ChoiceChip(label: Text(k), selected: cat == k, onSelected: (_) => setS(() => cat = k)),
            ]),
            if (c.destino != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Usar el destino seleccionado'),
                subtitle: const Text('Si no, se guarda mi ubicación actual'),
                value: usarDestino,
                onChanged: (v) => setS(() => usarDestino = v),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () {
              c.guardarPunto(nombre.text, cat, usarDestino);
              Navigator.pop(ctx);
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    ),
  );
  nombre.dispose();
}

Future<void> dialogoRuta(BuildContext context, Controlador c) async {
  final nombre = TextEditingController(text: c.destinoNombre);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Guardar ruta frecuente'),
      content: TextField(controller: nombre, decoration: const InputDecoration(labelText: 'Nombre de la ruta')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        FilledButton(
          onPressed: () {
            c.guardarRutaFrecuente(nombre.text);
            Navigator.pop(ctx);
          },
          child: const Text('Guardar'),
        ),
      ],
    ),
  );
  nombre.dispose();
}

// ============================================================================
// 12. BRÚJULA (flutter_compass)
// ============================================================================

/// Brújula circular: el disco gira en sentido contrario al rumbo del teléfono, de modo que la «N»
/// siempre señala el norte; el triángulo fijo de arriba marca hacia dónde apunta el teléfono.
/// Toque = alternar «norte arriba» / «rumbo arriba» (el mapa gira con la brújula).
class Brujula extends StatelessWidget {
  final ValueListenable<double?> rumbo;
  final bool disponible;
  final bool rumboArriba;
  final VoidCallback alPulsar;

  const Brujula({
    super.key,
    required this.rumbo,
    required this.disponible,
    required this.rumboArriba,
    required this.alPulsar,
  });

  static String _punto(double g) {
    const p = ['N', 'NE', 'E', 'SE', 'S', 'SO', 'O', 'NO'];
    return p[((g + 22.5) / 45.0).floor() % 8];
  }

  @override
  Widget build(BuildContext context) {
    final esc = Theme.of(context).colorScheme;
    return Material(
      elevation: 4,
      shape: const CircleBorder(),
      color: rumboArriba ? esc.primaryContainer : esc.surface,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: alPulsar,
        child: SizedBox(
          width: 80,
          height: 80,
          child: ValueListenableBuilder<double?>(
            valueListenable: rumbo,
            builder: (context, h, _) {
              if (!disponible || h == null) {
                return Center(
                  child: Text(
                    disponible ? 'Brújula…' : 'Sin\nsensor',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11),
                  ),
                );
              }
              return Stack(alignment: Alignment.center, children: [
                Transform.rotate(
                  angle: -h * math.pi / 180.0,
                  child: CustomPaint(size: const Size(80, 80), painter: _PintorDial(esc.onSurface, esc.error)),
                ),
                Align(
                  alignment: Alignment.topCenter,
                  child: Icon(Icons.arrow_drop_down, color: esc.primary, size: 26),
                ),
                Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('${h.round()}°', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  Text(_punto(h), style: const TextStyle(fontSize: 10)),
                ]),
              ]);
            },
          ),
        ),
      ),
    );
  }
}

class _PintorDial extends CustomPainter {
  final Color color;
  final Color norte;
  const _PintorDial(this.color, this.norte);

  @override
  void paint(Canvas canvas, Size size) {
    final centro = size.center(Offset.zero);
    final r = size.width / 2;
    final marca = Paint()
      ..color = color.withAlpha(150)
      ..strokeWidth = 1.5;
    // Marcas cada 30° (0° = arriba)
    for (var g = 0; g < 360; g += 30) {
      if (g % 90 == 0) continue; // en los cardinales va la letra
      final a = (g - 90) * math.pi / 180.0;
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(centro + dir * (r - 8), centro + dir * (r - 2), marca);
    }
    const letras = <int, String>{0: 'N', 90: 'E', 180: 'S', 270: 'O'};
    letras.forEach((g, t) {
      final tp = TextPainter(
        text: TextSpan(
          text: t,
          style: TextStyle(color: g == 0 ? norte : color, fontSize: 13, fontWeight: FontWeight.bold),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final a = (g - 90) * math.pi / 180.0;
      final p = centro + Offset(math.cos(a), math.sin(a)) * (r - 14);
      tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
    });
  }

  @override
  bool shouldRepaint(covariant _PintorDial o) => o.color != color || o.norte != norte;
}

