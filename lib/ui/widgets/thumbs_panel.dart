import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../state/app_controller.dart';
import '../../theme.dart';

/// 右侧面板：拍摄按钮 + 已拍页面缩略图列表
class ThumbsPanel extends StatelessWidget {
  final AppController controller;
  const ThumbsPanel({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Container(
      width: 190,
      color: AppColors.panelDark,
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 拍摄按钮
          Material(
            color: c.capturing ? AppColors.accentSoft : AppColors.accent,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: c.capturing
                  ? null
                  : () {
                      if (c.mode.name == 'book') {
                        c.captureBook();
                      } else {
                        c.capture();
                      }
                    },
              child: Container(
                height: 56,
                alignment: Alignment.center,
                child: c.capturing
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.4, color: Colors.black))
                    : const Text(
                        '拍摄',
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: Colors.black),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('已扫描 ${c.pages.length} 页',
                  style:
                      const TextStyle(fontSize: 12, color: AppColors.textDim)),
              if (c.pages.isNotEmpty)
                InkWell(
                  onTap: () => c.exportPdf(),
                  child: const Row(
                    children: [
                      Icon(Icons.picture_as_pdf,
                          size: 13, color: AppColors.accent),
                      SizedBox(width: 3),
                      Text('导出PDF',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.accent)),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: c.pages.isEmpty
                ? Center(
                    child: Text('拍摄的页面\n会出现在这里',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12,
                            height: 1.7,
                            color: AppColors.textDim.withValues(alpha: 0.7))),
                  )
                : ListView.separated(
                    itemCount: c.pages.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final page = c.pages[c.pages.length - 1 - i];
                      final idx = c.pages.length - 1 - i;
                      return _thumb(c, page, idx);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _thumb(AppController c, dynamic page, int index) {
    final Uint8List bytes = page.thumbnailJpg as Uint8List;
    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.divider),
          ),
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: bytes.isEmpty
                    ? Container(
                        height: 96,
                        width: double.infinity,
                        color: AppColors.panelDark,
                        child: const Icon(Icons.image_outlined,
                            color: AppColors.textDim),
                      )
                    : Image.memory(
                        bytes,
                        height: 96,
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
              ),
              const SizedBox(height: 4),
              Text(
                _timeLabel(page.time as DateTime),
                style:
                    const TextStyle(fontSize: 11, color: AppColors.textDim),
              ),
              if ((page.ocrText as String).isNotEmpty)
                const Text('已OCR',
                    style: TextStyle(fontSize: 10, color: AppColors.ok)),
            ],
          ),
        ),
        Positioned(
          top: 2,
          right: 2,
          child: Row(
            children: [
              _miniBtn(Icons.folder_open, () {
                final path = page.filePath as String;
                if (File(path).existsSync()) {
                  Process.run('explorer', ['/select,', path]);
                }
              }),
              _miniBtn(Icons.delete_outline, () => c.removePage(index)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _miniBtn(IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(icon, size: 13, color: AppColors.text),
      ),
    );
  }

  String _timeLabel(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
}
