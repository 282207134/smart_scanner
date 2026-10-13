import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../state/app_controller.dart';
import '../../theme.dart';

class ThumbsPanel extends StatelessWidget {
  final AppController controller;
  const ThumbsPanel({super.key, required this.controller});
  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Container(
      width: 206,
      color: AppColors.panelDark,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '已扫描 ${c.pages.length} 页',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: c.pages.isNotEmpty && !c.busy ? c.exportPdf : null,
            icon: const Icon(Icons.picture_as_pdf_outlined, size: 16),
            label: Text(
              c.selectedPaths.isEmpty
                  ? '导出PDF'
                  : '导出所选 ${c.selectedPaths.length} 页',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(height: 5),
          Expanded(
            child: c.pages.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.photo_library_outlined,
                          size: 36,
                          color: AppColors.textDim,
                        ),
                        SizedBox(height: 14),
                        Text(
                          '拍摄或导入图片',
                          style: TextStyle(fontSize: 13, color: AppColors.text),
                        ),
                        SizedBox(height: 6),
                        Text(
                          '在这里选择、排序\n并合成多页 PDF',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.6,
                            color: AppColors.textDim,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: c.pages.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, i) => _thumb(context, c.pages[i], i),
                  ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => c.openFile(c.outputDir),
            icon: const Icon(Icons.folder_open, size: 16),
            label: const Text('打开保存目录', style: TextStyle(fontSize: 12)),
          ),
          if (c.lastExportPath.isNotEmpty)
            TextButton(
              onPressed: () => c.openFile(c.lastExportPath),
              child: const Text('查看刚导出的文件', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Widget _thumb(BuildContext context, CapturedPage page, int index) {
    final c = controller, active = controller.selectedPage == index;
    return Material(
      color: active ? AppColors.card : AppColors.panel,
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        onTap: () => c.selectPage(index),
        onDoubleTap: () => _view(context, page),
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            border: Border.all(
              color: active ? AppColors.accent : AppColors.divider,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            children: [
              Stack(
                children: [
                  Container(
                    height: 110,
                    width: double.infinity,
                    color: AppColors.previewBg,
                    child: page.thumbnailJpg.isEmpty
                        ? const Icon(
                            Icons.insert_drive_file_outlined,
                            color: AppColors.textDim,
                          )
                        : Image.memory(
                            page.thumbnailJpg,
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) =>
                                const Icon(Icons.broken_image_outlined),
                          ),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: Checkbox(
                        value: c.selectedPaths.contains(page.filePath),
                        onChanged: c.busy
                            ? null
                            : (_) => c.toggleSelected(page.filePath),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 2,
                    top: 2,
                    child: Container(
                      color: AppColors.panelDark,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      child: Text(
                        '${index + 1}',
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Tooltip(
                message: page.filePath,
                child: Text(
                  AppController.basename(page.filePath),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (page.ocrText.isNotEmpty)
                    const Icon(
                      Icons.text_snippet,
                      size: 14,
                      color: AppColors.ok,
                    ),
                  _button(
                    Icons.arrow_upward,
                    '向前移动',
                    () => c.movePage(index, -1),
                  ),
                  _button(
                    Icons.arrow_downward,
                    '向后移动',
                    () => c.movePage(index, 1),
                  ),
                  _button(
                    Icons.open_in_new,
                    '查看图片',
                    () => _view(context, page),
                  ),
                  _button(
                    Icons.delete_outline,
                    '移出列表（保留文件）',
                    () => c.removePage(index),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _button(IconData icon, String label, VoidCallback action) => SizedBox(
    width: 27,
    height: 27,
    child: IconButton(
      padding: EdgeInsets.zero,
      tooltip: label,
      icon: Icon(icon, size: 15, color: AppColors.textDim),
      onPressed: controller.busy ? null : action,
    ),
  );
  Future<void> _view(BuildContext context, CapturedPage page) =>
      showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          child: SizedBox(
            width: 900,
            height: 680,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 18, right: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          AppController.basename(page.filePath),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: InteractiveViewer(
                    minScale: .2,
                    maxScale: 6,
                    child: Image.file(
                      File(page.sourcePath),
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) =>
                          const Center(child: Text('原始图片不存在')),
                    ),
                  ),
                ),
                if (page.ocrText.isNotEmpty)
                  SizedBox(
                    height: 140,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(page.ocrText),
                    ),
                  ),
                TextButton.icon(
                  onPressed: () =>
                      controller.openFile(page.filePath, reveal: true),
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: const Text('在文件夹中显示'),
                ),
              ],
            ),
          ),
        ),
      );
}
