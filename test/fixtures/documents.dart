import 'dart:typed_data';

import 'package:image/image.dart' as img;

Uint8List documentFixture({bool multiple = false}) {
  final image = img.Image(width: 1000, height: 700);
  img.fill(image, color: img.ColorRgb8(25, 32, 35));
  img.fillPolygon(
    image,
    vertices: [
      img.Point(110, 100),
      img.Point(470, 70),
      img.Point(490, 580),
      img.Point(90, 600),
    ],
    color: img.ColorRgb8(244, 240, 235),
  );
  for (var y = 160; y < 540; y += 35) {
    img.drawLine(
      image,
      x1: 150,
      y1: y,
      x2: 420,
      y2: y - 12,
      color: img.ColorRgb8(70, 75, 80),
      thickness: 3,
    );
  }
  if (multiple) {
    img.fillPolygon(
      image,
      vertices: [
        img.Point(610, 130),
        img.Point(880, 155),
        img.Point(900, 535),
        img.Point(590, 550),
      ],
      color: img.ColorRgb8(215, 237, 250),
    );
  }
  return Uint8List.fromList(img.encodePng(image));
}
