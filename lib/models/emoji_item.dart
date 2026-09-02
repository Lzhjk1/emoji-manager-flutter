class EmojiItem {
  const EmojiItem({
    required this.path,
    required this.name,
    required this.mimeType,
    required this.category,
    required this.lastModified,
    this.thumbnailPath,
    this.remark,
    this.fileSize = 0,
    this.homeCategory,
    this.isLink = false,
    this.isMissing = false,
  });

  final String path;
  final String name;
  final String mimeType;
  final String category;
  final int lastModified;
  final String? thumbnailPath;
  final String? remark;

  /// 文件字节数 (扫描时从 stat 取得, 用于去重 size 预筛)。
  final int fileSize;

  /// 实体文件所在目录对应的分类 (链接项的"来源"分类); 非链接项与 category 相同。
  final String? homeCategory;

  /// 是否为链接项: 实体文件在别的分类目录, 本条是索引里加出来的映射。
  final bool isLink;

  /// 链接失效标记: 实体文件丢失且自愈失败, 显示为置灰占位。
  final bool isMissing;

  EmojiItem copyWith({
    String? path,
    String? name,
    String? mimeType,
    String? category,
    int? lastModified,
    String? thumbnailPath,
    String? remark,
    int? fileSize,
    String? homeCategory,
    bool? isLink,
    bool? isMissing,
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
      fileSize: fileSize ?? this.fileSize,
      homeCategory: homeCategory ?? this.homeCategory,
      isLink: isLink ?? this.isLink,
      isMissing: isMissing ?? this.isMissing,
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
      fileSize: json['fileSize'] as int? ?? 0,
      homeCategory: json['homeCategory'] as String?,
      isLink: json['isLink'] as bool? ?? false,
      isMissing: json['isMissing'] as bool? ?? false,
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
      'fileSize': fileSize,
      'homeCategory': homeCategory,
      'isLink': isLink,
      'isMissing': isMissing,
    };
  }
}
