import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/document_geometry.dart';
import '../../core/auto_scan_detector.dart';
import '../../state/app_controller.dart';
import '../../theme.dart';
import '../../localization.dart';
import 'preview_grid.dart';

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
  int? _dragCorner;
  bool _dragSeam = false;
  Rect _currentFit = Rect.zero;
  Rect _contentFit = Rect.zero;
  Size _previewSize = Size.zero;

  @override
  Widget build(BuildContext context) {
    if (c.mode == ScanMode.ocr) {
      final page = c.currentPage;
      return CustomPaint(
        painter: const PreviewGridPainter(),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: page == null
                    ? Center(
                        child: Text(
                          context.tr('导入图片，或选择右侧已扫描页面'),
                          style: TextStyle(color: AppColors.textDim),
                        ),
                      )
                    : InteractiveViewer(
                        maxScale: 6,
                        child: Image.file(
                          File(page.sourcePath),
                          fit: BoxFit.contain,
                        ),
                      ),
              ),
              const SizedBox(height: 12),
              Text(
                context.tr('识别结果'),
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 150,
                child: SingleChildScrollView(
                  child: SelectableText(
                    c.ocrStatus.isNotEmpty
                        ? c.ocrStatus
                        : c.lastOcrText.isEmpty
                        ? context.tr('选择识别语言后点击“识别文字”')
                        : c.lastOcrText,
                    style: const TextStyle(fontSize: 13, height: 1.6),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Container(
      color: AppColors.previewBg,
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          final pixelRatio = c.supportsHighDensityPreview
              ? MediaQuery.devicePixelRatioOf(context)
              : 1.0;
          _previewSize = Size(w, h);
          // 画布尺寸请求（带迟滞）
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (w.isFinite && h.isFinite) {
              c.setCanvasSize(
                (w * pixelRatio).round(),
                (h * pixelRatio).round(),
              );
            }
          });

          final img = c.previewImage;
          final fit = _fitRect(img?.width ?? 0, img?.height ?? 0, w, h);
          _currentFit = fit;
          _contentFit = Rect.fromLTWH(
            fit.left + c.previewImageX * fit.width,
            fit.top + c.previewImageY * fit.height,
            c.previewImageWidth * fit.width,
            c.previewImageHeight * fit.height,
          );

          return Listener(
            onPointerDown: (event) => _beginDrag(event.localPosition),
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
                c.resetManualRegion();
                c.fitToWindow();
              },
              onScaleUpdate: (d) {
                if (c.busy || c.recording || c.autoScan) return;
                if (c.cutMode == CutMode.manual && _dragStart != null) {
                  if (_dragCorner != null) {
                    c.setManualCorner(
                      _dragCorner!,
                      ScanPoint(
                        (d.localFocalPoint.dx - _contentFit.left) /
                            _contentFit.width,
                        (d.localFocalPoint.dy - _contentFit.top) /
                            _contentFit.height,
                      ),
                    );
                    return;
                  }
                  final a = _toCanvas(_dragStart!);
                  final b = _toCanvas(d.localFocalPoint);
                  final rect = _normalized(Rect.fromPoints(a, b));
                  if (rect.width > 2 && rect.height > 2) {
                    c.setCutRect(
                      rect.left.round(),
                      rect.top.round(),
                      rect.width.round(),
                      rect.height.round(),
                    );
                  }
                } else if (_dragSeam) {
                  c.setBookSeam(
                    (d.localFocalPoint.dx - _contentFit.left) /
                        _contentFit.width,
                  );
                } else if (d.pointerCount == 1 &&
                    _dragStart != null &&
                    d.scale == 1.0) {
                  final delta = d.localFocalPoint - _dragStart!;
                  if (delta.distance > 6) {
                    c.panDrag(
                      (delta.dx * c.canvasW / _currentFit.width).round(),
                      (delta.dy * c.canvasH / _currentFit.height).round(),
                    );
                    _dragStart = d.localFocalPoint;
                  }
                }
              },
              onScaleEnd: (_) {
                _dragStart = null;
                _dragCorner = null;
                _dragSeam = false;
              },
              child: Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  CustomPaint(
                    painter: _PreviewPainter(
                      language: AppLanguage.of(context),
                      image: img,
                      fitRect: fit,
                      mode: c.mode,
                      cutMode: c.cutMode,
                      contentRect: _contentFit,
                      regions: c.detectedDocuments,
                      manual: c.manualRegion,
                      seam: c.bookSeam,
                      bookLayout: c.bookLayout,
                      bookPage: c.flattenMode == FlattenMode.singlePage
                          ? c.bookPage
                          : null,
                      bookReadingOrder:
                          c.flattenMode == FlattenMode.split ||
                              c.flattenMode == FlattenMode.flatten
                          ? c.bookReadingOrder
                          : null,
                      connected: c.connected,
                      previewOpen: c.previewOpen,
                      statusMessage: c.statusMessage,
                    ),
                    size: Size(w, h),
                  ),
                  if (c.mode == ScanMode.contract && c.signatureBytes != null)
                    _mark(c.signatureBytes!, c.markCorner, _contentFit),
                  if (c.mode == ScanMode.contract && c.stampBytes != null)
                    _mark(
                      c.stampBytes!,
                      c.markCorner == 3 ? 2 : 3,
                      _contentFit,
                    ),
                  if (c.previewOpen && !c.busy && c.cutMode == CutMode.manual)
                    _hint(context.tr('拖动四个角点贴合文件边缘；拖出新区域可重新框选')),
                  if (c.previewOpen &&
                      !c.busy &&
                      c.mode == ScanMode.idCard &&
                      c.cutMode != CutMode.manual)
                    _hint(
                      context.tr(
                        c.awaitingIdBack
                            ? '第 2 步 · 翻到背面，绿框贴合卡片后拍摄，自动合并'
                            : c.mergeIdSides
                            ? '第 1 步 · 放置正面，四周留边，绿框贴合卡片后拍摄'
                            : '放入一张卡片，绿框贴合边缘后拍摄；可选择双面模式',
                      ),
                    ),
                  if (c.mode == ScanMode.idCard && c.idFrontPreview != null)
                    Positioned(
                      right: 12,
                      bottom: 12,
                      child: Container(
                        width: 156,
                        padding: const EdgeInsets.all(8),
                        color: AppColors.panel,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Image.memory(
                              c.idFrontPreview!,
                              cacheWidth: 320,
                              height: 80,
                              fit: BoxFit.contain,
                              excludeFromSemantics: true,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              context.tr('正面已暂存 · 等待背面'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (c.previewOpen && !c.busy && c.mode == ScanMode.book)
                    _hint(
                      c.bookSeamManual
                          ? context.tr('手动中线 · 拖动虚线对齐书脊，或点击“重新识别中线”')
                          : context.tr('自动识别书脊与书页边界 · 可拖动虚线手动调整'),
                    ),
                  if (c.previewOpen &&
                      !c.busy &&
                      c.mode != ScanMode.idCard &&
                      (c.cutMode == CutMode.auto ||
                          c.cutMode == CutMode.multiImg))
                    _hint(
                      c.detectedDocuments.isEmpty
                          ? context.tr('正在寻找文件边界 · 请留出四周边缘')
                          : c.cutMode == CutMode.multiImg
                          ? context.tr('识别到 {0} 个文档 · 将分别保存', [
                              c.detectedDocuments.length,
                            ])
                          : context.tr('已检测到文件边界'),
                    ),
                  if (c.autoScan)
                    Center(
                      child: IgnorePointer(
                        child: Container(
                          key: const Key('auto-countdown'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 30,
                            vertical: 20,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: .55),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (c.autoProgress.phase ==
                                  AutoScanPhase.countdown)
                                Text(
                                  '${c.autoProgress.seconds}',
                                  style: const TextStyle(
                                    fontSize: 64,
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              Text(
                                c.capturing
                                    ? context.tr('正在扫描…')
                                    : switch (c.autoProgress.phase) {
                                        AutoScanPhase.countdown => context.tr(
                                          '画面已稳定，即将拍摄',
                                        ),
                                        AutoScanPhase.captured => context.tr(
                                          '本页已扫描，请更换文档',
                                        ),
                                        AutoScanPhase.moving => context.tr(
                                          '等待画面停止变化…',
                                        ),
                                        _ => context.tr('等待文件和稳定画面…'),
                                      },
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _beginDrag(Offset point) {
    _dragStart = null;
    _dragCorner = null;
    _dragSeam = false;
    if (c.busy || c.recording || c.autoScan || _contentFit.isEmpty) return;
    _dragStart = point;
    if (c.cutMode == CutMode.manual && c.manualRegion != null) {
      for (var i = 0; i < 4; i++) {
        final p = c.manualRegion!.corners[i];
        final handle = Offset(
          _contentFit.left + p.x * _contentFit.width,
          _contentFit.top + p.y * _contentFit.height,
        );
        if ((point - handle).distance < 28) {
          _dragCorner = i;
          break;
        }
      }
    }
    if (_dragCorner == null && !_contentFit.contains(point)) {
      _dragStart = null;
      return;
    }
    final seamX =
        c.bookLayout?.spineX(
          (point.dy - _contentFit.top) / _contentFit.height,
        ) ??
        c.bookSeam;
    _dragSeam =
        c.mode == ScanMode.book &&
        (point.dx - (_contentFit.left + seamX * _contentFit.width)).abs() < 28;
  }

  Widget _hint(String text) => Positioned(
    left: 10,
    right: 10,
    top: 10,
    child: IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        color: Colors.black.withValues(alpha: .6),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      ),
    ),
  );

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
    final fit = _currentFit;
    if (fit.isEmpty) return Offset.zero;
    final fx = (screen.dx - fit.left) / fit.width;
    final fy = (screen.dy - fit.top) / fit.height;
    return Offset(
      (fx * c.canvasW).clamp(0, c.canvasW.toDouble()),
      (fy * c.canvasH).clamp(0, c.canvasH.toDouble()),
    );
  }

  Widget _mark(Uint8List bytes, int corner, Rect fit) => Positioned(
    left: corner == 0 || corner == 2 ? fit.left + fit.width * .03 : null,
    right: corner == 1 || corner == 3
        ? _previewSize.width - fit.right + fit.width * .03
        : null,
    top: corner < 2 ? fit.top + fit.height * .03 : null,
    bottom: corner >= 2
        ? _previewSize.height - fit.bottom + fit.height * .03
        : null,
    width: fit.width * c.markSize,
    child: IgnorePointer(child: Image.memory(bytes, fit: BoxFit.contain)),
  );

  Rect _normalized(Rect r) => Rect.fromPoints(
    Offset(math.min(r.left, r.right), math.min(r.top, r.bottom)),
    Offset(math.max(r.left, r.right), math.max(r.top, r.bottom)),
  );
}

class _PreviewPainter extends CustomPainter {
  final ui.Image? image;
  final Rect fitRect;
  final AppLanguage language;
  final ScanMode mode;
  final CutMode cutMode;
  final Rect contentRect;
  final List<DocumentRegion> regions;
  final DocumentRegion? manual;
  final double seam;
  final BookLayout? bookLayout;
  final BookPage? bookPage;
  final BookReadingOrder? bookReadingOrder;
  final bool connected;
  final bool previewOpen;
  final String statusMessage;

  _PreviewPainter({
    required this.language,
    required this.image,
    required this.fitRect,
    required this.mode,
    required this.cutMode,
    required this.contentRect,
    required this.regions,
    required this.manual,
    required this.seam,
    this.bookLayout,
    this.bookPage,
    this.bookReadingOrder,
    required this.connected,
    required this.previewOpen,
    required this.statusMessage,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const PreviewGridPainter().paint(canvas, size);
    if (image != null) {
      // Frames contain opaque black letterboxing. Leave that area on the grid.
      final source = Rect.fromLTWH(
        (contentRect.left - fitRect.left) / fitRect.width * image!.width,
        (contentRect.top - fitRect.top) / fitRect.height * image!.height,
        contentRect.width / fitRect.width * image!.width,
        contentRect.height / fitRect.height * image!.height,
      );
      canvas.drawImageRect(
        image!,
        source,
        contentRect,
        Paint()..filterQuality = FilterQuality.medium,
      );
      canvas.drawRect(
        contentRect.deflate(.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = AppColors.textDim.withValues(alpha: .6),
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
        if (cutMode == CutMode.auto || cutMode == CutMode.multiImg) {
          final shown = cutMode == CutMode.multiImg
              ? regions
              : regions.isEmpty
              ? <DocumentRegion>[]
              : [regions.reduce((a, b) => a.area > b.area ? a : b)];
          for (var i = 0; i < shown.length; i++) {
            _region(
              canvas,
              shown[i],
              borderPaint,
              label: cutMode == CutMode.multiImg ? '${i + 1}' : null,
            );
          }
        }
      case ScanMode.book:
        for (var i = 0; i < regions.length; i++) {
          if (bookPage != null && regions.length == 2 && bookPage!.index != i) {
            continue;
          }
          final side = regions.length == 2 ? BookPage.values[i] : null;
          final position = side == null
              ? null
              : bookReadingOrder?.pages.indexOf(side);
          _region(
            canvas,
            regions[i],
            borderPaint,
            label: position == null
                ? (side == null ? null : language.translate(side.label))
                : '${position + 1} · ${language.translate(side!.label)}',
          );
        }
        Offset point(ScanPoint p) => Offset(
          contentRect.left + contentRect.width * p.x,
          contentRect.top + contentRect.height * p.y,
        );
        final top = point(bookLayout?.spineTop ?? ScanPoint(seam, 0));
        final bottom = point(bookLayout?.spineBottom ?? ScanPoint(seam, 1));
        final dash = Paint()
          ..strokeWidth = 2
          ..color = AppColors.guide;
        _dashedLine(canvas, top, bottom, dash);
        canvas.drawCircle(
          (top + bottom) / 2,
          9,
          Paint()..color = AppColors.accent,
        );
      case ScanMode.idCard:
        if (regions.isNotEmpty && cutMode != CutMode.manual) {
          _region(
            canvas,
            regions.reduce((a, b) => a.area > b.area ? a : b),
            borderPaint,
          );
        }
        if (regions.isEmpty && cutMode != CutMode.manual) {
          final width = math.min(
            contentRect.width * .72,
            contentRect.height * .7 * 1.586,
          );
          final card = Rect.fromCenter(
            center: contentRect.center,
            width: width,
            height: width / 1.586,
          );
          canvas.drawRRect(
            RRect.fromRectAndRadius(card, const Radius.circular(8)),
            borderPaint..color = AppColors.textDim,
          );
        }
    }

    // 手动裁剪矩形
    if (cutMode == CutMode.manual && manual != null && image != null) {
      final path = _path(manual!);
      canvas.drawPath(
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(contentRect)
          ..addPath(path, Offset.zero),
        Paint()..color = Colors.black.withValues(alpha: .38),
      );
      _region(
        canvas,
        manual!,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = AppColors.accent,
      );
      for (final p in manual!.corners) {
        final point = Offset(
          contentRect.left + p.x * contentRect.width,
          contentRect.top + p.y * contentRect.height,
        );
        canvas.drawCircle(point, 8, Paint()..color = AppColors.accent);
        canvas.drawCircle(point, 4, Paint()..color = Colors.white);
      }
    }
  }

  Path _path(DocumentRegion region) {
    final path = Path();
    for (var i = 0; i < 4; i++) {
      final p = region.corners[i],
          x = contentRect.left + p.x * contentRect.width,
          y = contentRect.top + p.y * contentRect.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    return path..close();
  }

  void _region(
    Canvas canvas,
    DocumentRegion region,
    Paint paint, {
    String? label,
  }) {
    canvas.drawPath(_path(region), paint);
    if (label != null) {
      final p = region.corners.first;
      final offset = Offset(
        contentRect.left + p.x * contentRect.width,
        contentRect.top + p.y * contentRect.height,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(
            color: Colors.black,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      canvas.drawRect(
        Rect.fromLTWH(offset.dx, offset.dy, tp.width + 14, tp.height + 8),
        Paint()..color = AppColors.guide,
      );
      tp.paint(canvas, offset + const Offset(7, 4));
    }
  }

  void _dashedLine(Canvas canvas, Offset top, Offset bottom, Paint paint) {
    const dashLen = 8.0, gap = 6.0;
    final delta = bottom - top, length = delta.distance;
    if (length == 0) return;
    final direction = delta / length;
    for (double distance = 0; distance < length; distance += dashLen + gap) {
      canvas.drawLine(
        top + direction * distance,
        top + direction * math.min(distance + dashLen, length),
        paint,
      );
    }
  }

  void _placeholder(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final tp = TextPainter(
      text: TextSpan(
        text: connected
            ? language.translate(previewOpen ? '等待画面...' : '正在打开摄像头...')
            : '${language.translate('未连接扫描仪')}\n\n$statusMessage',
        style: const TextStyle(
          color: AppColors.textDim,
          fontSize: 15,
          height: 1.6,
        ),
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
        ..color = AppColors.divider,
    );
  }

  @override
  bool shouldRepaint(_PreviewPainter old) =>
      old.image != image ||
      old.fitRect != fitRect ||
      old.mode != mode ||
      old.language != language ||
      old.cutMode != cutMode ||
      old.contentRect != contentRect ||
      old.regions != regions ||
      old.manual != manual ||
      old.seam != seam ||
      old.bookLayout != bookLayout ||
      old.bookPage != bookPage ||
      old.bookReadingOrder != bookReadingOrder ||
      old.previewOpen != previewOpen ||
      old.statusMessage != statusMessage;
}
