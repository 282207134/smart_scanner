import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:smart_scanner/core/document_vision.dart';
import 'package:smart_scanner/core/models.dart';

/// A light ID-1 card (85.6 × 54 mm) on a dark mat, with a darker shadow along
/// its right and bottom edges like an overhead lamp produces.
Uint8List _cardOnMat() {
  final image = img.Image(width: 2400, height: 1800);
  img.fill(image, color: img.ColorRgb8(30, 30, 30));
  const left = 800, top = 600, width = 856, height = 540;
  img.fillRect(
    image,
    x1: left + 12,
    y1: top + 12,
    x2: left + width + 30,
    y2: top + height + 30,
    color: img.ColorRgb8(4, 4, 4),
  );
  img.fillRect(
    image,
    x1: left,
    y1: top,
    x2: left + width - 1,
    y2: top + height - 1,
    radius: 30,
    color: img.ColorRgb8(238, 238, 232),
  );
  img.fillRect(
    image,
    x1: left + 60,
    y1: top + 120,
    x2: left + 260,
    y2: top + 400,
    color: img.ColorRgb8(90, 80, 70),
  );
  return Uint8List.fromList(img.encodeJpg(image, quality: 95));
}

void main() {
  test('自动裁切贴合卡片边缘，不带入阴影和背景', () {
    final output = DocumentVision.process(
      VisionRequest(_cardOnMat(), cut: CutMode.auto),
    );
    final card = img.decodeImage(output.images.single)!;
    expect(card.width, closeTo(856, 856 * .02));
    expect(card.height, closeTo(540, 540 * .02));
    expect(card.width / card.height, closeTo(85.6 / 54, .03));
  });
}
