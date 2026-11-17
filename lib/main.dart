// ============================================================================
//  NAVEGACIÓN MULTIMODAL OFFLINE — MÉXICO (Flutter, un solo main.dart)
//  GPS en tiempo real · mapas MBTiles locales · enrutamiento A* sobre GeoJSON
//  Voz (TTS/STT) manos libres · SQLite local (POIs, rutas frecuentes, historial)
//  Sin internet en tiempo de ejecución. Requiere Dart >= 3.0.
// ============================================================================
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
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as ruta_p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';
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

/// Construye el grafo desde un GeoJSON de OSM. Se ejecuta en un isolate (no congela la UI).
RedVial construirRed(String rutaArchivo) {
  final datos = jsonDecode(File(rutaArchivo).readAsStringSync());
  final features = datos is Map ? datos['features'] : datos;

  final claveANodo = <int, int>{};
  final lats = <double>[], lons = <double>[];
  final ef = <int>[], et = <int>[], ec = <int>[], ek = <int>[];
  final ed = <double>[];

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

  if (features is List) {
    for (final f in features) {
      if (f is! Map) continue;
      final props = f['properties'];
      final geom = f['geometry'];
      if (props is! Map || geom is! Map) continue;
      final claseVia = claseDesdeOsm(props['highway']?.toString());
      if (claseVia == null) continue;
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
  }
  if (ef.isEmpty) {
    throw Exception("El archivo no contiene vías (LineString con propiedad 'highway').");
  }

  // Compactar a CSR
  final n = lats.length, m = ef.length;
  final offs = Int32List(n + 1);
  for (final a in ef) {
    offs[a + 1]++;
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
  return RedVial(Float64List.fromList(lats), Float64List.fromList(lons), offs, dest, dist, clase, contra);
}

/// Motor de enrutamiento local: A* con red vial cargada; línea recta como respaldo.
class MotorRutas {
  RedVial? red;
  static const double _maxAjusteM = 3000;

  Future<int> cargar(String rutaArchivo) async {
    final nueva = await Isolate.run(() => construirRed(rutaArchivo));
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

/// Reconocimiento de voz para comandos manos libres. Prefiere el modo sin conexión (requiere el paquete
/// de voz en español descargado en Google > Ajustes > Voz > Reconocimiento sin conexión).
class Escucha {
  final SpeechToText _stt = SpeechToText();
  bool _init = false;
  void Function(bool)? _alEstado;
  void Function(String)? _alError;

  Future<void> escuchar({
    required void Function(String) alResultado,
    required void Function(String) alError,
    required void Function(bool) alEstado,
  }) async {
    _alEstado = alEstado;
    _alError = alError;
    if (!_init) {
      _init = await _stt.initialize(
        onStatus: (s) {
          if (s == 'done' || s == 'notListening') _alEstado?.call(false);
        },
        onError: (e) {
          _alEstado?.call(false);
          _alError?.call('Voz: ${e.errorMsg}. Revisa el permiso de micrófono y el paquete de voz sin conexión.');
        },
      );
    }
    if (!_init) {
      alError('Reconocimiento de voz no disponible o permiso de micrófono negado.');
      return;
    }
    String? idioma;
    for (final l in await _stt.locales()) {
      final id = l.localeId.replaceAll('-', '_');
      if (id == 'es_MX') {
        idioma = l.localeId;
        break;
      }
      if (id.startsWith('es') && idioma == null) idioma = l.localeId;
    }
    alEstado(true);
    await _stt.listen(
      onResult: (r) {
        if (r.finalResult) {
          alEstado(false);
          if (r.recognizedWords.trim().isEmpty) {
            alError('No te escuché, intenta de nuevo.');
          } else {
            alResultado(r.recognizedWords);
          }
        }
      },
      localeId: idioma,
      listenFor: const Duration(seconds: 8),
      pauseFor: const Duration(seconds: 3),
      listenOptions: SpeechListenOptions(onDevice: true, partialResults: false, cancelOnError: true),
    );
  }

  Future<void> cancelar() => _stt.cancel();
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

/// 1x1 PNG transparente para teselas que no existen en el archivo.
final Uint8List _pngVacio = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

class _ImagenMbTile extends ImageProvider<_ImagenMbTile> {
  final List<Database> bases;
  final int x, y, z;
  const _ImagenMbTile(this.bases, this.x, this.y, this.z);

  Future<Uint8List> _leer() async {
    final fila = (1 << z) - 1 - y; // MBTiles usa esquema TMS (eje Y invertido)
    for (final db in bases) {
      try {
        final r = await db.rawQuery(
            'SELECT tile_data FROM tiles WHERE zoom_level = ? AND tile_column = ? AND tile_row = ? LIMIT 1',
            [z, x, fila]);
        if (r.isNotEmpty) {
          final d = r.first['tile_data'];
          if (d is Uint8List) return d;
        }
      } catch (_) {}
    }
    return _pngVacio;
  }

  Future<ui.Codec> _decodificar(ImageDecoderCallback decode) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(await _leer());
    return decode(buffer);
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
// 8. CONTROLADOR (equivalente al ViewModel): estado + lógica de navegación
// ============================================================================

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
  List<String> mapas = [];
  int versionMapas = 0;
  String? mensaje;
  List<Poi> pois = [];
  List<RutaFrec> rutasFrec = [];
  List<Hist> historial = [];
  TileProvider proveedorTiles = ProveedorMbTiles(const []);

  // --- Estado interno ---
  StreamSubscription<Position>? _sub;
  final List<Database> _basesMb = [];
  int _idxSeg = 0, _desvios = 0, _ultimoRecalculo = 0;
  final Set<int> _anunciadas = {};
  double _velSuave = 0, _recorridoM = 0;
  int? _histId;
  String? _ultimaInstr;
  bool _gpsConNotificacion = false;

  void _msg(String t) {
    mensaje = t;
    notifyListeners();
  }

  Future<void> iniciar() async {
    voz.alError = _msg;
    await datos.abrir();
    await _recargar();
    await voz.iniciar();
    await _abrirMapas();
    await _cargarRedGuardada();
    await iniciarGps();
  }

  Future<void> _recargar() async {
    pois = await datos.pois();
    rutasFrec = await datos.rutas();
    historial = await datos.historial();
    notifyListeners();
  }

  // ------------------------------------------------------------------ GPS
  Future<void> alMostrar() => iniciarGps();

  Future<void> alOcultar() async {
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

  // ---------------------------------------------------- mapas y red vial
  Future<Directory> _carpeta(String nombre) async {
    final base = await getApplicationDocumentsDirectory();
    return Directory(ruta_p.join(base.path, nombre)).create(recursive: true);
  }

  Future<void> _abrirMapas() async {
    for (final d in _basesMb) {
      await d.close();
    }
    _basesMb.clear();
    final carpeta = await _carpeta('mapas');
    final archivos = carpeta
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.mbtiles'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in archivos) {
      try {
        _basesMb.add(await openDatabase(f.path, readOnly: true, singleInstance: false));
      } catch (_) {}
    }
    mapas = archivos.map((f) => ruta_p.basename(f.path)).toList();
    proveedorTiles = ProveedorMbTiles(List<Database>.of(_basesMb));
    versionMapas++;
    notifyListeners();
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
      _msg('Mapa importado.');
    } catch (e) {
      _msg('No se pudo importar el mapa: $e');
    }
  }

  Future<void> eliminarMapa(String nombre) async {
    final carpeta = await _carpeta('mapas');
    final f = File(ruta_p.join(carpeta.path, nombre));
    for (final d in _basesMb) {
      await d.close();
    }
    _basesMb.clear();
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

  Future<void> _cargarRedGuardada() async {
    final f = File(ruta_p.join((await _carpeta('red')).path, 'red_vial.geojson'));
    if (!await f.exists()) return;
    redEstado = 'Cargando red vial…';
    notifyListeners();
    try {
      final n = await motor.cargar(f.path);
      redCargada = true;
      redEstado = 'Red vial cargada ($n nodos)';
      notifyListeners();
      if (destino != null && fase != Fase.navegando) _calcularRuta();
    } catch (e) {
      redCargada = false;
      redEstado = 'Red vial inválida: $e';
      notifyListeners();
    }
  }

  Future<void> quitarRedVial() async {
    motor.red = null;
    final f = File(ruta_p.join((await _carpeta('red')).path, 'red_vial.geojson'));
    if (await f.exists()) await f.delete();
    redCargada = false;
    redEstado = 'Sin red vial: se usa ruta en línea recta';
    notifyListeners();
    if (destino != null && fase != Fase.navegando) _calcularRuta();
  }

  @override
  void dispose() {
    _sub?.cancel();
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
  }

  @override
  void dispose() {
    c.removeListener(_alCambiar);
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
                  if (c.permisoOk && !c.gpsActivo)
                    _aviso('El GPS está apagado.', 'Activar', Geolocator.openLocationSettings),
                  if (c.mapas.isEmpty)
                    _aviso('Sin mapas offline. Importa un archivo .mbtiles (raster).', 'Importar', c.importarMapa),
                  if (c.fase == Fase.navegando) _banner(esc),
                ]),
              ),
            ),
            Positioned(
              right: 8,
              top: MediaQuery.of(context).size.height * 0.33,
              child: Column(children: [
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
          maxNativeZoom: 19,
          errorTileCallback: (tile, error, stack) {},
        ),
        if (r != null)
          PolylineLayer(polylines: [Polyline(points: r.puntos, strokeWidth: 6, color: Colors.blue.shade700)]),
        MarkerLayer(markers: [
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
            TextButton(onPressed: alAccion, child: Text(accion)),
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

  Widget _ajustes(BuildContext ctx) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Guía por voz'),
        value: c.vozActiva,
        onChanged: c.establecerVoz,
      ),
      const Divider(),
      const Text('Mapas offline instalados (.mbtiles raster)', style: TextStyle(fontWeight: FontWeight.bold)),
      if (c.mapas.isEmpty) const Text('No hay mapas instalados.'),
      for (final m in c.mapas)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(m, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: IconButton(onPressed: () => c.eliminarMapa(m), icon: const Icon(Icons.delete_outline)),
        ),
      FilledButton(onPressed: c.importarMapa, child: const Text('Importar mapa (.mbtiles)')),
      const Divider(),
      const Text('Red vial para enrutamiento', style: TextStyle(fontWeight: FontWeight.bold)),
      Text(c.redEstado),
      const SizedBox(height: 8),
      FilledButton(onPressed: c.importarRedVial, child: const Text('Importar red vial (GeoJSON)')),
      if (c.redCargada)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: OutlinedButton(onPressed: c.quitarRedVial, child: const Text('Quitar red vial')),
        ),
    ]);
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
