import 'emoji_item.dart';

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

class EmojiScanResult {
  EmojiScanResult({
    required this.itemsByCategory,
    required this.categoryMetadata,
  });

  final Map<String, List<EmojiItem>> itemsByCategory;
  final Map<String, CategoryMetadata> categoryMetadata;

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
