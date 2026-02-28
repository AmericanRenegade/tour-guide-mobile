import 'dart:convert';

class ActiveLocation {
  final String id;
  final String name;
  final double lat;
  final double lng;
  final Map<String, dynamic>? triggerGeometry;
  final double triggerRadiusM;

  const ActiveLocation({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    this.triggerGeometry,
    required this.triggerRadiusM,
  });

  factory ActiveLocation.fromJson(Map<String, dynamic> json) {
    final geomRaw = json['trigger_geometry'];
    Map<String, dynamic>? geom;
    if (geomRaw is String) {
      try { geom = jsonDecode(geomRaw) as Map<String, dynamic>; } catch (_) {}
    } else if (geomRaw is Map) {
      geom = Map<String, dynamic>.from(geomRaw);
    }
    return ActiveLocation(
      id: json['id'] as String,
      name: json['name'] as String,
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      triggerGeometry: geom,
      triggerRadiusM: (json['trigger_radius_m'] as num?)?.toDouble() ?? 300.0,
    );
  }

  /// Effective radius in metres for circle zones. Falls back to trigger_radius_m
  /// if trigger_geometry is absent or is a non-circle type.
  double get circleRadiusM {
    final geom = triggerGeometry;
    if (geom != null && geom['type'] == 'circle') {
      return (geom['radius_m'] as num?)?.toDouble() ?? triggerRadiusM;
    }
    return triggerRadiusM;
  }

  bool get isPolygon =>
      triggerGeometry != null &&
      (triggerGeometry!['type'] == 'polygon' || triggerGeometry!['type'] == 'multipolygon');

  /// All polygon rings as lists of [lat, lng] pairs.
  /// For 'polygon': returns a single-element list.
  /// For 'multipolygon': returns one list per ring.
  List<List<List<double>>> get allPolygonRings {
    if (triggerGeometry == null) return [];
    final type = triggerGeometry!['type'];

    if (type == 'polygon') {
      final coords = triggerGeometry!['coordinates'] as List?;
      if (coords == null) return [];
      return [
        coords.map<List<double>>((c) => [(c[0] as num).toDouble(), (c[1] as num).toDouble()]).toList()
      ];
    }

    if (type == 'multipolygon') {
      final polygons = triggerGeometry!['polygons'] as List?;
      if (polygons == null) return [];
      return polygons.map<List<List<double>>>((ring) {
        final coords = ring as List;
        return coords.map<List<double>>((c) => [(c[0] as num).toDouble(), (c[1] as num).toDouble()]).toList();
      }).toList();
    }

    return [];
  }

  /// Backward-compatible: returns flat coordinates for a single polygon.
  /// For multipolygon, returns the first ring.
  List<List<double>> get polygonCoordinates {
    final rings = allPolygonRings;
    return rings.isNotEmpty ? rings.first : [];
  }
}
