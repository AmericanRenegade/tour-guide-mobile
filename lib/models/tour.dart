class Tour {
  final String id;
  final String name;
  final String? description;
  final String? photoUrl;
  final int locationCount;
  final List<String> locationIds;

  const Tour({
    required this.id,
    required this.name,
    this.description,
    this.photoUrl,
    required this.locationCount,
    required this.locationIds,
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
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'photo_url': photoUrl,
        'location_count': locationCount,
        'location_ids': locationIds,
      };
}
