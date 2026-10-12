import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../theme.dart';
import 'settings_dialog.dart';
import 'widgets/left_toolbar.dart';
import 'widgets/mode_tabs.dart';
import 'widgets/preview_view.dart';
import 'widgets/settings_bar.dart';
import 'widgets/status_bar.dart';
import 'widgets/thumbs_panel.dart';

/// 主页面（整体布局仿厂家软件：顶部标签、参数栏、左侧工具条、中央预览、右侧拍摄）
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
    if (mounted) setState(() {});
    final err = c.lastError;
    if (err != null) {
      c.clearError();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(err),
        backgroundColor: AppColors.err,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _header(),
          ModeTabs(controller: c),
          SettingsBar(controller: c),
          Expanded(
            child: Row(
              children: [
                LeftToolbar(controller: c),
                Expanded(
                  child: PreviewView(controller: c),
                ),
                ThumbsPanel(controller: c),
              ],
            ),
          ),
          StatusBarWidget(controller: c),
        ],
      ),
    );
  }

  Widget _header() {
    return Container(
      color: AppColors.panelDark,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: const BoxDecoration(
              color: AppColors.accent,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.document_scanner,
                color: Colors.black, size: 20),
          ),
          const SizedBox(width: 10),
          const Text('智能高拍仪',
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text)),
          const SizedBox(width: 14),
          _pill('标准版', active: true),
          const SizedBox(width: 8),
          _pill('旗舰版', active: false),
          const Spacer(),
          IconButton(
            tooltip: '输出设置',
            icon: const Icon(Icons.settings, color: AppColors.textDim),
            onPressed: () => showOutputSettingsDialog(context, c),
          ),
        ],
      ),
    );
  }

  Widget _pill(String text, {required bool active}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: active ? AppColors.accent : AppColors.card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(active ? Icons.settings_input_component : Icons.star,
              size: 13, color: active ? Colors.black : AppColors.textDim),
          const SizedBox(width: 5),
          Text(text,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: active ? Colors.black : AppColors.textDim)),
        ],
      ),
    );
  }
}
