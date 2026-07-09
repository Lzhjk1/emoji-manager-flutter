enum SortOrder {
  byOrder('按顺序文件'),
  byName('按名称'),
  byTime('按时间');

  const SortOrder(this.label);

  final String label;

  String get storageValue => name;

  static SortOrder fromStorage(String? value) {
    return SortOrder.values.firstWhere(
      (item) => item.name == value,
      orElse: () => SortOrder.byOrder,
    );
  }
}
