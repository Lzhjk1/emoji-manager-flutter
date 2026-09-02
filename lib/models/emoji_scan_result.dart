import 'emoji_item.dart';

/// 链接自愈报告: 一次扫描对账中 link 的恢复与丢失情况 (不持久化)。
class LinkHealReport {
  LinkHealReport();

  /// 成功恢复的 (旧路径 -> 新路径)。
  final List<MapEntry<String, String>> healed = [];

  /// 无法恢复而置灰的路径。
  final List<String> missing = [];

  bool get isEmpty => healed.isEmpty && missing.isEmpty;
}

/// 分类的元数据: 分类名、对应磁盘目录路径及修改时间。
class CategoryMetadata {
  const CategoryMetadata({
    required this.name,
    required this.path,
    required this.lastModified,
  });

  final String name;
  final String path;
  final int lastModified;

  factory CategoryMetadata.fromJson(Map<String, dynamic> json) {
    return CategoryMetadata(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      lastModified: json['lastModified'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'name': name,
      'path': path,
      'lastModified': lastModified,
    };
  }
}

/// 一次表情库扫描的结果: 各分类下的表情列表 + 分类元数据。
///
/// 扫描在后台 isolate 中完成, 结果经 JSON 序列化传回主 isolate 并可持久化缓存,
/// 下次启动若目录未变化可直接复用, 加快启动速度。
class EmojiScanResult {
  EmojiScanResult({
    required this.itemsByCategory,
    required this.categoryMetadata,
  });

  /// 分类名 -> 该分类下的表情列表。
  final Map<String, List<EmojiItem>> itemsByCategory;

  /// 分类名 -> 分类元数据。
  final Map<String, CategoryMetadata> categoryMetadata;

  /// 本次扫描对账时的链接自愈报告 (瞬态信息, 不参与序列化与缓存)。
  LinkHealReport? healReport;

  /// 构造空结果 (表情库为空或扫描失败时使用)。
  factory EmojiScanResult.empty() {
    return EmojiScanResult(
      itemsByCategory: {},
      categoryMetadata: {},
    );
  }

  factory EmojiScanResult.fromJson(Map<String, dynamic> json) {
    final itemsByCategory = <String, List<EmojiItem>>{};
    final rawItems = json['itemsByCategory'] as Map<String, dynamic>? ?? {};
    for (final entry in rawItems.entries) {
      final list = (entry.value as List<dynamic>? ?? <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(EmojiItem.fromJson)
          .toList();
      if (list.isNotEmpty) {
        itemsByCategory[entry.key] = list;
      }
    }

    final metadata = <String, CategoryMetadata>{};
    final rawMetadata = json['categoryMetadata'] as Map<String, dynamic>? ?? {};
    for (final entry in rawMetadata.entries) {
      final value = entry.value;
      if (value is Map<String, dynamic>) {
        metadata[entry.key] = CategoryMetadata.fromJson(value);
      }
    }

    return EmojiScanResult(
      itemsByCategory: itemsByCategory,
      categoryMetadata: metadata,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'itemsByCategory': itemsByCategory.map(
        (key, value) => MapEntry<String, dynamic>(
          key,
          value.map((item) => item.toJson()).toList(),
        ),
      ),
      'categoryMetadata': categoryMetadata.map(
        (key, value) => MapEntry<String, dynamic>(key, value.toJson()),
      ),
    };
  }
}
