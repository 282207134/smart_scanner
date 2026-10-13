import 'package:flutter/material.dart';

import '../../state/app_controller.dart';
import '../../theme.dart';

/// 左侧竖排工具栏
class LeftToolbar extends StatelessWidget {
  final AppController controller;
  const LeftToolbar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Container(
      width: 46,
      color: AppColors.panelDark,
      child: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 8),
            _btn(Icons.rotate_90_degrees_ccw_outlined, '左旋90°', c.rotateLeft),
            _btn(Icons.rotate_90_degrees_cw_outlined, '右旋90°', c.rotateRight),
            _btn(Icons.zoom_in, '放大', c.zoomIn),
            _btn(Icons.zoom_out, '缩小', c.zoomOut),
            _btn(Icons.filter_1, '1:1 实际大小', c.trueSize),
            _btn(Icons.fit_screen, '适合窗口', c.fitToWindow),
            _btn(
              Icons.center_focus_strong,
              c.focusing ? '正在重新对焦…' : '手动对焦',
              c.canCapture ? c.manualFocus : null,
              active: c.focusing,
            ),
            const Divider(color: AppColors.divider, height: 16),
            _btn(
              Icons.auto_mode,
              '自动扫描（连拍）',
              () => c.toggleAutoScan(),
              active: c.autoScan,
            ),
            _btn(Icons.picture_as_pdf, '导出PDF', () => c.exportPdf()),
            _btn(Icons.refresh, '刷新设备', () => c.refreshDevices()),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _btn(
    IconData icon,
    String tooltip,
    VoidCallback? onTap, {
    bool active = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(
          icon,
          size: 20,
          color: active ? AppColors.accent : AppColors.textDim,
        ),
        onPressed: onTap,
        splashRadius: 18,
      ),
    );
  }
}
