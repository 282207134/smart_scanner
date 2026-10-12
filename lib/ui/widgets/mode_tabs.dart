import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../state/app_controller.dart';
import '../../theme.dart';

/// 顶部功能模式标签页
class ModeTabs extends StatelessWidget {
  final AppController controller;
  const ModeTabs({super.key, required this.controller});

  static const _disabled = {ScanMode.video, ScanMode.contract};

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.bg,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          for (final m in ScanMode.values) ...[
            _TabButton(
              mode: m,
              active: controller.mode == m,
              disabled: _disabled.contains(m),
              onTap: () {
                if (_disabled.contains(m)) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('该功能开发中，敬请期待'),
                    duration: Duration(seconds: 2),
                    behavior: SnackBarBehavior.floating,
                  ));
                  return;
                }
                controller.setMode(m);
              },
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  final ScanMode mode;
  final bool active;
  final bool disabled;
  final VoidCallback onTap;
  const _TabButton(
      {required this.mode,
      required this.active,
      required this.disabled,
      required this.onTap});

  IconData get icon => switch (mode) {
        ScanMode.document => Icons.description_outlined,
        ScanMode.book => Icons.menu_book_outlined,
        ScanMode.idCard => Icons.badge_outlined,
        ScanMode.barcode => Icons.qr_code_scanner,
        ScanMode.video => Icons.videocam_outlined,
        ScanMode.ocr => Icons.text_snippet_outlined,
        ScanMode.contract => Icons.handshake_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final fg =
        disabled ? AppColors.textDim : (active ? Colors.black : AppColors.text);
    return Opacity(
      opacity: disabled ? 0.55 : 1,
      child: Material(
        color: active ? AppColors.accent : AppColors.panel,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: fg),
                const SizedBox(width: 6),
                Text(mode.label,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: fg)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
