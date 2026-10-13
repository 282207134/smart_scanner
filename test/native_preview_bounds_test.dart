import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Mac 原生拖动在缩放、旋转和画布尺寸变化后都不会越界', () async {
    final source = await File('macos/Runner/MainFlutterWindow.swift')
        .readAsString();
    final helper = source.substring(
      source.indexOf('enum PreviewBounds {'),
      source.indexOf('final class NativeScanner:'),
    );
    final directory = await Directory.systemTemp.createTemp('preview_bounds_');
    try {
      final script = File('${directory.path}/bounds.swift');
      await script.writeAsString('''
import Foundation
$helper
let canvas = CGSize(width: 1000, height: 800)
for image in [CGSize(width: 4160, height: 3120), CGSize(width: 1920, height: 1080), CGSize(width: 3120, height: 4160)] {
  for viewport in [canvas, CGSize(width: 400, height: 1000)] {
    let maximum = PreviewBounds.scale(image: image, canvas: viewport, maximized: true)
    assert(abs(image.height * maximum - viewport.height) < 0.000001)
    let compact = PreviewBounds.scale(image: image, canvas: viewport, maximized: false)
    assert(image.width * compact <= viewport.width * 0.85 + 0.000001)
    assert(image.height * compact <= viewport.height * 0.85 + 0.000001)
    assert(maximum > compact)
  }
}
var checks = 0
for image in [CGSize(width: 640, height: 360), CGSize(width: 1500, height: 1200), CGSize(width: 360, height: 640), CGSize(width: 1000, height: 800)] {
  for x in [-100000.0, 0.0, 100000.0] {
    for y in [-100000.0, 0.0, 100000.0] {
      let pan = PreviewBounds.clampPan(CGPoint(x: x, y: y), image: image, canvas: canvas)
      let origin = CGPoint(x: (canvas.width - image.width) / 2 + pan.x, y: (canvas.height - image.height) / 2 + pan.y)
      if image.width <= canvas.width { assert(origin.x >= 0 && origin.x + image.width <= canvas.width) }
      else { assert(origin.x <= 0 && origin.x + image.width >= canvas.width) }
      if image.height <= canvas.height { assert(origin.y >= 0 && origin.y + image.height <= canvas.height) }
      else { assert(origin.y <= 0 && origin.y + image.height >= canvas.height) }
      checks += 1
    }
  }
}
let first = PreviewBounds.clampPan(CGPoint(x: 100000, y: 100000), image: CGSize(width: 640, height: 360), canvas: canvas)
let reverse = PreviewBounds.clampPan(CGPoint(x: first.x - 1, y: first.y - 1), image: CGSize(width: 640, height: 360), canvas: canvas)
assert(reverse.x == first.x - 1 && reverse.y == first.y - 1)
let resized = PreviewBounds.clampPan(first, image: CGSize(width: 600, height: 400), canvas: CGSize(width: 600, height: 400))
assert(resized.x == 0 && resized.y == 0)
print("passed \\(checks) bounds checks, reverse drag and resize")
''');
      final result = await Process.run('/usr/bin/swift', [script.path]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('passed 36 bounds checks'));
    } finally {
      await directory.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);
}
