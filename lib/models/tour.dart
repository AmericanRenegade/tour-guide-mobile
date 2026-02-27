class Tour {
  final String id;
  final String name;
  final String? description;
  final String? photoUrl;
  final int locationCount;
  final List<String> locationIds;
  final List<String> stateCodes;
  final int locationsVisited;
  final bool enrolled;
  final String? enrolledAt;

  const Tour({
    required this.id,
    required this.name,
    this.description,
    this.photoUrl,
    required this.locationCount,
    required this.locationIds,
    this.stateCodes = const [],
    this.locationsVisited = 0,
    this.enrolled = false,
    this.enrolledAt,
  });

  factory Tour.fromJson(Map<String, dynamic> j) => Tour(
        id: j['id'] as String,
        name: j['name'] as String,
        description: j['description'] as String?,
        photoUrl: j['photo_url'] as String?,
        locationCount: (j['location_count'] as num?)?.toInt() ?? 0,
        locationIds: (j['location_ids'] as List?)
                ?.map((e) => e as String)
                .toList() ??
            [],
        stateCodes: (j['state_codes'] as List?)
                ?.map((e) => e as String)
                .toList() ??
            [],
        locationsVisited: (j['locations_visited'] as num?)?.toInt() ?? 0,
        enrolled: j['enrolled'] as bool? ?? false,
        enrolledAt: j['enrolled_at'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'photo_url': photoUrl,
        'location_count': locationCount,
        'location_ids': locationIds,
        'state_codes': stateCodes,
        'locations_visited': locationsVisited,
        'enrolled': enrolled,
        'enrolled_at': enrolledAt,
      };
}
