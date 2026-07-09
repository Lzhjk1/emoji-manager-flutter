class EmojiItem {
  const EmojiItem({
    required this.path,
    required this.name,
    required this.mimeType,
    required this.category,
    required this.lastModified,
    this.thumbnailPath,
    this.remark,
  });

  final String path;
  final String name;
  final String mimeType;
  final String category;
  final int lastModified;
  final String? thumbnailPath;
  final String? remark;

  EmojiItem copyWith({
    String? path,
    String? name,
    String? mimeType,
    String? category,
    int? lastModified,
    String? thumbnailPath,
    String? remark,
    bool clearRemark = false,
  }) {
    return EmojiItem(
      path: path ?? this.path,
      name: name ?? this.name,
      mimeType: mimeType ?? this.mimeType,
      category: category ?? this.category,
      lastModified: lastModified ?? this.lastModified,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      remark: clearRemark ? null : (remark ?? this.remark),
    );
  }

  factory EmojiItem.fromJson(Map<String, dynamic> json) {
    return EmojiItem(
      path: json['path'] as String? ?? '',
      name: json['name'] as String? ?? '',
      mimeType: json['mimeType'] as String? ?? 'image/jpeg',
      category: json['category'] as String? ?? '',
      lastModified: json['lastModified'] as int? ?? 0,
      thumbnailPath: json['thumbnailPath'] as String?,
      remark: json['remark'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'path': path,
      'name': name,
      'mimeType': mimeType,
      'category': category,
      'lastModified': lastModified,
      'thumbnailPath': thumbnailPath,
      'remark': remark,
    };
  }
}
