import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dartcv4/dartcv.dart' as cv;

import 'document_geometry.dart';
import 'models.dart';

class VisionRequest {
  final Uint8List bytes;
  final CutMode cut;
  final ColorEffect effect;
  final DocumentRegion? manual;
  final BookPage bookPage;
  final bool smartEdge, removeBackground;
  const VisionRequest(
    this.bytes, {
    this.cut = CutMode.none,
    this.effect = ColorEffect.native,
    this.manual,
    this.bookPage = BookPage.left,
    this.smartEdge = false,
    this.removeBackground = false,
  });
}

class VisionOutput {
  final List<Uint8List> images;
  final List<DocumentRegion> regions;
  final String notice;
  const VisionOutput(this.images, this.regions, {this.notice = ''});
}

/// Portable OpenCV processing. All native allocations stay inside one isolate.
class DocumentVision {
  static List<DocumentRegion> detectRgb((Uint8List, int, int) input) {
    final rgb = cv.Mat.fromList(
      input.$3,
      input.$2,
      cv.MatType.CV_8UC3,
      input.$1,
    );
    try {
      return detect(rgb, rgb: true);
    } finally {
      rgb.dispose();
    }
  }

  static List<DocumentRegion> detectBytes(Uint8List bytes) {
    final source = cv.imdecode(bytes, cv.IMREAD_COLOR);
    try {
      return detect(source);
    } finally {
      source.dispose();
    }
  }

  static List<DocumentRegion> detect(cv.Mat source, {bool rgb = false}) {
    if (source.isEmpty) return [];
    final owned = <cv.Mat>[];
    cv.Mat keep(cv.Mat m) {
      owned.add(m);
      return m;
    }

    try {
      final scale = math.min(1.0, 900 / math.max(source.cols, source.rows));
      final small = keep(
        cv.resize(source, (
          (source.cols * scale).round(),
          (source.rows * scale).round(),
        )),
      );
      final gray = keep(
        cv.cvtColor(small, rgb ? cv.COLOR_RGB2GRAY : cv.COLOR_BGR2GRAY),
      );
      final blurred = keep(cv.gaussianBlur(gray, (7, 7), 1.5));
      final kernel = keep(cv.getStructuringElement(cv.MORPH_RECT, (5, 5)));
      final masks = <cv.Mat>[];
      for (final thresholds in [(12.0, 40.0), (30.0, 90.0), (60.0, 160.0)]) {
        final edges = keep(cv.canny(blurred, thresholds.$1, thresholds.$2));
        masks.add(keep(cv.morphologyEx(edges, cv.MORPH_CLOSE, kernel)));
      }
      final binary = keep(
        cv.threshold(blurred, 0, 255, cv.THRESH_BINARY | cv.THRESH_OTSU).$2,
      );
      masks.add(keep(cv.morphologyEx(binary, cv.MORPH_CLOSE, kernel)));
      final candidates = <DocumentRegion>[];
      for (final mask in masks) {
        final (contours, hierarchy) = cv.findContours(
          mask,
          cv.RETR_LIST,
          cv.CHAIN_APPROX_SIMPLE,
        );
        try {
          for (var i = 0; i < contours.length; i++) {
            final contour = contours[i];
            try {
              final area = cv.contourArea(contour) / (small.cols * small.rows);
              if (area < .012 || area > .96) continue;
              final perimeter = cv.arcLength(contour, true);
              for (final epsilon in [.015, .025, .04, .06]) {
                final poly = cv.approxPolyDP(
                  contour,
                  perimeter * epsilon,
                  true,
                );
                try {
                  if (poly.length != 4 || !cv.isContourConvex(poly)) continue;
                  final points = <ScanPoint>[];
                  for (var j = 0; j < 4; j++) {
                    final p = poly[j];
                    points.add(ScanPoint(p.x / small.cols, p.y / small.rows));
                    p.dispose();
                  }
                  final ordered = _order(points);
                  final region = DocumentRegion(ordered);
                  if (!region.valid ||
                      region.area < .012 ||
                      region.area > .96) {
                    continue;
                  }
                  final minSide = List.generate(
                    4,
                    (j) => ordered[j].distanceTo(ordered[(j + 1) % 4]),
                  ).reduce(math.min);
                  if (minSide < .065) continue;
                  // Exclude frame/mat boundaries and long cables.
                  if (ordered
                          .where(
                            (p) =>
                                (p.x < .015 || p.x > .985) &&
                                (p.y < .015 || p.y > .985),
                          )
                          .length >=
                      2) {
                    continue;
                  }
                  final rectangleQuality = _angleQuality(
                    ordered,
                    small.cols,
                    small.rows,
                  );
                  if (rectangleQuality < .45) continue;
                  final ratio = area / region.area;
                  if (ratio < .68 || ratio > 1.3) continue;
                  candidates.add(
                    DocumentRegion(ordered, confidence: rectangleQuality),
                  );
                  break;
                } finally {
                  poly.dispose();
                }
              }
            } finally {
              contour.dispose();
            }
          }
        } finally {
          contours.dispose();
          hierarchy.dispose();
        }
      }
      candidates.sort((a, b) => b.area.compareTo(a.area));
      final result = <DocumentRegion>[];
      for (final candidate in candidates) {
        if (result.any((r) => r.overlap(candidate) > .75)) continue;
        result.add(candidate);
        if (result.length == 12) break;
      }
      // Reading order: rows from top to bottom, then left to right.
      result.sort(
        (a, b) => ((a.top - b.top).abs() < .08)
            ? a.left.compareTo(b.left)
            : a.top.compareTo(b.top),
      );
      return result;
    } finally {
      for (final m in owned.reversed) {
        m.dispose();
      }
    }
  }

