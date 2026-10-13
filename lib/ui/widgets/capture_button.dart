import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../state/app_controller.dart';
import '../../theme.dart';

class CaptureButton extends StatelessWidget {
  final AppController controller;
  const CaptureButton({super.key, required this.controller});
  @override
  Widget build(BuildContext context) {
    final c = controller, video = controller.mode == ScanMode.video;
    final label = video
        ? (c.recording ? '停止录制' : '开始录制')
        : c.mode == ScanMode.ocr
        ? '识别文字'
        : c.autoScan
        ? '停止自动扫描'
        : c.autoMode
        ? '开始自动扫描'
        : '拍摄';
    final enabled =
        c.autoScan ||
        (c.recording && !c.busy) ||
        (c.mode == ScanMode.ocr
            ? c.currentPage != null && !c.busy
            : c.canCapture);
    return SizedBox(
      width: 170,
      height: 58,
      child: FilledButton(
        key: const Key('primary-capture'),
        style: FilledButton.styleFrom(
          backgroundColor: c.recording ? AppColors.err : AppColors.accent,
          foregroundColor: const Color(0xFF172139),
          disabledBackgroundColor: AppColors.card,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        ),
        onPressed: enabled
            ? () {
                if (video) {
                  c.recording ? c.stopRecord() : c.startRecord();
                } else if (c.mode == ScanMode.ocr) {
                  c.ocrLastCapture();
                } else if (c.autoScan || c.autoMode) {
                  c.toggleAutoScan();
                } else {
                  c.capture();
                }
              }
            : null,
        child: c.busy && !c.autoScan
            ? const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 10),
                  Text('处理中…'),
                ],
              )
            : Text(
                label,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }
}
