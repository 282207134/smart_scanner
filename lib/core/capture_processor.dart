import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Processing used when the vendor's still-photo command does not respond.
class CaptureProcessor {
  static Uint8List fromFrame({
    required Uint8List rgb,
    required int width,
    required int height,
    required int canvasW,
    required int canvasH,
    int rotation = 0,
    int colorMode = 0,
    int cutMode = 0,
    List<int>? cutRect,
    bool smartEdge = false,
    bool removeBg = false,
  }) {
    var image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgb.buffer,
      bytesOffset: rgb.offsetInBytes,
      numChannels: 3,
      order: img.ChannelOrder.rgb,
    );
    if (rotation % 4 != 0) {
      image = img.copyRotate(image, angle: (rotation % 4) * 90);
    }
    if (cutMode == 2 && cutRect != null && cutRect[2] > 0 && cutRect[3] > 0) {
      final scale = math.min(canvasW / image.width, canvasH / image.height);
      final left = (canvasW - image.width * scale) / 2;
      final top = (canvasH - image.height * scale) / 2;
      final x = ((cutRect[0] - left) / scale).round().clamp(0, image.width - 1);
      final y = ((cutRect[1] - top) / scale).round().clamp(0, image.height - 1);
      final right = ((cutRect[0] + cutRect[2] - left) / scale).round().clamp(
        x + 1,
        image.width,
      );
      final bottom = ((cutRect[1] + cutRect[3] - top) / scale).round().clamp(
        y + 1,
        image.height,
      );
      image = img.copyCrop(
        image,
        x: x,
        y: y,
        width: right - x,
        height: bottom - y,
      );
    } else if (cutMode == 1 || smartEdge) {
      image = _paperBounds(image);
    }
    if (colorMode == 1 || colorMode == 2) img.grayscale(image);
    if (colorMode == 2) {
      final histogram = List<int>.filled(256, 0);
      for (final pixel in image) {
        histogram[pixel.r.toInt()]++;
      }
      final threshold = _otsu(histogram).clamp(60, 220);
      for (final pixel in image) {
        final v = pixel.r > threshold ? 255 : 0;
        pixel.setRgb(v, v, v);
      }
    } else if (colorMode >= 3 || removeBg) {
      // Lift paper shadows while preserving colored stamps and text.
      for (final pixel in image) {
        num lift(num n) => ((n - 30) * 255 / 195).round().clamp(0, 255);
        pixel.setRgb(lift(pixel.r), lift(pixel.g), lift(pixel.b));
      }
    }
    return Uint8List.fromList(img.encodeJpg(image, quality: 95));
  }

  static int _otsu(List<int> histogram) {
    var total = 0, sum = 0;
    for (var i = 0; i < 256; i++) {
      total += histogram[i];
      sum += i * histogram[i];
    }
    var count = 0, partial = 0, threshold = 127;
    double best = -1;
    for (var i = 0; i < 256; i++) {
      count += histogram[i];
      partial += i * histogram[i];
      if (count == 0 || count == total) continue;
      final difference = partial / count - (sum - partial) / (total - count);
      final variance = count * (total - count) * difference * difference;
      if (variance > best) {
        best = variance;
        threshold = i;
      }
    }
    return threshold;
  }

  // Conservatively detect a light sheet on a dark scanning mat. Ambiguous
  // scenes keep the complete image rather than cutting off document content.
  static img.Image _paperBounds(img.Image original) {
    final small = img.copyResize(
      original,
      width: math.min(256, original.width),
    );
    final histogram = List<int>.filled(256, 0);
    final luminance = Uint8List(small.width * small.height);
    for (final p in small) {
      final v = (p.r * .299 + p.g * .587 + p.b * .114).round();
      luminance[p.y * small.width + p.x] = v;
      histogram[v]++;
    }
    final threshold = _otsu(histogram).clamp(100, 220);
    final visited = Uint8List(luminance.length);
    List<int>? best;
    var bestCount = 0;
    for (var start = 0; start < luminance.length; start++) {
      if (visited[start] != 0 || luminance[start] <= threshold) continue;
      final queue = <int>[start];
      visited[start] = 1;
      var minX = small.width, minY = small.height, maxX = 0, maxY = 0;
      for (var i = 0; i < queue.length; i++) {
        final n = queue[i], x = n % small.width, y = n ~/ small.width;
        minX = math.min(minX, x);
        maxX = math.max(maxX, x);
        minY = math.min(minY, y);
        maxY = math.max(maxY, y);
        for (final next in [
          if (x > 0) n - 1,
          if (x + 1 < small.width) n + 1,
          if (y > 0) n - small.width,
          if (y + 1 < small.height) n + small.width,
        ]) {
          if (visited[next] == 0 && luminance[next] > threshold) {
            visited[next] = 1;
            queue.add(next);
          }
        }
      }
      final area = (maxX - minX + 1) * (maxY - minY + 1);
      if (queue.length > bestCount &&
          queue.length > luminance.length * .08 &&
          queue.length / area > .65 &&
          area < luminance.length * .92 &&
          minX > 0 &&
          minY > 0 &&
          maxX < small.width - 1 &&
          maxY < small.height - 1) {
        best = [minX, minY, maxX + 1, maxY + 1];
        bestCount = queue.length;
      }
    }
    if (best == null) return original;
    final sx = original.width / small.width,
        sy = original.height / small.height;
    final x = (best[0] * sx - 2).round().clamp(0, original.width - 1);
    final y = (best[1] * sy - 2).round().clamp(0, original.height - 1);
    final right = (best[2] * sx + 2).round().clamp(x + 1, original.width);
    final bottom = (best[3] * sy + 2).round().clamp(y + 1, original.height);
    return img.copyCrop(
      original,
      x: x,
      y: y,
      width: right - x,
      height: bottom - y,
    );
  }
}