  static List<ScanPoint> _order(List<ScanPoint> points) {
    final cx = points.map((p) => p.x).reduce((a, b) => a + b) / 4;
    final cy = points.map((p) => p.y).reduce((a, b) => a + b) / 4;
    points.sort(
      (a, b) => math
          .atan2(a.y - cy, a.x - cx)
          .compareTo(math.atan2(b.y - cy, b.x - cx)),
    );
    var start = 0;
    for (var i = 1; i < 4; i++) {
      if (points[i].x + points[i].y < points[start].x + points[start].y) {
        start = i;
      }
    }
    return List.generate(4, (i) => points[(start + i) % 4]);
  }

  static double _angleQuality(List<ScanPoint> p, int w, int h) {
    double worst = 0;
    for (var i = 0; i < 4; i++) {
      final a = p[(i + 3) % 4], b = p[i], c = p[(i + 1) % 4];
      final ax = (a.x - b.x) * w,
          ay = (a.y - b.y) * h,
          bx = (c.x - b.x) * w,
          by = (c.y - b.y) * h;
      final cosine =
          (ax * bx + ay * by).abs() /
          math.sqrt((ax * ax + ay * ay) * (bx * bx + by * by));
      worst = math.max(worst, cosine);
    }
    return 1 - worst;
  }

  static VisionOutput process(VisionRequest request) {
    final source = cv.imdecode(request.bytes, cv.IMREAD_COLOR);
    if (source.isEmpty) {
      source.dispose();
      throw StateError('无法解码扫描图像');
    }
    try {
      List<DocumentRegion> regions = [];
      if (request.cut == CutMode.manual) {
        if (request.manual?.valid != true) {
          throw StateError('请调整四个裁切角点，使它们贴合文档边缘');
        }
        regions = [request.manual!];
      } else if (request.cut == CutMode.auto ||
          request.cut == CutMode.multiImg ||
          request.smartEdge) {
        regions = detect(source);
        if (regions.isEmpty && request.cut != CutMode.none) {
          throw StateError('没有检测到完整文档边界，请将文件放入画面、留出边缘，或使用手动裁切');
        }
        if (request.cut != CutMode.multiImg && regions.isNotEmpty) {
          regions = [regions.reduce((a, b) => a.area > b.area ? a : b)];
        }
      }
      final images = <Uint8List>[];
      if (regions.isEmpty) {
        images.add(
          _encodeEffect(source, request.effect, request.removeBackground),
        );
      } else {
        for (final region in regions) {
          final cropped = warp(source, region);
          try {
            images.add(
              _encodeEffect(cropped, request.effect, request.removeBackground),
            );
          } finally {
            cropped.dispose();
          }
        }
      }
      return VisionOutput(images, regions);
    } finally {
      source.dispose();
    }
  }

