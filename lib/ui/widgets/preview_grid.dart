import 'package:flutter/material.dart';

import '../../theme.dart';

/// Fixed workspace grid; camera pixels are painted above it only in their area.
class PreviewGridPainter extends CustomPainter {
  const PreviewGridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = AppColors.previewBg);
    final grid = Paint()
      ..color = AppColors.divider.withValues(alpha: .65)
      ..strokeWidth = 1;
    const spacing = 24.0;
    for (double x = 0; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (double y = 0; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
  }

  @override
  bool shouldRepaint(PreviewGridPainter oldDelegate) => false;
}
