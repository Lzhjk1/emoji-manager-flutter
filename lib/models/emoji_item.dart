/// 单张表情的元数据模型。
///
/// [path] 指向原图文件, [thumbnailPath] 指向缩略图缓存文件;
/// [mimeType] 由文件头魔数检测得出, 不信任文件扩展名。
/// 通过 [toJson]/[fromJson] 序列化后持久化到本地缓存。
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

  /// 原图文件的绝对路径。
  final String path;

  /// 显示名称 (通常为不含扩展名的文件名)。
  final String name;

  /// MIME 类型 (如 image/png、image/gif), 依据文件头魔数判断。
  final String mimeType;

  /// 所属分类名, 对应磁盘上的目录名; '最近使用' 为虚拟分类。
  final String category;

  /// 原图文件最后修改时间 (毫秒时间戳), 用于按时间排序。
  final int lastModified;

  /// 缩略图缓存文件路径, 可能为 null (尚未生成或生成失败)。
  final String? thumbnailPath;

  /// 用户为该表情添加的备注, 可为空。
  final String? remark;

  /// 复制并按需覆盖字段; [clearRemark] 为 true 时显式清空备注。
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
