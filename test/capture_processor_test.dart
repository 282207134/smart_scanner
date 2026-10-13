import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:smart_scanner/core/capture_processor.dart';
import 'package:smart_scanner/core/document_exporter.dart';

void main() {
  img.Image process(
    img.Image source, {
    int rotation = 0,
    int color = 0,
    int cut = 0,
    List<int>? rect,
    int cw = 100,
    int ch = 100,
  }) => img.decodeJpg(
    CaptureProcessor.fromFrame(
      rgb: Uint8List.fromList(source.getBytes(order: img.ChannelOrder.rgb)),
      width: source.width,
      height: source.height,
      canvasW: cw,
      canvasH: ch,
      rotation: rotation,
      colorMode: color,
      cutMode: cut,
      cutRect: rect,
    ),
  )!;

  test('备用拍照保持原始像素尺寸，旋转后交换宽高', () {
    final source = img.Image(width: 160, height: 90);
    final output = process(source, rotation: 1);
    expect(output.width, 90);
    expect(output.height, 160);
  });
  test('手动裁切按预览留白映射到原图', () {
    final source = img.Image(width: 200, height: 100);
    img.fill(source, color: img.ColorRgb8(255, 0, 0));
    final output = process(source, cut: 2, rect: [25, 25, 50, 50]);
    expect(output.width, 100);
    expect(output.height, 100);
    expect(output.getPixel(50, 50).r, greaterThan(240));
  });
  test('灰度和黑白输出改变实际图像像素', () {
    final source = img.Image(width: 40, height: 30);
    img.fill(source, color: img.ColorRgb8(180, 40, 70));
    for (var x = 20; x < 40; x++) {
      for (var y = 0; y < 30; y++) {
        source.setPixelRgb(x, y, 240, 240, 240);
      }
    }
    final gray = process(source, color: 1).getPixel(5, 5);
    expect((gray.r - gray.g).abs(), lessThan(3));
    expect((gray.g - gray.b).abs(), lessThan(3));
    final bw = process(source, color: 2);
    expect(bw.getPixel(5, 5).r, lessThan(5));
    expect(bw.getPixel(30, 5).r, greaterThan(250));
  });
  test('自动裁切保留亮纸边缘，模糊场景保留原图', () {
    final source = img.Image(width: 200, height: 150);
    for (var y = 25; y < 125; y++) {
      for (var x = 40; x < 160; x++) {
        source.setPixelRgb(x, y, 240, 240, 240);
      }
    }
    final output = process(source, cut: 1);
    expect(output.width, inInclusiveRange(120, 130));
    expect(output.height, inInclusiveRange(100, 110));
    img.fill(source, color: img.ColorRgb8(240, 240, 240));
    expect(process(source, cut: 1).width, 200);
  });
  test('双页分割顺序和内容准确，不丢失奇数宽度像素', () {
    final source = img.Image(width: 101, height: 80);
    img.fill(source, color: img.ColorRgb8(255, 0, 0));
    for (var x = 50; x < 101; x++) {
      for (var y = 0; y < 80; y++) {
        source.setPixelRgb(x, y, 0, 0, 255);
      }
    }
    final halves = DocumentExporter.splitBook(
      Uint8List.fromList(img.encodePng(source)),
    ).map(img.decodeJpg).toList();
    expect(halves[0]!.width, 50);
    expect(halves[1]!.width, 51);
    expect(halves[0]!.getPixel(10, 10).r, greaterThan(240));
    expect(halves[1]!.getPixel(10, 10).b, greaterThan(240));
  });
}
