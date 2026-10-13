import 'dart:math' as math;

/// Coordinates are relative to the actual camera image, excluding letterboxing.
class ScanPoint {
  final double x, y;
  const ScanPoint(this.x, this.y);
  ScanPoint clamp() => ScanPoint(x.clamp(0, 1), y.clamp(0, 1));
  double distanceTo(ScanPoint p) =>
      math.sqrt(math.pow(x - p.x, 2) + math.pow(y - p.y, 2));
}

class DocumentRegion {
  /// Clockwise, top-left, top-right, bottom-right, bottom-left.
  final List<ScanPoint> corners;
  final double confidence;
  const DocumentRegion(this.corners, {this.confidence = 1});
  static const inset = DocumentRegion([
    ScanPoint(.15, .12),
    ScanPoint(.85, .12),
    ScanPoint(.85, .88),
    ScanPoint(.15, .88),
  ]);
  double get area {
    double sum = 0;
    for (var i = 0; i < corners.length; i++) {
      final a = corners[i], b = corners[(i + 1) % corners.length];
      sum += a.x * b.y - b.x * a.y;
    }
    return sum.abs() / 2;
  }

  double get left => corners.map((p) => p.x).reduce(math.min);
  double get right => corners.map((p) => p.x).reduce(math.max);
  double get top => corners.map((p) => p.y).reduce(math.min);
  double get bottom => corners.map((p) => p.y).reduce(math.max);
  bool get valid {
    if (corners.length != 4 || area < .003) return false;
    if (corners.any(
      (p) =>
          !p.x.isFinite ||
          !p.y.isFinite ||
          p.x < 0 ||
          p.x > 1 ||
          p.y < 0 ||
          p.y > 1,
    )) {
      return false;
    }
    double? direction;
    for (var i = 0; i < 4; i++) {
      final a = corners[i], b = corners[(i + 1) % 4], c = corners[(i + 2) % 4];
      final cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
      if (cross.abs() < .0001) return false;
      direction ??= cross.sign;
      if (cross.sign != direction) return false;
    }
    return true;
  }

  DocumentRegion replaceCorner(int index, ScanPoint point) => DocumentRegion(
    List.generate(4, (i) => i == index ? point.clamp() : corners[i]),
  );
  double overlap(DocumentRegion other) {
    final intersection =
        math.max(0, math.min(right, other.right) - math.max(left, other.left)) *
        math.max(0, math.min(bottom, other.bottom) - math.max(top, other.top));
    return intersection /
        math.min(
          (right - left) * (bottom - top),
          (other.right - other.left) * (other.bottom - other.top),
        );
  }
}

class BookLayout {
  final List<DocumentRegion> pages;
  final ScanPoint? spineTop, spineBottom;
  const BookLayout(this.pages, {this.spineTop, this.spineBottom});

  double? spineX(double y) {
    final a = spineTop, b = spineBottom;
    if (a == null || b == null || (b.y - a.y).abs() < .001) return null;
    return a.x + (b.x - a.x) * (y - a.y) / (b.y - a.y);
  }
}
