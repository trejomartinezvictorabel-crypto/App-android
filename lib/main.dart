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
  parada('📍'),
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
  final List<int> limiteSeg; // límite de velocidad (km/h) de cada segmento; 0 = desconocido
  final List<String> calleSeg; // nombre de la calle de cada segmento; '' = sin nombre
  const Ruta(this.puntos, this.acum, this.total, this.duracionS, this.maniobras, this.aproximada, this.modo,
      {this.limiteSeg = const <int>[], this.calleSeg = const <String>[]});
}

/// Convierte la polilínea en instrucciones de giro en español.
/// [calles]: nombre de la calle de cada segmento (pts[i] → pts[i+1]).
/// [paradas]: índice de vértice → texto de la parada intermedia que termina ahí.
List<Maniobra> generarManiobras(List<LatLng> pts, List<double> acum,
    {List<String> calles = const <String>[], Map<int, String> paradas = const <int, String>{}}) {
  const distRef = 12.0, angMin = 30.0, sepMin = 25.0;
  final res = <Maniobra>[];
  if (pts.length < 2) return res;
  String calleEn(int seg) => seg >= 0 && seg < calles.length ? calles[seg] : '';

  var primera = '';
  for (var s = 0; s < pts.length - 1 && s < calles.length && acum[s] < 300; s++) {
    if (calles[s].isNotEmpty) {
      primera = calles[s];
      break;
    }
  }
  res.add(Maniobra(0, pts[0], TipoGiro.salida,
      'Dirígete al ${Geo.cardinal(Geo.rumbo(pts[0], pts[1]))}${primera.isEmpty ? '' : ' por $primera'}', 0));
  var ultima = -sepMin;
  for (var i = 1; i < pts.length - 1; i++) {
    final parada = paradas[i];
    if (parada != null) {
      res.add(Maniobra(i, pts[i], TipoGiro.parada, 'Llegas a $parada', acum[i]));
      ultima = acum[i];
      continue;
    }
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
    final saliente = calleEn(i);
    if (saliente.isNotEmpty && saliente != calleEn(i - 1)) texto = '$texto en $saliente';
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
/// Por arista: [clase] tipo de vía, [contra] bits (1 = contra sentido, 2 = peaje),
/// [velMax] límite de velocidad en km/h (0 = desconocido) y [nombreE] id del nombre de la calle (-1 = sin nombre).
class RedVial {
  final Float64List lats, lons;
  final Int32List offs, dest;
  final Float32List dist;
  final Uint8List clase, contra, velMax;
  final Int32List nombreE;
  // Calles para buscar sin internet: nombre, nombre normalizado y nodos representativos
  final List<String> nombres, nombresNorm;
  final Int32List repOffs, repNodos;
  // Índice de cuadrícula para encontrar el nodo más cercano sin recorrer toda la red
  final double celdaG, minLat, minLon;
  final int filas, cols;
  final Int32List celdaOffs, celdaNodos;

  RedVial({
    required this.lats,
    required this.lons,
    required this.offs,
    required this.dest,
    required this.dist,
    required this.clase,
    required this.contra,
    required this.velMax,
    required this.nombreE,
    required this.nombres,
    required this.nombresNorm,
    required this.repOffs,
    required this.repNodos,
    required this.celdaG,
    required this.minLat,
    required this.minLon,
    required this.filas,
    required this.cols,
    required this.celdaOffs,
    required this.celdaNodos,
  });

  int get nodos => lats.length;

  bool _tieneSalida(int i, Modo m) {
    for (var e = offs[i]; e < offs[i + 1]; e++) {
      if (m.velEnVia(ClaseVia.values[clase[e]]) > 0 && ((contra[e] & 1) == 0 || m.ignoraSentido)) return true;
    }
    return false;
  }

  /// Nodo transitable más cercano a [c], o -1 si está a más de [maxM]. Usa la cuadrícula (rápido en redes grandes).
  int nodoCercano(LatLng c, Modo m, double maxM) {
    if (lats.isEmpty) return -1;
    final kx = math.max(1000.0, 111320.0 * math.cos(c.latitude * math.pi / 180.0));
    const ky = 110540.0;
    final celdaM = math.min(celdaG * kx, celdaG * ky);
    final cr = ((c.latitude - minLat) / celdaG).floor();
    final cc = ((c.longitude - minLon) / celdaG).floor();
    final maxAnillos = (maxM / celdaM).ceil() + 1;
    var mejor = -1;
    var mejorD2 = double.maxFinite;
    for (var a = 0; a <= maxAnillos; a++) {
      for (var fr = cr - a; fr <= cr + a; fr++) {
        if (fr < 0 || fr >= filas) continue;
        final borde = fr == cr - a || fr == cr + a;
        final paso = borde ? 1 : 2 * a;
        for (var co = cc - a; co <= cc + a; co += paso) {
          if (co >= 0 && co < cols) {
            final id = fr * cols + co;
            for (var q = celdaOffs[id]; q < celdaOffs[id + 1]; q++) {
              final i = celdaNodos[q];
              final dx = (lons[i] - c.longitude) * kx, dy = (lats[i] - c.latitude) * ky;
              final d2 = dx * dx + dy * dy;
              if (d2 < mejorD2 && _tieneSalida(i, m)) {
                mejorD2 = d2;
                mejor = i;
              }
            }
          }
          if (paso == 0) break; // seguridad: a == 0 en fila interior no ocurre, pero evita ciclos infinitos
        }
      }
      if (mejor >= 0 && math.sqrt(mejorD2) <= a * celdaM) break;
    }
    return (mejor >= 0 && math.sqrt(mejorD2) <= maxM) ? mejor : -1;
  }

  /// Calles cuyo nombre contiene [norm] (ya normalizado). Cada calle puede traer varios puntos (tramos lejanos).
  List<({String nombre, double lat, double lon})> buscarCalles(String norm, {int limite = 30}) {
    final r = <({String nombre, double lat, double lon})>[];
    if (norm.length < 2) return r;
    final empiezan = <int>[], contienen = <int>[];
    for (var i = 0; i < nombresNorm.length; i++) {
      final t = nombresNorm[i];
      if (t.startsWith(norm)) {
        empiezan.add(i);
      } else if (t.contains(norm)) {
        contienen.add(i);
      }
      if (empiezan.length + contienen.length >= 400) break;
    }
    for (final i in [...empiezan, ...contienen]) {
      for (var q = repOffs[i]; q < repOffs[i + 1]; q++) {
        final n = repNodos[q];
        r.add((nombre: nombres[i], lat: lats[n], lon: lons[n]));
        if (r.length >= limite) return r;
      }
    }
    return r;
  }

  /// Rumbo aproximado (0..360) entre dos nodos, en plano local (barato: se usa dentro de A*).
  double _rumbo(int a, int b) {
    final dLat = lats[b] - lats[a];
    final dLon = (lons[b] - lons[a]) * math.cos((lats[a] + lats[b]) * 0.5 * math.pi / 180.0);
    return (math.atan2(dLon, dLat) * 180.0 / math.pi + 360.0) % 360.0;
  }

  /// Segundos extra por girar en una intersección (en México se circula por la derecha: la izquierda cruza tráfico).
  double _penalGiro(int a, int b, int c, Modo modo) {
    final d = Geo.difAng(_rumbo(a, b), _rumbo(b, c));
    final ad = d.abs();
    if (modo == Modo.pie || modo == Modo.bici) return ad >= 60 ? 2.0 : 0.0;
    if (ad < 35) return 0.0;
    final der = d > 0;
    if (ad < 70) return der ? 2.0 : 4.0;
    if (ad < 130) return der ? 5.0 : 10.0;
    if (ad < 165) return der ? 8.0 : 14.0;
    return 30.0; // vuelta en U
  }

  static bool _usaLimite(Modo m) => m == Modo.auto || m == Modo.moto || m == Modo.transporte;

  /// Duración real (sin penalizaciones de preferencia) de una lista de aristas.
  double duracionAristas(List<int> aristas, Modo modo) {
    var s = 0.0;
    final lim = _usaLimite(modo);
    for (final e in aristas) {
      var vel = modo.velEnVia(ClaseVia.values[clase[e]]);
      if (vel <= 0) vel = modo.velProm;
      if (lim && velMax[e] > 0) vel = math.min(vel, velMax[e] * 0.95);
      s += dist[e] / (vel / 3.6);
    }
    return s;
  }

  /// A* con costo en segundos y heurística = distancia / velocidad máxima del modo.
  /// Considera límites de velocidad, giros en intersecciones y preferencias (evitar peajes / terracería).
  /// [penalizadas]: aristas que cuestan más (para generar rutas alternativas).
  ({List<int> nodos, List<int> aristas})? aStar(int origen, int destino, Modo modo,
      {bool evitarPeajes = false, bool evitarTerraceria = false, Uint8List? penalizadas}) {
    if (origen == destino) return (nodos: <int>[origen], aristas: <int>[]);
    final n = lats.length;
    final g = Float64List(n)..fillRange(0, n, double.infinity);
    final previo = Int32List(n)..fillRange(0, n, -1);
    final viaE = Int32List(n)..fillRange(0, n, -1);
    final cerrado = Uint8List(n);
    final vMax = modo.velMax / 3.6;
    final latD = lats[destino], lonD = lons[destino];
    double h(int i) => Geo.dist(lats[i], lons[i], latD, lonD) / vMax;
    final clases = ClaseVia.values;
    final lim = _usaLimite(modo);

    final cola = _MonticuloMin();
    g[origen] = 0;
    cola.agregar(h(origen), origen);
    while (!cola.vacio) {
      final u = cola.sacar();
      if (cerrado[u] == 1) continue;
      if (u == destino) {
        final nodosR = <int>[];
        final aristasR = <int>[];
        for (var c = destino; c != -1; c = previo[c]) {
          nodosR.add(c);
          if (viaE[c] >= 0) aristasR.add(viaE[c]);
        }
        return (nodos: nodosR.reversed.toList(), aristas: aristasR.reversed.toList());
      }
      cerrado[u] = 1;
      final pu = previo[u];
      final esCruce = offs[u + 1] - offs[u] >= 3;
      for (var e = offs[u]; e < offs[u + 1]; e++) {
        final v = dest[e];
        if (cerrado[v] == 1) continue;
        final bits = contra[e];
        if ((bits & 1) == 1 && !modo.ignoraSentido) continue;
        final cls = clases[clase[e]];
        var vel = modo.velEnVia(cls);
        if (vel <= 0) continue;
        if (lim && velMax[e] > 0) vel = math.min(vel, velMax[e] * 0.95);
        if (evitarTerraceria && cls == ClaseVia.terraceria) vel = vel / 4;
        var costo = dist[e] / (vel / 3.6);
        if (evitarPeajes && (bits & 2) != 0) costo = costo * 2 + 900;
        if (penalizadas != null && penalizadas[e] == 1) costo *= 1.8;
        if (pu >= 0 && esCruce) costo += _penalGiro(pu, u, v, modo);
        final nuevo = g[u] + costo;
        if (nuevo < g[v]) {
          g[v] = nuevo;
          previo[v] = u;
          viaE[v] = e;
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

  double operator [](int i) => _d[i];
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

/// "50", "50 mph", "MX:urban"... → km/h (0 si no se puede interpretar).
int _parseMaxspeed(String? t) {
  if (t == null) return 0;
  final m = RegExp(r'^\s*(\d{1,3})\s*(mph)?').firstMatch(t);
  if (m == null) return 0;
  var v = int.parse(m.group(1)!);
  if (m.group(2) != null) v = (v * 1.609).round();
  return v.clamp(5, 200);
}

/// Construye el grafo desde uno o varios GeoJSON de OSM. Se ejecuta en un isolate (no congela la UI).
/// Los archivos descargados por la app se leen línea por línea (poca memoria); cualquier otro
/// GeoJSON (p. ej. importado a mano) se carga completo, como antes.
Future<RedVial> construirRed(List<String> rutas) async {
  final claveANodo = <int, int>{};
  final lats = _ListaF64(), lons = _ListaF64();
  final ef = _ListaI32(), et = _ListaI32(), en = _ListaI32();
  final ec = _ListaU8(), ek = _ListaU8(), ev = _ListaU8();
  final ed = _ListaF32();
  final idsNombre = <String, int>{};
  final nombres = <String>[];
  final reps = <int, List<int>>{};

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

  void arista(int a, int b, double d, int clase, bool contra, bool peaje, int lim, int nombre) {
    ef.add(a);
    et.add(b);
    ed.add(d);
    ec.add(clase);
    ek.add((contra ? 1 : 0) | (peaje ? 2 : 0));
    ev.add(lim);
    en.add(nombre);
  }

  // Un nodo representativo por calle y por zona (a >1.5 km de los demás) para buscarla por nombre
  void representante(int nombre, int nodoId) {
    final l = reps.putIfAbsent(nombre, () => <int>[]);
    if (l.length >= 12) return;
    for (final o in l) {
      if (Geo.dist(lats[o], lons[o], lats[nodoId], lons[nodoId]) < 1500) return;
    }
    l.add(nodoId);
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
    final nombreCrudo = (props['name'] ?? props['ref'])?.toString().trim() ?? '';
    var nid = -1;
    if (nombreCrudo.isNotEmpty) {
      nid = idsNombre.putIfAbsent(nombreCrudo, () {
        nombres.add(nombreCrudo);
        return nombres.length - 1;
      });
    }
    final lim = _parseMaxspeed(props['maxspeed']?.toString());
    final peaje = props['toll']?.toString() == 'yes';
    _recorrerLineas(geom['coordinates'], (linea) {
      var primero = -1;
      for (var i = 0; i < linea.length - 1; i++) {
        final a = linea[i], b = linea[i + 1];
        if (a is! List || b is! List || a.length < 2 || b.length < 2) continue;
        final lonA = (a[0] as num).toDouble(), latA = (a[1] as num).toDouble();
        final lonB = (b[0] as num).toDouble(), latB = (b[1] as num).toDouble();
        final ia = nodo(latA, lonA), ib = nodo(latB, lonB);
        if (ia == ib) continue;
        if (primero < 0) primero = ia;
        final d = Geo.dist(latA, lonA, latB, lonB);
        final ci = claseVia.index;
        if (sentido == 0) {
          arista(ia, ib, d, ci, false, peaje, lim, nid);
          arista(ib, ia, d, ci, false, peaje, lim, nid);
        } else if (sentido == 1) {
          arista(ia, ib, d, ci, false, peaje, lim, nid);
          arista(ib, ia, d, ci, true, peaje, lim, nid);
        } else {
          arista(ib, ia, d, ci, false, peaje, lim, nid);
          arista(ia, ib, d, ci, true, peaje, lim, nid);
        }
      }
      if (nid >= 0 && primero >= 0) representante(nid, primero);
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
  final velMax = Uint8List(m);
  final nombreE = Int32List(m);
  for (var e = 0; e < m; e++) {
    final q = pos[ef[e]]++;
    dest[q] = et[e];
    dist[q] = ed[e];
    clase[q] = ec[e];
    contra[q] = ek[e];
    velMax[q] = ev[e];
    nombreE[q] = en[e];
  }
  final latsT = lats.recortar(), lonsT = lons.recortar();

  // Índice de cuadrícula (nodo más cercano en tiempo casi constante)
  var minLat = double.infinity, maxLat = -double.infinity, minLon = double.infinity, maxLon = -double.infinity;
  for (var i = 0; i < n; i++) {
    if (latsT[i] < minLat) minLat = latsT[i];
    if (latsT[i] > maxLat) maxLat = latsT[i];
    if (lonsT[i] < minLon) minLon = lonsT[i];
    if (lonsT[i] > maxLon) maxLon = lonsT[i];
  }
  var celda = 0.02; // ~2 km
  while (((maxLat - minLat) / celda + 1) * ((maxLon - minLon) / celda + 1) > 6e6) {
    celda *= 2;
  }
  final filas = ((maxLat - minLat) / celda).floor() + 1;
  final cols = ((maxLon - minLon) / celda).floor() + 1;
  final celdaOffs = Int32List(filas * cols + 1);
  final celdaDe = Int32List(n);
  for (var i = 0; i < n; i++) {
    final id = ((latsT[i] - minLat) / celda).floor() * cols + ((lonsT[i] - minLon) / celda).floor();
    celdaDe[i] = id;
    celdaOffs[id + 1]++;
  }
  for (var i = 0; i < filas * cols; i++) {
    celdaOffs[i + 1] += celdaOffs[i];
  }
  final posC = Int32List.fromList(celdaOffs.sublist(0, filas * cols));
  final celdaNodos = Int32List(n);
  for (var i = 0; i < n; i++) {
    celdaNodos[posC[celdaDe[i]]++] = i;
  }

  // Calles para el buscador
  final nombresNorm = <String>[for (final s in nombres) Fmt.normalizar(s)];
  final repOffs = Int32List(nombres.length + 1);
  final repLista = <int>[];
  for (var i = 0; i < nombres.length; i++) {
    final l = reps[i];
    if (l != null) repLista.addAll(l);
    repOffs[i + 1] = repLista.length;
  }

  return RedVial(
    lats: latsT,
    lons: lonsT,
    offs: offs,
    dest: dest,
    dist: dist,
    clase: clase,
    contra: contra,
    velMax: velMax,
    nombreE: nombreE,
    nombres: nombres,
    nombresNorm: nombresNorm,
    repOffs: repOffs,
    repNodos: Int32List.fromList(repLista),
    celdaG: celda,
    minLat: minLat,
    minLon: minLon,
    filas: filas,
    cols: cols,
    celdaOffs: celdaOffs,
    celdaNodos: celdaNodos,
  );
}

/// Un tramo de ruta entre dos puntos clave (origen → parada → destino).
class _Tramo {
  final List<LatLng> pts;
  final List<String> calles; // una por segmento
  final List<int> lims; // una por segmento
  final double seg;
  final bool aprox;
  final List<int> aristas;
  const _Tramo(this.pts, this.calles, this.lims, this.seg, this.aprox, this.aristas);
}

/// Motor de enrutamiento local: A* con red vial cargada; línea recta como respaldo.
class MotorRutas {
  RedVial? red;
  bool evitarPeajes = false;
  bool evitarTerraceria = false;
  List<int> _ultimasAristas = const <int>[];
  static const double _maxAjusteM = 3000;

  Future<int> cargar(List<String> rutas) async {
    final nueva = await Isolate.run(() => construirRed(rutas));
    red = nueva;
    return nueva.nodos;
  }

  /// Ruta de [o] a [d] pasando por [paradas] (en orden). [nombresParadas] se usa para anunciarlas.
  Future<Ruta> calcular(LatLng o, LatLng d, Modo modo,
      {List<LatLng> paradas = const <LatLng>[], List<String> nombresParadas = const <String>[]}) async {
    await Future<void>.delayed(Duration.zero); // deja pintar el indicador de "calculando"
    final clave = <LatLng>[o, ...paradas, d];
    final tramos = <_Tramo>[];
    for (var i = 0; i < clave.length - 1; i++) {
      tramos.add(_tramo(clave[i], clave[i + 1], modo));
      if (i < clave.length - 2) await Future<void>.delayed(Duration.zero);
    }
    _ultimasAristas = tramos.length == 1 ? tramos.first.aristas : const <int>[];
    return _unir(tramos, modo, nombresParadas);
  }

  _Tramo _tramo(LatLng o, LatLng d, Modo modo, {Uint8List? pen}) {
    final r = red;
    if (r != null) {
      final no = r.nodoCercano(o, modo, _maxAjusteM);
      final nd = r.nodoCercano(d, modo, _maxAjusteM);
      if (no >= 0 && nd >= 0) {
        final camino = r.aStar(no, nd, modo,
            evitarPeajes: evitarPeajes, evitarTerraceria: evitarTerraceria, penalizadas: pen);
        if (camino != null) {
          final pts = <LatLng>[o];
          final calles = <String>[];
          final lims = <int>[];
          for (var i = 0; i < camino.nodos.length; i++) {
            final n = camino.nodos[i];
            final c = LatLng(r.lats[n], r.lons[n]);
            if (Geo.distLL(pts.last, c) > 0.5) {
              pts.add(c);
              if (i == 0) {
                calles.add('');
                lims.add(0);
              } else {
                final e = camino.aristas[i - 1];
                final id = r.nombreE[e];
                calles.add(id >= 0 ? r.nombres[id] : '');
                lims.add(r.velMax[e]);
              }
            }
          }
          if (Geo.distLL(pts.last, d) > 0.5) {
            pts.add(d);
            calles.add('');
            lims.add(0);
          }
          final vProm = modo.velProm / 3.6;
          final primero = LatLng(r.lats[camino.nodos.first], r.lons[camino.nodos.first]);
          final ultimo = LatLng(r.lats[camino.nodos.last], r.lons[camino.nodos.last]);
          final extra = (Geo.distLL(o, primero) + Geo.distLL(ultimo, d)) / vProm;
          return _Tramo(pts, calles, lims, r.duracionAristas(camino.aristas, modo) + extra, false, camino.aristas);
        }
      }
    }
    final dist = Geo.distLL(o, d);
    return _Tramo(<LatLng>[o, d], <String>[''], <int>[0], dist / (modo.velProm / 3.6), true, const <int>[]);
  }

  Ruta _unir(List<_Tramo> tramos, Modo modo, List<String> nombresParadas) {
    final pts = <LatLng>[];
    final calles = <String>[];
    final lims = <int>[];
    final paradas = <int, String>{};
    var seg = 0.0;
    for (var t = 0; t < tramos.length; t++) {
      final tr = tramos[t];
      seg += tr.seg;
      if (pts.isEmpty) {
        pts.addAll(tr.pts);
      } else {
        pts.addAll(tr.pts.skip(1)); // el primer punto coincide con la parada anterior
      }
      calles.addAll(tr.calles);
      lims.addAll(tr.lims);
      if (t < tramos.length - 1) {
        final nombre = t < nombresParadas.length ? nombresParadas[t] : '';
        paradas[pts.length - 1] = 'la parada ${t + 1}${nombre.isEmpty ? '' : ', $nombre'}';
      }
    }
    return _armar(pts, seg, tramos.every((t) => t.aprox), modo, calles, lims, paradas);
  }

  Ruta _armar(List<LatLng> entrada, double seg, bool aprox, Modo modo, List<String> calles, List<int> lims,
      Map<int, String> paradas) {
    final pts = entrada.length < 2 ? <LatLng>[entrada[0], entrada[0]] : entrada;
    final acum = List<double>.filled(pts.length, 0);
    for (var i = 1; i < pts.length; i++) {
      acum[i] = acum[i - 1] + Geo.distLL(pts[i - 1], pts[i]);
    }
    return Ruta(pts, acum, acum.last, seg, generarManiobras(pts, acum, calles: calles, paradas: paradas), aprox, modo,
        limiteSeg: lims, calleSeg: calles);
  }

  /// Hasta 2 alternativas a la última ruta calculada (solo de un tramo): penaliza las vías ya usadas y recalcula.
  Future<List<Ruta>> alternativas(LatLng o, LatLng d, Modo modo, Ruta mejor) async {
    final r = red;
    if (r == null || mejor.aproximada || _ultimasAristas.isEmpty) return <Ruta>[];
    final usadas = Uint8List(r.dest.length);
    final base = <int>{};
    for (final e in _ultimasAristas) {
      usadas[e] = 1;
      base.add(e);
    }
    final res = <Ruta>[];
    for (var k = 0; k < 2; k++) {
      await Future<void>.delayed(Duration.zero);
      final t = _tramo(o, d, modo, pen: usadas);
      if (t.aprox || t.aristas.isEmpty) break;
      var compartidas = 0;
      for (final e in t.aristas) {
        if (base.contains(e)) compartidas++;
      }
      if (compartidas / t.aristas.length > 0.85) break; // casi igual: no sirve como alternativa
      if (t.seg > mejor.duracionS * 1.8 + 120) break; // mucho más lenta
      res.add(_unir(<_Tramo>[t], modo, const <String>[]));
      for (final e in t.aristas) {
        usadas[e] = 1;
        base.add(e);
      }
    }
    return res;
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
// 7. MAPA OFFLINE: PROVEEDOR DE TESELAS MBTILES (RASTER Y VECTORIAL)
// ============================================================================
//
//  Tesela vacía = píxel 100 % TRANSPARENTE (se ve el fondo gris); nunca se lanza una excepción
//  que rompa el renderizado.

Future<ui.Codec> _codecTransparente() async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(Uint8List(4)); // R,G,B,A = 0
  final descriptor = ui.ImageDescriptor.raw(buffer, width: 1, height: 1, pixelFormat: ui.PixelFormat.rgba8888);
  return descriptor.instantiateCodec();
}

// ----------------------------------------------------------------------------
//  MAPAS VECTORIALES (.mbtiles con teselas pbf / Mapbox Vector Tile)
//  Sin paquetes extra: se decodifica el protobuf y se dibuja con dart:ui en una imagen
//  por tesela, que flutter_map muestra igual que una tesela raster. Más allá del zoom
//  máximo del archivo se re-dibuja la tesela madre ampliada (los trazos siguen nítidos).
//  Esquema esperado: OpenMapTiles (water, landcover, landuse, transportation, building,
//  boundary, place, transportation_name); también reconoce nombres de capas tipo Shortbread.
// ----------------------------------------------------------------------------

class _Pb {
  final Uint8List b;
  int p = 0;
  final int fin;
  _Pb(this.b) : fin = b.length;

  bool get hay => p < fin;

  int varint() {
    var r = 0, s = 0;
    while (true) {
      if (p >= fin) throw const FormatException('protobuf truncado');
      final x = b[p++];
      r |= (x & 0x7F) << s;
      if (x < 0x80) return r;
      s += 7;
      if (s > 63) throw const FormatException('varint inválido');
    }
  }

  Uint8List bytesLen() {
    final n = varint();
    if (n < 0 || p + n > fin) throw const FormatException('longitud inválida');
    final r = Uint8List.sublistView(b, p, p + n);
    p += n;
    return r;
  }

  void saltar(int wire) {
    switch (wire) {
      case 0:
        varint();
      case 1:
        p += 8;
      case 2:
        bytesLen();
      case 5:
        p += 4;
      default:
        throw const FormatException('tipo de campo desconocido');
    }
  }

  double float32() {
    final v = ByteData.sublistView(b, p, p + 4).getFloat32(0, Endian.little);
    p += 4;
    return v;
  }

  double float64() {
    final v = ByteData.sublistView(b, p, p + 8).getFloat64(0, Endian.little);
    p += 8;
    return v;
  }
}

class _FeatVec {
  final int tipo; // 1 = punto, 2 = línea, 3 = polígono
  final Map<String, Object> props;
  final List<Float32List> partes; // [x0, y0, x1, y1, ...] en unidades de la tesela
  const _FeatVec(this.tipo, this.props, this.partes);
}

class _CapaVec {
  final String nombre;
  final int extent;
  final List<_FeatVec> feats;
  const _CapaVec(this.nombre, this.extent, this.feats);
}

int _zigzag(int v) => (v >> 1) ^ -(v & 1);

Uint8List _descomprimirTesela(Uint8List d) {
  if (d.length > 2 && d[0] == 0x1f && d[1] == 0x8b) return Uint8List.fromList(gzip.decode(d));
  return d;
}

List<_CapaVec> _decodificarMvt(Uint8List datos) {
  final capas = <_CapaVec>[];
  final t = _Pb(datos);
  while (t.hay) {
    final tag = t.varint();
    if ((tag >> 3) == 3 && (tag & 7) == 2) {
      capas.add(_decodificarCapa(t.bytesLen()));
    } else {
      t.saltar(tag & 7);
    }
  }
  return capas;
}

Object _decodificarValor(Uint8List d) {
  final r = _Pb(d);
  Object v = '';
  while (r.hay) {
    final tag = r.varint();
    switch (tag >> 3) {
      case 1:
        v = utf8.decode(r.bytesLen(), allowMalformed: true);
      case 2:
        v = r.float32();
      case 3:
        v = r.float64();
      case 4:
      case 5:
        v = r.varint();
      case 6:
        v = _zigzag(r.varint());
      case 7:
        v = r.varint() != 0;
      default:
        r.saltar(tag & 7);
    }
  }
  return v;
}

_CapaVec _decodificarCapa(Uint8List d) {
  final r = _Pb(d);
  var nombre = '';
  var extent = 4096;
  final claves = <String>[];
  final valores = <Object>[];
  final crudas = <Uint8List>[];
  while (r.hay) {
    final tag = r.varint();
    switch (tag >> 3) {
      case 1:
        nombre = utf8.decode(r.bytesLen(), allowMalformed: true);
      case 2:
        crudas.add(r.bytesLen());
      case 3:
        claves.add(utf8.decode(r.bytesLen(), allowMalformed: true));
      case 4:
        valores.add(_decodificarValor(r.bytesLen()));
      case 5:
        extent = r.varint();
      default:
        r.saltar(tag & 7);
    }
  }
  final feats = <_FeatVec>[];
  for (final c in crudas) {
    final f = _decodificarFeature(c, claves, valores);
    if (f != null) feats.add(f);
  }
  return _CapaVec(nombre, extent <= 0 ? 4096 : extent, feats);
}

_FeatVec? _decodificarFeature(Uint8List d, List<String> claves, List<Object> valores) {
  final r = _Pb(d);
  var tipo = 0;
  Uint8List? tags;
  Uint8List? geom;
  while (r.hay) {
    final tag = r.varint();
    switch (tag >> 3) {
      case 2:
        tags = r.bytesLen();
      case 3:
        tipo = r.varint();
      case 4:
        geom = r.bytesLen();
      default:
        r.saltar(tag & 7);
    }
  }
  if (geom == null || tipo < 1 || tipo > 3) return null;

  final props = <String, Object>{};
  if (tags != null) {
    final tg = _Pb(tags);
    while (tg.hay) {
      final k = tg.varint();
      if (!tg.hay) break;
      final v = tg.varint();
      if (k < claves.length && v < valores.length) props[claves[k]] = valores[v];
    }
  }

  final partes = <Float32List>[];
  var actual = <double>[];
  void cerrarParte() {
    if (actual.isNotEmpty) partes.add(Float32List.fromList(actual));
    actual = <double>[];
  }

  final g = _Pb(geom);
  var x = 0, y = 0;
  while (g.hay) {
    final cmd = g.varint();
    final id = cmd & 7;
    final n = cmd >> 3;
    if (id == 1 || id == 2) {
      for (var i = 0; i < n; i++) {
        x += _zigzag(g.varint());
        y += _zigzag(g.varint());
        if (id == 1) {
          if (tipo == 1) {
            partes.add(Float32List.fromList(<double>[x.toDouble(), y.toDouble()]));
            continue;
          }
          cerrarParte(); // nueva línea o nuevo anillo
        }
        actual.add(x.toDouble());
        actual.add(y.toDouble());
      }
    } else if (id == 7) {
      if (actual.length >= 2) {
        actual.add(actual[0]);
        actual.add(actual[1]);
      }
      cerrarParte();
    } else {
      throw const FormatException('comando de geometría desconocido');
    }
  }
  cerrarParte();
  return _FeatVec(tipo, props, partes);
}

// ---------------------------------------------------------------- dibujo
const int _pxTesela = 512; // lado de la imagen que se dibuja (el doble de 256: nítido en pantallas densas)

int _categoriaCapa(String n) {
  switch (n) {
    case 'landcover':
    case 'landuse':
    case 'park':
    case 'natural':
    case 'land':
    case 'landuse_overlay':
    case 'green':
      return 1;
    case 'water':
    case 'water_polygons':
    case 'ocean':
    case 'water_areas':
      return 2;
    case 'waterway':
    case 'water_lines':
    case 'waterway_lines':
      return 3;
    case 'building':
    case 'buildings':
      return 4;
    case 'transportation':
    case 'roads':
    case 'streets':
    case 'road':
      return 5;
    case 'boundary':
    case 'boundaries':
    case 'admin':
      return 6;
    case 'place':
    case 'places':
    case 'place_labels':
      return 7;
    case 'transportation_name':
    case 'street_labels':
      return 8;
    default:
      return 0;
  }
}

String _claseDe(_FeatVec f) => '${f.props['class'] ?? f.props['kind'] ?? f.props['subclass'] ?? f.props['highway'] ?? ''}';

String _nombreDe(_FeatVec f) {
  final v = f.props['name:es'] ?? f.props['name_es'] ?? f.props['name:latin'] ?? f.props['name'];
  return v == null ? '' : '$v';
}

ui.Color? _colorSuelo(String clase) {
  final c = clase.toLowerCase();
  if (c.contains('wood') || c.contains('forest')) return const ui.Color(0xFFCDE5BB);
  if (c.contains('park') ||
      c.contains('garden') ||
      c.contains('grass') ||
      c.contains('meadow') ||
      c.contains('recreation') ||
      c.contains('nature') ||
      c.contains('scrub') ||
      c.contains('golf')) {
    return const ui.Color(0xFFD3EBC4);
  }
  if (c.contains('farm') || c.contains('agri') || c.contains('orchard') || c.contains('vineyard')) {
    return const ui.Color(0xFFEEF0D5);
  }
  if (c.contains('residential')) return const ui.Color(0xFFEAE6DE);
  if (c.contains('industrial') || c.contains('commercial') || c.contains('retail')) return const ui.Color(0xFFE6E0E8);
  if (c.contains('sand') || c.contains('beach') || c.contains('desert')) return const ui.Color(0xFFF3E7C3);
  if (c.contains('cemetery')) return const ui.Color(0xFFCFE0C9);
  if (c.contains('hospital')) return const ui.Color(0xFFF3DEDC);
  if (c.contains('school') || c.contains('university') || c.contains('college')) return const ui.Color(0xFFF0E9CC);
  if (c.contains('pitch') || c.contains('sport') || c.contains('stadium')) return const ui.Color(0xFFCFEBD0);
  if (c.contains('ice') || c.contains('glacier')) return const ui.Color(0xFFFFFFFF);
  return null;
}

/// 5 autopista/troncal, 4 primaria, 3 secundaria, 2 terciaria, 1 calle local, 0 vereda/terracería, -1 ferrocarril, -9 omitir.
int _rangoVia(String c) {
  switch (c) {
    case 'motorway':
    case 'trunk':
    case 'motorway_link':
    case 'trunk_link':
      return 5;
    case 'primary':
    case 'primary_link':
      return 4;
    case 'secondary':
    case 'secondary_link':
      return 3;
    case 'tertiary':
    case 'tertiary_link':
      return 2;
    case 'path':
    case 'footway':
    case 'pedestrian':
    case 'steps':
    case 'cycleway':
    case 'bridleway':
    case 'track':
      return 0;
    case 'rail':
    case 'transit':
    case 'subway':
    case 'light_rail':
    case 'tram':
      return -1;
    case 'ferry':
    case 'aerialway':
    case 'aeroway':
    case 'construction':
    case 'proposed':
      return -9;
    default:
      return 1;
  }
}

void _agregarTrazos(ui.Path p, _FeatVec f, double k, double ox, double oy, {required bool cerrar}) {
  for (final parte in f.partes) {
    if (parte.length < 4) continue;
    p.moveTo(parte[0] * k - ox, parte[1] * k - oy);
    for (var i = 2; i + 1 < parte.length; i += 2) {
      p.lineTo(parte[i] * k - ox, parte[i + 1] * k - oy);
    }
    if (cerrar) p.close();
  }
}

/// ¿Todo el objeto cae fuera de la imagen? (solo importa al ampliar una tesela madre)
bool _fueraDeImagen(_FeatVec f, double k, double ox, double oy) {
  var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
  for (final parte in f.partes) {
    for (var i = 0; i + 1 < parte.length; i += 2) {
      final x = parte[i] * k - ox, y = parte[i + 1] * k - oy;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }
  const m = 80.0;
  return maxX < -m || minX > _pxTesela + m || maxY < -m || minY > _pxTesela + m;
}

ui.Paragraph _parrafo(String t, double tam, {ui.Paint? contorno, ui.Color? color, bool negrita = false}) {
  final b = ui.ParagraphBuilder(ui.ParagraphStyle(textAlign: ui.TextAlign.center, maxLines: 2))
    ..pushStyle(ui.TextStyle(
      color: contorno == null ? color : null,
      foreground: contorno,
      fontSize: tam,
      fontWeight: negrita ? ui.FontWeight.w700 : ui.FontWeight.w500,
    ))
    ..addText(t);
  final p = b.build();
  p.layout(const ui.ParagraphConstraints(width: 300));
  return p;
}

class _EstiloLugar {
  final double tam;
  final bool negrita;
  const _EstiloLugar(this.tam, this.negrita);
}

_EstiloLugar? _estiloLugar(String c, int z) {
  switch (c) {
    case 'country':
      return z >= 3 && z <= 6 ? const _EstiloLugar(26, true) : null;
    case 'state':
    case 'region':
      return z >= 5 && z <= 8 ? const _EstiloLugar(22, true) : null;
    case 'city':
      return z >= 4 ? const _EstiloLugar(30, true) : null;
    case 'town':
      return z >= 8 ? const _EstiloLugar(26, true) : null;
    case 'village':
      return z >= 10 ? const _EstiloLugar(22, false) : null;
    case 'suburb':
    case 'quarter':
    case 'neighbourhood':
    case 'hamlet':
    case 'locality':
      return z >= 13 ? const _EstiloLugar(20, false) : null;
    default:
      return null;
  }
}

class _EtiquetaLugar {
  final num rango;
  final String nombre;
  final double x, y;
  final _EstiloLugar estilo;
  const _EtiquetaLugar(this.rango, this.nombre, this.x, this.y, this.estilo);
}

/// Dibuja una tesela vectorial. [zDatos] = zoom de los datos; [d] = niveles de ampliación sobre ellos;
/// ([sx], [sy]) = cuál sub-tesela de la madre se muestra (0 cuando d == 0).
Future<ui.Image> _dibujarVectorial(List<_CapaVec> capas, int zDatos, int d, int sx, int sy) async {
  final z = zDatos + d;
  final escala = (1 << d).toDouble();
  final ox = sx * _pxTesela.toDouble(), oy = sy * _pxTesela.toDouble();
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec, ui.Rect.fromLTWH(0, 0, _pxTesela.toDouble(), _pxTesela.toDouble()));
  canvas.drawRect(ui.Rect.fromLTWH(0, 0, _pxTesela.toDouble(), _pxTesela.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFF2EFE9));
  final recortar = d > 0;

  double kDe(_CapaVec c) => _pxTesela * escala / c.extent;
  final relleno = ui.Paint()..style = ui.PaintingStyle.fill;
  final trazo = ui.Paint()
    ..style = ui.PaintingStyle.stroke
    ..strokeCap = ui.StrokeCap.round
    ..strokeJoin = ui.StrokeJoin.round;

  // 1) suelo (parques, bosques, uso de suelo): un trazado por color
  final suelo = <ui.Color, ui.Path>{};
  for (final capa in capas) {
    if (_categoriaCapa(capa.nombre) != 1) continue;
    final k = kDe(capa);
    for (final f in capa.feats) {
      if (f.tipo != 3) continue;
      final col = _colorSuelo(_claseDe(f));
      if (col == null) continue;
      if (recortar && _fueraDeImagen(f, k, ox, oy)) continue;
      final p = suelo.putIfAbsent(col, () => ui.Path()..fillType = ui.PathFillType.evenOdd);
      _agregarTrazos(p, f, k, ox, oy, cerrar: true);
    }
  }
  suelo.forEach((col, p) => canvas.drawPath(p, relleno..color = col));

  // 2) agua
  const colAgua = ui.Color(0xFFA9D3E8);
  final agua = ui.Path()..fillType = ui.PathFillType.evenOdd;
  for (final capa in capas) {
    if (_categoriaCapa(capa.nombre) != 2) continue;
    final k = kDe(capa);
    for (final f in capa.feats) {
      if (f.tipo != 3) continue;
      if (recortar && _fueraDeImagen(f, k, ox, oy)) continue;
      _agregarTrazos(agua, f, k, ox, oy, cerrar: true);
    }
  }
  canvas.drawPath(agua, relleno..color = colAgua);

  // 3) ríos y arroyos
  final rios = ui.Path();
  for (final capa in capas) {
    if (_categoriaCapa(capa.nombre) != 3) continue;
    final k = kDe(capa);
    for (final f in capa.feats) {
      if (f.tipo != 2) continue;
      final c = _claseDe(f);
      if (z < 11 && c != 'river') continue;
      if (recortar && _fueraDeImagen(f, k, ox, oy)) continue;
      _agregarTrazos(rios, f, k, ox, oy, cerrar: false);
    }
  }
  canvas.drawPath(
      rios,
      trazo
        ..color = colAgua
        ..strokeWidth = (z < 11 ? 1.6 : 2.6) * 2);

  // 4) edificios (solo con zoom alto)
  if (z >= 15) {
    final edif = ui.Path()..fillType = ui.PathFillType.evenOdd;
    for (final capa in capas) {
      if (_categoriaCapa(capa.nombre) != 4) continue;
      final k = kDe(capa);
      for (final f in capa.feats) {
        if (f.tipo != 3) continue;
        if (recortar && _fueraDeImagen(f, k, ox, oy)) continue;
        _agregarTrazos(edif, f, k, ox, oy, cerrar: true);
      }
    }
    canvas.drawPath(edif, relleno..color = const ui.Color(0xFFDDD6CE));
    if (z >= 16) {
      canvas.drawPath(
          edif,
          trazo
            ..color = const ui.Color(0xFFC9BFB5)
            ..strokeWidth = 1.6);
    }
  }

  // 5) límites político-administrativos (estado y país)
  final lim = ui.Path();
  for (final capa in capas) {
    if (_categoriaCapa(capa.nombre) != 6) continue;
    final k = kDe(capa);
    for (final f in capa.feats) {
      if (f.tipo != 2) continue;
      final nivel = f.props['admin_level'];
      if (nivel is num && nivel > 4) continue;
      if (recortar && _fueraDeImagen(f, k, ox, oy)) continue;
      _agregarTrazos(lim, f, k, ox, oy, cerrar: false);
    }
  }
  canvas.drawPath(
      lim,
      trazo
        ..color = const ui.Color(0xFF9A8FB5)
        ..strokeWidth = 3);

  // 6) vías: por rango, de menor a mayor importancia
  final porRango = <int, ui.Path>{};
  final minRango = z < 6 ? 5 : (z < 9 ? 4 : (z < 11 ? 3 : (z < 13 ? 2 : (z < 14 ? 1 : 0))));
  for (final capa in capas) {
    if (_categoriaCapa(capa.nombre) != 5) continue;
    final k = kDe(capa);
    for (final f in capa.feats) {
      if (f.tipo != 2) continue;
      final c = _claseDe(f);
      final rango = _rangoVia(c);
      if (rango == -9) continue;
      if (rango == -1) {
        if (z < 10) continue;
      } else {
        if (rango < minRango) continue;
        if (rango == 0 && z < 15) continue;
        if (c == 'service' && z < 15) continue;
      }
      if (recortar && _fueraDeImagen(f, k, ox, oy)) continue;
      _agregarTrazos(porRango.putIfAbsent(rango, () => ui.Path()), f, k, ox, oy, cerrar: false);
    }
  }
  final factor = math.max(0.35, math.min(4.0, math.pow(2, (z - 14) * 0.55).toDouble()));
  const anchos = <int, double>{5: 5.0, 4: 4.5, 3: 4.0, 2: 3.5, 1: 2.8, 0: 1.3, -1: 1.2};
  const rellenos = <int, ui.Color>{
    5: ui.Color(0xFFF5A56E),
    4: ui.Color(0xFFFBD38D),
    3: ui.Color(0xFFF8F0A8),
    2: ui.Color(0xFFFFFFFF),
    1: ui.Color(0xFFFFFFFF),
    0: ui.Color(0xFF9C8F7A),
    -1: ui.Color(0xFF8A8A8A),
  };
  const bordes = <int, ui.Color>{
    5: ui.Color(0xFFC1693C),
    4: ui.Color(0xFFC9A24D),
    3: ui.Color(0xFFB5B08A),
    2: ui.Color(0xFFBDBDBD),
    1: ui.Color(0xFFCFCFCF),
  };
  final orden = porRango.keys.toList()..sort();
  for (final r in orden) {
    final p = porRango[r]!;
    final w = (anchos[r] ?? 2.0) * 2 * factor;
    final borde = bordes[r];
    if (borde != null && z >= 11) {
      canvas.drawPath(
          p,
          trazo
            ..color = borde
            ..strokeWidth = w + 3);
    }
    canvas.drawPath(
        p,
        trazo
          ..color = rellenos[r] ?? const ui.Color(0xFFFFFFFF)
          ..strokeWidth = w);
  }

  // 7) etiquetas con anti-choques: lugares primero, luego nombres de calles
  final ocupados = <ui.Rect>[];
  final halo = ui.Paint()
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 4
    ..color = const ui.Color(0xCCFFFFFF);
  const colTexto = ui.Color(0xFF333333);

  bool libre(ui.Rect r) {
    for (final o in ocupados) {
      if (o.overlaps(r)) return false;
    }
    return true;
  }

  final lugares = <_EtiquetaLugar>[];
  for (final capa in capas) {
    if (_categoriaCapa(capa.nombre) != 7) continue;
    final k = kDe(capa);
    for (final f in capa.feats) {
      if (f.tipo != 1 || f.partes.isEmpty) continue;
      final nombre = _nombreDe(f);
      if (nombre.isEmpty) continue;
      final est = _estiloLugar(_claseDe(f), z);
      if (est == null) continue;
      final px = f.partes.first[0] * k - ox, py = f.partes.first[1] * k - oy;
      if (px < 0 || px > _pxTesela || py < 0 || py > _pxTesela) continue;
      final rango = f.props['rank'];
      lugares.add(_EtiquetaLugar(rango is num ? rango : 50, nombre, px, py, est));
    }
  }
  lugares.sort((a, b) => a.rango.compareTo(b.rango));
  for (final l in lugares) {
    final fondo = _parrafo(l.nombre, l.estilo.tam, contorno: halo, negrita: l.estilo.negrita);
    final texto = _parrafo(l.nombre, l.estilo.tam, color: colTexto, negrita: l.estilo.negrita);
    final caja = ui.Rect.fromCenter(
        center: ui.Offset(l.x, l.y), width: texto.longestLine + 8, height: texto.height + 4);
    if (!libre(caja)) continue;
    ocupados.add(caja);
    canvas.drawParagraph(fondo, ui.Offset(l.x - 150, l.y - fondo.height / 2));
    canvas.drawParagraph(texto, ui.Offset(l.x - 150, l.y - texto.height / 2));
  }

  if (z >= 15) {
    final usados = <String, int>{};
    for (final capa in capas) {
      final cat = _categoriaCapa(capa.nombre);
      if (cat != 8 && cat != 5) continue;
      final k = kDe(capa);
      for (final f in capa.feats) {
        if (f.tipo != 2 || f.partes.isEmpty) continue;
        final nombre = _nombreDe(f);
        if (nombre.isEmpty || (usados[nombre] ?? 0) >= 2) continue;
        // parte más larga y su punto medio
        Float32List? mejor;
        for (final p in f.partes) {
          if (mejor == null || p.length > mejor.length) mejor = p;
        }
        if (mejor == null || mejor.length < 4) continue;
        final n = mejor.length ~/ 2;
        var largo = 0.0;
        for (var i = 1; i < n; i++) {
          largo += math.sqrt(math.pow(mejor[2 * i] - mejor[2 * i - 2], 2) + math.pow(mejor[2 * i + 1] - mejor[2 * i - 1], 2)) * k;
        }
        final texto = _parrafo(nombre, 18, color: const ui.Color(0xFF555555));
        if (largo < texto.longestLine * 1.15) continue;
        var acum = 0.0;
        var mx = 0.0, my = 0.0, ang = 0.0;
        for (var i = 1; i < n; i++) {
          final ax = mejor[2 * i - 2] * k - ox, ay = mejor[2 * i - 1] * k - oy;
          final bx = mejor[2 * i] * k - ox, by = mejor[2 * i + 1] * k - oy;
          final seg = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
          if (acum + seg >= largo / 2) {
            final t = seg <= 0 ? 0.0 : (largo / 2 - acum) / seg;
            mx = ax + (bx - ax) * t;
            my = ay + (by - ay) * t;
            ang = math.atan2(by - ay, bx - ax);
            break;
          }
          acum += seg;
        }
        if (mx < 0 || mx > _pxTesela || my < 0 || my > _pxTesela) continue;
        if (ang > math.pi / 2) ang -= math.pi;
        if (ang < -math.pi / 2) ang += math.pi;
        final lado = math.max(texto.longestLine, texto.height) + 6;
        final caja = ui.Rect.fromCenter(center: ui.Offset(mx, my), width: lado, height: lado);
        if (!libre(caja)) continue;
        ocupados.add(caja);
        usados[nombre] = (usados[nombre] ?? 0) + 1;
        final fondo = _parrafo(nombre, 18, contorno: halo);
        canvas.save();
        canvas.translate(mx, my);
        canvas.rotate(ang);
        canvas.drawParagraph(fondo, ui.Offset(-150, -fondo.height / 2));
        canvas.drawParagraph(texto, ui.Offset(-150, -texto.height / 2));
        canvas.restore();
      }
    }
  }

  final imagen = await rec.endRecording().toImage(_pxTesela, _pxTesela);
  return imagen;
}

// ---------------------------------------------------------------- proveedor de teselas

class _ImagenMbTile extends ImageProvider<_ImagenMbTile> {
  final List<Database> bases;
  final List<bool> vectorial; // por base: true = teselas pbf
  final List<int> zMaxBase; // por base: zoom máximo con datos
  final int x, y, z;
  const _ImagenMbTile(this.bases, this.vectorial, this.zMaxBase, this.x, this.y, this.z);

  // Teselas vectoriales ya decodificadas (las sub-teselas ampliadas comparten la madre) y cola de dibujo
  static final Map<String, List<_CapaVec>> _cache = <String, List<_CapaVec>>{};
  static Future<void> _turno = Future<void>.value();

  /// Dibuja de una en una y cede el hilo entre teselas para que la interfaz no se trabe.
  static Future<T> _enCola<T>(Future<T> Function() trabajo) {
    final completer = Completer<T>();
    _turno = _turno.then((_) async {
      try {
        completer.complete(await trabajo());
      } catch (e, s) {
        completer.completeError(e, s);
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
    });
    return completer.future;
  }

  /// Lee la tesela de la tabla `tiles` (zoom_level, tile_column, tile_row, tile_data).
  Future<Uint8List?> _leer(Database db, int zz, int xx, int yy) async {
    // MBTiles usa esquema TMS (Y invertida); flutter_map usa XYZ  →  y_tms = (1 << z) - 1 - y
    final fila = (1 << zz) - 1 - yy;
    try {
      final r = await db.rawQuery(
          'SELECT tile_data FROM tiles WHERE zoom_level = ? AND tile_column = ? AND tile_row = ? LIMIT 1',
          [zz, xx, fila]);
      if (r.isNotEmpty) {
        final d = r.first['tile_data'];
        if (d is Uint8List && d.isNotEmpty) return d;
      }
    } catch (_) {}
    return null; // no existe en la base offline
  }

  Future<ui.Image> _transparente() async {
    final codec = await _codecTransparente();
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  Future<ui.Image?> _vectorialDe(int i) {
    final zb = zMaxBase[i];
    final d = z > zb ? z - zb : 0;
    if (d > 6) return Future<ui.Image?>.value(null);
    final zd = z - d;
    final xd = x >> d, yd = y >> d;
    final sx = x & ((1 << d) - 1), sy = y & ((1 << d) - 1);
    return _enCola<ui.Image?>(() async {
      final clave = '$i/$zd/$xd/$yd';
      var capas = _cache.remove(clave); // se reinserta al final: así el más antiguo es el primero
      if (capas == null) {
        final datos = await _leer(bases[i], zd, xd, yd);
        if (datos == null) return null;
        capas = _decodificarMvt(_descomprimirTesela(datos));
      }
      _cache[clave] = capas;
      if (_cache.length > 20) _cache.remove(_cache.keys.first);
      return _dibujarVectorial(capas, zd, d, sx, sy);
    });
  }

  Future<ImageInfo> _cargar(ImageDecoderCallback decode) async {
    try {
      for (var i = 0; i < bases.length; i++) {
        if (vectorial[i]) {
          final img = await _vectorialDe(i);
          if (img != null) return ImageInfo(image: img, scale: _pxTesela / 256.0);
        } else {
          if (z > zMaxBase[i]) continue;
          final datos = await _leer(bases[i], z, x, y);
          if (datos != null) {
            final buffer = await ui.ImmutableBuffer.fromUint8List(datos);
            final codec = await decode(buffer); // el await permite atrapar datos corruptos
            final frame = await codec.getNextFrame();
            codec.dispose();
            return ImageInfo(image: frame.image);
          }
        }
      }
    } catch (_) {}
    return ImageInfo(image: await _transparente());
  }

  @override
  Future<_ImagenMbTile> obtainKey(ImageConfiguration configuration) => SynchronousFuture<_ImagenMbTile>(this);

  @override
  ImageStreamCompleter loadImage(_ImagenMbTile key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_cargar(decode));

  @override
  bool operator ==(Object other) =>
      other is _ImagenMbTile && other.x == x && other.y == y && other.z == z && identical(other.bases, bases);

  @override
  int get hashCode => Object.hash(x, y, z, identityHashCode(bases));
}

class ProveedorMbTiles extends TileProvider {
  final List<Database> bases;
  final List<bool> vectorial;
  final List<int> zMaxBase;
  ProveedorMbTiles(this.bases, [List<bool>? vectorial, List<int>? zMaxBase])
      : vectorial = vectorial ?? List<bool>.filled(bases.length, false),
        zMaxBase = zMaxBase ?? List<int>.filled(bases.length, 19);

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      _ImagenMbTile(bases, vectorial, zMaxBase, coordinates.x, coordinates.y, coordinates.z);
}

// ============================================================================
// 7B. DESCARGA DE MAPAS Y RED VIAL (Overpass · Nominatim · servidor de teselas)
// ============================================================================
//
//  Fuentes PÚBLICAS (la app solo necesita internet mientras descarga):
//   · Red vial ....... Overpass API (datos de OpenStreetMap, licencia ODbL).
//   · Municipios ..... Nominatim (buscador de OpenStreetMap).
//   · Mapas vectoriales ... el servidor de teselas XYZ que el usuario indique (ver panel de Ajustes).
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
            final nom = tags['name'] ?? tags['ref'];
            if (nom != null) linea.write(',"name":${jsonEncode('$nom')}');
            final ms = tags['maxspeed'];
            if (ms != null) linea.write(',"maxspeed":${jsonEncode('$ms')}');
            if ('${tags['toll']}' == 'yes') linea.write(',"toll":"yes"');
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

/// ¿Son teselas vectoriales (protobuf, con o sin gzip) y no una imagen ni una página de error?
bool _esTeselaVectorial(Uint8List b) {
  if (_formatoImagen(b) != null) return false;
  try {
    _decodificarMvt(_descomprimirTesela(b));
    return true;
  } catch (_) {
    return false;
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

/// Descarga teselas VECTORIALES (pbf) de un servidor XYZ y las empaqueta en un archivo .mbtiles
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
            if (!_esTeselaVectorial(datos)) {
              fatal = const ErrorDescarga('El servidor no devolvió teselas vectoriales (pbf/mvt). '
                  'Revisa la URL: debe ser de teselas vectoriales, no imágenes PNG/JPG.');
            } else {
              formato ??= 'pbf';
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
        'format': formato ?? 'pbf',
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
  // Rutas alternativas, paradas intermedias, preferencias y datos de la vía actual
  List<Ruta> opcionesRuta = <Ruta>[];
  int idxRuta = 0;
  final List<LatLng> paradas = <LatLng>[];
  final List<String> paradasNombres = <String>[];
  int limiteActual = 0; // km/h de la vía actual (0 = desconocido)
  String calleActual = '';
  bool evitarPeajes = false, evitarTerraceria = false;
  int _ultimoAvisoVelMs = 0;
  bool vozActiva = true;
  bool escuchando = false;
  bool redCargada = false;
  String redEstado = 'Sin red vial: se usa ruta en línea recta';
  List<MapaLocal> mapas = [];
  // Rango de zoom real de los .mbtiles cargados y área que cubren (metadata "bounds")
  int zoomMinTiles = 0, zoomMaxTiles = 19;
  bool hayVectorial = false; // hay mapas vectoriales: se re-dibujan ampliados hasta el zoom 19
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
      await _cargarRedGuardada();
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
    await _cargarRedGuardada();
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
    paradas.clear();
    paradasNombres.clear();
    opcionesRuta = <Ruta>[];
    idxRuta = 0;
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
    paradas.clear();
    paradasNombres.clear();
    opcionesRuta = <Ruta>[];
    idxRuta = 0;
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
      final o = LatLng(u.latitude, u.longitude);
      final r = await motor.calcular(o, d, modo,
          paradas: List<LatLng>.of(paradas), nombresParadas: List<String>.of(paradasNombres));
      opcionesRuta = <Ruta>[r];
      idxRuta = 0;
      _aplicarRuta(r);
      notifyListeners();
      if (r.aproximada) _msg('Ruta en línea recta (sin red vial cargada o sin camino).');
      if (iniciar) {
        await _comenzar(r);
      } else if (recalculo) {
        voz.hablar('Ruta recalculada', urgente: true);
      } else if (paradas.isEmpty && !r.aproximada) {
        _buscarAlternativas(o, d, r); // sin await: aparecen cuando estén listas
      }
    } catch (e) {
      calculando = false;
      _msg('No se pudo calcular la ruta: $e');
    }
  }

  // ---------------------------------------------------- rutas alternativas, paradas y preferencias
  void _aplicarRuta(Ruta r) {
    _idxSeg = 0;
    _desvios = 0;
    _anunciadas.clear();
    ruta = r;
    calculando = false;
    restanteM = r.total;
    etaS = r.duracionS.round();
    proxima = r.maniobras.where((m) => m.tipo != TipoGiro.salida).firstOrNull;
    distProxima = proxima?.acumM ?? r.total;
    limiteActual = 0;
    calleActual = '';
  }

  Future<void> _buscarAlternativas(LatLng o, LatLng d, Ruta mejor) async {
    try {
      final alt = await motor.alternativas(o, d, mejor.modo, mejor);
      if (alt.isEmpty || !identical(ruta, mejor)) return; // cambió el destino mientras se calculaba
      opcionesRuta = <Ruta>[mejor, ...alt];
      notifyListeners();
    } catch (_) {}
  }

  /// Rota entre la ruta principal y sus alternativas (antes de iniciar la navegación).
  void alternarRuta() {
    if (opcionesRuta.length < 2 || fase == Fase.navegando) return;
    idxRuta = (idxRuta + 1) % opcionesRuta.length;
    _aplicarRuta(opcionesRuta[idxRuta]);
    notifyListeners();
  }

  /// Agrega una parada intermedia antes del destino final (sin destino todavía, será el destino).
  Future<void> agregarParada(LatLng ll, String nombre) async {
    if (destino == null) {
      await establecerDestino(ll, nombre);
      return;
    }
    if (fase == Fase.navegando) return _msg('Detén la navegación para cambiar las paradas.');
    paradas.add(ll);
    paradasNombres.add(nombre);
    notifyListeners();
    await _calcularRuta();
  }

  Future<void> quitarParada(int i) async {
    if (fase == Fase.navegando) return _msg('Detén la navegación para cambiar las paradas.');
    if (i < 0 || i >= paradas.length) return;
    paradas.removeAt(i);
    paradasNombres.removeAt(i);
    notifyListeners();
    await _calcularRuta();
  }

  void _avisarVelocidad() {
    if (limiteActual <= 0 || modo == Modo.pie || modo == Modo.bici) return;
    if (velKmh <= limiteActual + 10) return;
    final ahora = DateTime.now().millisecondsSinceEpoch;
    if (ahora - _ultimoAvisoVelMs < 45000) return;
    _ultimoAvisoVelMs = ahora;
    voz.hablar('Reduce la velocidad. El límite es $limiteActual kilómetros por hora.');
  }

  Future<void> establecerEvitarPeajes(bool v) async {
    evitarPeajes = v;
    motor.evitarPeajes = v;
    await _guardarAjustes();
    notifyListeners();
    if (destino != null) await _calcularRuta(recalculo: fase == Fase.navegando);
  }

  Future<void> establecerEvitarTerraceria(bool v) async {
    evitarTerraceria = v;
    motor.evitarTerraceria = v;
    await _guardarAjustes();
    notifyListeners();
    if (destino != null) await _calcularRuta(recalculo: fase == Fase.navegando);
  }

  // ---------------------------------------------------- navegación activa
  Future<void> iniciarNavegacion() async {
    if (destino == null) return _msg('Elige un destino primero.');
    final u = ubic;
    if (u == null) return _msg('Esperando señal GPS…');
    final r = ruta;
    // Si elegiste una ruta alternativa y sigues cerca de su inicio, se respeta (no se recalcula)
    if (r != null &&
        idxRuta > 0 &&
        !r.aproximada &&
        Geo.dist(u.latitude, u.longitude, r.puntos.first.latitude, r.puntos.first.longitude) < 150) {
      await _comenzar(r);
      return;
    }
    await _calcularRuta(iniciar: true); // recalcula desde la posición actual
  }

  Future<void> _comenzar(Ruta r) async {
    _recorridoM = 0;
    opcionesRuta = <Ruta>[r];
    idxRuta = 0;
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
      limiteActual = pr.seg < r.limiteSeg.length ? r.limiteSeg[pr.seg] : 0;
      calleActual = pr.seg < r.calleSeg.length ? r.calleSeg[pr.seg] : '';
      _avisarVelocidad();
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
    final raster = <String>[];
    final flagsVec = <bool>[];
    final zMaxBases = <int>[];
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
        var esVec = fmt == 'pbf' || fmt == 'mvt';
        if (!esVec && fmt.isEmpty) {
          // Sin metadata "format": se mira una tesela de muestra (si no es imagen, se asume vectorial)
          final mu = await db.rawQuery('SELECT tile_data FROM tiles LIMIT 1');
          final d0 = mu.isEmpty ? null : mu.first['tile_data'];
          if (d0 is Uint8List) esVec = _esTeselaVectorial(d0);
        }
        if (!esVec) {
          await db.close(); // esta app solo usa mapas VECTORIALES: los raster (png/jpg/webp) se ignoran
          raster.add(m.nombre);
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
        flagsVec.add(esVec);
        zMaxBases.add(b is int ? b : 19);
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
    hayVectorial = flagsVec.contains(true);
    proveedorTiles = ProveedorMbTiles(List<Database>.of(_basesMb), flagsVec, zMaxBases);
    versionMapas++;
    notifyListeners();
    if (raster.isNotEmpty && validos.isEmpty) {
      _msg('${raster.join(', ')} es un mapa RASTER y se ignora: esta app solo usa mapas vectoriales (.mbtiles con teselas pbf).');
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
      return _msg('Formato no soportado: usa un archivo .mbtiles VECTORIAL (teselas pbf).');
    }
    _msg('Importando mapa… los archivos grandes pueden tardar.');
    try {
      final carpeta = await _carpeta('mapas');
      await File(origen).copy(ruta_p.join(carpeta.path, ruta_p.basename(origen).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')));
      await _abrirMapas();
      if (mapas.isNotEmpty) _msg('Mapa vectorial importado.');
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
      if (!_esGeoJson(origen)) {
        redEstado = 'Sin red vial: se usa ruta en línea recta';
        return _msg('Formato no soportado: usa un archivo .geojson.');
      }
      final nombre = ruta_p.basename(origen).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      await File(origen).copy(ruta_p.join(carpeta.path, nombre));
      await _cargarRedGuardada();
    } catch (e) {
      redEstado = 'Error al importar la red vial';
      _msg('No se pudo importar la red vial: $e');
    }
  }

  // ---- Regiones de red vial guardadas (varios .geojson en la carpeta «red») ----
  static bool _esGeoJson(String ruta) {
    final m = ruta.toLowerCase();
    return m.endsWith('.geojson') || m.endsWith('.json');
  }

  /// Archivos de red vial de la app (carpeta «red») y, si hay permiso, los .geojson de Descargas
  /// (se leen EN SITIO, igual que los mapas). Si un nombre está en los dos sitios se usa el de la app.
  Future<List<File>> _archivosRed() async {
    final dir = await _carpeta('red');
    final r = dir.listSync().whereType<File>().where((f) => _esGeoJson(f.path)).toList();
    final vistos = r.map((f) => ruta_p.basename(f.path).toLowerCase()).toSet();
    redEnDescargas.clear();
    if (await _tienePermisoDescargas()) {
      for (final ruta in await _carpetasDescargas()) {
        try {
          final d = Directory(ruta);
          if (!await d.exists()) continue;
          await for (final e in d.list(followLinks: false)) {
            // en Descargas solo .geojson (un .json suelto puede ser cualquier otra cosa)
            if (e is File && e.path.toLowerCase().endsWith('.geojson') && vistos.add(ruta_p.basename(e.path).toLowerCase())) {
              r.add(e);
              redEnDescargas.add(e.path);
            }
          }
          break;
        } on FileSystemException {
          continue;
        }
      }
    }
    r.sort((a, b) => a.path.compareTo(b.path));
    return r;
  }

  final Set<String> redEnDescargas = <String>{};

  /// Botón «Buscar en Descargas» de la red vial.
  Future<void> buscarRedEnDescargas() async {
    if (!await _pedirPermisoDescargas()) {
      _msg('Sin el permiso «Acceso a todos los archivos» no puedo leer la carpeta Descargas.');
      return;
    }
    await _cargarRedGuardada();
    _msg(redEnDescargas.isEmpty
        ? 'No encontré archivos .geojson en la carpeta Descargas.'
        : 'Red vial leída desde Descargas (${redEnDescargas.length} ${redEnDescargas.length == 1 ? 'archivo' : 'archivos'}).');
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
    if (redEnDescargas.contains(f.path)) {
      return _msg('Ese archivo está en Descargas: bórralo desde tu administrador de archivos.');
    }
    try {
      if (await f.exists()) await f.delete();
    } catch (e) {
      _msg('No se pudo borrar la región: $e');
    }
    await _cargarRedGuardada();
  }

  Future<void> quitarRedVial() async {
    for (final f in await _archivosRed()) {
      if (redEnDescargas.contains(f.path)) continue; // los de Descargas no se tocan
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
        if (m is Map) {
          plantillaTeselas = '${m['plantilla'] ?? ''}';
          evitarPeajes = m['evitarPeajes'] == true;
          evitarTerraceria = m['evitarTerraceria'] == true;
          motor.evitarPeajes = evitarPeajes;
          motor.evitarTerraceria = evitarTerraceria;
        }
      }
    } catch (_) {}
  }

  Future<void> _guardarAjustes() async {
    try {
      await (await _archivoAjustesDescarga()).writeAsString(jsonEncode({
        'plantilla': plantillaTeselas,
        'evitarPeajes': evitarPeajes,
        'evitarTerraceria': evitarTerraceria,
      }));
    } catch (_) {}
  }

  Future<void> _guardarPlantilla(String p) async {
    plantillaTeselas = p;
    await _guardarAjustes();
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

  /// Descarga teselas vectoriales del país, un estado o un municipio y las guarda como .mbtiles.
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
      return _msg('La URL del servidor debe incluir {z}, {x} y {y}. Ej.: https://servidor/{z}/{x}/{y}.pbf');
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
          maxNativeZoom: c.hayVectorial ? 19 : c.zoomMaxTiles,
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
      const Text('Mapas vectoriales offline (.mbtiles pbf)', style: TextStyle(fontWeight: FontWeight.bold)),
      if (c.mapas.isEmpty) const Text('No hay mapas vectoriales. Copia el .mbtiles (pbf) a la carpeta Descargas y pulsa «Buscar en Descargas».'),
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
          subtitle: Text('${c.redEnDescargas.contains(f.path) ? 'Leído desde Descargas' : 'Guardado en la app'} · ${_tamanoArchivo(f)}'),
          trailing: c.redEnDescargas.contains(f.path)
              ? null
              : IconButton(onPressed: () => c.eliminarRegionRed(f), icon: const Icon(Icons.delete_outline)),
        ),
      if (c.regionesRed.isEmpty) const Text('Copia tu .geojson a la carpeta Descargas y pulsa «Buscar en Descargas».'),
      const SizedBox(height: 8),
      FilledButton(onPressed: c.buscarRedEnDescargas, child: const Text('Buscar en Descargas')),
      const SizedBox(height: 8),
      OutlinedButton(onPressed: c.importarRedVial, child: const Text('Elegir y copiar un .geojson…')),
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
                labelText: 'Servidor de teselas vectoriales (XYZ, pbf)',
                hintText: 'https://tu-servidor/{z}/{x}/{y}.pbf',
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

