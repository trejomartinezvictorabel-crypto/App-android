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
  static const List<double> _pie = [0, 5, 5, 5, 5, 5, 5,
