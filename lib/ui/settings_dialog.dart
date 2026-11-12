import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../state/app_controller.dart';
import '../theme.dart';
import '../localization.dart';
import 'widgets/settings_bar.dart';

/// 输出设置对话框
Future<void> showOutputSettingsDialog(
  BuildContext context,
  AppController c,
) async {
  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        scrollable: true,
        title: Text(
          ctx.tr('输出设置'),
          style: TextStyle(fontSize: 16, color: AppColors.text),
        ),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _row(ctx.tr('界面语言'), [
                Expanded(
                  child: DropdownButton<AppLanguage>(
                    key: const Key('interface-language'),
                    value: c.language,
                    isExpanded: true,
                    items: [
                      for (final language in AppLanguage.values)
                        DropdownMenuItem(
                          value: language,
                          child: Text(language.label),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      c.setInterfaceLanguage(value);
                      setState(() {});
                    },
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              if (Platform.isWindows) ...[
                _row(ctx.tr('设备接入'), [
                  Expanded(
                    child: DropdownButton<bool>(
                      value: c.windowsVendorService,
                      isExpanded: true,
                      items: [
                        DropdownMenuItem(
                          value: false,
                          child: Text(ctx.tr('系统摄像头（内置 / USB）')),
                        ),
                        DropdownMenuItem(
                          value: true,
                          child: Text(ctx.tr('厂商扫描仪服务')),
                        ),
                      ],
                      onChanged: !c.canSwitchBackend
                          ? null
                          : (value) async {
                              if (value == null) return;
                              final switching = c.useWindowsVendorService(
                                value,
                              );
                              setState(() {});
                              await switching;
                              if (ctx.mounted) setState(() {});
                            },
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
              ],
              _row(ctx.tr('保存目录'), [
                Expanded(
                  child: Text(
                    c.outputDir,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textDim,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.black,
                  ),
                  icon: const Icon(Icons.folder_open, size: 15),
                  label: Text(ctx.tr('选择目录')),
                  onPressed: () async {
                    final dir = await getDirectoryPath();
                    if (dir != null) await c.setOutputDir(dir);
                    if (ctx.mounted) setState(() {});
                  },
                ),
              ]),
              const SizedBox(height: 12),
              _row(ctx.tr('命名方式'), [
                LabeledSelect<NameStyle>(
                  label: '',
                  value: c.nameStyle,
                  items: c.availableNameStyles,
                  onChanged: (v) {
                    c.setNameStyle(v!);
                    setState(() {});
                  },
                ),
              ]),
              const SizedBox(height: 12),
              _row(ctx.tr('默认格式'), [
                LabeledSelect<OutputFormat>(
                  label: '',
                  value: c.outputFormat,
                  items: c.availableFormats,
                  onChanged: (v) {
                    c.setOutputFormat(v!);
                    setState(() {});
                  },
                ),
                const SizedBox(width: 16),
                Text(
                  ctx.tr('JPG画质'),
                  style: TextStyle(fontSize: 13, color: AppColors.textDim),
                ),
                Expanded(
                  child: Slider(
                    value: c.jpgQuality.toDouble(),
                    min: 30,
                    max: 100,
                    divisions: 14,
                    activeColor: AppColors.accent,
                    inactiveColor: AppColors.divider,
                    label: '${c.jpgQuality}',
                    onChanged: (v) {
                      c.setJpgQuality(v.round());
                      setState(() {});
                    },
                  ),
                ),
              ]),
              const SizedBox(height: 6),
              Text(
                ctx.tr('拍摄与导出保存在所选目录。勾选、调整页面顺序后可导出 PDF；原图会保留。'),
                style: TextStyle(fontSize: 11, color: AppColors.textDim),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              ctx.tr('关闭'),
              style: TextStyle(color: AppColors.accent),
            ),
          ),
        ],
      ),
    ),
  );
}

Widget _row(String label, List<Widget> children) {
  return Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      SizedBox(
        width: 100,
        child: Text(
          label,
          style: const TextStyle(fontSize: 13, color: AppColors.textDim),
        ),
      ),
      ...children,
    ],
  );
}