  static cv.Mat warp(cv.Mat source, DocumentRegion region) {
    final p = region.corners;
    double distance(ScanPoint a, ScanPoint b) => math.sqrt(
      math.pow((a.x - b.x) * source.cols, 2) +
          math.pow((a.y - b.y) * source.rows, 2),
    );
    final w = math
        .max(distance(p[0], p[1]), distance(p[3], p[2]))
        .round()
        .clamp(16, source.cols * 2);
    final h = math
        .max(distance(p[0], p[3]), distance(p[1], p[2]))
        .round()
        .clamp(16, source.rows * 2);
    final src = cv.VecPoint2f.generate(
      4,
      (i) => cv.Point2f(p[i].x * (source.cols - 1), p[i].y * (source.rows - 1)),
    );
    final dst = cv.VecPoint2f.generate(
      4,
      (i) => cv.Point2f(
        [0.0, w - 1.0, w - 1.0, 0.0][i],
        [0.0, 0.0, h - 1.0, h - 1.0][i],
      ),
    );
    final matrix = cv.getPerspectiveTransform2f(src, dst);
    try {
      return cv.warpPerspective(source, matrix, (
        w,
        h,
      ), borderMode: cv.BORDER_REPLICATE);
    } finally {
      matrix.dispose();
      src.dispose();
      dst.dispose();
    }
  }

  static Uint8List _encodeEffect(
    cv.Mat source,
    ColorEffect effect,
    bool background,
  ) {
    final owned = <cv.Mat>[];
    cv.Mat keep(cv.Mat m) {
      owned.add(m);
      return m;
    }

    try {
      var result = source;
      if (effect == ColorEffect.grayscale || effect == ColorEffect.blackWhite) {
        result = keep(cv.cvtColor(source, cv.COLOR_BGR2GRAY));
        if (effect == ColorEffect.blackWhite) {
          result = keep(
            cv.adaptiveThreshold(
              result,
              255,
              cv.ADAPTIVE_THRESH_GAUSSIAN_C,
              cv.THRESH_BINARY,
              31,
              12,
            ),
          );
        }
      } else if (effect == ColorEffect.docOpt ||
          effect == ColorEffect.whitePaperStamp ||
          background) {
        final blur = keep(
          cv.gaussianBlur(source, (0, 0), math.max(10, source.cols / 35)),
        );
        result = keep(cv.divide(source, blur, scale: 245));
      }
      final (ok, bytes) = cv.imencode('.png', result);
      if (!ok) throw StateError('扫描图像编码失败');
      return bytes;
    } finally {
      for (final m in owned.reversed) {
        m.dispose();
      }
    }
  }

