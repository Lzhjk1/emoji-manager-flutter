import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../models/emoji_item.dart';

class EmojiPreviewDialog extends StatefulWidget {
  const EmojiPreviewDialog({
    super.key,
    required this.item,
    required this.currentIndex,
    required this.totalCount,
    required this.onSaveRemark,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onMoveToStart,
    required this.onMoveToEnd,
  });

  final EmojiItem item;
  final int currentIndex;
  final int totalCount;
  final Future<void> Function(String remark) onSaveRemark;
  final Future<void> Function() onMoveUp;
  final Future<void> Function() onMoveDown;
  final Future<void> Function() onMoveToStart;
  final Future<void> Function() onMoveToEnd;
  static final DateFormat _dateFormat = DateFormat('yyyy-MM-dd HH:mm:ss');

  @override
  State<EmojiPreviewDialog> createState() => _EmojiPreviewDialogState();
}

class _EmojiPreviewDialogState extends State<EmojiPreviewDialog> {
  late final TextEditingController _remarkController;
  bool _savingRemark = false;
  bool _reordering = false;

  @override
  void initState() {
    super.initState();
    _remarkController = TextEditingController(text: widget.item.remark ?? '');
  }

  @override
  void dispose() {
    _remarkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final file = File(widget.item.path);
    final sizeInBytes = file.existsSync() ? file.lengthSync() : 0;

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      backgroundColor: const Color(0xFF17191C),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 760),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          widget.item.category,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Colors.white60,
                              ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _InfoChip(label: '分类', value: widget.item.category),
                  _InfoChip(
                    label: '格式',
                    value: widget.item.mimeType.replaceFirst('image/', '').toUpperCase(),
                  ),
                  _InfoChip(label: '大小', value: _formatFileSize(sizeInBytes)),
                  _InfoChip(
                    label: '顺序',
                    value: '${widget.currentIndex + 1} / ${widget.totalCount}',
                  ),
                  _InfoChip(
                    label: '修改时间',
                    value: EmojiPreviewDialog._dateFormat.format(
                      DateTime.fromMillisecondsSinceEpoch(widget.item.lastModified),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SelectableText(
                widget.item.path,
                maxLines: 2,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white60,
                    ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _remarkController,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '备注',
                  hintText: '输入备注，留空表示清除备注',
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _savingRemark ? null : _saveRemark,
                    icon: const Icon(Icons.edit_note_outlined),
                    label: Text(_savingRemark ? '保存中...' : '保存备注'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _savingRemark
                        ? null
                        : () {
                            _remarkController.clear();
                            _saveRemark();
                          },
                    icon: const Icon(Icons.clear),
                    label: const Text('清除备注'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.tonalIcon(
                    onPressed:
                        _reordering || widget.currentIndex <= 0 ? null : _moveToStart,
                    icon: const Icon(Icons.vertical_align_top),
                    label: const Text('置顶'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed:
                        _reordering || widget.currentIndex <= 0 ? null : _moveUp,
                    icon: const Icon(Icons.keyboard_arrow_up),
                    label: const Text('上移'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _reordering ||
                            widget.currentIndex >= widget.totalCount - 1
                        ? null
                        : _moveDown,
                    icon: const Icon(Icons.keyboard_arrow_down),
                    label: const Text('下移'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _reordering ||
                            widget.currentIndex >= widget.totalCount - 1
                        ? null
                        : _moveToEnd,
                    icon: const Icon(Icons.vertical_align_bottom),
                    label: const Text('置底'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: ColoredBox(
                    color: const Color(0xFF111315),
                    child: Image.file(
                      File(widget.item.path),
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) {
                        return const Center(
                          child: Text('图片加载失败'),
                        );
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: () => _copyPath(context),
                    icon: const Icon(Icons.copy_all_outlined),
                    label: const Text('复制路径'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () => _shareFile(context),
                    icon: const Icon(Icons.share_outlined),
                    label: const Text('分享'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('关闭'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _copyPath(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: widget.item.path));
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制文件路径')),
    );
  }

  Future<void> _shareFile(BuildContext context) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(widget.item.path)],
        title: widget.item.name,
        subject: widget.item.name,
        text: widget.item.name,
      ),
    );
  }

  Future<void> _saveRemark() async {
    setState(() {
      _savingRemark = true;
    });
    await widget.onSaveRemark(_remarkController.text);
    if (!mounted) {
      return;
    }
    setState(() {
      _savingRemark = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('备注已保存')),
    );
  }

  Future<void> _moveUp() => _runReorderAction(widget.onMoveUp);

  Future<void> _moveDown() => _runReorderAction(widget.onMoveDown);

  Future<void> _moveToStart() => _runReorderAction(widget.onMoveToStart);

  Future<void> _moveToEnd() => _runReorderAction(widget.onMoveToEnd);

  Future<void> _runReorderAction(Future<void> Function() action) async {
    setState(() {
      _reordering = true;
    });
    await action();
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop();
  }

  String _formatFileSize(int bytes) {
    if (bytes <= 0) {
      return '未知';
    }
    const units = ['B', 'KB', 'MB', 'GB'];
    var size = bytes.toDouble();
    var unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }
    final fractionDigits = size >= 100 ? 0 : (size >= 10 ? 1 : 2);
    return '${size.toStringAsFixed(fractionDigits)} ${units[unitIndex]}';
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF1F2329),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: '$label  ',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white54,
                    ),
              ),
              TextSpan(
                text: value,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
