import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../state/app_controller.dart';
import '../../theme.dart';

/// 预览区：帧渲染 + 叠加层（裁剪框/书脊线）+ 交互（滚轮缩放、拖拽平移/框选）
class PreviewView extends StatefulWidget {
  final AppController controller;
  const PreviewView({super.key, required this.controller});

  @override
  State<PreviewView> createState() => _PreviewViewState();
}

class _PreviewViewState extends State<PreviewView> {
  AppController get c => widget.controller;

  // 手动裁剪矩形（画布坐标）
  Offset? _dragStart;
  Rect? _cutRect;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.previewBg,
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          // 画布尺寸请求（带迟滞）
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (w.isFinite && h.isFinite) {
              c.setCanvasSize(w.round(), h.round());
            }
          });

          final img = c.previewImage;
          final fit = _fitRect(img?.width ?? 0, img?.height ?? 0, w, h);

          return Listener(
            onPointerSignal: (signal) {
              if (signal is PointerScrollEvent) {
                if (signal.scrollDelta.dy < 0) {
                  c.zoomIn();
                } else if (signal.scrollDelta.dy > 0) {
                  c.zoomOut();
                }
              }
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: () {
                setState(() => _cutRect = null);
                c.fitToWindow();
              },
              onScaleStart: (d) {
                _dragStart = d.localFocalPoint;
              },
              onScaleUpdate: (d) {
                if (c.cutMode == CutMode.manual && _dragStart != null) {
                  final a = _toCanvas(_dragStart!);
                  final b = _toCanvas(d.localFocalPoint);
                  setState(() {
                    _cutRect = Rect.fromPoints(a, b);
                  });
                  final rect = _normalized(_cutRect!);
                  c.backend.setCutRect(rect.left.round(), rect.top.round(),
                      rect.width.round(), rect.height.round());
                } else if (d.pointerCount == 1 &&
                    _dragStart != null &&
                    d.scale == 1.0) {
                  final delta = d.localFocalPoint - _dragStart!;
                  if (delta.distance > 6) {
                    c.panDrag(delta.dx.round(), delta.dy.round());
                    _dragStart = d.localFocalPoint;
                  }
                }
              },
              onScaleEnd: (_) => _dragStart = null,
              child: CustomPaint(
                painter: _PreviewPainter(
                  image: img,
                  fitRect: fit,
                  mode: c.mode,
                  cutMode: c.cutMode,
                  cutRect: _cutRect,
                  connected: c.connected,
                  previewOpen: c.previewOpen,
                  statusMessage: c.statusMessage,
                ),
                size: Size(w, h),
              ),
            ),
          );
        },
      ),
    );
  }

  Rect _fitRect(int iw, int ih, double w, double h) {
    if (iw <= 0 || ih <= 0) {
      return Rect.fromLTWH(0, 0, w, h);
    }
    final s = math.min(w / iw, h / ih);
    final dw = iw * s, dh = ih * s;
    return Rect.fromLTWH((w - dw) / 2, (h - dh) / 2, dw, dh);
  }

  /// 屏幕坐标 → 画布坐标
  Offset _toCanvas(Offset screen) {
    final box = context.findRenderObject() as RenderBox?;
    final size = box?.size ?? Size.zero;
    final fit = _fitRect(c.previewImage?.width ?? 0, c.previewImage?.height ?? 0,
        size.width, size.height);
    final fx = (screen.dx - fit.left) / fit.width;
    final fy = (screen.dy - fit.top) / fit.height;
    return Offset(fx * c.canvasW, fy * c.canvasH);
  }

  Rect _normalized(Rect r) => Rect.fromPoints(
      Offset(math.min(r.left, r.right), math.min(r.top, r.bottom)),
      Offset(math.max(r.left, r.right), math.max(r.top, r.bottom)));
}

class _PreviewPainter extends CustomPainter {
  final ui.Image? image;
  final Rect fitRect;
  final ScanMode mode;
  final CutMode cutMode;
  final Rect? cutRect;
  final bool connected;
  final bool previewOpen;
  final String statusMessage;

  _PreviewPainter({
    required this.image,
    required this.fitRect,
    required this.mode,
    required this.cutMode,
    required this.cutRect,
    required this.connected,
    required this.previewOpen,
    required this.statusMessage,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (image != null) {
      canvas.drawImageRect(
        image!,
        Rect.fromLTWH(0, 0, image!.width.toDouble(), image!.height.toDouble()),
        fitRect,
        Paint()..filterQuality = FilterQuality.medium,
      );
    } else {
      _placeholder(canvas, size);
      return;
    }

    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = AppColors.guide;

    switch (mode) {
      case ScanMode.document:
      case ScanMode.barcode:
      case ScanMode.ocr:
      case ScanMode.video:
      case ScanMode.contract:
        canvas.drawRect(fitRect, borderPaint);
      case ScanMode.book:
        canvas.drawRect(fitRect, borderPaint);
        // 书脊中缝虚线
        final mid = fitRect.center.dx;
        final dash = Paint()
          ..strokeWidth = 2
          ..color = AppColors.guide;
        _dashedVertical(canvas, mid, fitRect.top, fitRect.bottom, dash);
      case ScanMode.idCard:
        canvas.drawRect(fitRect, borderPaint);
        // 上下两块证件区域参考框
        final h = fitRect.height;
        final r1 = Rect.fromLTWH(fitRect.left + fitRect.width * 0.08,
            fitRect.top + h * 0.12, fitRect.width * 0.84, h * 0.3);
        final r2 = Rect.fromLTWH(fitRect.left + fitRect.width * 0.08,
            fitRect.top + h * 0.56, fitRect.width * 0.84, h * 0.3);
        final guide = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = AppColors.guide.withValues(alpha: 0.7);
        canvas.drawRRect(
            RRect.fromRectAndRadius(r1, const Radius.circular(8)), guide);
        canvas.drawRRect(
            RRect.fromRectAndRadius(r2, const Radius.circular(8)), guide);
    }

    // 手动裁剪矩形
    if (cutMode == CutMode.manual && cutRect != null && image != null) {
      final iw = image!.width.toDouble(), ih = image!.height.toDouble();
      final r = cutRect!;
      final sx = fitRect.width / iw, sy = fitRect.height / ih;
      final screen = Rect.fromLTWH(
        fitRect.left + math.min(r.left, r.right) * sx,
        fitRect.top + math.min(r.top, r.bottom) * sy,
        r.width * sx,
        r.height * sy,
      );
      canvas.drawRect(
          screen,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = AppColors.accent);
    }
  }

  void _dashedVertical(
      Canvas canvas, double x, double top, double bottom, Paint paint) {
    const dashLen = 8.0, gap = 6.0;
    double y = top;
    while (y < bottom) {
      canvas.drawLine(Offset(x, y), Offset(x, math.min(y + dashLen, bottom)),
          paint);
      y += dashLen + gap;
    }
  }

  void _placeholder(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final tp = TextPainter(
      text: TextSpan(
        text: connected
            ? (previewOpen ? '等待画面...' : '正在打开摄像头...')
            : '未连接扫描仪\n\n$statusMessage',
        style: const TextStyle(color: AppColors.textDim, fontSize: 15, height: 1.6),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: size.width - 80);
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));

    // 边框占位
    canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height).deflate(20),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = AppColors.divider);
  }

  @override
  bool shouldRepaint(_PreviewPainter old) =>
      old.image != image ||
      old.fitRect != fitRect ||
      old.mode != mode ||
      old.cutMode != cutMode ||
      old.cutRect != cutRect ||
      old.previewOpen != previewOpen ||
      old.statusMessage != statusMessage;
}
