import 'package:flutter/material.dart';

/// 通用卡片组件: 同时用于分类卡片与表情网格卡片。
///
/// 底层渐变背景 + 图片 (Contain 适配) + 底部文字遮罩;
/// 支持选中描边、右上角徽标 ([trailingLabel])、
/// 单击/长按/右键 ([onSecondaryTapUp]) 交互。
class ImageCard extends StatelessWidget {
  const ImageCard({
    super.key,
    required this.title,
    this.subtitle,
    this.imageProvider,
    this.width = 220,
    this.height = 220,
    this.selected = false,
    this.trailingLabel,
    this.showText = true,
    this.showBottomOverlay = true,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTapUp,
  });

  final ImageProvider<Object>? imageProvider;
  final String title;
  final String? subtitle;
  final double width;
  final double height;
  final bool selected;
  final String? trailingLabel;
  final bool showText;
  final bool showBottomOverlay;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final void Function(TapUpDetails details)? onSecondaryTapUp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(5),
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTapUp: onSecondaryTapUp,
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
              color: selected ? theme.colorScheme.primary : Colors.white10,
              width: selected ? 1.5 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 18,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0xFF30343A),
                          Color(0xFF17191C),
                        ],
                      ),
                    ),
                    child: imageProvider == null
                        ? const _CardPlaceholder()
                        : Image(
                            image: imageProvider!,
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) {
                              return const _CardPlaceholder();
                            },
                          ),
                  ),
                ),
                if (showBottomOverlay)
                  // 底部渐变遮罩, 保证文字在浅色图片上仍可读。
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 96,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.85),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (trailingLabel != null)
                  Positioned(
                    top: 12,
                    right: 12,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.58),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: Text(
                          trailingLabel!,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (showText)
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 16,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 图片缺失或加载失败时显示的占位图标。
class _CardPlaceholder extends StatelessWidget {
  const _CardPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Icon(
        Icons.emoji_emotions_outlined,
        size: 40,
        color: Colors.white38,
      ),
    );
  }
}
