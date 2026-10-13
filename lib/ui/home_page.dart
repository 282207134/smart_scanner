/// 主页面布局（严格仿科密参考截图）
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';

import '../state/app_controller.dart';
import '../theme.dart';
import 'settings_dialog.dart';
import 'widgets/left_toolbar.dart';
import 'widgets/mode_tabs.dart';
import 'widgets/preview_view.dart';
import 'widgets/settings_bar.dart';
import 'widgets/status_bar.dart';
import 'widgets/thumbs_panel.dart';
import 'widgets/capture_button.dart';

class HomePage extends StatefulWidget {
  final AppController controller;
  const HomePage({super.key, required this.controller});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      c.connect();
    });
  }

  @override
  void dispose() {
    c.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    final err = c.lastError;
    if (err != null) {
      c.clearError();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(err),
          backgroundColor: AppColors.err,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.f5): c.connect,
          const SingleActivator(LogicalKeyboardKey.keyS, control: true):
              c.exportPdf,
        },
        child: Focus(
          autofocus: true,
          child: Column(
            children: [
              _header(),
              ModeTabs(controller: c),
              Container(
                color: AppColors.panel,
                child: Row(
                  children: [
                    Expanded(child: SettingsBar(controller: c)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: CaptureButton(controller: c),
                    ),
                  ],
                ),
              ),
              if (c.usingMock)
                Container(
                  color: AppColors.accent.withValues(alpha: .1),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 5,
                  ),
                  child: const Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 14,
                        color: AppColors.accent,
                      ),
                      SizedBox(width: 8),
                      Text(
                        '演示模式 · 当前显示测试图案，拍摄内容为演示图片',
                        style: TextStyle(fontSize: 12, color: AppColors.accent),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: Row(
                  children: [
                    LeftToolbar(controller: c),
                    Expanded(child: PreviewView(controller: c)),
                    ThumbsPanel(controller: c),
                  ],
                ),
              ),
              StatusBarWidget(controller: c),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Container(
      color: AppColors.panelDark,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: const BoxDecoration(
              color: AppColors.accent,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const Icon(
              Icons.document_scanner,
              color: Colors.black,
              size: 18,
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            '智能高拍仪',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.text,
            ),
          ),
          const SizedBox(width: 10),
          _versionPill('扫描工作台', true),
          const Spacer(),
          TextButton.icon(
            onPressed: c.busy
                ? null
                : () async {
                    final files = await openFiles(
                      acceptedTypeGroups: [
                        const XTypeGroup(
                          label: '图片',
                          extensions: [
                            'jpg',
                            'jpeg',
                            'png',
                            'bmp',
                            'tif',
                            'tiff',
                          ],
                        ),
                      ],
                    );
                    if (files.isNotEmpty) {
                      await c.importPages(files.map((f) => f.path).toList());
                    }
                  },
            icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
            label: const Text('导入图片'),
          ),
          TextButton.icon(
            onPressed: c.connecting ? null : () => c.connect(),
            icon: const Icon(Icons.refresh, size: 16),
            label: Text(c.connecting ? '连接中' : '刷新设备'),
          ),
          PopupMenuButton<bool>(
            tooltip: '切换设备来源',
            onSelected: c.useDemo,
            itemBuilder: (_) => [
              const PopupMenuItem(value: false, child: Text('真实扫描仪')),
              const PopupMenuItem(value: true, child: Text('演示模式')),
            ],
            icon: Icon(
              c.usingMock ? Icons.science_outlined : Icons.usb,
              size: 18,
              color: AppColors.textDim,
            ),
          ),
          _iconBtn(Icons.settings, '输出设置', () async {
            if (context.mounted) await showOutputSettingsDialog(context, c);
          }),
        ],
      ),
    );
  }

  Widget _versionPill(String text, bool active) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: active ? AppColors.accent : AppColors.card,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: active ? Colors.black : AppColors.textDim,
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(icon, size: 18, color: AppColors.textDim),
        onPressed: onTap,
        splashRadius: 16,
      ),
    );
  }
}