  /// Map a curved page using a calibrated vertical displacement field.
  /// Each curve contains uniformly spaced samples across page width and its
  /// destination baseline. Public for repeatable pixel-level validation.
  static cv.Mat remapCurves(cv.Mat page, List<(double, List<double>)> curves) {
    final w = page.cols, h = page.rows;
    if (curves.isEmpty) return page.clone();
    final mapX = Float32List(w * h), mapY = Float32List(w * h);
    final anchors = [
      (0.0, List<double>.filled(17, 0)),
      ...curves,
      (h - 1.0, List<double>.filled(17, h - 1.0)),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    double sample(List<double> values, double x) {
      final index = x / (w - 1) * (values.length - 1),
          i = index.floor().clamp(0, values.length - 2),
          t = index - i;
      return values[i] * (1 - t) + values[i + 1] * t;
    }

    var section = 0;
    for (var y = 0; y < h; y++) {
      while (section < anchors.length - 2 && y > anchors[section + 1].$1) {
        section++;
      }
      final a = anchors[section], b = anchors[section + 1];
      final t = ((y - a.$1) / (b.$1 - a.$1)).clamp(0.0, 1.0);
      for (var x = 0; x < w; x++) {
        final i = y * w + x;
        mapX[i] = x.toDouble();
        mapY[i] =
            (sample(a.$2, x.toDouble()) * (1 - t) +
                    sample(b.$2, x.toDouble()) * t)
                .clamp(0, h - 1.0);
      }
    }
    final mx = cv.Mat.fromList(h, w, cv.MatType.CV_32FC1, mapX),
        my = cv.Mat.fromList(h, w, cv.MatType.CV_32FC1, mapY);
    try {
      return cv.remap(
        page,
        mx,
        my,
        cv.INTER_CUBIC,
        borderMode: cv.BORDER_REPLICATE,
      );
    } finally {
      mx.dispose();
      my.dispose();
    }
  }

  static List<(double, List<double>)> textCurves(cv.Mat page) {
    final owned = <cv.Mat>[];
    cv.Mat keep(cv.Mat m) {
      owned.add(m);
      return m;
    }

    try {
      final scale = math.min(1.0, 1000 / page.cols),
          w = (page.cols * scale).round(),
          h = (page.rows * scale).round();
      final small = keep(cv.resize(page, (w, h)));
      final gray = keep(cv.cvtColor(small, cv.COLOR_BGR2GRAY));
      final mask = keep(
        cv.adaptiveThreshold(
          gray,
          255,
          cv.ADAPTIVE_THRESH_GAUSSIAN_C,
          cv.THRESH_BINARY_INV,
          31,
          13,
        ),
      );
      final kernel = keep(
        cv.getStructuringElement(cv.MORPH_RECT, (math.max(9, w ~/ 40), 1)),
      );
      final joined = keep(cv.morphologyEx(mask, cv.MORPH_CLOSE, kernel));
      // Table borders are connected vertically, so their full contour cannot
      // serve as one text baseline. Isolate horizontal strokes first.
      final thicken = keep(cv.getStructuringElement(cv.MORPH_RECT, (1, 3)));
      final lineKernel = keep(
        cv.getStructuringElement(cv.MORPH_RECT, (math.max(12, w ~/ 40), 1)),
      );
      final lineJoin = keep(
        cv.getStructuringElement(cv.MORPH_RECT, (math.max(20, w ~/ 15), 3)),
      );
      final thick = keep(cv.dilate(mask, thicken));
      final strokes = keep(cv.morphologyEx(thick, cv.MORPH_OPEN, lineKernel));
      final ruled = keep(cv.morphologyEx(strokes, cv.MORPH_CLOSE, lineJoin));
      final curves = <(double, List<double>)>[];
      for (final lines in [joined, ruled]) {
        final (contours, hierarchy) = cv.findContours(
          lines,
          cv.RETR_EXTERNAL,
          cv.CHAIN_APPROX_NONE,
        );
        try {
          for (var i = 0; i < contours.length; i++) {
            final contour = contours[i];
            try {
              final points = <(int, int)>[];
              for (var j = 0; j < contour.length; j++) {
                final p = contour[j];
                points.add((p.x, p.y));
                p.dispose();
              }
              if (points.isEmpty) continue;
              final minX = points.map((p) => p.$1).reduce(math.min),
                  maxX = points.map((p) => p.$1).reduce(math.max);
              final minY = points.map((p) => p.$2).reduce(math.min),
                  maxY = points.map((p) => p.$2).reduce(math.max);
              if (maxX - minX < w * .5 ||
                  maxY - minY > h * .12 ||
                  minY < h * .04 ||
                  maxY > h * .96) {
                continue;
              }
              final bins = List.generate(17, (_) => <int>[]);
              for (final p in points) {
                bins[(p.$1 / (w - 1) * 16).round().clamp(0, 16)].add(p.$2);
              }
              final valid = bins.where((b) => b.isNotEmpty).length;
              if (valid < 10) continue;
              final values = List<double?>.generate(17, (j) {
                final b = bins[j]..sort();
                return b.isEmpty
                    ? null
                    : b[(b.length * .75).floor().clamp(0, b.length - 1)] /
                          scale;
              });
              for (var j = 0; j < 17; j++) {
                if (values[j] != null) continue;
                var l = j - 1, r = j + 1;
                while (l >= 0 && values[l] == null) {
                  l--;
                }
                while (r < 17 && values[r] == null) {
                  r++;
                }
                values[j] = l < 0
                    ? values[r]
                    : r == 17
                    ? values[l]
                    : values[l]! +
                          (values[r]! - values[l]!) * (j - l) / (r - l);
              }
              final samples = List<double>.generate(
                17,
                (j) =>
                    (values[math.max(0, j - 1)]! +
                        values[j]! +
                        values[math.min(16, j + 1)]!) /
                    3,
              );
              final baseline = samples.reduce((a, b) => a + b) / 17;
              if (samples.reduce(math.max) - samples.reduce(math.min) >
                  page.rows * .1) {
                continue;
              }
              curves.add((baseline, samples));
            } finally {
              contour.dispose();
            }
          }
        } finally {
          contours.dispose();
          hierarchy.dispose();
        }
      }
      curves.sort((a, b) => a.$1.compareTo(b.$1));
      final filtered = <(double, List<double>)>[];
      for (final curve in curves) {
        if (filtered.isNotEmpty &&
            (curve.$1 - filtered.last.$1 < page.rows * .018 ||
                List.generate(
                      17,
                      (i) => curve.$2[i] - filtered.last.$2[i],
                    ).reduce(math.min) <
                    page.rows * .008)) {
          continue;
        }
        filtered.add(curve);
      }
      return filtered;
    } finally {
      for (final m in owned.reversed) {
        m.dispose();
      }
    }
  }

  static BookLayout detectBookRgb((Uint8List, int, int, double?) input) {
    final rgb = cv.Mat.fromList(
      input.$3,
      input.$2,
      cv.MatType.CV_8UC3,
      input.$1,
    );
    final source = cv.cvtColor(rgb, cv.COLOR_RGB2BGR);
    try {
      return detectBook(source, seam: input.$4);
    } finally {
      source.dispose();
      rgb.dispose();
    }
  }

  /// A guide is a prior, not a fixed half-image cut. Automatic detection searches
  /// the spread; a manually moved guide restricts the capture calibration.
  static double bookSpine(cv.Mat source, double hint) {
    final regions = detect(source);
    if (regions.isEmpty) return hint;
    final spread = regions.reduce((a, b) => a.area > b.area ? a : b);
    final line = _bookSpineLine(source, spread, null, prior: hint);
    return (line.$1 + line.$2) / 2;
  }

  static (double, double) _bookSpineLine(
    cv.Mat source,
    DocumentRegion spread,
    double? hint, {
    double? prior,
  }) {
    final scale = math.min(1.0, 900 / source.cols);
    final small = cv.resize(source, (
      (source.cols * scale).round(),
      (source.rows * scale).round(),
    ));
    final gray = cv.cvtColor(small, cv.COLOR_BGR2GRAY);
    final width = spread.right - spread.left;
    final center = hint ?? prior ?? (spread.left + spread.right) / 2;
    final left =
        ((hint == null ? spread.left + width * .23 : hint - .065) * small.cols)
            .round()
            .clamp(0, small.cols - 2);
    final right =
        ((hint == null ? spread.right - width * .23 : hint + .065) * small.cols)
            .round()
            .clamp(left + 2, small.cols);
    final rect = cv.Rect(left, 0, right - left, small.rows);
    final strip = cv.Mat.fromMat(gray, roi: rect, copy: true);
    rect.dispose();
    final blur = cv.gaussianBlur(strip, (3, 3), .8);
    final edges = cv.canny(blur, 20, 60);
    final height = (spread.bottom - spread.top) * small.rows;
    final lines = cv.HoughLinesP(
      edges,
      1,
      math.pi / 360,
      30,
      minLineLength: height * .58,
      maxLineGap: height * .08,
    );
    try {
      var result = (center, center), best = 0.0;
      final pixels = edges.data;
      final y0 = (spread.top * small.rows + height * .06).round();
      final y1 = (spread.bottom * small.rows - height * .06).round();
      for (var i = 0; i < lines.rows; i++) {
        final line = lines.at<cv.Vec4i>(i, 0);
        try {
          final dx = line.val3 - line.val1, dy = line.val4 - line.val2;
          if (dy.abs() < height * .58 || dx.abs() > height * .3) continue;
          final slope = dx / dy;
          final intercept = line.val1 - slope * line.val2;
          final top = (left + intercept) / small.cols;
          final bottom = (left + intercept + slope * small.rows) / small.cols;
          final mid = (top + bottom) / 2;
          if (mid < spread.left + width * .15 ||
              mid > spread.right - width * .15) {
            continue;
          }
          // A crease continues through the page height. Text columns and table
          // borders usually supply only a short or intermittent vertical edge.
          var support = 0;
          for (var j = 0; j < 40; j++) {
            final y = (y0 + (y1 - y0) * j / 39).round().clamp(
              0,
              edges.rows - 1,
            );
            final x = (intercept + slope * y).round();
            var found = false;
            for (var offset = -3; offset <= 3; offset++) {
              final px = x + offset;
              if (px >= 0 &&
                  px < edges.cols &&
                  pixels[y * edges.cols + px] > 0) {
                found = true;
              }
            }
            if (found) support++;
          }
          final coverage = support / 40;
          if (coverage < .55) continue;
          final score =
              dy.abs() / height + coverage * 2 - (mid - center).abs() / width;
          if (score > best) {
            best = score;
            result = (top.clamp(.05, .95), bottom.clamp(.05, .95));
          }
        } finally {
          line.dispose();
        }
      }
      return result;
    } finally {
      lines.dispose();
      edges.dispose();
      blur.dispose();
      strip.dispose();
      gray.dispose();
      small.dispose();
    }
  }

  static BookLayout detectBook(cv.Mat source, {double? seam}) {
    final regions = detect(source);
    if (regions.isEmpty) return const BookLayout([]);
    DocumentRegion largest(Iterable<DocumentRegion> items) =>
        items.reduce((a, b) => a.area > b.area ? a : b);
    final spread = largest(regions);
    final principal = regions
        .where((r) => r.area >= spread.area * .25)
        .toList();
    final center =
        seam ??
        (principal.map((r) => r.left).reduce(math.min) +
                principal.map((r) => r.right).reduce(math.max)) /
            2;
    final left = principal.where((r) => (r.left + r.right) / 2 < center);
    final right = principal.where((r) => (r.left + r.right) / 2 >= center);
    List<DocumentRegion> pages;
    final aspect =
        (spread.right - spread.left) *
        source.cols /
        ((spread.bottom - spread.top) * source.rows);
    if (left.isNotEmpty &&
        right.isNotEmpty &&
        largest(left).overlap(largest(right)) < .1) {
      pages = [largest(left), largest(right)];
    } else if (aspect < .95) {
      return BookLayout([spread]);
    } else {
      final line = _bookSpineLine(source, spread, seam);
      final p = spread.corners;
      ScanPoint intersect(ScanPoint a, ScanPoint b, double margin) {
        final dx = b.x - a.x, dy = b.y - a.y;
        final slope = line.$2 - line.$1;
        final t = ((line.$1 + margin + slope * a.y - a.x) / (dx - slope * dy))
            .clamp(0.0, 1.0);
        return ScanPoint(a.x + dx * t, a.y + dy * t);
      }

      final fallback = [
        DocumentRegion([
          p[0],
          intersect(p[0], p[1], .003),
          intersect(p[3], p[2], .003),
          p[3],
        ]),
        DocumentRegion([
          intersect(p[0], p[1], -.003),
          p[1],
          p[2],
          intersect(p[3], p[2], -.003),
        ]),
      ];
      // Detect each page independently so the two sloping top/bottom borders
      // are not forced into the four corners of one flat spread.
      final scale = math.min(1.0, 900 / math.max(source.cols, source.rows));
      final small = cv.resize(source, (
        (source.cols * scale).round(),
        (source.rows * scale).round(),
      ));
      try {
        pages = List.generate(2, (side) {
          final data = Uint8List.fromList(small.data);
          for (var y = 0; y < small.rows; y++) {
            final x =
                ((line.$1 +
                            (line.$2 - line.$1) * y / small.rows +
                            (side == 0 ? .003 : -.003)) *
                        small.cols)
                    .round()
                    .clamp(0, small.cols);
            final start = y * small.cols * 3;
            data.fillRange(
              side == 0 ? start + x * 3 : start,
              side == 0 ? start + small.cols * 3 : start + x * 3,
              0,
            );
          }
          final half = cv.Mat.fromList(
            small.rows,
            small.cols,
            cv.MatType.CV_8UC3,
            data,
          );
          try {
            // Mask boundaries can form a large quadrilateral in the background.
            // Keep page refinements close to the detected spread's extent.
            final margin = (spread.bottom - spread.top) * .05;
            final found = detect(half).where(
              (r) =>
                  r.area >= fallback[side].area * .6 &&
                  r.top >= spread.top - margin &&
                  r.bottom <= spread.bottom + margin,
            );
            return found.isEmpty ? fallback[side] : largest(found);
          } finally {
            half.dispose();
          }
        });
      } finally {
        small.dispose();
      }
    }
    ScanPoint midpoint(ScanPoint a, ScanPoint b) =>
        ScanPoint((a.x + b.x) / 2, (a.y + b.y) / 2);
    return BookLayout(
      pages,
      spineTop: midpoint(pages[0].corners[1], pages[1].corners[0]),
      spineBottom: midpoint(pages[0].corners[2], pages[1].corners[3]),
    );
  }

  static VisionOutput flattenBook((VisionRequest, FlattenMode, double?) args) {
    final request = args.$1, mode = args.$2;
    if (mode == FlattenMode.none) return process(request);
    final source = cv.imdecode(request.bytes, cv.IMREAD_COLOR);
    if (source.isEmpty) {
      source.dispose();
      throw StateError('无法读取书籍图像');
    }
    final images = <Uint8List>[];
    try {
      final layout = detectBook(source, seam: args.$3?.clamp(.15, .85));
      if (layout.pages.isEmpty) throw StateError('未检测到完整书页边界，请留出四周边缘');
      if (mode != FlattenMode.singlePage && layout.pages.length != 2) {
        throw StateError('未检测到两张完整书页，请留出四周边缘或选择单页展平');
      }
      final regions = mode == FlattenMode.singlePage
          ? [
              layout.pages[layout.pages.length == 1
                  ? 0
                  : request.bookPage.index],
            ]
          : layout.pages;
      var notice = '';
      for (final region in regions) {
        final page = warp(source, region);
        try {
          if (mode == FlattenMode.split) {
            images.add(
              _encodeEffect(page, request.effect, request.removeBackground),
            );
            continue;
          }
          final curves = textCurves(page);
          if (curves.length < 3) {
            images.add(
              _encodeEffect(page, request.effect, request.removeBackground),
            );
            notice = '文字行不足，本次仅矫正书页透视';
            continue;
          }
          final flattened = remapCurves(page, curves);
          try {
            images.add(
              _encodeEffect(
                flattened,
                request.effect,
                request.removeBackground,
              ),
            );
          } finally {
            flattened.dispose();
          }
        } finally {
          page.dispose();
        }
      }
      return VisionOutput(images, regions, notice: notice);
    } finally {
      source.dispose();
    }
  }
}
