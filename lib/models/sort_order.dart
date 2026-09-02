/// 表情列表的排序方式。
enum SortOrder {
  /// 按顺序文件 (order.txt 中登记的顺序) 排列。
  byOrder('按顺序文件'),

  /// 按名称排序。
  byName('按名称'),

  /// 按文件修改时间排序。
  byTime('按时间');

  const SortOrder(this.label);

  /// 界面上显示的中文名称。
  final String label;

  /// 写入设置存储时使用的值 (直接用枚举名)。
  String get storageValue => name;

  /// 从设置存储恢复枚举值, 未知值回退为按顺序文件。
  static SortOrder fromStorage(String? value) {
    return SortOrder.values.firstWhere(
      (item) => item.name == value,
      orElse: () => SortOrder.byOrder,
    );
  }
}
