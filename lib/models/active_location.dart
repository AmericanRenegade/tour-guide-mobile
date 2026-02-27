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
      triggerGeometry != null && triggerGeometry!['type'] == 'polygon';

  /// Polygon coordinates as list of [lat, lng] pairs.
  List<List<double>> get polygonCoordinates {
    if (!isPolygon) return [];
    final coords = triggerGeometry!['coordinates'] as List?;
    if (coords == null) return [];
    return coords
        .map<List<double>>((c) => [(c[0] as num).toDouble(), (c[1] as num).toDouble()])
        .toList();
  }
}
