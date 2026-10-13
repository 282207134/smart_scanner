import 'package:flutter/material.dart';

import 'dart:io';

import '../../state/app_controller.dart';
import '../../theme.dart';

/// 底部状态栏（设备 / 视频格式 / 分辨率 / 状态 / 版本）
class StatusBarWidget extends StatelessWidget {
  final AppController controller;
  const StatusBarWidget({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Container(
      color: AppColors.panelDark,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          const Text(
            '设备',
            style: TextStyle(fontSize: 12, color: AppColors.textDim),
          ),
          const SizedBox(width: 6),
          _miniDropdown<int>(
            value: c.devices.isEmpty ? null : c.deviceIndex,
            items: [
              for (final d in c.devices)
                DropdownMenuItem(
                  value: d.index,
                  child: Text(
                    d.name,
                    style: const TextStyle(fontSize: 12, color: AppColors.text),
                  ),
                ),
            ],
            onChanged: c.devices.isEmpty
                ? null
                : (v) {
                    if (v != null) c.selectDevice(v);
                  },
            hint: '未发现设备',
          ),
          const SizedBox(width: 18),
          const Text(
            '视频格式',
            style: TextStyle(fontSize: 12, color: AppColors.textDim),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.panel,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              Platform.isMacOS || c.usingMock ? 'RGB' : 'MJPEG',
              style: const TextStyle(fontSize: 12, color: AppColors.textDim),
            ),
          ),
          const SizedBox(width: 18),
          const Text(
            '分辨率',
            style: TextStyle(fontSize: 12, color: AppColors.textDim),
          ),
          const SizedBox(width: 6),
          _miniDropdown<String>(
            value: c.resolution?.label,
            items: [
              for (final r in c.resolutions)
                DropdownMenuItem(
                  value: r.label,
                  child: Text(
                    r.label,
                    style: const TextStyle(fontSize: 12, color: AppColors.text),
                  ),
                ),
            ],
            onChanged: c.resolutions.isEmpty
                ? null
                : (v) {
                    final r = c.resolutions.firstWhere((r) => r.label == v);
                    c.selectResolution(r);
                  },
            hint: '-',
          ),
          const SizedBox(width: 18),
          Icon(
            c.connected ? Icons.check_circle : Icons.error,
            size: 13,
            color: c.connected ? AppColors.ok : AppColors.err,
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              c.statusMessage,
              style: const TextStyle(fontSize: 12, color: AppColors.textDim),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (c.previewFps > 0)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Text(
                '${c.previewFps.toStringAsFixed(1)} fps',
                style: const TextStyle(fontSize: 11, color: AppColors.textDim),
              ),
            ),
          const Text(
            'V1.2.1',
            style: TextStyle(fontSize: 11, color: AppColors.textDim),
          ),
        ],
      ),
    );
  }

  Widget _miniDropdown<T>({
    required T? value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?>? onChanged,
    required String hint,
  }) {
    return Container(
      height: 26,
      width: 150,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(3),
      ),
      child: DropdownButton<T>(
        value: value,
        isDense: true,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        dropdownColor: AppColors.card,
        hint: Text(
          hint,
          style: const TextStyle(fontSize: 12, color: AppColors.textDim),
        ),
        items: items,
        onChanged: onChanged,
      ),
    );
  }
}
